;;; ~/.doom.d/+bindings.el -*- lexical-binding: t; -*-

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

(map!

 ;; Other window swap SPC w w does the same thing
 "M-o" #'other-window

 ;; Kill buffer
 "M-K" #'kill-this-buffer

 ;; Insert mode navigation
 :i "C-j" #'evil-next-line        ;; was electric-newline-and-maybe-indent
 :i "C-k" #'evil-previous-line    ;; was kill-line
 :i "C-h" #'evil-backward-char    ;; was unbound
 :i "C-l" #'evil-forward-char     ;; was recenter-top-bottom

 ;; Move line / region up or down
 :v "J" #'jsoa/move-region-down
 :v "K" #'jsoa/move-region-up
 )
