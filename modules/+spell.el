;;; +spell.el -*- lexical-binding: t; -*-


(after! spell-fu
  (add-hook 'html-mode-hook (lambda () (spell-fu-mode -1)))
  (add-hook 'html-ts-mode-hook (lambda () (spell-fu-mode -1))))
