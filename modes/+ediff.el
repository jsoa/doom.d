;;; ~/.doom.d/modes/ediff-mode.el -*- lexical-binding: t; -*-

;;
;; EDiff
;;

;; https://stackoverflow.com/a/29757750
;; Accept diffs from both A and B
;; key bindings
;; a = accept a
;; b = accept b
;; B = accept both
(defun ediff-copy-both-to-C ()
  (interactive)
  (ediff-copy-diff ediff-current-difference nil 'C nil
                   (concat
                    (ediff-get-region-contents ediff-current-difference 'A ediff-control-buffer)
                    (ediff-get-region-contents ediff-current-difference 'B ediff-control-buffer))))

;; Binding B in ediff mode (B for both)
(defun add-b-to-ediff-mode-map () (define-key ediff-mode-map "B" 'ediff-copy-both-to-C))

;; Add the hook
(add-hook! 'ediff-keymap-setup-hook 'add-b-to-ediff-mode-map)
