;;; expose-review-buffer.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'expose-log)
(require 'expose-review-store)
(require 'diff-mode nil t)
(require 'expose-review-request)

(declare-function expose-review-complete-current "expose-review")
(declare-function expose-review-rerun-current "expose-review")

(defface expose-review-heading-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for Expose review headings."
  :group 'expose-review)

(defface expose-review-high-face
  '((t :inherit error :weight bold))
  "Face for high-severity review items."
  :group 'expose-review)

(defface expose-review-medium-face
  '((t :inherit warning :weight bold))
  "Face for medium-severity review items."
  :group 'expose-review)

(defface expose-review-low-face
  '((t :inherit shadow))
  "Face for low-severity review items."
  :group 'expose-review)

(defvar-local expose-review-buffer-session nil
  "Review session displayed in the current dashboard buffer.")

(defvar-local expose-review-buffer-collapsed-sections
    '(review-input git-status review-scope diagnostics)
  "Collapsed section IDs in the current Expose review dashboard.")

(defun expose-review-buffer-session-progress-message (session fallback)
  "Return SESSION progress message or FALLBACK."

  (or
   (plist-get session :progress-message)
   fallback))

(defun expose-review-buffer-goto-line-column (line column)
  "Move to LINE and COLUMN in the current buffer."

  (goto-char (point-min))
  (forward-line
   (max 0
        (1- line)))
  (move-to-column column))

(defun expose-review-buffer-normalize-collapsed-sections ()
  "Normalize collapsed sections for the current review buffer."

  ;; Existing review buffers may have been created before `diagnostics'
  ;; became collapsible-by-default.
  (unless (memq 'diagnostics expose-review-buffer-collapsed-sections)
    (push 'diagnostics expose-review-buffer-collapsed-sections)))

(defun expose-review-buffer-insert-diagnostic-tool-status (label result)
  "Insert diagnostic tool LABEL status from RESULT."

  (if result

      (progn
        (insert
         (format
          "%s status: %s\n"
          label
          (or
           (plist-get result :status)
           "not-run")))

        (when-let ((error-message
                    (plist-get result :error)))
          (unless (string-empty-p error-message)
            (insert
             (propertize
              (format "%s error: %s\n" label error-message)
              'face
              'warning)))))

    (insert
     (format "%s status: not-run\n" label))))

(defun expose-review-buffer-insert-diagnostics-body (session)
  "Insert diagnostics body for SESSION."

  (let* ((diagnostics
          (plist-get session :diagnostics))

         (python-files
          (plist-get diagnostics :python-files))

         (frontend-files
          (plist-get diagnostics :frontend-files))

         (pyright
          (plist-get diagnostics :pyright))

         (ruff
          (plist-get diagnostics :ruff))

         (typescript
          (plist-get diagnostics :typescript))

         (eslint
          (plist-get diagnostics :eslint))

         (items
          (plist-get diagnostics :items)))

    (if diagnostics

        (progn
          (insert
           (format
            "Python files checked: %s\n"
            (if python-files
                (length python-files)
              0)))

          (when python-files
            (insert "\nChanged Python files:\n")
            (dolist (file python-files)
              (insert
               (format "- %s\n" file))))

          (insert
           (format
            "\nFrontend files checked: %s\n"
            (if frontend-files
                (length frontend-files)
              0)))

          (when frontend-files
            (insert "\nChanged frontend files:\n")
            (dolist (file frontend-files)
              (insert
               (format "- %s\n" file))))

          (insert "\n")
          (expose-review-buffer-insert-diagnostic-tool-status "Pyright" pyright)
          (expose-review-buffer-insert-diagnostic-tool-status "Ruff" ruff)
          (expose-review-buffer-insert-diagnostic-tool-status "TypeScript" typescript)
          (expose-review-buffer-insert-diagnostic-tool-status "ESLint" eslint)

          (insert "\nDiagnostics:\n")

          (if items

              (dolist (item items)
                (insert
                 (format
                  "- %s:%s [%s/%s] %s%s\n"
                  (plist-get item :file)
                  (plist-get item :line)
                  (plist-get item :tool)
                  (plist-get item :severity)
                  (plist-get item :message)
                  (let ((code
                         (plist-get item :code)))

                    (if (and code
                             (not
                              (string-empty-p code)))
                        (format " (%s)" code)
                      "")))))

            (insert "No diagnostics reported by configured tools.\n")))

      (insert "Diagnostics were not collected for this review.\n"))))

(defun expose-review-buffer-section-collapsed-p (section-id)
  "Return non-nil if SECTION-ID is collapsed."

  (memq section-id
        expose-review-buffer-collapsed-sections))

(defun expose-review-buffer-toggle-section (section-id)
  "Toggle collapsed state for SECTION-ID."

  (if (expose-review-buffer-section-collapsed-p section-id)

      (setq expose-review-buffer-collapsed-sections
            (delq section-id
                  expose-review-buffer-collapsed-sections))

    (push section-id
          expose-review-buffer-collapsed-sections)))

(defun expose-review-buffer-insert-review-input-body (session)
  "Insert review input health body for SESSION."

  (let ((stats
         (plist-get session :review-input-stats)))

    (if stats

        (progn
          (insert
           (format
            "Changed files:        %s\n"
            (or
             (plist-get stats :changed-files)
             0)))

          (insert
           (format
            "Branch diff bytes:    %s\n"
            (or
             (plist-get stats :branch-diff-bytes)
             0)))

          (insert
           (format
            "Staged diff bytes:    %s\n"
            (or
             (plist-get stats :staged-diff-bytes)
             0)))

          (insert
           (format
            "Unstaged diff bytes:  %s\n"
            (or
             (plist-get stats :unstaged-diff-bytes)
             0)))

          (insert
           (format
            "Tracked included:     %s\n"
            (or
             (plist-get stats :tracked-files-included)
             0)))

          (insert
           (format
            "Tracked bytes:        %s\n"
            (or
             (plist-get stats :tracked-file-bytes)
             0)))

          (insert
           (format
            "Untracked files:      %s\n"
            (or
             (plist-get stats :untracked-files)
             0)))

          (insert
           (format
            "Untracked included:   %s\n"
            (or
             (plist-get stats :untracked-included)
             0)))

          (insert
           (format
            "Untracked bytes:      %s\n"
            (or
             (plist-get stats :untracked-bytes)
             0)))

          (insert
           (format
            "Metadata files:       %s\n"
            (or
             (plist-get stats :metadata-files)
             0)))

          (insert
           (format
            "Python diagnostic files:   %s\n"
            (or
             (plist-get stats :python-diagnostic-files)
             0)))

          (insert
           (format
            "Frontend diagnostic files: %s\n"
            (or
             (plist-get stats :frontend-diagnostic-files)
             0)))

          (insert
           (format
            "Diagnostic files:          %s\n"
            (or
             (plist-get stats :diagnostic-files)
             0)))

          (insert
           (format
            "Pyright diagnostics:       %s\n"
            (or
             (plist-get stats :pyright-diagnostics)
             0)))

          (insert
           (format
            "Ruff diagnostics:          %s\n"
            (or
             (plist-get stats :ruff-diagnostics)
             0)))

          (insert
           (format
            "TypeScript diagnostics:    %s\n"
            (or
             (plist-get stats :typescript-diagnostics)
             0)))

          (insert
           (format
            "ESLint diagnostics:        %s\n"
            (or
             (plist-get stats :eslint-diagnostics)
             0)))

          (insert
           (format
            "Diagnostics total:         %s\n"
            (or
             (plist-get stats :diagnostics-total)
             0)))
          )

      (insert
       (propertize
        "Review input has not been prepared yet. This may be an older review session. Press R to rerun with current review context.\n"
        'face
        'warning)))))

(defun expose-review-buffer-insert-git-status-body (session)
  "Insert git status body for SESSION."

  (let ((git-status
         (plist-get session :git-status)))

    (if (and git-status
             (not
              (string-empty-p git-status)))

        (insert git-status "\n")

      (insert "Clean or no status available.\n"))))

(defun expose-review-buffer-insert-review-scope-body (session)
  "Insert review scope body for SESSION."

  (let ((files
         (plist-get session :changed-files)))

    (if files

        (dolist (file files)
          (insert
           (format "- %s\n" file)))

      (insert "No changed files detected.\n"))))

(defun expose-review-buffer-section-at-point ()
  "Return collapsible section id at point, or nil."

  (or
   (get-text-property
    (point)
    'expose-review-section)

   (get-text-property
    (line-beginning-position)
    'expose-review-section)

   (get-text-property
    (max
     (point-min)
     (1- (line-end-position)))
    'expose-review-section)))

(defun expose-review-buffer-insert-collapsible-heading (section-id title)
  "Insert collapsible heading TITLE for SECTION-ID."

  (let* ((collapsed
          (expose-review-buffer-section-collapsed-p section-id))

         (marker
          (if collapsed
              "▶"
            "▼"))

         (start
          (point)))

    (insert
     (propertize
      (format "%s %s" marker title)
      'face
      'expose-review-heading-face))

    (insert "\n")

    (add-text-properties
     start
     (point)
     (list
      'expose-review-section section-id
      'mouse-face 'highlight))))

(defun expose-review-buffer-insert-collapsible-section (section-id title body-fn)
  "Insert collapsible section TITLE using BODY-FN."

  (expose-review-buffer-insert-collapsible-heading
   section-id
   title)

  (unless (expose-review-buffer-section-collapsed-p section-id)
    (funcall body-fn))

  (insert "\n"))

(defun expose-review-buffer-name (session)
  "Return dashboard buffer name for SESSION."

  (format
   "*EXPOSE Review: %s:%s*"
   (plist-get session :project-name)
   (plist-get session :branch)))

(defun expose-review-buffer-current-session ()
  "Return the current dashboard review session."

  expose-review-buffer-session)

(defun expose-review-buffer-severity-face (severity)
  "Return face for SEVERITY."

  (pcase severity
    ('high 'expose-review-high-face)
    ('medium 'expose-review-medium-face)
    ('low 'expose-review-low-face)
    (_ 'shadow)))

(defun expose-review-buffer-insert-heading (text)
  "Insert heading TEXT."

  (insert
   (propertize
    text
    'face
    'expose-review-heading-face))

  (insert "\n"))

(defun expose-review-buffer-insert-local-info (session)
  "Insert local git/project information for SESSION."

  (expose-review-buffer-insert-heading "EXPOSE REVIEW")
  (insert "\n")

  (insert
   (format
    "Project: %s\n"
    (plist-get session :project-name)))

  (insert
   (format
    "Root:    %s\n"
    (plist-get session :project-root)))

  (insert
   (format
    "Branch:  %s\n"
    (plist-get session :branch)))

  (insert
   (format
    "Base:    %s\n"
    (plist-get session :base-branch)))

  (insert
   (format
    "State:   %s\n"
    (plist-get session :state)))

  (insert
   (format
    "Provider: %s\n"
    (plist-get session :provider)))

  (insert "\n")

  (expose-review-buffer-insert-collapsible-section
   'review-input
   "Review Input"
   (lambda ()
     (expose-review-buffer-insert-review-input-body session)))

  (expose-review-buffer-insert-collapsible-section
   'git-status
   "Git Status"
   (lambda ()
     (expose-review-buffer-insert-git-status-body session)))

  (expose-review-buffer-insert-collapsible-section
   'review-scope
   "Review Scope"
   (lambda ()
     (expose-review-buffer-insert-review-scope-body session)))

  (expose-review-buffer-insert-collapsible-section
   'diagnostics
   "Diagnostics"
   (lambda ()
     (expose-review-buffer-insert-diagnostics-body session)))

  )

(defun expose-review-buffer-activate ()
  "Toggle section or open review item at point."

  (interactive)

  (if-let ((section-id
            (expose-review-buffer-section-at-point)))

      (progn
        (expose-review-buffer-toggle-section section-id)
        (expose-review-buffer-render expose-review-buffer-session)

        ;; Try to keep point on the toggled section after rerender.
        (goto-char (point-min))
        (when (search-forward
               (pcase section-id
                 ('review-input "Review Input")
                 ('git-status "Git Status")
                 ('review-scope "Review Scope")
                 ('diagnostics "Diagnostics")
                 (_ ""))
               nil
               t)
          (beginning-of-line)))

    (expose-review-buffer-open-item)))

(defun expose-review-buffer-insert-item (item)
  "Insert detailed review ITEM."

  (let* ((block-start
          (point))

         (severity
          (plist-get item :severity))

         (category
          (plist-get item :category))

         (status
          (plist-get item :status))

         (face
          (expose-review-buffer-severity-face severity)))

    (expose-review-buffer-item-separator)

    (let ((header-start
           (point)))

      (insert
       (format
        "[%s] %s · %s · %s\n"
        (upcase
         (format "%s" severity))
        (plist-get item :id)
        category
        status))

      (add-text-properties
       header-start
       (point)
       (list
        'face face)))

    ;; Blue/link-looking path.
    (expose-review-buffer-insert-item-location item)

    (expose-review-buffer-insert-patch-target item)

    ;; Title, bounded to same width as separator.
    (expose-review-buffer-insert-filled-text
     (or
      (plist-get item :title)
      "Untitled review item")
     'bold)

    (insert "\n")

    (expose-review-buffer-insert-label-line
     "Comment"
     (plist-get item :comment))

    (expose-review-buffer-insert-label-line
     "Anchor"
     (plist-get item :anchor-text))

    (expose-review-buffer-insert-suggestion item)

    (let ((block-end
           (point)))

      ;; Make RET work anywhere inside the review item block.
      (add-text-properties
       block-start
       block-end
       (list
        'expose-review-item item)))

    (insert "\n")))

(defun expose-review-buffer-item-line-range (item)
  "Return display line range for ITEM."

  (let ((line-start
         (plist-get item :line-start))

        (line-end
         (plist-get item :line-end)))

    (if (and line-end
             line-start
             (/= line-start line-end))

        (format "%s-%s" line-start line-end)

      (format "%s" line-start))))

(defun expose-review-buffer-insert-item-location (item)
  "Insert clickable-looking location for ITEM."

  (insert
   (propertize
    (expose-review-buffer-item-location item)
    'face
    'link
    'help-echo
    "RET opens this finding"))

  (insert "\n\n"))

(defun expose-review-buffer-item-location (item)
  "Return display location for ITEM."

  (format
   "%s:%s"
   (plist-get item :file)
   (expose-review-buffer-item-line-range item)))

(defun expose-review-buffer-item-separator ()
  "Insert a review item separator."

  (insert
   (propertize
    (make-string
     (expose-review-buffer-content-width)
     ?─)
    'face
    'shadow))

  (insert "\n"))

(defun expose-review-buffer-insert-label-line (label value)
  "Insert LABEL and VALUE when VALUE is present."

  (when (and value
             (not
              (string-empty-p
               (format "%s" value))))

    (insert
     (propertize
      (format "%s:\n" label)
      'face
      (expose-review-buffer-subsection-face)))

    (expose-review-buffer-insert-filled-text value)
    (insert "\n")))

(defun expose-review-buffer-suggestion-patch-range (item)
  "Return patch target range for ITEM."

  (let* ((suggestion
          (plist-get item :suggestion))

         (line-start
          (plist-get suggestion :patch-line-start))

         (line-end
          (plist-get suggestion :patch-line-end))

         (patch
          (expose-review-buffer-suggestion-patch item)))

    (or
     ;; Numeric unified diff hunk.
     (expose-review-request-patch-new-range patch)

     ;; Header-only hunk fallback.
     (expose-review-buffer-patch-search-range item)

     ;; Stored metadata fallback.
     (and line-start
          line-end
          (cons line-start line-end)))))

(defun expose-review-buffer-non-empty-string-p (value)
  "Return non-nil if VALUE is a non-empty string."

  (and
   (stringp value)
   (not
    (string-empty-p
     (string-trim value)))))

(defun expose-review-buffer-patch-content-lines (patch prefix)
  "Return meaningful PATCH lines starting with PREFIX."

  (let (lines)

    (dolist (line
             (split-string
              (or patch "")
              "\n"
              t))

      (when (and
             (string-prefix-p prefix line)
             (not
              (string-prefix-p "+++" line))
             (not
              (string-prefix-p "---" line)))

        (let ((content
               (string-trim
                (substring line 1))))

          (when (expose-review-buffer-non-empty-string-p content)
            (push content lines)))))

    (nreverse lines)))

(defun expose-review-buffer-item-file-path (item)
  "Return absolute file path for ITEM."

  (when-let* ((session
               expose-review-buffer-session)

              (project-root
               (plist-get session :project-root))

              (file
               (plist-get item :file)))

    (expand-file-name file project-root)))

(defun expose-review-buffer-search-file-line-content (path content)
  "Return line number where CONTENT appears in PATH."

  (when (and path
             (file-readable-p path)
             (expose-review-buffer-non-empty-string-p content))

    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))

      (when (search-forward content nil t)
        (line-number-at-pos
         (match-beginning 0))))))

(defun expose-review-buffer-patch-search-range (item)
  "Return patch target range for ITEM by searching patch contents."

  (let* ((patch
          (expose-review-buffer-suggestion-patch item))

         (path
          (expose-review-buffer-item-file-path item))

         ;; Dashboard is showing the current file, so removed lines are usually
         ;; the best target for delete/replace suggestions.
         (candidate-lines
          (append
           (expose-review-buffer-patch-content-lines patch "-")
           (expose-review-buffer-patch-content-lines patch "+")))

         found-lines)

    (dolist (content candidate-lines)
      (when-let ((line
                  (expose-review-buffer-search-file-line-content
                   path
                   content)))
        (push line found-lines)))

    (when found-lines
      (cons
       (apply #'min found-lines)
       (apply #'max found-lines)))))

(defun expose-review-buffer-patch-target-location (item)
  "Return patch target display location for ITEM."

  (when-let ((range
              (expose-review-buffer-suggestion-patch-range item)))

    (let ((file
           (plist-get item :file))

          (line-start
           (car range))

          (line-end
           (cdr range)))

      (if (= line-start line-end)
          (format "%s:%s" file line-start)
        (format "%s:%s-%s" file line-start line-end)))))

(defun expose-review-buffer-insert-patch-target (item)
  "Insert patch target for ITEM when available."

  (when-let ((location
              (expose-review-buffer-patch-target-location item)))

    (insert
     (propertize
      "Patch target: "
      'face
      (expose-review-buffer-subsection-face)))

    (insert
     (propertize
      location
      'face
      'link
      'help-echo
      "Suggested patch target"))

    (insert "\n\n")))

(defun expose-review-buffer-suggestion-kind (item)
  "Return suggestion kind for ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :kind)
   'none))

(defun expose-review-buffer-suggestion-text (item)
  "Return suggestion text for ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :text)
   ""))

(defun expose-review-buffer-suggestion-patch (item)
  "Return suggestion patch for ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :patch)
   ""))

(defun expose-review-buffer-insert-suggestion (item)
  "Insert suggestion details for ITEM."

  (let ((kind
         (expose-review-buffer-suggestion-kind item))

        (text
         (expose-review-buffer-suggestion-text item))

        (patch
         (expose-review-buffer-suggestion-patch item)))

    (insert
     (propertize
      "Suggestion:\n"
      'face
      (expose-review-buffer-subsection-face)))

    (cond
     ((and
       (eq kind 'text)
       (not
        (string-empty-p text)))

      (expose-review-buffer-insert-filled-text text)
      (insert "\n"))

     ((and
       (eq kind 'patch)
       (not
        (string-empty-p patch)))

      (when (not
             (string-empty-p text))
        (expose-review-buffer-insert-filled-text text)
        (insert "\n"))

      (expose-review-buffer-insert-diff-patch patch)
      )

     (t
      (insert "No suggestion provided for this item.\n\n")))))

(defun expose-review-buffer-insert-items (session)
  "Insert review items from SESSION."

  (expose-review-buffer-insert-heading "Review Items")

  (pcase (plist-get session :state)
    ('preparing
     (insert
      (format
       "%s\n"
       (expose-review-buffer-session-progress-message
        session
        "Preparing review context..."))))

    ('sending
     (insert
      (format
       "%s\n"
       (expose-review-buffer-session-progress-message
        session
        "Waiting for AI provider response..."))))

    ('running
     (insert "AI review is running...\n"))

    ('failed
     (insert
      (propertize
       "AI review failed.\n"
       'face
       'error))

     (when-let ((error-message
                 (plist-get session :error)))
       (insert "\n" error-message "\n")))

    (_
     (let ((items
            (plist-get session :items)))

       (if items

           (progn
             (insert
              (propertize
               "RET opens the finding. TAB/S-TAB moves between findings. RET on a section toggles it.\n\n"
               'face
               'shadow))

             (dolist (item items)
               (expose-review-buffer-insert-item item))

             (expose-review-buffer-item-separator))

         (insert "No review findings.\n"))))))

(defun expose-review-buffer-content-width ()
  "Return preferred content width for review item text."

  (max
   60
   (min
    100
    (- (window-width)
       4))))

(defun expose-review-buffer-subsection-face ()
  "Return face used for review subsection labels."

  (if (facep 'expose-review-low-face)
      'expose-review-low-face
    'font-lock-doc-face))

(defun expose-review-buffer-fill-string (text)
  "Return TEXT filled to `expose-review-buffer-content-width'."

  (let ((width
         (expose-review-buffer-content-width)))

    (with-temp-buffer
      (let ((fill-column width)
            (adaptive-fill-mode t))

        (insert
         (string-trim-right
          (or text "")))

        (goto-char (point-min))
        (fill-region
         (point-min)
         (point-max))

        (buffer-string)))))

(defun expose-review-buffer-insert-filled-text (text &optional face)
  "Insert TEXT filled to review width, optionally using FACE."

  (let ((filled
         (expose-review-buffer-fill-string text)))

    (if face
        (insert
         (propertize filled 'face face))
      (insert filled))

    (unless (string-suffix-p "\n" filled)
      (insert "\n"))))

(defun expose-review-buffer-fontify-diff (text)
  "Return TEXT fontified as a unified diff."

  (if (not (fboundp 'diff-mode))
      text

    (with-temp-buffer
      (delay-mode-hooks
        (diff-mode))

      (font-lock-mode 1)

      (insert
       (string-trim-right
        (or text "")))

      (font-lock-ensure
       (point-min)
       (point-max))

      (buffer-string))))

(defun expose-review-buffer-insert-diff-patch (patch)
  "Insert PATCH with diff highlighting."

  (insert
   (propertize
    "Patch:\n"
    'face
    (expose-review-buffer-subsection-face)))

  (insert
   (expose-review-buffer-fontify-diff patch))

  (unless (bolp)
    (insert "\n"))

  (insert "\n"))

(defun expose-review-buffer-render (session)
  "Render SESSION in the current buffer."

  (let ((inhibit-read-only t))
    (erase-buffer)

    (expose-review-buffer-insert-local-info session)
    (expose-review-buffer-insert-items session)

    (goto-char (point-min))))

(defun expose-review-buffer-open (session)
  "Open dashboard for SESSION."

  (let ((buffer
         (get-buffer-create
          (expose-review-buffer-name session))))

    (with-current-buffer buffer
      (expose-review-buffer-mode)
      (setq expose-review-buffer-session session)
      (expose-review-buffer-normalize-collapsed-sections)
      (expose-review-buffer-render session))

    (switch-to-buffer buffer)))

(defun expose-review-buffer-refresh-open (session)
  "Refresh dashboard for SESSION if it is open."

  (when-let ((buffer
              (get-buffer
               (expose-review-buffer-name session))))

    (let ((window
           (get-buffer-window buffer t)))

      (with-current-buffer buffer

        (let ((point-line
               (line-number-at-pos))

              (point-column
               (current-column))

              (window-start-line
               (when window
                 (with-selected-window window
                   (line-number-at-pos
                    (window-start))))))

          (setq expose-review-buffer-session session)
          (expose-review-buffer-render session)

          ;; `expose-review-buffer-render' intentionally starts at the top for
          ;; first render. Refreshes should preserve where the user was reading.
          (expose-review-buffer-goto-line-column
           point-line
           point-column)

          (when (and window
                     window-start-line)
            (with-selected-window window
              (save-excursion
                (expose-review-buffer-goto-line-column
                 window-start-line
                 0)

                (set-window-start
                 window
                 (point)
                 t)))))))))

(defun expose-review-buffer-current-item ()
  "Return review item at point."

  (or
   (get-text-property
    (point)
    'expose-review-item)

   (get-text-property
    (line-beginning-position)
    'expose-review-item)

   (get-text-property
    (max
     (point-min)
     (1- (line-end-position)))
    'expose-review-item)))

(defun expose-review-buffer-next-item-position ()
  "Return position of the next review item after point."

  (let ((current
         (expose-review-buffer-current-item))

        (position
         (point))

        found)

    (while (and
            (not found)
            (< position
               (point-max)))

      (setq position
            (next-single-property-change
             position
             'expose-review-item
             nil
             (point-max)))

      (let ((item
             (get-text-property
              position
              'expose-review-item)))

        (when (and item
                   (not
                    (eq item current)))
          (setq found position))))

    found))

(defun expose-review-buffer-previous-item-position ()
  "Return position of the previous review item before point."

  (let ((current
         (expose-review-buffer-current-item))

        (position
         (point))

        found)

    (while (and
            (not found)
            (> position
               (point-min)))

      (setq position
            (previous-single-property-change
             position
             'expose-review-item
             nil
             (point-min)))

      ;; Step back into the previous property range.
      (let* ((probe
              (max
               (point-min)
               (1- position)))

             (item
              (get-text-property
               probe
               'expose-review-item)))

        (when (and item
                   (not
                    (eq item current)))
          (setq found probe))))

    found))

(defun expose-review-buffer-next-item ()
  "Move to next review item."

  (interactive)

  (if-let ((position
            (expose-review-buffer-next-item-position)))

      (progn
        (goto-char position)
        (beginning-of-line))

    (message "No next review item")))

(defun expose-review-buffer-previous-item ()
  "Move to previous review item."

  (interactive)

  (if-let ((position
            (expose-review-buffer-previous-item-position)))

      (progn
        (goto-char position)
        (beginning-of-line))

    (message "No previous review item")))

(defun expose-review-buffer-open-item ()
  "Open the review item at point."

  (interactive)

  (let ((item
         (expose-review-buffer-current-item)))

    (unless item
      (user-error "No review item on this line"))

    (let* ((session
            expose-review-buffer-session)

           (project-root
            (plist-get session :project-root))

           (file
            (plist-get item :file))

           (line
            (or
             (plist-get item :line-start)
             1))

           (path
            (expand-file-name file project-root)))

      (unless (file-exists-p path)
        (user-error "File does not exist: %s" path))

      (find-file path)
      (goto-char (point-min))
      (forward-line
       (max 0
            (1- line)))
      (recenter))))

(defun expose-review-buffer-reload ()
  "Reload current review dashboard from disk."

  (interactive)

  (unless expose-review-buffer-session
    (user-error "No review session in this buffer"))

  (let* ((project-root
          (plist-get expose-review-buffer-session :project-root))

         (branch
          (plist-get expose-review-buffer-session :branch))

         (session
          (expose-review-store-read-active
           project-root
           branch)))

    (unless session
      (user-error "No active review session found"))

    (setq expose-review-buffer-session session)
    (expose-review-buffer-render session)))

;;; ---------------------------------------------------------------------------
;;; Mode
;;; ---------------------------------------------------------------------------

(defvar expose-review-buffer-mode-map
  (make-sparse-keymap)
  "Keymap for `expose-review-buffer-mode'.")

(setq expose-review-buffer-mode-map
      (let ((map
             (make-sparse-keymap)))

        ;; Review-specific navigation.
        (define-key map (kbd "TAB") #'expose-review-buffer-next-item)
        (define-key map (kbd "<backtab>") #'expose-review-buffer-previous-item)
        (define-key map (kbd "RET") #'expose-review-buffer-activate)

        ;; Dashboard actions.
        (define-key map (kbd "g") #'expose-review-buffer-reload)
        (define-key map (kbd "C") #'expose-review-complete-current)
        (define-key map (kbd "R") #'expose-review-rerun-current)
        (define-key map (kbd "q") #'quit-window)

        map))

(define-derived-mode expose-review-buffer-mode special-mode "Expose-Review"
  "Major mode for Expose review dashboards."

  ;; This dashboard is prose-heavy. Let review comments wrap visually.
  ;; This does not modify/corrupt copied text; it is display-only wrapping.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only t)

  (visual-line-mode 1)

  ;; This buffer should still feel like a normal Evil-readable buffer.
  (when (bound-and-true-p evil-local-mode)
    (evil-normal-state)))

(with-eval-after-load 'evil
  ;; Keep normal Evil movement/copy/search behavior.
  ;; Only override review/dashboard-specific keys.
  (evil-define-key* 'normal expose-review-buffer-mode-map
    (kbd "TAB") #'expose-review-buffer-next-item
    (kbd "<backtab>") #'expose-review-buffer-previous-item
    (kbd "RET") #'expose-review-buffer-activate
    (kbd "g") #'expose-review-buffer-reload
    (kbd "C") #'expose-review-complete-current
    (kbd "R") #'expose-review-rerun-current
    (kbd "q") #'quit-window)

  (evil-define-key* 'motion expose-review-buffer-mode-map
    (kbd "TAB") #'expose-review-buffer-next-item
    (kbd "<backtab>") #'expose-review-buffer-previous-item
    (kbd "RET") #'expose-review-buffer-activate
    (kbd "g") #'expose-review-buffer-reload
    (kbd "C") #'expose-review-complete-current
    (kbd "R") #'expose-review-rerun-current
    (kbd "q") #'quit-window)

  (evil-set-initial-state 'expose-review-buffer-mode 'normal))

(provide 'expose-review-buffer)
