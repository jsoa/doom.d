;;; modules/+evil.el -*- lexical-binding: t; -*-

;;
;; Evil mode
;;

;; Don't move cursor back on existing insert mode
(after! evil
  (setq evil-move-beyond-eol t)
  (setq evil-move-cursor-back nil)
  (setq-default evil-kill-on-visual-paste nil)
  )
