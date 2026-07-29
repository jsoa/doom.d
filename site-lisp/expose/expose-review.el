;;; expose-review.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'expose-log)
(require 'expose-provider)
(require 'expose-transport)
(require 'expose-review-buffer)
(require 'expose-review-context)
(require 'expose-review-request)
(require 'expose-review-store)
(require 'expose-review-source)

(defvar expose-provider-default)

(defcustom expose-review-provider-timeout-seconds 180
  "Seconds to wait for an AI review provider before failing the review."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-progress-interval-seconds 5
  "Seconds between Expose Review progress updates."
  :type 'integer
  :group 'expose-review)

(defun expose-review-progress-started-at (session)
  "Return progress start time for SESSION."

  (or
   (plist-get session :progress-started-at)
   (float-time)))

(defun expose-review-progress-elapsed-seconds (session)
  "Return elapsed progress seconds for SESSION."

  (floor
   (-
    (float-time)
    (expose-review-progress-started-at session))))

(defun expose-review-progress-message (session)
  "Return human-readable progress message for SESSION."

  (let ((elapsed
         (expose-review-progress-elapsed-seconds session)))

    (pcase (plist-get session :state)
      ('preparing
       (format "Preparing review context... %ds elapsed" elapsed))

      ('sending
       (format "Waiting for AI provider response... %ds elapsed" elapsed))

      (_
       nil))))

(defun expose-review-touch-progress (original-session)
  "Update progress metadata for ORIGINAL-SESSION while it is still active."

  (let ((latest-session
         (expose-review-latest-session-for original-session)))

    (when (and
           latest-session
           (expose-review-session-still-active-p
            original-session
            latest-session)
           (memq
            (plist-get latest-session :state)
            '(preparing sending running)))

      (let ((message
             (expose-review-progress-message latest-session)))

        (when message
          (setq latest-session
                (plist-put latest-session :progress-message message))

          (setq latest-session
                (plist-put latest-session :updated-at
                           (expose-review-context-now)))

          (expose-review-store-save-session latest-session)
          (expose-review-buffer-refresh-open latest-session)

          (expose-log
           "Review"
           "%s"
           message)))

      ;; Schedule the next heartbeat only if the same session is still active.
      (run-at-time
       expose-review-progress-interval-seconds
       nil
       #'expose-review-touch-progress
       original-session))))

(defun expose-review-provider ()
  "Return provider used for Expose reviews."

  (if (boundp 'expose-provider-default)
      expose-provider-default
    'clipboard))

(defun expose-review-session-active-state-p (state)
  "Return non-nil if STATE represents an active review run."

  (memq state
        '(running preparing sending)))

(defun expose-review-session-still-active-p (original-session latest-session)
  "Return non-nil if ORIGINAL-SESSION still matches LATEST-SESSION."

  (and latest-session

       (equal
        (plist-get latest-session :id)
        (plist-get original-session :id))

       (expose-review-session-active-state-p
        (plist-get latest-session :state))))

(defun expose-review-latest-session-for (session)
  "Return latest active session matching SESSION's project and branch."

  (expose-review-store-read-active
   (plist-get session :project-root)
   (plist-get session :branch)))

(defun expose-review-current-project-session ()
  "Return active review session for the current project, or nil."

  (let* ((project-root
          (expose-review-context-project-root))

         (branch
          (expose-review-context-current-branch project-root)))

    (expose-review-store-read-active
     project-root
     branch)))

(defun expose-review-open-or-start ()
  "Open existing review session or start a new one."

  (interactive)

  (let* ((project-root
          (expose-review-context-project-root))

         (branch
          (expose-review-context-current-branch project-root))

         (existing-session
          (expose-review-store-read-active
           project-root
           branch)))

    (if existing-session

        (progn
          (expose-log
           "Review"
           "Opening existing review session %s."
           (plist-get existing-session :id))

          (expose-review-buffer-open existing-session))

      (expose-review-start-new project-root))))

(defun expose-review-start-new (project-root)
  "Start a new review session for PROJECT-ROOT."

  (let* ((provider
          (expose-review-provider))

         (session
          (expose-review-context-create-session
           project-root
           provider)))

    (expose-log
     "Review"
     "Starting new review session %s."
     (plist-get session :id))

    (expose-review-store-save-session session)
    (expose-review-buffer-open session)

    ;; Let the dashboard render before the provider starts working.
    (run-at-time
     0
     nil
     #'expose-review-start-async
     session)

    session))

(defun expose-review-start-async (session)
  "Start async AI review for SESSION."

  (setq session
        (plist-put session :state 'preparing))

  (setq session
        (plist-put session :progress-started-at
                   (float-time)))

  (setq session
        (plist-put session :progress-message
                   "Preparing review context..."))

  (setq session
        (plist-put session :updated-at
                   (expose-review-context-now)))

  (expose-review-store-save-session session)
  (expose-review-buffer-refresh-open session)

  (run-at-time
   expose-review-progress-interval-seconds
   nil
   #'expose-review-touch-progress
   session)

  (expose-log
   "Review"
   "Preparing review context for %s."
   (plist-get session :id))

  (if (fboundp 'make-thread)

      (make-thread
       (lambda ()
         (expose-review-prepare-context-thread session))
       "expose-review-context")

    ;; Fallback for older Emacs: still runs soon, but on main thread.
    (run-at-time
     0
     nil
     #'expose-review-prepare-context-thread
     session)))

(defun expose-review-prepare-context-thread (session)
  "Prepare review context for SESSION, then continue on the main event loop."

  (condition-case error

      (let* ((project-root
              (plist-get session :project-root))

             (context
              (expose-review-context-build-ai project-root))

             (document
              (expose-review-request-build-document context)))

        ;; Hop back through the timer queue before touching UI/session state.
        (run-at-time
         0
         nil
         #'expose-review-send-prepared-context
         session
         context
         document))

    (error
     (run-at-time
      0
      nil
      #'expose-review-handle-error
      session
      (error-message-string error)))))

(defun expose-review-send-prepared-context (original-session context document)
  "Send prepared review CONTEXT and DOCUMENT for ORIGINAL-SESSION."

  (let ((latest-session
         (expose-review-latest-session-for original-session)))

    (if (not
         (expose-review-session-still-active-p
          original-session
          latest-session))

        (expose-log
         "Review"
         "Ignoring stale prepared review context for %s."
         (plist-get original-session :id))

      (let* ((provider
              (plist-get latest-session :provider))

             (review-input-stats
              (plist-get context :review-input-stats))

             (completed nil)

             timeout-timer)

        (setq latest-session
              (plist-put latest-session :state 'sending))

        (setq latest-session
              (plist-put latest-session :progress-started-at
                         (float-time)))

        (setq latest-session
              (plist-put latest-session :review-input-stats review-input-stats))

        (setq latest-session
              (plist-put latest-session :diagnostics
                         (plist-get context :diagnostics)))

        (setq latest-session
              (plist-put latest-session :updated-at
                         (expose-review-context-now)))

        (expose-review-store-save-session latest-session)
        (expose-review-buffer-refresh-open latest-session)

        (run-at-time
         expose-review-progress-interval-seconds
         nil
         #'expose-review-touch-progress
         latest-session)

        (expose-log
         "Review"
         "Sending review request for %s using %s. Request size: %d bytes."
         (plist-get latest-session :id)
         provider
         (length document))

        ;; Provider-level watchdog. If Copilot/Codex/etc. hangs or waits for
        ;; interactive input, the review should fail loudly instead of staying
        ;; in `sending' forever.
        (setq timeout-timer
              (run-at-time
               expose-review-provider-timeout-seconds
               nil
               (lambda ()
                 (unless completed
                   (setq completed t)

                   (expose-review-handle-error
                    latest-session
                    (format
                     "AI provider timed out after %d seconds while using %s."
                     expose-review-provider-timeout-seconds
                     provider))))))

        (expose-transport-send-document-async
         provider
         document

         (lambda (response-text)
           (unless completed
             (setq completed t)

             (when (timerp timeout-timer)
               (cancel-timer timeout-timer))

             (expose-review-handle-response
              latest-session
              response-text)))

         (plist-get latest-session :project-root)

         (lambda (error-data)
           (setq completed t)

           (when (timerp timeout-timer)
             (cancel-timer timeout-timer))

           (expose-review-handle-error
            latest-session
            (error-message-string error-data))))))))

(defun expose-review-handle-response (original-session response)
  "Handle provider RESPONSE for ORIGINAL-SESSION."

  (let* ((response-text
          (expose-transport-response-text response))

         (project-root
          (plist-get original-session :project-root))

         (branch
          (plist-get original-session :branch))

         (latest-session
          (expose-review-store-read-active
           project-root
           branch)))

    (if (not
         (expose-review-session-still-active-p
          original-session
          latest-session))

        (expose-log
         "Review"
         "Ignoring stale review response for %s."
         (plist-get original-session :id))

      ;; Always persist the raw provider response before parsing. If parsing
      ;; fails, the failed session still contains the exact response that broke.
      (setq latest-session
            (plist-put latest-session :raw-response response-text))

      (setq latest-session
            (plist-put latest-session :updated-at
                       (expose-review-context-now)))

      (expose-review-store-save-session latest-session)

      (condition-case error

          (let ((items
                 (expose-review-request-parse-items response-text)))

            (setq latest-session
                  (plist-put
                   latest-session
                   :items
                   (expose-transport-readable-value items)))

            (setq latest-session
                  (plist-put latest-session :state 'ready))

            (setq latest-session
                  (plist-put latest-session :error nil))

            (setq latest-session
                  (plist-put latest-session :updated-at
                             (expose-review-context-now)))

            (expose-review-store-save-session latest-session)
            (expose-review-buffer-refresh-open latest-session)

            (expose-review-source-refresh-project
             (plist-get latest-session :project-root))

            (expose-log
             "Review"
             "Review session %s completed with %d items."
             (plist-get latest-session :id)
             (length items)))

        (error
         (setq latest-session
               (plist-put latest-session :state 'failed))

         (setq latest-session
               (plist-put
                latest-session
                :error
                (format
                 "Could not parse AI review JSON: %s"
                 (error-message-string error))))

         (setq latest-session
               (plist-put latest-session :updated-at
                          (expose-review-context-now)))

         (expose-review-store-save-session latest-session)
         (expose-review-buffer-refresh-open latest-session)

         (expose-review-source-refresh-project
          (plist-get latest-session :project-root))

         (expose-log
          "Review"
          "Review session %s failed to parse JSON: %s"
          (plist-get latest-session :id)
          (error-message-string error)))))))

(defun expose-review-handle-error (original-session error-message)
  "Mark ORIGINAL-SESSION failed with ERROR-MESSAGE."

  (let ((latest-session
         (expose-review-latest-session-for original-session)))

    (if (not
         (expose-review-session-still-active-p
          original-session
          latest-session))

        (expose-log
         "Review"
         "Ignoring stale review error for %s: %s"
         (plist-get original-session :id)
         error-message)

      (setq latest-session
            (plist-put latest-session :state 'failed))

      (setq latest-session
            (plist-put latest-session :error error-message))

      (setq latest-session
            (plist-put latest-session :updated-at
                       (expose-review-context-now)))

      (expose-review-store-save-session latest-session)
      (expose-review-buffer-refresh-open latest-session)

      (expose-review-source-refresh-project
       (plist-get latest-session :project-root))

      (expose-log
       "Review"
       "Review session %s failed: %s"
       (plist-get latest-session :id)
       error-message))))

(defun expose-review-complete-current ()
  "Complete the current review session."

  (interactive)

  (let ((session
         (expose-review-buffer-current-session)))

    (unless session
      (user-error "No Expose review session in this buffer"))

    (when (yes-or-no-p "Complete this Expose review? ")

      (let* ((project-root
              (plist-get session :project-root))

             (branch
              (plist-get session :branch))

             (history-path
              (expose-review-store-complete-active
               project-root
               branch)))

        ;; Completing the review removes the active session, so source buffers
        ;; should drop fringe markers, review hovers, and ExReview minor mode.
        (when (fboundp 'expose-review-source-refresh-project)
          (expose-review-source-refresh-project project-root))

        (message
         "Expose review completed: %s"
         history-path)

        (kill-buffer
         (current-buffer))))))

(defun expose-review-rerun-current ()
  "Complete current review and start a fresh one."

  (interactive)

  (let ((session
         (expose-review-buffer-current-session)))

    (unless session
      (user-error "No Expose review session in this buffer"))

    (when (yes-or-no-p "Rerun Expose review? Current active review will be archived. ")

      (let ((project-root
             (plist-get session :project-root))

            (branch
             (plist-get session :branch)))

        (expose-review-store-complete-active
         project-root
         branch)

        ;; Drop old review source overlays before the new review starts.
        (when (fboundp 'expose-review-source-refresh-project)
          (expose-review-source-refresh-project project-root))

        (kill-buffer
         (current-buffer))

        (expose-review-start-new project-root)))))

(provide 'expose-review)
