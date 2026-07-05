;;; review/commands.el -*- lexical-binding: t; -*-

(require 'jsoa-transport)

;;; ---------------------------------------------------------------------------
;;; Review
;;; ---------------------------------------------------------------------------

(defun jsoa-review ()
  "Review the code at point."

  (interactive)

  (jsoa-transport-send
   'review
   'clipboard))

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

(defun jsoa-diagnostics ()
  "Review diagnostics at point."

  (interactive)

  (jsoa-transport-send
   'diagnostics
   'clipboard))

;;; ---------------------------------------------------------------------------
;;; Explain
;;; ---------------------------------------------------------------------------

(defun jsoa-explain ()
  "Explain the symbol at point."

  (interactive)

  (jsoa-transport-send
   'explain
   'clipboard))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun jsoa-review-self-test ()
  "Exercise the entire review pipeline."

  (interactive)

  (jsoa-review)

  (message "JSOA review pipeline OK"))


(provide 'jsoa-commands)
