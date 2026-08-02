;;; modules/+flycheck.el -*- lexical-binding: t; -*-

(after! flycheck
  ;; Check on save and when Flycheck turns on, but not constantly while typing.
  (setq flycheck-check-syntax-automatically
        '(save mode-enabled)

        ;; Keep diagnostics/underlines, but let Expose be the diagnostic UI.
        flycheck-display-errors-function nil
        flycheck-help-echo-function nil))
