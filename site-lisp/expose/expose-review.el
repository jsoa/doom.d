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
  "Return the current Expose review provider."

  (if (boundp 'expose-provider-default)
      expose-provider-default
    'clipboard))

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

  (let* ((project-root
          (plist-get session :project-root))

         (provider
          (plist-get session :provider))

         (context
          (expose-review-context-build-ai project-root))

         (document
          (expose-review-request-build-document context)))

    (expose-log
     "Review"
     "Sending review request for %s using %s."
     (plist-get session :id)
     provider)

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

(defun expose-review-session-still-active-p (original latest)
  "Return non-nil if ORIGINAL still matches LATEST active session."

  (and latest
       (equal
        (plist-get original :id)
        (plist-get latest :id))
       (eq
        (plist-get latest :state)
        'running)))

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
