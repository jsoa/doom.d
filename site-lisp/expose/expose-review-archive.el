;;; expose-review-archive.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'expose-log)
(require 'expose-review-request)
(require 'diff-mode nil t)

(defgroup expose-review-archive nil
  "Read-only archive viewers for Expose reviews."
  :group 'expose-review)

(defcustom expose-review-archive-response-preview-length 4000
  "Maximum raw response preview length shown when archived review has no parsed items."
  :type 'integer
  :group 'expose-review-archive)

(defvar expose-review-archive-full-buffer-name
  "*EXPOSE Full Review Archives*"
  "Buffer name for full review archives.")

(defvar expose-review-archive-region-buffer-name
  "*EXPOSE Region Review Archives*"
  "Buffer name for region review archives.")

(defvar-local expose-review-archive-kind nil
  "Archive kind shown in current archive buffer.")

(defvar-local expose-review-archive-project-root nil
  "Project root shown in current archive buffer.")

(defvar-local expose-review-archive-expanded-paths nil
  "Hash table of expanded archive paths in current archive buffer.")

(defface expose-review-archive-entry-title-face
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Face for archive entry titles."
  :group 'expose-review-archive)

(defface expose-review-archive-meta-face
  '((t (:inherit shadow)))
  "Face for archive metadata."
  :group 'expose-review-archive)

(defface expose-review-archive-label-face
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Face for archive field labels."
  :group 'expose-review-archive)

(defface expose-review-archive-location-face
  '((t (:inherit font-lock-constant-face)))
  "Face for archive file locations."
  :group 'expose-review-archive)

(defface expose-review-archive-high-face
  '((t (:inherit error :weight bold)))
  "Face for high severity archive items."
  :group 'expose-review-archive)

(defface expose-review-archive-medium-face
  '((t (:inherit warning :weight bold)))
  "Face for medium severity archive items."
  :group 'expose-review-archive)

(defface expose-review-archive-low-face
  '((t (:inherit success :weight bold)))
  "Face for low severity archive items."
  :group 'expose-review-archive)

(defface expose-review-archive-info-face
  '((t (:inherit font-lock-doc-face :weight bold)))
  "Face for info severity archive items."
  :group 'expose-review-archive)

(defface expose-review-archive-section-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for expanded archive section headings."
  :group 'expose-review-archive)

(defun expose-review-archive-severity-face (severity)
  "Return face for SEVERITY."

  (pcase
      (downcase
       (expose-review-archive-string severity))

    ("high"
     'expose-review-archive-high-face)

    ("medium"
     'expose-review-archive-medium-face)

    ("low"
     'expose-review-archive-low-face)

    ("info"
     'expose-review-archive-info-face)

    (_
     'expose-review-archive-info-face)))


(defun expose-review-archive-fontify-diff (text)
  "Return TEXT fontified as a diff when possible."

  (if (not
       (fboundp 'diff-mode))

      text

    (with-temp-buffer
      (delay-mode-hooks
        (diff-mode))

      (font-lock-mode 1)

      (insert
       (or text ""))

      (font-lock-ensure
       (point-min)
       (point-max))

      (buffer-string))))


(defun expose-review-archive-insert-indented-lines
    (text indent &optional face)
  "Insert TEXT line by line with INDENT spaces and optional FACE."

  (dolist (line
           (split-string
            (expose-review-archive-string text)
            "\n"))

    (insert
     (make-string indent ?\s))

    (insert
     (if face
         (propertize line 'face face)
       line))

    (insert "\n")))

(defvar expose-review-archive-mode-map
  (let ((map
         (make-sparse-keymap)))

    (set-keymap-parent map special-mode-map)

    ;; Single entry expand/collapse.
    (define-key map (kbd "TAB") #'expose-review-archive-toggle-at-point)
    (define-key map (kbd "<tab>") #'expose-review-archive-toggle-at-point)
    (define-key map [tab] #'expose-review-archive-toggle-at-point)

    ;; Expand all / collapse all.
    (define-key map (kbd "<backtab>") #'expose-review-archive-toggle-all)
    (define-key map (kbd "S-TAB") #'expose-review-archive-toggle-all)
    (define-key map [backtab] #'expose-review-archive-toggle-all)

    ;; Quit only.
    (define-key map (kbd "q") #'quit-window)

    map)
  "Keymap for `expose-review-archive-mode'.")

(defun expose-review-archive-install-evil-keys ()
  "Install Evil bindings for `expose-review-archive-mode'."

  (when (fboundp 'evil-define-key*)

    (evil-define-key*
      '(normal motion)
      expose-review-archive-mode-map

      ;; Single entry expand/collapse.
      (kbd "TAB")
      #'expose-review-archive-toggle-at-point

      (kbd "<tab>")
      #'expose-review-archive-toggle-at-point

      [tab]
      #'expose-review-archive-toggle-at-point

      ;; Expand all / collapse all.
      (kbd "<backtab>")
      #'expose-review-archive-toggle-all

      (kbd "S-TAB")
      #'expose-review-archive-toggle-all

      [backtab]
      #'expose-review-archive-toggle-all

      ;; Quit.
      "q"
      #'quit-window)))


(with-eval-after-load 'evil
  (expose-review-archive-install-evil-keys))

(expose-review-archive-install-evil-keys)

(define-derived-mode expose-review-archive-mode special-mode "ExposeArchives"
  "Read-only archive viewer for Expose reviews."

  (setq truncate-lines nil)
  (setq buffer-read-only t))

(defun expose-review-archive-project-root ()
  "Return current project root."

  (if-let ((project
            (project-current nil)))

      (file-name-as-directory
       (project-root project))

    (user-error "Expose archive viewer requires a project")))

(defun expose-review-archive-call-git (project-root &rest args)
  "Run git with ARGS in PROJECT-ROOT and return trimmed stdout."

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

        (unless (= status 0)
          (user-error
           "Git command failed: git %s"
           (string-join args " ")))

        (string-trim
         (buffer-string))))))

(defun expose-review-archive-git-path (project-root path)
  "Return git-private PATH under PROJECT-ROOT."

  (expand-file-name
   (expose-review-archive-call-git
    project-root
    "rev-parse"
    "--git-path"
    path)
   project-root))

(defun expose-review-archive-full-root (project-root)
  "Return full review archive root for PROJECT-ROOT."

  (expose-review-archive-git-path
   project-root
   "expose/reviews"))

(defun expose-review-archive-region-history-dir (project-root)
  "Return region review history directory for PROJECT-ROOT."

  (expose-review-archive-git-path
   project-root
   "expose/region-reviews/history"))

(defun expose-review-archive-read-session-file (path)
  "Read archived review session from PATH."

  (when (file-readable-p path)

    (condition-case error-data

        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (read (current-buffer)))

      (error
       (expose-log
        "ReviewArchive"
        "Failed to read archive %s: %s"
        path
        (error-message-string error-data))

       nil))))

(defun expose-review-archive-file-mtime (path)
  "Return modification time for PATH."

  (file-attribute-modification-time
   (file-attributes path)))

(defun expose-review-archive-newer-file-p (a b)
  "Return non-nil when A is newer than B."

  (time-less-p
   (expose-review-archive-file-mtime b)
   (expose-review-archive-file-mtime a)))

(defun expose-review-archive-eld-files (dir &optional recursive)
  "Return .eld files under DIR.

When RECURSIVE is non-nil, search recursively."

  (when (file-directory-p dir)

    (sort
     (if recursive
         (directory-files-recursively dir "\\.eld\\'")
       (directory-files dir t "\\.eld\\'"))
     #'expose-review-archive-newer-file-p)))

(defun expose-review-archive-history-path-p (path)
  "Return non-nil if PATH looks like a history archive path."

  (string-match-p
   "/history/[^/]+\\.eld\\'"
   (replace-regexp-in-string
    "\\\\"
    "/"
    path)))

(defun expose-review-archive-full-files (project-root)
  "Return full review archive files for PROJECT-ROOT."

  (seq-filter
   #'expose-review-archive-history-path-p
   (or
    (expose-review-archive-eld-files
     (expose-review-archive-full-root project-root)
     t)
    nil)))

(defun expose-review-archive-region-files (project-root)
  "Return region review archive files for PROJECT-ROOT."

  (or
   (expose-review-archive-eld-files
    (expose-review-archive-region-history-dir project-root))
   nil))

(defun expose-review-archive-files (kind project-root)
  "Return archive files for KIND in PROJECT-ROOT."

  (pcase kind
    ('full
     (expose-review-archive-full-files project-root))

    ('region
     (expose-review-archive-region-files project-root))

    (_
     nil)))

(defun expose-review-archive-plist-get-any (plist keys)
  "Return first value from PLIST matching one of KEYS."

  (catch 'value
    (dolist (key keys)
      (when (plist-member plist key)
        (throw 'value
               (plist-get plist key))))
    nil))

(defun expose-review-archive-string (value)
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

(defun expose-review-archive-blank-p (value)
  "Return non-nil when VALUE is nil or blank."

  (string-empty-p
   (string-trim
    (expose-review-archive-string value))))

(defun expose-review-archive-list-value (value)
  "Return VALUE as a list."

  (cond
   ((null value)
    nil)

   ((vectorp value)
    (append value nil))

   ((listp value)
    value)

   (t
    nil)))

(defun expose-review-archive-session-items (session)
  "Return review items from SESSION."

  (expose-review-archive-list-value
   (plist-get session :items)))

(defun expose-review-archive-item-count (session)
  "Return number of review items in SESSION."

  (length
   (expose-review-archive-session-items session)))

(defun expose-review-archive-item-word (count)
  "Return item/items for COUNT."

  (if (= count 1)
      "item"
    "items"))

(defun expose-review-archive-session-state (session)
  "Return SESSION state string."

  (expose-review-archive-string
   (or
    (plist-get session :state)
    "unknown")))

(defun expose-review-archive-session-time (session)
  "Return best timestamp from SESSION."

  (or
   (plist-get session :archived-at)
   (plist-get session :completed-at)
   (plist-get session :updated-at)
   (plist-get session :created-at)
   ""))

(defun expose-review-archive-format-location (file line-start line-end)
  "Format FILE LINE-START LINE-END."

  (if (and file line-start line-end)

      (format
       "%s:%s%s"
       file
       line-start
       (if (= line-start line-end)
           ""
         (format "-%s" line-end)))

    "unknown location"))

(defun expose-review-archive-session-line-start (session)
  "Return SESSION start line."

  (or
   (plist-get session :region-line-start)
   (plist-get session :line-start)
   (plist-get session :line_start)))

(defun expose-review-archive-session-line-end (session)
  "Return SESSION end line."

  (or
   (plist-get session :region-line-end)
   (plist-get session :line-end)
   (plist-get session :line_end)
   (expose-review-archive-session-line-start session)))

(defun expose-review-archive-region-title (session)
  "Return title for archived region review SESSION."

  (let* ((file
          (plist-get session :file))

         (line-start
          (expose-review-archive-session-line-start session))

         (line-end
          (expose-review-archive-session-line-end session))

         (count
          (expose-review-archive-item-count session)))

    (format
     "%s  [%s]  %d %s"
     (expose-review-archive-format-location
      file
      line-start
      line-end)
     (expose-review-archive-session-state session)
     count
     (expose-review-archive-item-word count))))

(defun expose-review-archive-full-branch-from-path (project-root path)
  "Return branch slug from full review archive PATH under PROJECT-ROOT."

  (let* ((root
          (expose-review-archive-full-root project-root))

         (relative
          (file-relative-name path root))

         (parts
          (split-string relative "/" t)))

    (car parts)))

(defun expose-review-archive-full-title (project-root path session)
  "Return title for archived full review SESSION at PATH."

  (let* ((branch
          (or
           (plist-get session :branch)
           (expose-review-archive-full-branch-from-path project-root path)
           "unknown-branch"))

         (count
          (expose-review-archive-item-count session)))

    (format
     "%s  [%s]  %d %s"
     branch
     (expose-review-archive-session-state session)
     count
     (expose-review-archive-item-word count))))

(defun expose-review-archive-entry-title (kind project-root path session)
  "Return display title for archive KIND PROJECT-ROOT PATH SESSION."

  (pcase kind
    ('full
     (expose-review-archive-full-title project-root path session))

    ('region
     (expose-review-archive-region-title session))

    (_
     path)))

(defun expose-review-archive-entry-subtitle (path session)
  "Return display subtitle for PATH SESSION."

  (let ((time
         (expose-review-archive-session-time session)))

    (string-join
     (delq
      nil
      (list
       (unless (expose-review-archive-blank-p time)
         time)

       (abbreviate-file-name path)))
     "  —  ")))

(defun expose-review-archive-entries (kind project-root)
  "Return archive entries for KIND in PROJECT-ROOT."

  (delq
   nil
   (mapcar
    (lambda (path)
      (when-let ((session
                  (expose-review-archive-read-session-file path)))

        (list
         :kind kind
         :path path
         :session session
         :title
         (expose-review-archive-entry-title
          kind
          project-root
          path
          session)
         :subtitle
         (expose-review-archive-entry-subtitle
          path
          session))))
    (expose-review-archive-files kind project-root))))

(defun expose-review-archive-expanded-p (path)
  "Return non-nil when archive PATH is expanded."

  (and
   expose-review-archive-expanded-paths
   (gethash path expose-review-archive-expanded-paths)))

(defun expose-review-archive-set-expanded (path expanded)
  "Set archive PATH expansion state to EXPANDED."

  (unless expose-review-archive-expanded-paths
    (setq expose-review-archive-expanded-paths
          (make-hash-table :test 'equal)))

  (if expanded
      (puthash path t expose-review-archive-expanded-paths)
    (remhash path expose-review-archive-expanded-paths)))

(defun expose-review-archive-entry-path-at-point ()
  "Return archive path at point or nearest parent entry."

  (or
   (get-text-property
    (line-beginning-position)
    'expose-review-archive-path)

   (save-excursion
     (catch 'path
       (while (not (bobp))
         (forward-line -1)

         (when-let ((path
                     (get-text-property
                      (line-beginning-position)
                      'expose-review-archive-path)))
           (throw 'path path)))

       nil))))

(defun expose-review-archive-goto-path (path)
  "Move point to archive entry PATH."

  (goto-char (point-min))

  (catch 'found
    (while (not (eobp))
      (when (equal
             path
             (get-text-property
              (line-beginning-position)
              'expose-review-archive-path))

        (throw 'found t))

      (forward-line 1))))

(defun expose-review-archive-all-expanded-p (entries)
  "Return non-nil when all archive ENTRIES are expanded."

  (and
   entries
   (seq-every-p
    (lambda (entry)
      (expose-review-archive-expanded-p
       (plist-get entry :path)))
    entries)))


(defun expose-review-archive-toggle-all ()
  "Expand all archive entries, or collapse all when already expanded."

  (interactive)

  (let* ((entries
          (expose-review-archive-entries
           expose-review-archive-kind
           expose-review-archive-project-root))

         (expand
          (not
           (expose-review-archive-all-expanded-p entries))))

    (unless entries
      (user-error "No archived reviews found"))

    (dolist (entry entries)
      (expose-review-archive-set-expanded
       (plist-get entry :path)
       expand))

    (expose-review-archive-render)

    (message
     "Expose archive: %s all."
     (if expand
         "expanded"
       "collapsed"))))

(defun expose-review-archive-toggle-at-point ()
  "Toggle archive entry at point."

  (interactive)

  (let ((path
         (expose-review-archive-entry-path-at-point)))

    (unless path
      (user-error "Point is not on an archive entry"))

    (expose-review-archive-set-expanded
     path
     (not
      (expose-review-archive-expanded-p path)))

    (expose-review-archive-render)

    (expose-review-archive-goto-path path)))

(defun expose-review-archive-refresh ()
  "Refresh current archive buffer."

  (interactive)

  (let ((path
         (expose-review-archive-entry-path-at-point)))

    (expose-review-archive-render)

    (when path
      (expose-review-archive-goto-path path))))

(defun expose-review-archive-json-summary (response)
  "Return summary from raw JSON RESPONSE when available."

  (when (and response
             (stringp response)
             (not
              (string-empty-p
               (string-trim response))))

    (condition-case nil

        (let* ((json
                (if (fboundp 'expose-review-request-extract-json)
                    (expose-review-request-extract-json response)
                  response))

               (parsed
                (json-parse-string
                 json
                 :object-type 'plist
                 :array-type 'list)))

          (plist-get parsed :summary))

      (error
       nil))))

(defun expose-review-archive-truncate (text length)
  "Truncate TEXT to LENGTH."

  (let ((value
         (or text "")))

    (if (> (length value) length)

        (concat
         (substring value 0 length)
         "\n\n... truncated ...")

      value)))

(defun expose-review-archive-item-line-start (item)
  "Return ITEM start line."

  (expose-review-archive-plist-get-any
   item
   '(:line-start :line_start)))

(defun expose-review-archive-item-line-end (item)
  "Return ITEM end line."

  (or
   (expose-review-archive-plist-get-any
    item
    '(:line-end :line_end))
   (expose-review-archive-item-line-start item)))

(defun expose-review-archive-item-file (item session)
  "Return ITEM file or SESSION file."

  (or
   (plist-get item :file)
   (plist-get session :file)))

(defun expose-review-archive-item-suggestion (item)
  "Return suggestion plist from ITEM."

  (plist-get item :suggestion))

(defun expose-review-archive-insert-field (label value)
  "Insert LABEL and VALUE when VALUE is non-blank."

  (unless (expose-review-archive-blank-p value)

    (insert "    ")

    (insert
     (propertize
      label
      'face
      'expose-review-archive-label-face))

    (insert " ")

    (insert
     (propertize
      (expose-review-archive-string value)
      'face
      'expose-review-archive-meta-face))

    (insert "\n")))

(defun expose-review-archive-insert-block (label value)
  "Insert multiline LABEL and VALUE when VALUE is non-blank."

  (unless (expose-review-archive-blank-p value)

    (insert "    ")

    (insert
     (propertize
      label
      'face
      'expose-review-archive-section-face))

    (insert "\n")

    (expose-review-archive-insert-indented-lines
     value
     6)))

(defun expose-review-archive-insert-patch-block (label value)
  "Insert multiline diff LABEL and VALUE when VALUE is non-blank."

  (unless (expose-review-archive-blank-p value)

    (insert "    ")

    (insert
     (propertize
      label
      'face
      'expose-review-archive-section-face))

    (insert "\n")

    (expose-review-archive-insert-indented-lines
     (expose-review-archive-fontify-diff value)
     6)))

(defun expose-review-archive-insert-item (item session index)
  "Insert archived review ITEM for SESSION at INDEX."

  (let* ((file
          (expose-review-archive-item-file item session))

         (line-start
          (expose-review-archive-item-line-start item))

         (line-end
          (expose-review-archive-item-line-end item))

         (id
          (expose-review-archive-string
           (or
            (plist-get item :id)
            (format "R%s" index))))

         (severity
          (expose-review-archive-string
           (or
            (plist-get item :severity)
            "info")))

         (category
          (expose-review-archive-string
           (or
            (plist-get item :category)
            "")))

         (title
          (expose-review-archive-string
           (or
            (plist-get item :title)
            "Review item")))

         (comment
          (expose-review-archive-string
           (or
            (plist-get item :comment)
            "")))

         (anchor
          (expose-review-archive-string
           (or
            (plist-get item :anchor-text)
            (plist-get item :anchor_text)
            "")))

         (suggestion
          (expose-review-archive-item-suggestion item))

         (suggestion-text
          (expose-review-archive-string
           (or
            (plist-get suggestion :text)
            "")))

         (suggestion-patch
          (expose-review-archive-string
           (or
            (plist-get suggestion :patch)
            "")))

         (severity-face
          (expose-review-archive-severity-face severity)))

    (insert "  ")

    (insert
     (propertize
      (format "%s. " id)
      'face
      'expose-review-archive-meta-face))

    (insert
     (propertize
      (format "[%s]" (upcase severity))
      'face
      severity-face))

    (insert " ")

    (insert
     (propertize
      title
      'face
      'expose-review-archive-entry-title-face))

    (unless (expose-review-archive-blank-p category)
      (insert
       (propertize
        (format " (%s)" category)
        'face
        'expose-review-archive-meta-face)))

    (insert "\n")

    (expose-review-archive-insert-field
     "Lines:"
     (propertize
      (expose-review-archive-format-location
       file
       line-start
       line-end)
      'face
      'expose-review-archive-location-face))

    (expose-review-archive-insert-block
     "Comment:"
     comment)

    (expose-review-archive-insert-block
     "Anchor:"
     anchor)

    (expose-review-archive-insert-block
     "Suggested change:"
     suggestion-text)

    (expose-review-archive-insert-patch-block
     "Suggested patch:"
     suggestion-patch)

    (insert "\n")))

(defun expose-review-archive-insert-expanded-entry (entry)
  "Insert expanded body for archive ENTRY."

  (let* ((session
          (plist-get entry :session))

         (items
          (expose-review-archive-session-items session))

         (response
          (plist-get session :response))

         (summary
          (or
           (plist-get session :summary)
           (expose-review-archive-json-summary response)))

         (error
          (plist-get session :error)))

    (insert "\n")

    (expose-review-archive-insert-field
     "State:"
     (expose-review-archive-session-state session))

    (expose-review-archive-insert-field
     "Archived:"
     (expose-review-archive-session-time session))

    (expose-review-archive-insert-field
     "Provider:"
     (plist-get session :provider))

    (expose-review-archive-insert-block
     "Summary:"
     summary)

    (expose-review-archive-insert-block
     "Error:"
     error)

    (insert "\n")

    (cond
     (items
      (cl-loop
       for item in items
       for index from 1
       do
       (expose-review-archive-insert-item
        item
        session
        index)))

     ((not
       (expose-review-archive-blank-p response))
      (expose-review-archive-insert-block
       "Raw response:"
       (expose-review-archive-truncate
        response
        expose-review-archive-response-preview-length)))

     (t
      (insert
       (propertize
        "  No review details stored.\n\n"
        'face
        'expose-review-archive-meta-face))))))

(defun expose-review-archive-insert-entry (entry)
  "Insert archive ENTRY."

  (let* ((path
          (plist-get entry :path))

         (expanded
          (expose-review-archive-expanded-p path))

         (marker
          (if expanded
              "▾"
            "▸"))

         (line-start
          (point)))

    (insert
     (propertize
      marker
      'face
      'expose-review-archive-section-face))

    (insert " ")

    (insert
     (propertize
      (plist-get entry :title)
      'face
      'expose-review-archive-entry-title-face))

    (insert "\n")

    ;; This property is only for RET/TAB expand-collapse behavior.
    ;; It does not make the text clickable or file-opening.
    (add-text-properties
     line-start
     (point)
     (list
      'expose-review-archive-path path))

    (unless
        (expose-review-archive-blank-p
         (plist-get entry :subtitle))

      (insert "  ")

      (insert
       (propertize
        (plist-get entry :subtitle)
        'face
        'expose-review-archive-meta-face))

      (insert "\n"))

    (when expanded
      (expose-review-archive-insert-expanded-entry entry))

    (insert "\n")))

(defun expose-review-archive-title (kind)
  "Return title for archive KIND."

  (pcase kind
    ('full
     "Full Review Archives")

    ('region
     "Region Review Archives")

    (_
     "Review Archives")))

(defun expose-review-archive-render ()
  "Render current archive buffer."

  (let ((inhibit-read-only t)
        (default-directory expose-review-archive-project-root)
        (entries
         (expose-review-archive-entries
          expose-review-archive-kind
          expose-review-archive-project-root)))

    (erase-buffer)

    (insert
     (format
      "# %s\n\n"
      (expose-review-archive-title
       expose-review-archive-kind)))

    (insert
     (format
      "Project: %s\n"
      (abbreviate-file-name
       expose-review-archive-project-root)))

    (insert "TAB expands/collapses one. S-TAB expands/collapses all. q quits.\n")
    (insert "This buffer is read-only; archive entries do not jump to files or apply changes.\n\n")

    (if entries

        (dolist (entry entries)
          (expose-review-archive-insert-entry entry))

      (insert "No archived reviews found.\n"))

    (goto-char (point-min))))

(defun expose-review-archive-buffer-name (kind)
  "Return archive buffer name for KIND."

  (pcase kind
    ('full
     expose-review-archive-full-buffer-name)

    ('region
     expose-review-archive-region-buffer-name)

    (_
     "*EXPOSE Review Archives*")))

(defun expose-review-archive-open (kind)
  "Open archive viewer for KIND."

  (let* ((project-root
          (expose-review-archive-project-root))

         (buffer
          (get-buffer-create
           (expose-review-archive-buffer-name kind))))

    (with-current-buffer buffer
      ;; Important: make project-aware commands like Magit use the same
      ;; project that this archive buffer is displaying.
      (setq default-directory project-root)

      (expose-review-archive-mode)

      ;; `special-mode' may reset some buffer-local state, so set these after
      ;; enabling the mode.
      (setq default-directory project-root)
      (setq expose-review-archive-kind kind)
      (setq expose-review-archive-project-root project-root)

      (unless expose-review-archive-expanded-paths
        (setq expose-review-archive-expanded-paths
              (make-hash-table :test 'equal)))

      (expose-review-archive-render))

    (switch-to-buffer buffer)))

;;;###autoload
(defun expose-review-archive-open-full ()
  "Open read-only full review archive viewer."

  (interactive)

  (expose-review-archive-open 'full))

;;;###autoload
(defun expose-review-archive-open-region ()
  "Open read-only region review archive viewer."

  (interactive)

  (expose-review-archive-open 'region))

(provide 'expose-review-archive)
