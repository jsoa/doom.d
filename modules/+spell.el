;;; +spell.el -*- lexical-binding: t; -*-


;; A named function rather than an anonymous lambda per hook: lambdas
;; can't be removed with `remove-hook', and re-evaluating this file adds
;; a second copy of each instead of replacing it.
(defun jsoa/disable-spell-fu ()
  "Turn `spell-fu-mode' off in the current buffer."
  (spell-fu-mode -1))

(after! spell-fu
  (add-hook 'html-mode-hook #'jsoa/disable-spell-fu)
  (add-hook 'html-ts-mode-hook #'jsoa/disable-spell-fu))
