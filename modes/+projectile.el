;;; ~/.doom.d/modes/projectile.el -*- lexical-binding: t; -*-

;;
;; Projectile
;;

(after! projectile

  ;; Open magit buffer on project switch
  ;; REF: https://github.com/ericdanan/counsel-projectile/issues/62#issuecomment-353732566
  (counsel-projectile-modify-action
   'counsel-projectile-switch-project-action
   '((move counsel-projectile-switch-project-action-vc 1)
     (setkey counsel-projectile-switch-project-action-vc "o")
     (setkey counsel-projectile-switch-project-action " "))))
