;;; +dashboard.el -*- lexical-binding: t; -*-


;; =========================
;; Helpers
;; =========================

(defconst jsoa/dashboard-width 90)

(defface jsoa/dashboard-header
  '((t (:weight bold :height 1.1)))
  "Dashboard section headers.")

(defun jsoa/start-section (title)
  (insert (propertize title 'face 'jsoa/dashboard-header))
  (insert "\n")
  (move-to-column 0))

(defun jsoa/dashboard-left-padding ()
  (max 0 (/ (- (window-width) jsoa/dashboard-width) 2)))

(defun jsoa/dashboard-separator ()
  (insert (make-string jsoa/dashboard-width ?-) "\n"))

(defun jsoa/action-button (num label action)
  (list
   :text (format "[%d] %s" num label)
   :action action))

(defun jsoa/dashboard-move-to-content ()
  (goto-char (point-min))
  (when-let ((pos (next-button (point) t)))
    (goto-char pos)))

(defun jsoa/open-file-other-window (file root &optional line)
  "Open FILE in another window and optionally jump to LINE."
  (let ((win (get-mru-window nil t t)))
    (when win (select-window win)))
  (find-file (expand-file-name file root))
  (when line
    (goto-char (point-min))
    (forward-line (1- line))))

(defun jsoa/insert-file-button (file root)
  (let ((start (point)))
    (insert file)
    (make-text-button
     start (point)
     'action (lambda (_)
               (jsoa/open-file-other-window file root))
     'follow-link t
     'face 'link))
  (insert "\n"))

(defun jsoa/insert-todo-button (line root)
  (when (string-match "^\\([^:]+\\):\\([0-9]+\\):\\(.*\\)$" line)
    (let* ((file (match-string 1 line))
           (linenum (string-to-number (match-string 2 line)))
           (text (string-trim (match-string 3 line)))

           ;; split TODO keyword from rest
           (parts (split-string text " " t))
           (keyword (car parts))
           (rest (string-join (cdr parts) " ")))

      ;; clickable file:line
      (let ((start (point)))
        (insert (format "%s:%d" file linenum))
        (make-text-button
         start (point)
         'action (lambda (_)
                   (jsoa/open-file-other-window file root linenum))
         'follow-link nil
         'face 'link))

      (insert ": ")

      ;; styled TODO keyword
      (insert
       (propertize
        keyword
        'face (cond
               ((string= keyword "FIXME:") 'error)
               ((string= keyword "TODO:")  'font-lock-warning-face)
               ((string= keyword "HACK:")  'font-lock-constant-face)
               ((string= keyword "NOTE:")  'font-lock-doc-face)
               (t 'default))))

      ;; rest of line (normal text)
      (when rest
        (insert " " rest))

      (insert "\n"))))

;; =========================
;; Project info
;; =========================

(defun jsoa/project-info (root)
  (let* ((name (file-name-nondirectory (directory-file-name root)))
         (files
          (if (file-directory-p (expand-file-name ".git" root))
              (let ((default-directory root))
                (length
                 (split-string
                  (shell-command-to-string
                   "git ls-files --others --cached --exclude-standard")
                  "\n" t)))
            (length
             (directory-files-recursively root ".*" nil nil t)))))

    (let ((default-directory root))
      (let ((todos (string-trim
                    (shell-command-to-string
                     "rg -c 'TODO:' | awk -F: '{sum+=$2} END {print sum}'")))
            (fixmes (string-trim
                     (shell-command-to-string
                      "rg -c 'FIXME:' | awk -F: '{sum+=$2} END {print sum}'")))
            (branch (ignore-errors
                      (string-trim
                       (shell-command-to-string
                        "git rev-parse --abbrev-ref HEAD")))))

        (insert "\n")
        (jsoa/start-section (format "Project: %s" name))
        (insert (format "Files:   %d\n" files))
        (insert (format "TODOs:   %s (FIXME: %s)\n" todos fixmes))
        (insert (format "Branch:  %s\n\n" (or branch "N/A")))))))

;; =========================
;; Project actions
;; =========================

(defvar jsoa/dashboard-actions-list nil)

(defun jsoa/dashboard-actions (root)
  (jsoa/start-section "Actions")

  (setq jsoa/dashboard-actions-list
        `((1 "Magit Status"
           ,(lambda () (let ((default-directory root)) (magit-status root))))
          (2 "Find File"
             ,(lambda () (let ((default-directory root)) (call-interactively #'projectile-find-file))))
          (3 "Search"
             ,(lambda () (let ((default-directory root)) (call-interactively #'+default/search-project))))))

  ;; map for keybindings
  (setq jsoa/dashboard-actions-map
        (mapcar (lambda (a) (cons (nth 0 a) (nth 2 a)))
                jsoa/dashboard-actions-list))

  (let ((start (point)))
    (insert
     (mapconcat (lambda (a)
                  (format "[%d] %s" (nth 0 a) (nth 1 a)))
                jsoa/dashboard-actions-list
                "   ")
     "\n\n")

    ;; attach buttons
    (dolist (a jsoa/dashboard-actions-list)
      (let ((text (format "[%d] %s" (nth 0 a) (nth 1 a)))
            (fn   (nth 2 a)))
        (save-excursion
          (goto-char start)
          (when (search-forward text nil t)
            (make-text-button
             (match-beginning 0) (match-end 0)
             'action (lambda (_) (funcall fn))
             'follow-link t
             'face 'link)))))))

;; =========================
;; Git summary
;; =========================

(defun jsoa/git-summary (root)
  (let ((default-directory root))
    (when (file-directory-p (expand-file-name ".git" root))
      (let* ((status-lines
              (split-string
               (shell-command-to-string "git status --porcelain=v1")
               "\n" t))

             (untracked
              (seq-filter (lambda (l) (string-prefix-p "??" l)) status-lines))

             (unstaged
              (seq-filter
               (lambda (l)
                 (and (>= (length l) 2)
                      (not (string-prefix-p "??" l))
                      (not (eq (aref l 1) ?\s))))
               status-lines))

             (stashes
              (seq-take
               (split-string
                (shell-command-to-string "git stash list")
                "\n" t)
               5))

             (commits
              (split-string
               (shell-command-to-string
                "git log -5 --pretty=format:'%h %d %s'")
               "\n" t)))

        ;; Untracked
        (when untracked
          (jsoa/start-section "Untracked files")
          (dolist (l untracked)
            (jsoa/insert-file-button (substring l 3) root))
          (insert "\n")
          (jsoa/dashboard-separator)
          )

        ;; Unstaged
        (when unstaged

          (jsoa/start-section (format "Unstaged changes (%d)" (length unstaged)))

          (dolist (l unstaged)
            (let* ((file (string-trim (substring l 3)))
                   (status (substring l 0 2))
                   (label
                    (cond
                     ((string-match "^ M" status) "modified")
                     ((string-match "^ D" status) "deleted")
                     ((string-match "^ A" status) "added")
                     ((string-match "^ R" status) "renamed")
                     (t "changed"))))
              (let ((start (point)))
                (insert (format "%-10s %s\n" label file))
                (make-text-button
                 (+ start 11) (point) ;; after label
                 'action (lambda (_)
                           (jsoa/open-file-other-window file root))
                 'follow-link t
                 'face 'link))
              ))
          (insert "\n")
          (jsoa/dashboard-separator)
          )

        ;; Stashes
        (when stashes

          (jsoa/start-section (format "Stashes (%d)" (length stashes)))

          (dolist (s stashes)
            (if (string-match "^\\(stash@{[0-9]+}\\)\\(.*\\)$" s)
                (let ((ref (match-string 1 s))   ;; stash@{0}
                      (msg (string-trim (match-string 2 s))))

                  ;; clickable stash ref
                  (let ((start (point)))
                    (insert ref)
                    (make-text-button
                     start (point)
                     'action (lambda (_)
                               (let ((default-directory root))
                                 (magit-stash-show ref)))
                     'follow-link nil
                     'face 'link))

                  ;; rest of line (non-clickable)
                  (when (not (string-empty-p msg))
                    (insert " " msg)))

              ;; fallback (just in case format is weird)
              (insert s))

            (insert "\n"))
          (insert "\n")
          (jsoa/dashboard-separator)
          )

        ;; Commits
        (when commits
          (jsoa/start-section "Recent Commits")
          (dolist (c commits)
            (if (string-match "^\\([a-f0-9]+\\)\\(.*\\)$" c)
                (let ((hash (match-string 1 c))
                      (msg (string-trim (match-string 2 c))))

                  ;; clickable commit hash
                  (let ((start (point)))
                    (insert hash)
                    (make-text-button
                     start (point)
                     'action (lambda (_)
                               (let ((default-directory root))
                                 (magit-show-commit hash)))
                     'follow-link nil
                     'face 'link))

                  ;; rest of line (non-clickable)
                  (when (not (string-empty-p msg))
                    (insert " " msg)))

              ;; fallback
              (insert c))

            (insert "\n"))
          (insert "\n")
          )))))

(defun jsoa/todos-section (root)
  "Insert TODOs section for ROOT."
  (let ((default-directory root))
    (let ((output
           (shell-command-to-string
            "rg --no-heading --line-number --color never \
-e 'TODO:' -e 'FIXME:' -e 'HACK:' -e 'NOTE:'")))

      (if (string-empty-p (string-trim output))
          (insert (propertize "No TODOs found 🎉\n\n" 'face 'success))

        (let* ((lines (split-string output "\n" t))
               (count (length lines)))

          (jsoa/start-section (format "TODOs (%d)" count))

          (dolist (line lines)
            (jsoa/insert-todo-button line root))

          (insert "\n"))))))

;; =========================
;; Render
;; =========================

(defun jsoa/render-project-dashboard (root)
  (let ((inhibit-read-only t)
        (default-directory root))

    (erase-buffer)

    (jsoa/project-info root)

    (jsoa/dashboard-separator)

    (jsoa/dashboard-actions root)

    (jsoa/dashboard-separator)

    (jsoa/git-summary root)

    (jsoa/dashboard-separator)

    (jsoa/todos-section root)

    ;; Center everything once
    (indent-rigidly (point-min) (point)
                    (jsoa/dashboard-left-padding))

    (jsoa/dashboard-move-to-content)))

;; =========================
;; Commands
;; =========================

(defvar jsoa/dashboard-actions-map nil)

(defun jsoa/dashboard-run-action (n)
  (when-let ((fn (alist-get n jsoa/dashboard-actions-map)))
    (funcall fn)))

(define-derived-mode jsoa-dashboard-mode special-mode "Dashboard"
  "Major mode for project dashboard.")
(map! :map jsoa-dashboard-mode-map
      :n "1" (lambda () (interactive) (jsoa/dashboard-run-action 1))
      :n "2" (lambda () (interactive) (jsoa/dashboard-run-action 2))
      :n "3" (lambda () (interactive) (jsoa/dashboard-run-action 3)))

(defun jsoa/project-command-center (project-root)
  (let* ((name (file-name-nondirectory
                (directory-file-name project-root)))
         (buf (get-buffer-create (format "*todos:%s*" name)))
         (gitignore (expand-file-name ".gitignore" project-root)))

    ;; Anchor project
    (when (file-exists-p gitignore)
      (find-file-noselect gitignore))

    (delete-other-windows)
    (balance-windows)

    ;; Show buffer
    (switch-to-buffer buf)

    ;; Initial render
    (with-current-buffer buf
      (cd project-root)
      (jsoa-dashboard-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jsoa/render-project-dashboard project-root)))

    (run-with-idle-timer
     0 nil
     (lambda ()
       (when (and (buffer-live-p buf)
                  (eq (current-buffer) buf))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (jsoa/render-project-dashboard project-root))))))))

(defun jsoa/project-dashboard ()
  "Open dashboard for current project."
  (interactive)
  (let ((root (projectile-project-root)))
    (unless root
      (user-error "Not in a project"))
    (jsoa/project-command-center root)))
