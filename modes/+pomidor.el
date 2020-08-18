;;; modes/+pomidor.el -*- lexical-binding: t; -*-

;;;
;;; Pomidor
;;;
(after! pomidor
  (setq pomidor-sound-tick nil
        pomidor-sound-tack nil)
  )

(use-package! org-pomodoro
  :custom-face
  (org-pomodoro-mode-line ((t (:inherit warning))))
  (org-pomodoro-mode-line-overtime ((t (:inherit error))))
  (org-pomodoro-mode-line-break ((t (:inherit success))))
  :bind (:map org-agenda-mode-map
          ("P" . org-pomodoro)))
