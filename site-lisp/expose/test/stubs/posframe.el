;;; posframe.el --- minimal stub for unit tests -*- lexical-binding: t; -*-

;; Stands in for the real `posframe' package so pure-logic Expose modules
;; can be `require'd (and thus loaded/tested) in CI without installing UI
;; dependencies. The Expose test suite never calls posframe's actual
;; functions, only modules that merely `require' it at load time.

(provide 'posframe)

;;; posframe.el ends here
