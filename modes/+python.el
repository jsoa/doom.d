;;; ~/.doom.d/modes/python.el -*- lexical-binding: t; -*-

;;
;; Python mode
;;
(add-hook! python-mode
  ;; The main reason this was removed is because it seems like the line
  ;; shifts auto-complete options to the right of the line (just for the
  ;; first item in the option list)
  (fci-mode)
  )
