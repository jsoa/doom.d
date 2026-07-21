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

  (expose-review-buffer-insert-heading "Git Status")

  (let ((git-status
         (plist-get session :git-status)))

    (if (and git-status
             (not
              (string-empty-p git-status)))

        (insert git-status "\n")

      (insert "Clean or no status available.\n")))

  (insert "\n")

  (expose-review-buffer-insert-heading "Review Scope")

  (let ((files
         (plist-get session :changed-files)))

    (if files

        (dolist (file files)
          (insert
           (format "- %s\n" file)))

      (insert "No changed files detected.\n")))

  (insert "\n"))

(defun expose-review-buffer-format-location (item)
  "Return location string for ITEM."

  (format
   "%s:%s"
   (plist-get item :file)
   (plist-get item :line-start)))

(defun expose-review-buffer-insert-item (item)
  "Insert review ITEM."

  (let* ((start
          (point))

         (severity
          (plist-get item :severity))

         (face
          (expose-review-buffer-severity-face severity))

         (status
          (plist-get item :status)))

    (insert
     (format
      "[%-6s] %-4s %-12s %-36s %s\n"
      severity
      (plist-get item :id)
      status
      (expose-review-buffer-format-location item)
      (plist-get item :title)))

    (add-text-properties
     start
     (point)
     (list
      'expose-review-item item
      'mouse-face 'highlight
      'face face))))

(defun expose-review-buffer-insert-items (session)
  "Insert review items from SESSION."

  (expose-review-buffer-insert-heading "Review Items")

  (pcase (plist-get session :state)
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
               "RET opens the finding. TAB/S-TAB moves between findings.\n\n"
               'face
               'shadow))

             (dolist (item items)
               (expose-review-buffer-insert-item item)))

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
      (expose-review-buffer-render session))

    ;; Use the current window like a project dashboard, instead of letting
    ;; Doom/popup display rules choose a small popup window.
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
  "Return review item on the current line."

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

(defun expose-review-buffer-next-item ()
  "Move to next review item."

  (interactive)

  (let ((found nil))
    (while (and
            (not found)
            (< (point)
               (point-max)))

      (forward-line 1)

      (when (expose-review-buffer-current-item)
        (setq found t)))

    (unless found
      (message "No next review item"))))

(defun expose-review-buffer-previous-item ()
  "Move to previous review item."

  (interactive)

  (let ((found nil))
    (while (and
            (not found)
            (> (point)
               (point-min)))

      (forward-line -1)

      (when (expose-review-buffer-current-item)
        (setq found t)))

    (unless found
      (message "No previous review item"))))

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

  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)

  ;; This buffer should still feel like a normal Evil-readable buffer.
  ;; Previous versions forced emacs-state, which made j/k stop behaving
  ;; like normal navigation.
  (when (bound-and-true-p evil-local-mode)
    (evil-normal-state)))

(with-eval-after-load 'evil
  ;; Keep normal Evil movement/copy/search behavior.
  ;; Only override review/dashboard-specific keys.
  (evil-define-key* 'normal expose-review-buffer-mode-map
    (kbd "TAB") #'expose-review-buffer-next-item
    (kbd "<backtab>") #'expose-review-buffer-previous-item
    (kbd "RET") #'expose-review-buffer-open-item
    (kbd "g") #'expose-review-buffer-reload
    (kbd "C") #'expose-review-complete-current
    (kbd "R") #'expose-review-rerun-current
    (kbd "q") #'quit-window)

  (evil-define-key* 'motion expose-review-buffer-mode-map
    (kbd "TAB") #'expose-review-buffer-next-item
    (kbd "<backtab>") #'expose-review-buffer-previous-item
    (kbd "RET") #'expose-review-buffer-open-item
    (kbd "g") #'expose-review-buffer-reload
    (kbd "C") #'expose-review-complete-current
    (kbd "R") #'expose-review-rerun-current
    (kbd "q") #'quit-window)

  (evil-set-initial-state 'expose-review-buffer-mode 'normal))

(provide 'expose-review-buffer)
