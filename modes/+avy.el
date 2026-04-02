;;; modes/+avy.el -*- lexical-binding: t; -*-

;; config.el
(use-package! avy
  :config
  (setq avy-timeout-seconds 0.3))

(map! :leader
      (:prefix ("j" . "jump")
               "j" #'avy-goto-char-timer
               "c" #'avy-goto-char-2
               "w" #'avy-goto-word-1
               "l" #'avy-goto-line))
