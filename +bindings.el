;;; ~/.doom.d/+bindings.el -*- lexical-binding: t; -*-


(map!
 ;; map the window manipulation keys to meta 0, 1, 2, 3
 ;; these commands can be used normally using C-x instead of M
 "M-3" #'split-window-horizontally
 "M-2" #'split-window-vertically
 "M-1" #'delete-other-windows
 "M-0" #'delete-window

 ;; Other window swap
 "M-o" #'other-window

 ;; Kill buffer
 ;; "M-K" #'kill-this-buffer

 ;; Ibuffer + select ibuffer
 "C-x C-b" #'ibuffer-other-window

 ;; Comment or uncomment region or line (custom)
 "M-/" #'jsoa/comment-or-uncomment-region-or-line

 ;; Rename buffer
 ;; "C-c R" #'jsoa/rename-current-file-or-buffer

 ;; Magit
 ;; [(f9)] #'magit-status

 ;; mu4e
 ;; [(f8)] #'mu4e

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
