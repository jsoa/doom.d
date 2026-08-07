;;; modules/+projectile.el -*- lexical-binding: t; -*-

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

  ;; Projectile's master-branch async-indexing wait loop can spin forever at
  ;; 100% CPU instead of detecting completion (no live subprocess, but `done'
  ;; never flips) -- this forces the synchronous alien path instead, which
  ;; doesn't have that bug.
  (setq projectile-async-indexing nil)

  (setq +workspaces-switch-project-function #'jsoa/project-command-center)


  )
