;;; markdown-mode.el --- minimal stub for unit tests -*- lexical-binding: t; -*-

;; Stands in for the real `markdown-mode' package so pure-logic Expose
;; modules can be `require'd (and thus loaded/tested) in CI without
;; installing the full major mode. The Expose test suite never renders
;; Markdown, only exercises modules that `require' this feature at load
;; time.

(provide 'markdown-mode)

;;; markdown-mode.el ends here
