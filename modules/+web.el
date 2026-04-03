;;; ~/.doom.d/modes/web-mode.el -*- lexical-binding: t; -*-

;;
;; Web Mode
;;

(after! js
  (setq js-indent-level 2))

(after! web-mode

  (add-to-list 'auto-mode-alist '("\\.tpl\\.php\\'" . web-mode))

  ;; Include django as an engine
  (add-to-list 'web-mode-engines-alist '("django" . "\\.html\\'"))

  (setq web-mode-markup-indent-offset 2)
  (setq web-mode-code-indent-offset 2)
  (setq web-mode-css-indent-offset 2)
  (setq web-mode-enable-auto-indentation t)
  (setq web-mode-enable-auto-closing nil)
  (setq web-mode-enable-css-colorization t))
