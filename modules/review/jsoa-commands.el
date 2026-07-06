;;; review/commands.el -*- lexical-binding: t; -*-

(require 'jsoa-transport)

(defcustom jsoa-provider-default
  'codex
  "Default provider used by JSOA."
  :type '(choice
          (const clipboard)
          (const codex))
  :group 'jsoa)

;;; ---------------------------------------------------------------------------
;;; Review
;;; ---------------------------------------------------------------------------

(defun jsoa-review ()
  (interactive)

  (jsoa-transport-send
   'review
   jsoa-provider-default))

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

(defun jsoa-diagnostics ()
  "Review diagnostics at point."

  (interactive)

  (jsoa-transport-send
   'diagnostics
   jsoa-provider-default))

;;; ---------------------------------------------------------------------------
;;; Explain
;;; ---------------------------------------------------------------------------

(defun jsoa-explain ()
  "Explain the symbol at point."

  (interactive)

  (jsoa-transport-send
   'explain
   jsoa-provider-default))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun jsoa-review-self-test ()
  "Exercise the entire review pipeline."

  (interactive)

  (jsoa-review)

  (message "JSOA review pipeline OK"))


(provide 'jsoa-commands)
