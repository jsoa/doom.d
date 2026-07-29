;;; expose-review-store.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'expose-log)
(require 'expose-transport)

(defgroup expose-review nil
  "Branch-level AI code review sessions for Expose."
  :group 'expose)

(defcustom expose-review-session-version 1
  "Current Expose review session data version."
  :type 'integer
  :group 'expose-review)

(defun expose-review-store-git-path (project-root path)
  "Return Git-local PATH for PROJECT-ROOT using `git rev-parse --git-path'."

  (with-temp-buffer
    (let ((default-directory project-root))
      (unless (= 0
                 (call-process
                  "git"
                  nil
                  t
                  nil
                  "rev-parse"
                  "--git-path"
                  path))
        (error "Could not resolve git path: %s" path))

      (expand-file-name
       (string-trim
        (buffer-string))
       project-root))))

(defun expose-review-store-root (project-root)
  "Return the Expose review storage root for PROJECT-ROOT."

  (expose-review-store-git-path
   project-root
   "expose/reviews"))

(defun expose-review-store-branch-slug (branch)
  "Return a filesystem-safe slug for BRANCH."

  (let ((slug
         (replace-regexp-in-string
          "[^[:alnum:]._+-]+"
          "-"
          (or branch "detached"))))

    (if (string-empty-p slug)
        "detached"
      slug)))

(defun expose-review-store-session-dir (project-root branch)
  "Return the review session directory for PROJECT-ROOT and BRANCH."

  (expand-file-name
   (expose-review-store-branch-slug branch)
   (expose-review-store-root project-root)))

(defun expose-review-store-active-path (project-root branch)
  "Return active review path for PROJECT-ROOT and BRANCH."

  (expand-file-name
   "active.eld"
   (expose-review-store-session-dir project-root branch)))

(defun expose-review-store-history-dir (project-root branch)
  "Return history directory for PROJECT-ROOT and BRANCH."

  (expand-file-name
   "history"
   (expose-review-store-session-dir project-root branch)))

(defun expose-review-store-timestamp ()
  "Return a timestamp suitable for review history filenames."

  (format-time-string "%Y%m%dT%H%M%S"))

(defun expose-review-store-history-path (project-root branch)
  "Return a new history file path for PROJECT-ROOT and BRANCH."

  (expand-file-name
   (format "%s.eld"
           (expose-review-store-timestamp))
   (expose-review-store-history-dir project-root branch)))

(defun expose-review-store-save-session (session)
  "Persist SESSION and return its path."

  (let* ((project-root
          (plist-get session :project-root))

         (branch
          (plist-get session :branch))

         (path
          (expose-review-store-active-path
           project-root
           branch)))

    (make-directory
     (file-name-directory path)
     t)

    (with-temp-file path
      (let ((print-length nil)
            (print-level nil)
            (print-circle t))

        (prin1
         (expose-transport-readable-value session)
         (current-buffer))

        (insert "\n")))

    (expose-log
     "ReviewStore"
     "Saved review session to %s."
     path)

    path))

(defun expose-review-store-read-session-file (path)
  "Read review session data from PATH.

Return nil when PATH cannot be read or parsed."

  (when (file-readable-p path)

    (condition-case error

        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (read (current-buffer)))

      (error
       (expose-log
        "ReviewStore"
        "Failed to read review session %s: %s"
        path
        (error-message-string error))

       nil))))

(defun expose-review-store-read-active (project-root branch)
  "Read active review for PROJECT-ROOT and BRANCH."

  (expose-review-store-read-session-file
   (expose-review-store-active-path
    project-root
    branch)))

(defun expose-review-store-active-exists-p (project-root branch)
  "Return non-nil if an active review exists for PROJECT-ROOT and BRANCH."

  (file-exists-p
   (expose-review-store-active-path
    project-root
    branch)))

(defun expose-review-store-delete-active (project-root branch)
  "Delete active review for PROJECT-ROOT and BRANCH."

  (let ((path
         (expose-review-store-active-path
          project-root
          branch)))

    (when (file-exists-p path)
      (delete-file path)

      (expose-log
       "ReviewStore"
       "Deleted active review %s."
       path))))

(defun expose-review-store-complete-active (project-root branch)
  "Archive and delete active review for PROJECT-ROOT and BRANCH."

  (let* ((session
          (expose-review-store-read-active
           project-root
           branch))

         (active-path
          (expose-review-store-active-path
           project-root
           branch))

         (history-path
          (expose-review-store-history-path
           project-root
           branch)))

    (unless session
      (user-error "No active Expose review found"))

    (setq session
          (plist-put session :state 'done))

    (setq session
          (plist-put session :updated-at
                     (format-time-string "%Y-%m-%dT%H:%M:%S%z")))

    ;; Save the completed state before archiving.
    (expose-review-store-save-session session)

    (make-directory
     (file-name-directory history-path)
     t)

    (copy-file
     active-path
     history-path
     t)

    (delete-file active-path)

    (expose-log
     "ReviewStore"
     "Archived review to %s."
     history-path)

    history-path))

(provide 'expose-review-store)
