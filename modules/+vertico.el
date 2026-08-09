;;; modules/+vertico.el -*- lexical-binding: t; -*-

(setq +vertico-buffer-culling t)

;; No `consult-project-function' here: Doom sets it to `doom-project-root'
;; in its own `(use-package! consult :defer t :config ...)', which runs on
;; first consult load -- i.e. after this file -- so setting it here was
;; silently overwritten anyway. `doom-project-root' delegates to
;; `projectile-project-root', so the effective behavior is unchanged.
