;;; ~/.doom.d/modes/dired.el -*- lexical-binding: t; -*-

;;
;; Dired
;;

(after! dired
  ;; Change the switches
  (setq dired-listing-switches "-alhGg1v --group-directories-first"))
