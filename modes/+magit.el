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
