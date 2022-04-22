;;; ~/.doom.d/+bindings.el -*- lexical-binding: t; -*-


(map!

 ;; Other window swap
 "M-o" #'other-window

 ;; Kill buffer
 "M-K" #'kill-this-buffer

 ;; pass
 [(f7)] #'pass

 ;; Insert mode navigation
 :i "C-j" #'evil-next-line        ;; was electric-newline-and-maybe-indent
 :i "C-k" #'evil-previous-line    ;; was kill-line
 :i "C-h" #'evil-backward-char    ;; was unbound
 :i "C-l" #'evil-forward-char     ;; was recenter-top-bottom

 ;; Move line / region up or down
 :v "J" (concat ":m '>+1" (kbd "RET") "gv=gv")
 :v "K" (concat ":m '<-2" (kbd "RET") "gv=gv")
)

(map! :leader
      :desc "prodigy"
      "e" #'prodigy)

