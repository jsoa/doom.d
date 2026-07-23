;;; expose-review-buffer.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'expose-log)
(require 'expose-review-store)

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

         (pyright
          (plist-get diagnostics :pyright))

         (ruff
          (plist-get diagnostics :ruff))

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

          (insert "\n")
          (expose-review-buffer-insert-diagnostic-tool-status "Pyright" pyright)
          (expose-review-buffer-insert-diagnostic-tool-status "Ruff" ruff)

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
            "Diagnostic files:    %s\n"
            (or
             (plist-get stats :diagnostic-files)
             0)))

          (insert
           (format
            "Pyright diagnostics: %s\n"
            (or
             (plist-get stats :pyright-diagnostics)
             0)))

          (insert
           (format
            "Ruff diagnostics:    %s\n"
            (or
             (plist-get stats :ruff-diagnostics)
             0)))

          (insert
           (format
            "Diagnostics total:   %s\n"
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

(defun expose-review-buffer-insert-review-input (session)
  "Insert review input health information for SESSION."

  (expose-review-buffer-insert-heading "Review Input")

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
            "Tracked included:    %s\n"
            (or
             (plist-get stats :tracked-files-included)
             0)))

          (insert
           (format
            "Tracked bytes:       %s\n"
            (or
             (plist-get stats :tracked-file-bytes)
             0)))

          (insert
           (format
            "Metadata files:       %s\n"
            (or
             (plist-get stats :metadata-files)
             0))))

      (insert "Review input has not been prepared yet.\n")))

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

(defun expose-review-buffer-format-location (item)
  "Return location string for ITEM."

  (format
   "%s:%s"
   (plist-get item :file)
   (plist-get item :line-start)))

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

    (insert
     (propertize
      (expose-review-buffer-item-location item)
      'face
      'font-lock-keyword-face))

    (insert "\n\n")

    (insert
     (propertize
      (or
       (plist-get item :title)
       "Untitled review item")
      'face
      'bold))

    (insert "\n\n")

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
        'expose-review-item item
        'mouse-face 'highlight)))

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
     (max
      60
      (min
       100
       (- (window-width)
          4)))
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
      'expose-review-heading-face))

    (insert
     (format "%s\n\n" value))))

(defun expose-review-buffer-suggestion-kind (item)
  "Return suggestion kind for ITEM."

  (plist-get
   (plist-get item :suggestion)
   :kind))

(defun expose-review-buffer-suggestion-patch (item)
  "Return suggestion patch for ITEM."

  (plist-get
   (plist-get item :suggestion)
   :patch))

(defun expose-review-buffer-insert-suggestion (item)
  "Insert suggestion details for ITEM."

  (let ((kind
         (expose-review-buffer-suggestion-kind item))

        (patch
         (expose-review-buffer-suggestion-patch item)))

    (insert
     (propertize
      "Suggestion:\n"
      'face
      'expose-review-heading-face))

    (cond
     ((and patch
           (not
            (string-empty-p patch))
           (not
            (eq kind 'none)))

      (insert
       (format
        "Kind: %s\n\n"
        kind))

      (insert "```diff\n")
      (insert patch)
      (unless (string-suffix-p "\n" patch)
        (insert "\n"))
      (insert "```\n\n"))

     (t
      (insert "No applyable suggestion provided for this item.\n\n")))))

(defun expose-review-buffer-insert-items (session)
  "Insert review items from SESSION."

  (expose-review-buffer-insert-heading "Review Items")

  (pcase (plist-get session :state)
    ('preparing
     (insert "Preparing review context...\n"))

    ('sending
     (insert "Sending review request to provider...\n"))

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

    (with-current-buffer buffer
      (setq expose-review-buffer-session session)
      (expose-review-buffer-render session))))

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
        (define-key map (kbd "RET") #'expose-review-buffer-open-item)

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
