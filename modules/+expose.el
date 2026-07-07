;;; modules/+expose.el -*- lexical-binding: t; -*-

(add-to-list
 'load-path
 (expand-file-name "site-lisp/expose" doom-user-dir))

(load
 (expand-file-name "site-lisp/expose/expose.el" doom-user-dir)
 nil
 nil)

(setq expose-hover-delay 0.25
      expose-popup-max-height 10
      expose-popup-max-width 120)

(expose-mode 1)
