;;; modes/+copilot.el -*- lexical-binding: t; -*-

(defun jsoa/copilot-trigger-or-accept ()
  (interactive)
  (if (copilot--overlay-visible)
      (copilot-accept-completion)
    (copilot-complete)))

(use-package! copilot
  :hook (prog-mode . copilot-mode)
  :config
  (setq copilot-idle-delay nil)
  (map! :i
        "C-<right>" #'copilot-accept-completion-by-word
        "C-<down>"  #'copilot-accept-completion-by-line
        "C-<tab>" #'jsoa/copilot-trigger-or-accept))
