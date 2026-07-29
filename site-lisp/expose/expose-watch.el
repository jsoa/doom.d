;;; expose-watch.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-provider)
(require 'expose-hover)
(require 'expose-review-request)
(require 'expose-transport)
(require 'expose-redact)
(require 'nerd-icons nil t)

(defgroup expose-watch nil
  "Background watch reviews for changed hunks."
  :group 'expose)

(defcustom expose-watch-show-fringe-markers nil
  "When non-nil, show Expose Watch markers in the right fringe.

This is disabled by default because diagnostics, Git gutters, and other
tools may already use the same fringe space."
  :type 'boolean
  :group 'expose-watch)

(defcustom expose-watch-response-storage-max-length 50000
  "Maximum number of provider response characters stored by Expose Watch.

Set to nil to store full responses."
  :type '(choice integer
          (const :tag "No limit" nil))
  :group 'expose-watch)

(defcustom expose-watch-context-lines 60
  "Number of source context lines included around each changed hunk."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-max-hunks-per-run 4
  "Maximum changed hunks reviewed in one Expose Watch run."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-max-items-per-run 3
  "Maximum findings requested from one Expose Watch run."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-mode-line-icon "nf-fa-eye"
  "Nerd Icons icon name shown when Expose Watch is active."
  :type 'string
  :group 'expose-watch)

(defcustom expose-watch-hover-delay 0.25
  "Delay before showing Expose Watch hover."
  :type 'number
  :group 'expose-watch)

(defvar expose-provider-default)

(defvar-local expose-watch-source-overlays nil
  "Source overlays for Expose Watch comments in the current buffer.")

(defvar-local expose-watch-hover-timer nil
  "Idle timer for Expose Watch hovers.")

(defvar-local expose-watch-state 'idle
  "Current Expose Watch state for this buffer.

Expected values are `idle', `running', and `error'.")

(defvar-local expose-watch-visible-item-count 0
  "Number of visible Expose Watch comments in this buffer.")

(defvar-local expose-watch-pending-hashes nil
  "Hunk hashes currently being reviewed for this buffer.")

(defvar expose-watch--restoring nil
  "Non-nil while restoring watch mode from stored state.")

(defconst expose-watch-list-buffer-name
  "*EXPOSE Watch*")

(defvar-local expose-watch-list-project-root nil
  "Project root displayed by the current Expose Watch list buffer.")

;;; ---------------------------------------------------------------------------
;;; Faces / Fringe
;;; ---------------------------------------------------------------------------

(defface expose-watch-hunk-face
  '((t (:background "#262b33" :extend t)))
  "Subtle face for reviewed changed hunks."
  :group 'expose-watch)

(defface expose-watch-item-face
  '((t (:inherit diff-refine-added :extend t)))
  "Face for concrete Expose Watch comment lines."
  :group 'expose-watch)

(defface expose-watch-fringe-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for Expose Watch right-fringe markers."
  :group 'expose-watch)

(defface expose-watch-mode-line-face
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Face for active Expose Watch mode-line indicator."
  :group 'expose-watch)

(defface expose-watch-mode-line-running-face
  '((t (:inherit warning :weight bold)))
  "Face for running Expose Watch mode-line indicator."
  :group 'expose-watch)

(defface expose-watch-mode-line-error-face
  '((t (:inherit error :weight bold)))
  "Face for failed Expose Watch mode-line indicator."
  :group 'expose-watch)

(defface expose-watch-list-title-face
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Face for Expose Watch list titles."
  :group 'expose-watch)

(defface expose-watch-list-meta-face
  '((t (:inherit shadow)))
  "Face for Expose Watch list metadata."
  :group 'expose-watch)

(defface expose-watch-list-label-face
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Face for Expose Watch list labels."
  :group 'expose-watch)

(defface expose-watch-high-face
  '((t (:inherit error :weight bold)))
  "Face for high severity Expose Watch comments."
  :group 'expose-watch)

(defface expose-watch-medium-face
  '((t (:inherit warning :weight bold)))
  "Face for medium severity Expose Watch comments."
  :group 'expose-watch)

(defface expose-watch-low-face
  '((t (:inherit success :weight bold)))
  "Face for low severity Expose Watch comments."
  :group 'expose-watch)

(defface expose-watch-info-face
  '((t (:inherit font-lock-doc-face :weight bold)))
  "Face for info severity Expose Watch comments."
  :group 'expose-watch)

(defun expose-watch-apply-faces ()

  "Force Expose Watch faces to current theme values."

  (set-face-attribute
   'expose-watch-fringe-face
   nil
   :foreground 'unspecified
   :inherit 'font-lock-keyword-face))

(define-fringe-bitmap
  'expose-watch-fringe-bitmap
  [#b00000000
   #b01110000
   #b01110000
   #b01110000
   #b01110000
   #b01110000
   #b00000000
   #b00000000]
  nil
  nil
  'center)

(expose-watch-apply-faces)

;;; ---------------------------------------------------------------------------
;;; Mode line
;;; ---------------------------------------------------------------------------

(defun expose-watch-mode-line-icon ()
  "Return the Expose Watch mode-line icon."

  (if (fboundp 'nerd-icons-faicon)

      (nerd-icons-faicon
       expose-watch-mode-line-icon
       :height 0.9
       :v-adjust -0.02)

    "👁"))

(defun expose-watch-mode-line-face ()
  "Return mode-line face for current Expose Watch state."

  (pcase expose-watch-state
    ('running
     'expose-watch-mode-line-running-face)

    ('error
     'expose-watch-mode-line-error-face)

    (_
     'expose-watch-mode-line-face)))

(defun expose-watch-mode-line-state-label ()
  "Return compact state label for Expose Watch mode line."

  (pcase expose-watch-state
    ('running
     "…")

    ('error
     "!")

    (_
     "")))

(defun expose-watch-mode-line-count-label ()
  "Return compact visible item count label for Expose Watch mode line."

  (if (> expose-watch-visible-item-count 0)

      (format
       ":%d"
       expose-watch-visible-item-count)

    ""))

(defun expose-watch-mode-line ()
  "Return Expose Watch mode-line indicator."

  (propertize
   (format
    " %s%s%s "
    (expose-watch-mode-line-icon)
    (expose-watch-mode-line-state-label)
    (expose-watch-mode-line-count-label))
   'face
   (expose-watch-mode-line-face)
   'help-echo
   (pcase expose-watch-state
     ('running
      "Expose Watch is reviewing changed hunks")

     ('error
      "Expose Watch is active, but the last review failed")

     (_
      "Expose Watch is active for this buffer"))))

(defun expose-watch-refresh-mode-line ()
  "Refresh mode-line for Expose Watch."

  (force-mode-line-update t))

(defvar expose-watch-mode-line-indicator
  '(:eval
    (when (bound-and-true-p expose-watch-mode)
      (expose-watch-mode-line)))
  "Mode-line construct for Expose Watch.")

(defun expose-watch-install-mode-line ()
  "Install Expose Watch mode-line indicator.

This installs into `mode-line-misc-info' so normal Emacs and
Doom modeline's `misc-info' segment can display it without requiring
user config to redefine the whole modeline."

  (unless (member
           expose-watch-mode-line-indicator
           mode-line-misc-info)

    (setq mode-line-misc-info
          (append
           mode-line-misc-info
           (list expose-watch-mode-line-indicator)))))

(defun expose-watch-uninstall-mode-line ()
  "Remove Expose Watch mode-line indicator."

  (setq mode-line-misc-info
        (remove
         expose-watch-mode-line-indicator
         mode-line-misc-info)))

;;; ---------------------------------------------------------------------------
;;; Basic helpers
;;; ---------------------------------------------------------------------------

(defun expose-watch-refresh-running-state (&optional failed)
  "Refresh Expose Watch running state.

When FAILED is non-nil, show the error state. Otherwise keep showing
running while any hunk hashes are still pending."

  (cond
   (failed
    (expose-watch-set-state 'error))

   (expose-watch-pending-hashes
    (expose-watch-set-state 'running))

   (t
    (expose-watch-set-state 'idle))))


(defun expose-watch-finish-pending-hashes (hashes &optional failed)
  "Remove HASHES from pending Watch state and refresh mode line.

When FAILED is non-nil, leave Watch in the error state."

  (setq expose-watch-pending-hashes
        (seq-difference
         expose-watch-pending-hashes
         hashes
         #'string=))

  (expose-watch-refresh-running-state failed))

(defun expose-watch-now ()
  "Return current timestamp string."

  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun expose-watch-storage-response (response)
  "Return provider RESPONSE normalized for persistent storage."

  (expose-transport-storage-response
   response
   expose-watch-response-storage-max-length))

(defun expose-watch-string (value)
  "Return VALUE as a display string."

  (cond
   ((null value)
    "")

   ((stringp value)
    value)

   ((symbolp value)
    (symbol-name value))

   ((numberp value)
    (number-to-string value))

   (t
    (format "%s" value))))

(defun expose-watch-blank-p (value)
  "Return non-nil when VALUE is nil or blank."

  (string-empty-p
   (string-trim
    (expose-watch-string value))))

(defun expose-watch-plist-get-any (plist keys)
  "Return first value in PLIST matching one of KEYS."

  (catch 'value
    (dolist (key keys)
      (when (plist-member plist key)
        (throw 'value
               (plist-get plist key))))
    nil))

(defun expose-watch-escape (text)
  "Escape TEXT for XML-ish request bodies."

  (let ((value
         (expose-watch-string text)))

    (setq value
          (replace-regexp-in-string "&" "&amp;" value t t))

    (setq value
          (replace-regexp-in-string "<" "&lt;" value t t))

    (setq value
          (replace-regexp-in-string ">" "&gt;" value t t))

    value))

(defun expose-watch-project-root ()
  "Return current project root, or raise an error."

  (if-let ((project
            (project-current nil)))

      (file-name-as-directory
       (project-root project))

    (user-error "Expose Watch requires a project")))

(defun expose-watch-current-project-root ()
  "Return current project root, or nil."

  (when-let ((project
              (project-current nil)))

    (file-name-as-directory
     (project-root project))))

(defun expose-watch-buffer-file (project-root)
  "Return current buffer file relative to PROJECT-ROOT."

  (unless buffer-file-name
    (user-error "Expose Watch requires a file buffer"))

  (file-relative-name
   buffer-file-name
   project-root))

(defun expose-watch-current-buffer-file ()
  "Return current buffer file relative to its project."

  (when-let ((project-root
              (expose-watch-current-project-root)))

    (when buffer-file-name
      (file-relative-name
       buffer-file-name
       project-root))))

(defun expose-watch-call-git (project-root &rest args)
  "Run git with ARGS in PROJECT-ROOT and return stdout.

Return nil when git fails."

  (let ((default-directory project-root))

    (with-temp-buffer
      (let ((status
             (apply
              #'call-process
              "git"
              nil
              t
              nil
              args)))

        (when (= status 0)
          (buffer-string))))))

(defun expose-watch-git-path (project-root path)
  "Return git-private PATH under PROJECT-ROOT."

  (let ((result
         (expose-watch-call-git
          project-root
          "rev-parse"
          "--git-path"
          path)))

    (unless result
      (user-error "Not inside a Git repository"))

    (expand-file-name
     (string-trim result)
     project-root)))

;;; ---------------------------------------------------------------------------
;;; Storage
;;; ---------------------------------------------------------------------------

(defun expose-watch-store-dir (project-root)
  "Return Expose Watch storage directory for PROJECT-ROOT."

  (expose-watch-git-path
   project-root
   "expose/watch"))

(defun expose-watch-active-path (project-root)
  "Return active Expose Watch session path for PROJECT-ROOT."

  (expand-file-name
   "active.eld"
   (expose-watch-store-dir project-root)))

(defun expose-watch-read-file (path)
  "Read Lisp data from PATH.

If PATH contains unreadable data, move it aside and return nil."

  (when (file-readable-p path)

    (condition-case error-data

        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (read (current-buffer)))

      (error
       (let ((bad-path
              (format
               "%s.bad.%s"
               path
               (format-time-string "%Y%m%d%H%M%S"))))

         (ignore-errors
           (rename-file path bad-path t))

         (expose-log
          "Watch"
          "Failed to read %s: %s. Moved bad file to %s."
          path
          (error-message-string error-data)
          bad-path)

         nil)))))

(defun expose-watch-write-file (path data)
  "Write DATA to PATH."

  (make-directory
   (file-name-directory path)
   t)

  (with-temp-file path
    (let ((print-length nil)
          (print-level nil)
          (print-circle t))

      (prin1
       (expose-transport-readable-value data)
       (current-buffer)))))

(defun expose-watch-empty-session (project-root)
  "Return empty Expose Watch session for PROJECT-ROOT."

  (list
   :kind 'watch
   :project-root project-root
   :created-at (expose-watch-now)
   :updated-at (expose-watch-now)
   :files nil))

(defun expose-watch-load-session (project-root)
  "Load Expose Watch session for PROJECT-ROOT."

  (or
   (expose-watch-read-file
    (expose-watch-active-path project-root))
   (expose-watch-empty-session project-root)))

(defun expose-watch-save-session (session)
  "Persist Expose Watch SESSION."

  (setq session
        (plist-put
         session
         :updated-at
         (expose-watch-now)))

  (expose-watch-write-file
   (expose-watch-active-path
    (plist-get session :project-root))
   session)

  session)

(defun expose-watch-file-state (session file)
  "Return watch file state for FILE in SESSION."

  (cl-find
   file
   (plist-get session :files)
   :test #'string=
   :key
   (lambda (state)
     (plist-get state :file))))

(defun expose-watch-new-file-state (file)
  "Return new watch state for FILE."

  (list
   :file file
   :enabled t
   :created-at (expose-watch-now)
   :updated-at (expose-watch-now)
   :last-save-at nil
   :last-error nil
   :reviewed-hunks nil))

(defun expose-watch-put-file-state (session state)
  "Put file STATE into SESSION and return SESSION."

  (let* ((file
          (plist-get state :file))

         (files
          (seq-remove
           (lambda (existing)
             (string=
              file
              (plist-get existing :file)))
           (plist-get session :files))))

    (plist-put
     session
     :files
     (append files
             (list state)))))

(defun expose-watch-ensure-file-state (session file)
  "Ensure SESSION has state for FILE."

  (or
   (expose-watch-file-state session file)
   (expose-watch-new-file-state file)))

(defun expose-watch-enable-file-state (project-root file)
  "Mark FILE watched in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file)))

    (setq state
          (plist-put state :enabled t))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-disable-file-state (project-root file)
  "Mark FILE unwatched in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file)))

    (setq state
          (plist-put state :enabled nil))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-file-enabled-p (project-root file)
  "Return non-nil when FILE is watched in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-file-state session file)))

    (and state
         (plist-get state :enabled))))

(defun expose-watch-reviewed-hunk-hashes (state)
  "Return reviewed hunk hashes from file STATE."

  (mapcar
   (lambda (hunk)
     (plist-get hunk :hash))
   (plist-get state :reviewed-hunks)))

(defun expose-watch-hunk-reviewed-p (state hunk)
  "Return non-nil if HUNK was already reviewed in STATE."

  (member
   (plist-get hunk :hash)
   (expose-watch-reviewed-hunk-hashes state)))

(defun expose-watch-record-hunk (project-root file hunk items response &optional error)
  "Record reviewed HUNK for FILE in PROJECT-ROOT with ITEMS and RESPONSE."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file))

         (hash
          (plist-get hunk :hash))

         (existing
          (seq-remove
           (lambda (entry)
             (string=
              hash
              (plist-get entry :hash)))
           (plist-get state :reviewed-hunks)))

         (entry
          (list
           :hash hash
           :line-start (plist-get hunk :line-start)
           :line-end (plist-get hunk :line-end)
           :created-at (expose-watch-now)
           :items (expose-transport-readable-value items)
           :response
           (expose-watch-storage-response response)
           :error
           (when error
             (expose-watch-string error)))))

    (setq state
          (plist-put state :enabled t))

    (setq state
          (plist-put state :last-save-at
                     (expose-watch-now)))

    (setq state
          (plist-put state :last-error
                     (when error
                       (expose-watch-string error))))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (setq state
          (plist-put state :reviewed-hunks
                     (append existing
                             (list entry))))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-clear-file (project-root file)
  "Clear stored watch comments for FILE in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file)))

    (setq state
          (plist-put state :reviewed-hunks nil))

    (setq state
          (plist-put state :last-error nil))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-clear-project-session (project-root)
  "Clear all stored watch comments for PROJECT-ROOT."

  (let ((session
         (expose-watch-load-session project-root)))

    (dolist (state
             (plist-get session :files))

      (setq state
            (plist-put state :reviewed-hunks nil))

      (setq state
            (plist-put state :last-error nil)))

    (setq session
          (plist-put
           session
           :files
           (mapcar
            (lambda (state)
              (plist-put state :updated-at
                         (expose-watch-now)))
            (plist-get session :files))))

    (expose-watch-save-session session)))

;;; ---------------------------------------------------------------------------
;;; Git hunks
;;; ---------------------------------------------------------------------------

(defun expose-watch-hunk-range-end (line-start raw-length)
  "Return hunk end line from LINE-START and RAW-LENGTH."

  (let ((length
         (if raw-length
             (string-to-number raw-length)
           1)))

    (if (> length 0)
        (+ line-start
           (1- length))
      line-start)))

(defun expose-watch-hunk-hash (file line-start line-end text)
  "Return stable hash for FILE LINE-START LINE-END TEXT."

  (secure-hash
   'sha1
   (format
    "%s:%s:%s:%s"
    file
    line-start
    line-end
    text)))

(defun expose-watch-parse-diff-hunks (file diff)
  "Parse unified DIFF for FILE into changed hunks."

  (let (hunks
        current)

    (dolist (line
             (split-string
              (or diff "")
              "\n"))

      (if (string-match
           "^@@ .* \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
           line)

          (progn
            (when current
              (push current hunks))

            (let* ((line-start
                    (string-to-number
                     (match-string 1 line)))

                   (line-end
                    (expose-watch-hunk-range-end
                     line-start
                     (match-string 2 line))))

              (setq current
                    (list
                     :file file
                     :line-start line-start
                     :line-end line-end
                     :lines (list line)))))

        (when current
          (setq current
                (plist-put
                 current
                 :lines
                 (append
                  (plist-get current :lines)
                  (list line)))))))

    (when current
      (push current hunks))

    (mapcar
     (lambda (hunk)
       (let* ((text
               (string-join
                (plist-get hunk :lines)
                "\n"))

              (line-start
               (plist-get hunk :line-start))

              (line-end
               (plist-get hunk :line-end)))

         (setq hunk
               (plist-put hunk :text text))

         (setq hunk
               (plist-put hunk :hash
                          (expose-watch-hunk-hash
                           file
                           line-start
                           line-end
                           text)))

         hunk))
     (nreverse hunks))))

(defun expose-watch-current-file-diff (project-root file)
  "Return git diff for FILE in PROJECT-ROOT."

  (or
   (expose-watch-call-git
    project-root
    "diff"
    "--no-ext-diff"
    "--unified=20"
    "HEAD"
    "--"
    file)
   ""))

(defun expose-watch-current-file-hunks (project-root file)
  "Return changed hunks for FILE in PROJECT-ROOT."

  (if (expose-redact-excluded-path-p file project-root)

      (progn
        (expose-redact-log-excluded-path file project-root)
        nil)

    (expose-watch-parse-diff-hunks
     file
     (expose-watch-current-file-diff
      project-root
      file))))

;;; ---------------------------------------------------------------------------
;;; Source text / request
;;; ---------------------------------------------------------------------------

(defun expose-watch-buffer-line-count ()
  "Return number of lines in the current buffer."

  (line-number-at-pos
   (point-max)))

(defun expose-watch-line-start-position (line)
  "Return buffer position at beginning of LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))
    (point)))

(defun expose-watch-line-after-position (line)
  "Return buffer position at beginning of the line after LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0 line))
    (point)))

(defun expose-watch-numbered-text (text start-line)
  "Return TEXT with line numbers starting at START-LINE."

  (let* ((lines
          (split-string
           (or text "")
           "\n"))

         (end-line
          (+ start-line
             (max 0
                  (1- (length lines)))))

         (width
          (length
           (number-to-string end-line)))

         (line-number
          (1- start-line)))

    (mapconcat
     (lambda (line)
       (setq line-number
             (1+ line-number))

       (format
        (format "%%%dd | %%s" width)
        line-number
        line))
     lines
     "\n")))

(defun expose-watch-hunk-context (hunk)
  "Return numbered source context for HUNK."

  (let* ((line-start
          (plist-get hunk :line-start))

         (line-end
          (plist-get hunk :line-end))

         (context-start-line
          (max
           1
           (- line-start
              expose-watch-context-lines)))

         (context-end-line
          (min
           (expose-watch-buffer-line-count)
           (+ line-end
              expose-watch-context-lines)))

         (context-start
          (expose-watch-line-start-position context-start-line))

         (context-end
          (expose-watch-line-after-position context-end-line))

         (text
          (buffer-substring-no-properties
           context-start
           context-end)))

    (expose-watch-numbered-text
     text
     context-start-line)))

(defun expose-watch-request-hunk-block (hunk)
  "Return request block for HUNK."

  (format
   "  <changed-hunk file=\"%s\" line_start=\"%s\" line_end=\"%s\" hash=\"%s\">
    <diff>
%s
    </diff>
    <source-context numbered=\"true\">
%s
    </source-context>
  </changed-hunk>"
   (expose-watch-escape
    (plist-get hunk :file))
   (plist-get hunk :line-start)
   (plist-get hunk :line-end)
   (plist-get hunk :hash)
   (expose-watch-escape
    (plist-get hunk :text))
   (expose-watch-escape
    (expose-watch-hunk-context hunk))))

(defun expose-watch-diagnostic-file-current-p (diagnostic-file)
  "Return non-nil when DIAGNOSTIC-FILE belongs to current buffer."

  (or
   (not diagnostic-file)
   (not buffer-file-name)
   (ignore-errors
     (file-equal-p diagnostic-file buffer-file-name))))


(defun expose-watch-diagnostics ()
  "Return current buffer diagnostics as plain text."

  (let (lines)

    (when (boundp 'flycheck-current-errors)

      (dolist (error flycheck-current-errors)

        (when (and
               (fboundp 'flycheck-error-message)
               (fboundp 'flycheck-error-line)
               (fboundp 'flycheck-error-level)
               (expose-watch-diagnostic-file-current-p
                (when (fboundp 'flycheck-error-filename)
                  (flycheck-error-filename error))))

          (push
           (format
            "%s:%s: %s"
            (or
             (flycheck-error-line error)
             "?")
            (flycheck-error-level error)
            (flycheck-error-message error))
           lines))))

    (if lines
        (string-join
         (nreverse lines)
         "\n")
      "No editor diagnostics reported.")))

(defun expose-watch-request (file hunks)
  "Build Expose Watch request for FILE and HUNKS."

  (let ((diagnostics
         (expose-watch-diagnostics)))

    (format
     "<expose-watch-request>
  <instruction>
    You are watching me code. Review only the changed hunks below.

    Rules:
    - Return valid JSON only.
    - Do not return Markdown.
    - Do not wrap JSON in code fences.
    - Only comment when something is genuinely useful.
    - Prefer no findings over noisy findings.
    - Do not review unchanged code except as supporting context.
    - Do not suggest broad rewrites.
    - Maximum findings: %s.
    - Every finding must use real file line_start and line_end values.
    - Findings should point to the smallest useful changed-line range.

    Scope / name-resolution rules:
    - All changed-hunk blocks are from the same current file.
    - A variable, function, import, class, or type may be declared outside the shown hunk.
    - Absence from the shown context is not evidence that a name is undeclared.
    - Do not report undefined-variable, undeclared-variable, missing-import, or unknown-name findings unless the editor diagnostics explicitly report that problem.
    - If editor diagnostics do not report an undefined-name problem, assume name resolution is unknown and do not create that finding.

    Return exactly this shape:

    {
      \"summary\": \"Short optional summary.\",
      \"items\": [
        {
          \"id\": \"W1\",
          \"severity\": \"high|medium|low|info\",
          \"category\": \"correctness|security|performance|maintainability|tests|typing|style\",
          \"file\": \"%s\",
          \"line_start\": 123,
          \"line_end\": 126,
          \"title\": \"Short title\",
          \"comment\": \"Useful comment.\",
          \"anchor_text\": \"Relevant source line or phrase.\",
          \"suggestion\": {
            \"kind\": \"none|text|patch\",
            \"text\": \"Suggested fix or implementation direction.\",
            \"patch\": \"\"
          }
        }
      ]
    }

    If there are no useful findings, return:

    {
      \"summary\": \"No useful watch comments.\",
      \"items\": []
    }
  </instruction>

  <location file=\"%s\" major_mode=\"%s\" />

  <editor-diagnostics>
%s
  </editor-diagnostics>

%s
</expose-watch-request>"
     expose-watch-max-items-per-run
     (expose-watch-escape file)
     (expose-watch-escape file)
     major-mode
     (expose-watch-escape diagnostics)
     (string-join
      (mapcar
       #'expose-watch-request-hunk-block
       hunks)
      "\n\n"))))

;;; ---------------------------------------------------------------------------
;;; Review item helpers
;;; ---------------------------------------------------------------------------

(defun expose-watch-item-line-start (item &optional fallback)
  "Return ITEM line start or FALLBACK."

  (or
   (expose-watch-plist-get-any
    item
    '(:line-start :line_start))
   fallback
   1))

(defun expose-watch-item-line-end (item &optional fallback)
  "Return ITEM line end or FALLBACK."

  (or
   (expose-watch-plist-get-any
    item
    '(:line-end :line_end))
   (expose-watch-item-line-start item fallback)))

(defun expose-watch-item-file (item fallback)
  "Return ITEM file or FALLBACK."

  (or
   (plist-get item :file)
   fallback))

(defun expose-watch-item-overlaps-hunk-p (item hunk)
  "Return non-nil when ITEM overlaps HUNK."

  (let ((item-start
         (expose-watch-item-line-start item))

        (item-end
         (expose-watch-item-line-end item))

        (hunk-start
         (plist-get hunk :line-start))

        (hunk-end
         (plist-get hunk :line-end)))

    (and
     (<= item-start hunk-end)
     (<= hunk-start item-end))))

(defun expose-watch-items-for-hunk (items hunk)
  "Return ITEMS that overlap HUNK."

  (seq-filter
   (lambda (item)
     (expose-watch-item-overlaps-hunk-p item hunk))
   items))

(defun expose-watch-current-hunk-hashes (project-root file)
  "Return hashes for currently changed hunks in FILE."

  (mapcar
   (lambda (hunk)
     (plist-get hunk :hash))
   (expose-watch-current-file-hunks project-root file)))


(defun expose-watch-current-buffer-active-hunk-entries ()
  "Return reviewed hunk entries that still match the current file diff.

This prevents stale Watch comments from remaining attached to source
lines after the changed code was edited again or removed."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file))

              (entries
               (expose-watch-current-buffer-hunk-entries)))

    (let ((current-hashes
           (expose-watch-current-hunk-hashes project-root file)))

      (seq-filter
       (lambda (entry)
         (member
          (plist-get entry :hash)
          current-hashes))
       entries))))

(defun expose-watch-current-buffer-hunk-entries ()
  "Return reviewed hunk entries for current buffer."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file))

              (session
               (expose-watch-load-session project-root))

              (state
               (expose-watch-file-state session file)))

    (plist-get state :reviewed-hunks)))

(defun expose-watch-current-buffer-items ()
  "Return all Expose Watch items for current buffer."

  (apply
   #'append
   (mapcar
    (lambda (hunk)
      (plist-get hunk :items))
    (or
     (expose-watch-current-buffer-hunk-entries)
     nil))))

(defun expose-watch-severity-face (severity)
  "Return face for SEVERITY."

  (pcase
      (downcase
       (expose-watch-string severity))

    ("high"
     'expose-watch-high-face)

    ("medium"
     'expose-watch-medium-face)

    ("low"
     'expose-watch-low-face)

    (_
     'expose-watch-info-face)))

(defun expose-watch-format-location (file line-start line-end)
  "Format FILE LINE-START LINE-END."

  (if (= line-start line-end)

      (format "%s:%s" file line-start)

    (format "%s:%s-%s" file line-start line-end)))

(defun expose-watch-suggestion-text (item)
  "Return suggestion text from ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :text)
   ""))

(defun expose-watch-suggestion-patch (item)
  "Return suggestion patch from ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :patch)
   ""))

;;; ---------------------------------------------------------------------------
;;; Source overlays
;;; ---------------------------------------------------------------------------

(defun expose-watch-source-clear ()
  "Clear Expose Watch source overlays."

  (mapc
   #'delete-overlay
   expose-watch-source-overlays)

  (setq expose-watch-source-overlays nil)
  (setq expose-watch-visible-item-count 0)
  (expose-watch-refresh-mode-line))

(defun expose-watch-source-add-hunk-overlay (_hunk)
  "Do not visually mark reviewed hunks.

Expose Watch only marks concrete comments in the source buffer."
  nil)

(defun expose-watch-source-add-fringe-overlay (item file)
  "Add right-fringe marker for ITEM in FILE."

  (let* ((line
          (expose-watch-item-line-start item))

         (position
          (expose-watch-line-start-position line))

         (overlay
          (make-overlay position position nil t nil)))

    (overlay-put overlay 'priority 46)
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'help-echo "Expose Watch comment")
    (overlay-put overlay 'expose-watch-item item)
    (overlay-put overlay 'expose-watch-file file)
    (overlay-put overlay 'expose-watch-fringe t)

    (overlay-put
     overlay
     'before-string
     (propertize
      "!"
      'face
      'expose-watch-fringe-face
      'display
      '(right-fringe
        expose-watch-fringe-bitmap
        expose-watch-fringe-face)))

    (push overlay expose-watch-source-overlays)))

(defun expose-watch-source-add-item-overlay (item file)
  "Add visible source overlay and optional right-fringe marker for ITEM in FILE."

  (let* ((line-start
          (expose-watch-item-line-start item))

         (line-end
          (expose-watch-item-line-end item line-start))

         (start
          (expose-watch-line-start-position line-start))

         (end
          (expose-watch-line-after-position line-end))

         (overlay
          (make-overlay start end nil t nil)))

    ;; Full-line marker is the primary Watch indicator. This avoids relying
    ;; on the right fringe, which may already be used by diagnostics or Git.
    (overlay-put overlay 'face 'expose-watch-item-face)
    (overlay-put overlay 'priority 48)
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'help-echo "Expose Watch comment")
    (overlay-put overlay 'expose-watch-item item)
    (overlay-put overlay 'expose-watch-file file)

    (push overlay expose-watch-source-overlays)

    (when expose-watch-show-fringe-markers
      (expose-watch-source-add-fringe-overlay item file))))

(defun expose-watch-source-refresh ()
  "Refresh Expose Watch source overlays for current buffer."

  (expose-watch-source-clear)

  (when (and
         expose-watch-mode
         buffer-file-name)

    (let ((file
           (expose-watch-current-buffer-file)))

      ;; Only show overlays for reviewed hunks that still exist in the
      ;; current working-tree diff. Old comments remain in the Watch list,
      ;; but they should not hover over changed/removed code.
      (dolist (hunk
               (expose-watch-current-buffer-active-hunk-entries))

        (dolist (item
                 (plist-get hunk :items))

          (expose-watch-source-add-item-overlay
           item
           file)

          (setq expose-watch-visible-item-count
                (1+ expose-watch-visible-item-count))))))

  (expose-watch-refresh-mode-line))

(defun expose-watch-source-refresh-all ()
  "Refresh Expose Watch overlays in all file buffers."

  (dolist (buffer
           (buffer-list))

    (when (buffer-live-p buffer)

      (with-current-buffer buffer
        (when (bound-and-true-p expose-watch-mode)
          (expose-watch-source-refresh))))))

(defun expose-watch-item-at-point ()
  "Return Expose Watch item at point, or nil."

  (cl-loop
   for overlay in (overlays-at (point))
   for item = (overlay-get overlay 'expose-watch-item)
   when item
   return item))

(defun expose-watch-hover-body (item)
  "Return hover body for ITEM."

  (let* ((severity
          (expose-watch-string
           (or
            (plist-get item :severity)
            "info")))

         (category
          (expose-watch-string
           (or
            (plist-get item :category)
            "")))

         (title
          (expose-watch-string
           (or
            (plist-get item :title)
            "Watch comment")))

         (comment
          (expose-watch-string
           (or
            (plist-get item :comment)
            "")))

         (anchor
          (expose-watch-string
           (or
            (plist-get item :anchor-text)
            (plist-get item :anchor_text)
            "")))

         (file
          (expose-watch-item-file
           item
           (or
            (expose-watch-current-buffer-file)
            "")))

         (line-start
          (expose-watch-item-line-start item))

         (line-end
          (expose-watch-item-line-end item))

         (suggestion
          (expose-watch-suggestion-text item))

         (patch
          (expose-watch-suggestion-patch item))

         (severity-face
          (expose-watch-severity-face severity)))

    (with-temp-buffer
      (insert
       (propertize
        (format "[%s]" (upcase severity))
        'face
        severity-face))

      (unless (expose-watch-blank-p category)
        (insert
         (propertize
          (format " %s" category)
          'face
          'shadow)))

      (insert "\n")

      (insert
       (propertize
        (expose-watch-format-location
         file
         line-start
         line-end)
        'face
        'font-lock-constant-face))

      (insert "\n\n")

      (insert
       (propertize title 'face 'bold))

      (insert "\n\n")

      (unless (expose-watch-blank-p comment)
        (insert comment)
        (insert "\n\n"))

      (unless (expose-watch-blank-p anchor)
        (insert
         (propertize
          "Anchor\n"
          'face
          'font-lock-keyword-face))
        (insert anchor)
        (insert "\n\n"))

      (unless (expose-watch-blank-p suggestion)
        (insert
         (propertize
          "Suggestion\n"
          'face
          'font-lock-keyword-face))
        (insert suggestion)
        (insert "\n\n"))

      (unless (expose-watch-blank-p patch)
        (insert
         (propertize
          "Patch\n"
          'face
          'font-lock-keyword-face))
        (insert patch)
        (insert "\n"))

      (buffer-string))))

(defun expose-watch-show-hover (buffer position)
  "Show Expose Watch hover for BUFFER at POSITION."

  (when (buffer-live-p buffer)

    (with-current-buffer buffer

      (when (and
             expose-watch-mode
             (= position
                (point)))

        (when-let ((item
                    (expose-watch-item-at-point)))

          (expose-popup-show-view
           (list
            :title "Expose Watch"
            :body (expose-watch-hover-body item)
            :history nil)))))))

(defun expose-watch-schedule-hover ()
  "Schedule Expose Watch hover."

  (when expose-watch-hover-timer
    (cancel-timer expose-watch-hover-timer)
    (setq expose-watch-hover-timer nil))

  (setq expose-watch-hover-timer
        (run-with-idle-timer
         expose-watch-hover-delay
         nil
         #'expose-watch-show-hover
         (current-buffer)
         (point))))

(defun expose-watch-cancel-hover ()
  "Cancel pending Expose Watch hover."

  (when expose-watch-hover-timer
    (cancel-timer expose-watch-hover-timer)
    (setq expose-watch-hover-timer nil)))

(defun expose-watch-post-command ()
  "Schedule Expose Watch hover when point is on a watch comment."

  (cond
   ((and
     (symbolp this-command)
     (fboundp 'expose-popup-command-p)
     (expose-popup-command-p this-command))

    (expose-watch-cancel-hover))

   ((expose-watch-item-at-point)
    (expose-watch-schedule-hover))

   (t
    (expose-watch-cancel-hover))))

;;; ---------------------------------------------------------------------------
;;; Review current changed hunks
;;; ---------------------------------------------------------------------------

(defun expose-watch-new-hunks (project-root file)
  "Return changed hunks for FILE that have not already been reviewed."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file))

         (hunks
          (expose-watch-current-file-hunks project-root file)))

    (seq-take
     (seq-remove
      (lambda (hunk)
        (or
         (expose-watch-hunk-reviewed-p state hunk)
         (member
          (plist-get hunk :hash)
          expose-watch-pending-hashes)))
      hunks)
     expose-watch-max-hunks-per-run)))

(defun expose-watch-set-state (state)
  "Set Expose Watch STATE for current buffer."

  (setq expose-watch-state state)
  (expose-watch-refresh-mode-line))

;;;###autoload
(defun expose-watch-review-current-buffer ()
  "Review changed hunks in the current watched buffer."

  (interactive)

  (unless buffer-file-name
    (user-error "Expose Watch requires a file buffer"))

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-watch-project-root))

         (file
          (expose-watch-buffer-file project-root)))

    (when (expose-redact-excluded-path-p file project-root)
      (expose-redact-log-excluded-path file project-root)
      (user-error "Expose Watch refuses to review excluded path: %s" file))

    (let* ((hunks
            (expose-watch-new-hunks project-root file)))

      (unless hunks
        (when (called-interactively-p 'interactive)
          (message "Expose Watch: no new changed hunks to review")))

      (when hunks
        (let* ((provider
                expose-provider-default)

               (document
                (expose-watch-request file hunks))

               (hashes
                (mapcar
                 (lambda (hunk)
                   (plist-get hunk :hash))
                 hunks)))

          (setq expose-watch-pending-hashes
                (append
                 expose-watch-pending-hashes
                 hashes))

          (expose-watch-set-state 'running)

          (expose-log
           "Watch"
           "Reviewing %d changed hunk(s) in %s using %s."
           (length hunks)
           file
           provider)

          (expose-transport-send-document-async
           provider
           document

           (lambda (response-text)

             (when (buffer-live-p source-buffer)

               (with-current-buffer source-buffer

                 (setq expose-watch-pending-hashes
                       (seq-difference
                        expose-watch-pending-hashes
                        hashes
                        #'string=))

                 (condition-case parse-error

                     (let ((items
                            (expose-review-request-parse-items response-text)))

                       (dolist (hunk hunks)
                         (expose-watch-record-hunk
                          project-root
                          file
                          hunk
                          (expose-watch-items-for-hunk items hunk)
                          response-text))

                       (expose-watch-set-state 'idle)
                       (expose-watch-source-refresh)

                       (expose-log
                        "Watch"
                        "Watch review completed for %s with %d item(s)."
                        file
                        (length items)))

                   (error
                    (expose-watch-set-state 'error)

                    (expose-log
                     "Watch"
                     "Watch review failed to parse response for %s: %s"
                     file
                     (error-message-string parse-error)))))))

           project-root

           (lambda (error-data)

             (when (buffer-live-p source-buffer)

               (with-current-buffer source-buffer

                 (setq expose-watch-pending-hashes
                       (seq-difference
                        expose-watch-pending-hashes
                        hashes
                        #'string=))

                 (expose-watch-set-state 'error)

                 (expose-log
                  "Watch"
                  "Watch review failed for %s: %s"
                  file
                  (error-message-string error-data)))))))))))

(defun expose-watch-after-save ()
  "Run Expose Watch after saving the current buffer."

  (when expose-watch-mode
    ;; First remove any source markers whose old hunk hash no longer exists.
    ;; This keeps removed/changed code from showing misleading hovers while
    ;; the next Watch review is running.
    (expose-watch-source-refresh)

    (expose-watch-review-current-buffer)))

;;; ---------------------------------------------------------------------------
;;; Watch list buffer
;;; ---------------------------------------------------------------------------

(defvar expose-watch-list-mode-map
  (let ((map
         (make-sparse-keymap)))

    (set-keymap-parent map special-mode-map)

    (define-key map (kbd "q") #'quit-window)

    map)
  "Keymap for `expose-watch-list-mode'.")

(define-derived-mode expose-watch-list-mode special-mode "ExposeWatch"
  "Read-only Expose Watch list buffer."

  (setq truncate-lines nil)
  (setq buffer-read-only t))

(defun expose-watch-list-insert-label (label value)
  "Insert LABEL and VALUE."

  (unless (expose-watch-blank-p value)

    (insert
     (propertize
      label
      'face
      'expose-watch-list-label-face))

    (insert " ")

    (insert
     (propertize
      (expose-watch-string value)
      'face
      'expose-watch-list-meta-face))

    (insert "\n")))

(defun expose-watch-list-insert-item (item file created-at)
  "Insert watch ITEM for FILE CREATED-AT."

  (let* ((severity
          (expose-watch-string
           (or
            (plist-get item :severity)
            "info")))

         (category
          (expose-watch-string
           (or
            (plist-get item :category)
            "")))

         (title
          (expose-watch-string
           (or
            (plist-get item :title)
            "Watch comment")))

         (comment
          (expose-watch-string
           (or
            (plist-get item :comment)
            "")))

         (line-start
          (expose-watch-item-line-start item))

         (line-end
          (expose-watch-item-line-end item))

         (face
          (expose-watch-severity-face severity)))

    (insert
     (propertize
      (format "[%s] " (upcase severity))
      'face
      face))

    (insert
     (propertize
      title
      'face
      'expose-watch-list-title-face))

    (unless (expose-watch-blank-p category)
      (insert
       (propertize
        (format " (%s)" category)
        'face
        'expose-watch-list-meta-face)))

    (insert "\n")

    (insert "  ")

    (insert
     (propertize
      (expose-watch-format-location
       file
       line-start
       line-end)
      'face
      'font-lock-constant-face))

    (unless (expose-watch-blank-p created-at)
      (insert
       (propertize
        (format "  —  %s" created-at)
        'face
        'expose-watch-list-meta-face)))

    (insert "\n")

    (unless (expose-watch-blank-p comment)
      (dolist (line
               (split-string comment "\n"))

        (insert "  ")
        (insert line)
        (insert "\n")))

    (insert "\n")))

(defun expose-watch-list-render ()
  "Render the current Expose Watch list buffer."

  (let* ((inhibit-read-only t)

         (default-directory
          expose-watch-list-project-root)

         (session
          (expose-watch-load-session
           expose-watch-list-project-root)))

    (erase-buffer)

    (insert
     (propertize
      "Expose Watch\n"
      'face
      'expose-watch-list-title-face))

    (insert "\n")

    (expose-watch-list-insert-label
     "Project:"
     (abbreviate-file-name expose-watch-list-project-root))

    (insert "q quits.\n\n")

    (let ((files
           (plist-get session :files)))

      (if files

          (dolist (state files)

            (let ((file
                   (plist-get state :file))

                  (enabled
                   (plist-get state :enabled))

                  (hunks
                   (plist-get state :reviewed-hunks)))

              (insert
               (propertize
                (format
                 "%s %s\n"
                 (if enabled "●" "○")
                 file)
                'face
                (if enabled
                    'expose-watch-list-title-face
                  'expose-watch-list-meta-face)))

              (if hunks

                  (dolist (hunk hunks)

                    (let ((items
                           (plist-get hunk :items))

                          (created-at
                           (plist-get hunk :created-at))

                          (error
                           (plist-get hunk :error)))

                      (cond
                       (items
                        (dolist (item items)
                          (expose-watch-list-insert-item
                           item
                           file
                           created-at)))

                       (error
                        (insert
                         (propertize
                          (format "  Watch failed: %s\n\n" error)
                          'face
                          'expose-watch-high-face)))

                       (t
                        (insert
                         (propertize
                          (format
                           "  %s:%s-%s — no useful comments. %s\n\n"
                           file
                           (plist-get hunk :line-start)
                           (plist-get hunk :line-end)
                           created-at)
                          'face
                          'expose-watch-list-meta-face))))))

                (insert
                 (propertize
                  "  No watch comments yet.\n\n"
                  'face
                  'expose-watch-list-meta-face)))))

        (insert "No watched files yet.\n")))

    (goto-char (point-min))))

;;;###autoload
(defun expose-watch-open-list ()
  "Open Expose Watch list for the current project."

  (interactive)

  (let* ((project-root
          (expose-watch-project-root))

         (buffer
          (get-buffer-create expose-watch-list-buffer-name)))

    (with-current-buffer buffer
      (setq default-directory project-root)
      (expose-watch-list-mode)
      (setq default-directory project-root)
      (setq expose-watch-list-project-root project-root)
      (expose-watch-list-render))

    (switch-to-buffer buffer)))

;;; ---------------------------------------------------------------------------
;;; Minor modes / commands
;;; ---------------------------------------------------------------------------

(defun expose-watch-enable-if-watched ()
  "Enable `expose-watch-mode' when current file is stored as watched."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file)))

    (when (expose-watch-file-enabled-p project-root file)

      (let ((expose-watch--restoring t))
        (expose-watch-mode 1)))))

;;;###autoload
(define-minor-mode expose-watch-mode
  "Watch this buffer for changed hunks and background review comments."
  :lighter nil

  (if expose-watch-mode

      (progn
        (unless expose-watch--restoring
          (let* ((project-root
                  (expose-watch-project-root))

                 (file
                  (expose-watch-buffer-file project-root)))

            (expose-watch-enable-file-state project-root file)))

        (setq expose-watch-state 'idle)

        (add-hook 'after-save-hook #'expose-watch-after-save nil t)
        (add-hook 'post-command-hook #'expose-watch-post-command nil t)

        (expose-watch-source-refresh)
        (expose-watch-refresh-mode-line))

    (remove-hook 'after-save-hook #'expose-watch-after-save t)
    (remove-hook 'post-command-hook #'expose-watch-post-command t)

    (expose-watch-cancel-hover)
    (expose-watch-source-clear)

    (setq expose-watch-state 'idle)
    (setq expose-watch-visible-item-count 0)

    (unless expose-watch--restoring
      (when-let* ((project-root
                   (expose-watch-current-project-root))

                  (file
                   (expose-watch-current-buffer-file)))

        (expose-watch-disable-file-state project-root file)))

    (expose-watch-refresh-mode-line)))

;;;###autoload
(define-minor-mode expose-watch-global-mode
  "Restore Expose Watch mode for watched files."
  :global t

  (if expose-watch-global-mode

      (progn
        (add-hook 'find-file-hook #'expose-watch-enable-if-watched)

        (dolist (buffer
                 (buffer-list))
          (with-current-buffer buffer
            (when buffer-file-name
              (expose-watch-enable-if-watched)))))

    (remove-hook 'find-file-hook #'expose-watch-enable-if-watched)))

;;;###autoload
(defun expose-watch-current-buffer ()
  "Enable Expose Watch for the current buffer."

  (interactive)

  (expose-watch-mode 1)

  (message
   "Expose Watch enabled for %s."
   (or
    (expose-watch-current-buffer-file)
    (buffer-name))))

;;;###autoload
(defun expose-watch-unwatch-current-buffer ()
  "Disable Expose Watch for the current buffer."

  (interactive)

  (expose-watch-mode -1)

  (message
   "Expose Watch disabled for %s."
   (or
    (expose-watch-current-buffer-file)
    (buffer-name))))

;;;###autoload
(defun expose-watch-clear-current-buffer ()
  "Clear Expose Watch comments for the current buffer."

  (interactive)

  (let* ((project-root
          (expose-watch-project-root))

         (file
          (expose-watch-buffer-file project-root)))

    (expose-watch-clear-file project-root file)
    (expose-watch-source-refresh)

    (message
     "Expose Watch comments cleared for %s."
     file)))

;;;###autoload
(defun expose-watch-clear-project ()
  "Clear Expose Watch comments for the current project."

  (interactive)

  (let ((project-root
         (expose-watch-project-root)))

    (expose-watch-clear-project-session project-root)
    (expose-watch-source-refresh-all)

    (message "Expose Watch project comments cleared.")))

(expose-watch-install-mode-line)

(provide 'expose-watch)
