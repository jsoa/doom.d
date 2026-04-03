;;; ~/.doom.d/modes/dired.el -*- lexical-binding: t; -*-

;;
;; Dired
;;

(after! dired
  ;; Change the switches
  (setq counsel-dired-listing-switches "-alhGg1v --group-directories-first")
  (setq dired-listing-switches "-alhGg1v --group-directories-first"))
