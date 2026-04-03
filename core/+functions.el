;;; ~/.doom.d/+functions.el -*- lexical-binding: t; -*-

;;
;; Custom functions
;;


(defun jsoa/move-region-down ()
  (interactive)
  (evil-visual-line)
  (evil-next-line)
  (transpose-lines 1)
  (evil-previous-line))

(defun jsoa/move-region-up ()
  (interactive)
  (evil-visual-line)
  (evil-previous-line)
  (transpose-lines 1)
  (evil-next-line))
