;;; expose-review.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'expose-log)
(require 'expose-provider)
(require 'expose-review-buffer)
(require 'expose-review-context)
(require 'expose-review-request)
(require 'expose-review-store)

(defvar expose-provider-default)

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
        (plist-put session :updated-at
                   (expose-review-context-now)))

  (expose-review-store-save-session session)
  (expose-review-buffer-refresh-open session)

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

(defun expose-review-send-prepared-context (session context document)
  "Send prepared review CONTEXT and DOCUMENT for SESSION."

  (let* ((provider
          (plist-get session :provider))

         (review-input-stats
          (plist-get context :review-input-stats)))

    (setq session
          (plist-put session :state 'sending))

    (setq session
          (plist-put session :review-input-stats review-input-stats))

    (setq session
          (plist-put session :diagnostics
                     (plist-get context :diagnostics)))

    (setq session
          (plist-put session :updated-at
                     (expose-review-context-now)))

    (expose-review-store-save-session session)
    (expose-review-buffer-refresh-open session)

    (expose-log
     "Review"
     "Sending review request for %s using %s. Request size: %d bytes."
     (plist-get session :id)
     provider
     (length document))

    (condition-case error
        (expose-provider-send-async
         provider
         document
         (lambda (response)
           (expose-review-handle-response
            session
            response)))

      (error
       (expose-review-handle-error
        session
        (error-message-string error))))))

(defun expose-review-handle-response (original-session response)
  "Handle provider RESPONSE for ORIGINAL-SESSION."

  (let* ((project-root
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

      (condition-case error

          (let ((items
                 (expose-review-request-parse-items response)))

            (setq latest-session
                  (plist-put latest-session :items items))

            (setq latest-session
                  (plist-put latest-session :state 'ready))

            (setq latest-session
                  (plist-put latest-session :raw-response
                             (substring-no-properties
                              (or response ""))))

            (setq latest-session
                  (plist-put latest-session :updated-at
                             (expose-review-context-now)))

            (expose-review-store-save-session latest-session)
            (expose-review-buffer-refresh-open latest-session)

            (expose-log
             "Review"
             "Review session %s completed with %d items."
             (plist-get latest-session :id)
             (length items)))

        (error
         (expose-review-handle-error
          latest-session
          (error-message-string error)))))))

(defun expose-review-handle-error (session message)
  "Mark SESSION failed with MESSAGE."

  (let* ((project-root
          (plist-get session :project-root))

         (branch
          (plist-get session :branch))

         (latest-session
          (or
           (expose-review-store-read-active
            project-root
            branch)
           session)))

    (setq latest-session
          (plist-put latest-session :state 'failed))

    (setq latest-session
          (plist-put latest-session :error message))

    (setq latest-session
          (plist-put latest-session :updated-at
                     (expose-review-context-now)))

    (expose-review-store-save-session latest-session)
    (expose-review-buffer-refresh-open latest-session)

    (expose-log
     "Review"
     "Review session %s failed: %s"
     (plist-get latest-session :id)
     message)))

(defun expose-review-complete-current ()
  "Complete the current review session."

  (interactive)

  (let ((session
         (expose-review-buffer-current-session)))

    (unless session
      (user-error "No Expose review session in this buffer"))

    (when (yes-or-no-p "Complete this Expose review? ")

      (let ((history-path
             (expose-review-store-complete-active
              (plist-get session :project-root)
              (plist-get session :branch))))

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

        (ignore-errors
          (expose-review-store-complete-active
           project-root
           branch))

        (kill-buffer
         (current-buffer))

        (expose-review-start-new project-root)))))

(provide 'expose-review)
