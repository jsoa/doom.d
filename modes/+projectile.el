;;; ~/.doom.d/modes/projectile.el -*- lexical-binding: t; -*-

;;
;; Projectile
;;

(after! projectile
  ;; Don't add projects inside our "Development" folder
  ;; https://emacs.stackexchange.com/a/29494
  (setq projectile-sort-order 'modification-time)
  (require 'f)
  (defun my-projectile-ignore-project (project-root)
    (f-descendant-of? project-root (expand-file-name "~/Development")))
  (setq projectile-ignored-project-function #'my-projectile-ignore-project))


(after! counsel-projectile
  ;; Open magit buffer on project switch
  ;; REF: https://github.com/ericdanan/counsel-projectile/issues/62#issuecomment-353732566
  (counsel-projectile-modify-action
   'counsel-projectile-switch-project-action
   '((move counsel-projectile-switch-project-action-vc 1)
     (setkey counsel-projectile-switch-project-action-vc "o")
     (setkey counsel-projectile-switch-project-action " "))))
