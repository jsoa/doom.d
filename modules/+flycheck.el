;;; modes/+flycheck.el -*- lexical-binding: t; -*-

(after! flycheck
  (setq flycheck-check-syntax-automatically '(save mode-enabled))
  (setq flycheck-display-errors-delay 0.2)
  )
