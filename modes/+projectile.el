;;; ~/.doom.d/modes/projectile.el -*- lexical-binding: t; -*-

;;
;; Projectile
;;

(after! projectile
  (setq projectile-sort-order 'modification-time)

  ;; Magit status as the default project open
  (setq +workspaces-switch-project-function #'magit-status)

  ;; Don't add projects inside our "Development" folder
  ;; https://emacs.stackexchange.com/a/29494
  (require 'f)
  (defun my-projectile-ignore-project (project-root)
    (f-descendant-of? project-root (expand-file-name "~/Development")))
  (setq projectile-ignored-project-function #'my-projectile-ignore-project))
