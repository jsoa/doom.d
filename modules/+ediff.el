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
(after! ediff
  (defun jsoa/ediff-copy-both-to-C ()
    "Copy both A and B changes into C."
    (interactive)
    (ediff-copy-diff
     ediff-current-difference
     nil 'C nil
     (concat
      (ediff-get-region-contents ediff-current-difference 'A ediff-control-buffer)
      (ediff-get-region-contents ediff-current-difference 'B ediff-control-buffer))))

  (map! :map ediff-mode-map
        :n "B" #'jsoa/ediff-copy-both-to-C))
