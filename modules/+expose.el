;;; modules/+expose.el -*- lexical-binding: t; -*-

(add-to-list
 'load-path
 (expand-file-name "site-lisp/expose" doom-user-dir))

(setq expose-provider-default 'copilot
      expose-provider-copilot-command "/home/js/.local/bin/copilot")

(setq expose-hover-delay 0.25
      expose-popup-max-height 10
      expose-popup-max-width 120)

(require 'expose)

(expose-mode 1)
