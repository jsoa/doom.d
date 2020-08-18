;;; ~/.doom.d/modes/magit.el -*- lexical-binding: t; -*-

;;
;; Magit
;;

;; Custom commit message prefix when commiting
(add-hook! 'git-commit-setup-hook 'jsoa/git-commit-setup)


;; https://emacs.stackexchange.com/a/36004
;; Refresh magit status buffer more frequently
(add-hook! 'after-save-hook 'magit-after-save-refresh-status t)

(defun endless/visit-pull-request-url ()
  "Visit the current branch's PR on Github."
  (interactive)
  (browse-url
   (format "https://github.com/%s/pull/new/%s"
     (replace-regexp-in-string
      "\\`.+github\\.com:\\(.+\\)\\.git\\'" "\\1"
      (magit-get "remote"
                 (magit-get-current-remote)
                 "url"))
     (magit-get-current-branch))))

(after! 'magit
  '(define-key magit-mode-map "V"
     #'endless/visit-pull-request-url))
