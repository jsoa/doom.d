;;; projectile.el --- minimal stub for unit tests -*- lexical-binding: t; -*-

;; Stands in for the real `projectile' package so pure-logic Expose modules
;; can be `require'd (and thus loaded/tested) in CI without installing
;; project-management dependencies. The Expose test suite never calls
;; projectile's actual functions, only modules that merely `require' it at
;; load time.

(provide 'projectile)

;;; projectile.el ends here
