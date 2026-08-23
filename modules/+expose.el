;;; modules/+expose.el -*- lexical-binding: t; -*-

(add-to-list
 'load-path
 (expand-file-name "site-lisp/expose" doom-user-dir))

(setq expose-hover-delay 0.25
      ;; Was 10 -- short enough that most LSP hover docstrings clipped and
      ;; needed scrolling (`SPC c h j'/`k') to read in full. 16 is roomier
      ;; without going all the way to the library's own default of 30.
      expose-popup-max-height 16
      expose-popup-max-width 120)

(require 'expose)

(expose-mode 1)
