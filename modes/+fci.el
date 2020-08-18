;;; ~/.doom.d/modes/fci-mode.el -*- lexical-binding: t; -*-


;;
;; Fill column indicator
;;

(use-package! fci-mode
  :after-call doom-before-switch-buffer-hook
  :config
  (defvar-local company-fci-mode-on-p nil)

  (defun company-turn-off-fci (&rest ignore)
    (setq company-fci-mode-on-p fci-mode)
    (when fci-mode (fci-mode -1)))

  (defun company-maybe-turn-on-fci (&rest ignore)
    (when company-fci-mode-on-p (fci-mode 1)))

  (add-hook 'company-completion-started-hook #'company-turn-off-fci)
  (add-hook 'company-completion-finished-hook #'company-maybe-turn-on-fci)
  (add-hook 'company-completion-cancelled-hook #'company-maybe-turn-on-fci))

(after! fill-column-indicator
  (set-default 'fill-column 80)
  (setq fci-rule-color "#222"))
