;;; ~/.doom.d/modes/projectile.el -*- lexical-binding: t; -*-

;;
;; Projectile
;;

(after! projectile
  (setq projectile-sort-order 'modification-time)

  ;; https://github.com/bbatsov/projectile/issues/1250
  (add-to-list 'projectile-globally-ignored-directories "*env")
  (add-to-list 'projectile-globally-ignored-directories "*venv")
  (add-to-list 'projectile-globally-ignored-directories "*node_modules")

  ;; Optimizations
  (setq projectile-enable-caching t)
  (setq projectile-indexing-method 'alien)
  (setq projectile-file-exists-remote-cache-expire nil)
  (setq projectile-auto-discover nil)
  (setq projectile-require-project-root t)

  (setq +workspaces-switch-project-function #'jsoa/project-command-center)


  )
