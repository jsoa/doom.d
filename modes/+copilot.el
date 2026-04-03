;;; modes/+copilot.el -*- lexical-binding: t; -*-

(defun my/copilot-trigger-or-accept ()
  (interactive)
  (if (copilot--overlay-visible)
      (copilot-accept-completion)
    (copilot-complete)))

(use-package! copilot
  :hook (prog-mode . copilot-mode)
  :config
  (setq copilot-idle-delay nil)
  (map! :i "C-<tab>" #'my/copilot-trigger-or-accept))
