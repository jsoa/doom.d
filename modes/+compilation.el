;;; ~/.doom.d/modes/compilation-mode.el -*- lexical-binding: t; -*-

;;
;; Compilation
;;

;; https://stackoverflow.com/questions/1292936/line-wrapping-within-emacs-compilation-buffer
(defun jsoa/compilation-mode-hook ()
  (setq truncate-lines nil) ;; automatically becomes buffer local
  (set (make-local-variable 'truncate-partial-width-windows) nil))

;; Compilation mode hook to wrap line
(add-hook! 'compilation-mode-hook 'jsoa/compilation-mode-hook)
