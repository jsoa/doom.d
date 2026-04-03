;;; ~/.doom.d/modes/magit.el -*- lexical-binding: t; -*-

;;
;; Magit
;;

;; Insert a commit message prefix, i.e. [ticket number]
;; If a branch name starts with "NAME-NUMBER", get it and supply
;; a commit prefix of [NAME-NUMBER] otherwise insert [-]
(defun jsoa/git-commit-setup ()
  (let ((branch-name (magit-get-current-branch)))
    (save-match-data ; is usually a good idea
      (if (string-match "^\\(\\w+-[0-9]+\\)" branch-name)
          (insert (concat "[" (match-string 1 branch-name) "] "))
        (insert "[-] ")))))

;; Custom commit message prefix when commiting
(add-hook! 'git-commit-setup-hook 'jsoa/git-commit-setup)

(after! magit
  ;; Do NOT show diffs automatically in status buffer
  (setq magit-diff-refine-hunk t
        magit-diff-paint-whitespace nil
        magit-diff-refine-ignore-whitespace t)
  (defun my/magit-toggle-diff ()
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
        :n "TAB" #'my/magit-toggle-diff)

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
