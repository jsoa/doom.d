;;; expose-commands.el -*- lexical-binding: t; -*-

(require 'expose-popup)
(require 'expose-hover)
(require 'expose-transport)

(defcustom expose-provider-default
  'codex
  "Default provider used by EXPOSE."
  :type '(choice
          (const clipboard)
          (const codex))
  :group 'expose)

;;; ---------------------------------------------------------------------------
;;; Popup Commands
;;; ---------------------------------------------------------------------------

(defun expose-close ()
  "Close the EXPOSE popup."

  (interactive)

  (expose-hover-close))

(defun expose-run-review ()
  "Run the registered EXPOSE review action."

  (interactive)

  (expose-popup-run-action ?r))

(defun expose-run-diagnostics ()
  "Run the registered EXPOSE diagnostics action."

  (interactive)

  (expose-popup-run-action ?d))

(defun expose-run-explain ()
  "Run the registered EXPOSE explain action."

  (interactive)

  (expose-popup-run-action ?e))

;;; ---------------------------------------------------------------------------
;;; Views
;;; ---------------------------------------------------------------------------

(defun expose-action-view (title response)
  "Create an EXPOSE popup view with TITLE and RESPONSE."

  (expose-popup-view-create
   title
   response))

(defun expose-send-view-action-async (type title callback)
  "Send TYPE asynchronously and call CALLBACK with a titled popup view."

  (expose-log
   "Command"
   "Starting async action %s using provider %s."
   type
   expose-provider-default)

  (expose-transport-send-async
   type
   expose-provider-default
   (lambda (response)

     (expose-log
      "Command"
      "Async action %s returned response (%d bytes)."
      type
      (length response))

     (funcall
      callback
      (expose-action-view title response))

     (expose-log
      "Command"
      "Async action %s completed."
      type))))

;;; ---------------------------------------------------------------------------
;;; Review
;;; ---------------------------------------------------------------------------

(defun expose-review ()
  "Run an asynchronous EXPOSE review."

  (interactive)

  (expose-run-review))

(defun expose-review-async (callback)
  "Run an asynchronous EXPOSE review and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'review
   "Review"
   callback))

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

(defun expose-diagnostics ()
  "Explain diagnostics at point asynchronously."

  (interactive)

  (expose-run-diagnostics))

(defun expose-diagnostics-async (callback)
  "Explain diagnostics asynchronously and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'diagnostics
   "Diagnostics"
   callback))

;;; ---------------------------------------------------------------------------
;;; Explain
;;; ---------------------------------------------------------------------------

(defun expose-explain ()
  "Explain the symbol or construct at point asynchronously."

  (interactive)

  (expose-run-explain))

(defun expose-explain-async (callback)
  "Explain the current symbol or construct and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'explain
   "Explain"
   callback))

;;; ---------------------------------------------------------------------------
;;; Actions
;;; ---------------------------------------------------------------------------

(defun expose-register-default-actions ()
  "Register EXPOSE default popup actions."

  (expose-popup-register-action
   ?r
   "Review"
   'view
   #'expose-review-async
   :async t)

  (expose-popup-register-action
   ?d
   "Diagnostics"
   'view
   #'expose-diagnostics-async
   :async t)

  (expose-popup-register-action
   ?e
   "Explain"
   'view
   #'expose-explain-async
   :async t))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-review-self-test ()
  "Exercise the EXPOSE review pipeline."

  (interactive)

  (expose-review)

  (message "EXPOSE review pipeline started"))

(provide 'expose-commands)
