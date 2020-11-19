;;; ~/.doom.d/+functions.el -*- lexical-binding: t; -*-

;;
;; Custom functions
;;


;; https://emacs.stackexchange.com/questions/13080/reloading-directory-local-variables
(defun jsoa/reload-dir-locals-for-current-buffer ()
  "reload dir locals for the current buffer"
  (interactive)
  (let ((enable-local-variables :all))
    (hack-dir-local-variables-non-file-buffer)))


(defun jsoa/file-info ()
  (interactive)
  (let ((dired-listing-switches "-alh"))
    (dired-other-window buffer-file-name)))

