;;; modules/+magit.el -*- lexical-binding: t; -*-

;;
;; Magit
;;

;; Insert a commit message prefix, i.e. [ticket number]
;; If a branch name starts with "NAME-NUMBER", get it and supply
;; a commit prefix of [NAME-NUMBER] otherwise insert [-]
(defun jsoa/git-commit-setup ()
  "Insert commit prefix [ABC-123]-style from current branch name, else [-]."
  (let ((branch-name (or (magit-get-current-branch) "")))
    (save-match-data
      ;; Capture KEY-NUM where KEY is uppercase letters and NUM is digits.
      ;; Must appear at start or after a slash.
      ;; Works for:
      ;; - ABC-123_my_test_branch
      ;; - ABC-123-my-test-branch
      ;; - feature/ABC-123-my_test_branch
      ;; - js/ABC-123
      ;; - js/ABC-123_mytestbranch
      ;; - some/thing/else/ABC-123
      (if (string-match "\\(?:^\\|/\\)\\([A-Z]+-[0-9]+\\)\\(?:\\b\\|[_-]\\|/\\|$\\)" branch-name)
          (insert (format "[%s] " (match-string 1 branch-name)))
        (insert "[-] ")))))

;; Custom commit message prefix when commiting
(add-hook! 'git-commit-setup-hook 'jsoa/git-commit-setup)

(after! magit
  ;; Word-level diff refinement, without highlighting whitespace-only
  ;; changes as part of it.
  (setq magit-diff-refine-hunk t
        magit-diff-paint-whitespace nil
        magit-diff-refine-ignore-whitespace t)

  ;; Diffs are not shown automatically in the status buffer by default;
  ;; this toggles `magit-insert-diff' in and out of
  ;; `magit-status-sections-hook' on demand instead.
  (defun jsoa/magit-toggle-diff ()
    (interactive)
    (if (member 'magit-insert-diff magit-status-sections-hook)
        (progn
          (setq magit-status-sections-hook
                (remove 'magit-insert-diff magit-status-sections-hook))
          (message "Diffs disabled"))
      (add-to-list 'magit-status-sections-hook 'magit-insert-diff t)
      (message "Diffs enabled"))
    (magit-refresh))

  (map! :map magit-status-mode-map
        :n "TAB" #'jsoa/magit-toggle-diff)

  (setq magit-diff-large-file-threshold (* 512 1024))

  (setq magit-repository-directories
        `(("~/code" . 2)
          ("~/Development/projects" . 2)))
  (setq magit-repolist-columns
        '(("Name"    25 magit-repolist-column-ident                  ())
          ("Version" 25 magit-repolist-column-version                ())
          ("D"        1 magit-repolist-column-dirty                  ())
          ("L<U"      3 magit-repolist-column-unpulled-from-upstream ((:right-align t)))
          ("L>U"      3 magit-repolist-column-unpushed-to-upstream   ((:right-align t)))
          ("Path"    99 magit-repolist-column-path                   ()))))
