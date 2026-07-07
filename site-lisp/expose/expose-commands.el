;;; expose-commands.el -*- lexical-binding: t; -*-

(require 'expose-log)
(require 'expose-popup)
(require 'expose-hover)
(require 'expose-transport)

(defcustom expose-provider-default
  'codex
  "Default provider used by Expose."
  :type '(choice
          (const clipboard)
          (const codex))
  :group 'expose)

;;; ---------------------------------------------------------------------------
;;; Popup Commands
;;; ---------------------------------------------------------------------------

(defun expose-close ()
  "Close the Expose popup."

  (interactive)

  (expose-hover-close))

(defun expose-run-review ()
  "Run the registered Expose review action."

  (interactive)

  (expose-popup-run-action ?r))

(defun expose-run-diagnostics ()
  "Run the registered Expose diagnostics action."

  (interactive)

  (expose-popup-run-action ?d))

(defun expose-run-explain ()
  "Run the registered Expose explain action."

  (interactive)

  (expose-popup-run-action ?e))

(defun expose-run-fix ()
  "Run the registered Expose fix action."

  (interactive)

  (expose-popup-run-action ?f))

(defun expose-run-refactor ()
  "Run the registered Expose refactor action."

  (interactive)

  (expose-popup-run-action ?R))

(defun expose-run-security ()
  "Run the registered Expose security action."

  (interactive)

  (expose-popup-run-action ?s))

(defun expose-run-performance ()
  "Run the registered Expose performance action."

  (interactive)

  (expose-popup-run-action ?p))

(defun expose-run-tests ()
  "Run the registered Expose tests action."

  (interactive)

  (expose-popup-run-action ?t))

(defun expose-run-edge-cases ()
  "Run the registered Expose edge cases action."

  (interactive)

  (expose-popup-run-action ?x))

(defun expose-run-flow ()
  "Run the registered Expose flow action."

  (interactive)

  (expose-popup-run-action ?w))

(defun expose-run-usage ()
  "Run the registered Expose usage action."

  (interactive)

  (expose-popup-run-action ?u))

(defun expose-run-docstring ()
  "Run the registered Expose docstring action."

  (interactive)

  (expose-popup-run-action ?D))

(defun expose-run-summary ()
  "Run the registered Expose summary action."

  (interactive)

  (expose-popup-run-action ?m))

(defun expose-run-types ()
  "Run the registered Expose types action."

  (interactive)

  (expose-popup-run-action ?T))

;;; ---------------------------------------------------------------------------
;;; Views
;;; ---------------------------------------------------------------------------

(defun expose-action-view (title response)
  "Create an Expose popup view with TITLE and RESPONSE."

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
;;; Action Commands
;;; ---------------------------------------------------------------------------

(defun expose-review ()
  "Run an asynchronous Expose review."

  (interactive)

  (expose-run-review))

(defun expose-review-async (callback)
  "Run an asynchronous Expose review and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'review
   "Review"
   callback))

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

(defun expose-fix ()
  "Suggest the smallest safe fix for the current code asynchronously."

  (interactive)

  (expose-run-fix))

(defun expose-fix-async (callback)
  "Suggest the smallest safe fix and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'fix
   "Fix"
   callback))

(defun expose-refactor ()
  "Suggest a behavior-preserving refactor asynchronously."

  (interactive)

  (expose-run-refactor))

(defun expose-refactor-async (callback)
  "Suggest a behavior-preserving refactor and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'refactor
   "Refactor"
   callback))

(defun expose-security ()
  "Review the current code for security issues asynchronously."

  (interactive)

  (expose-run-security))

(defun expose-security-async (callback)
  "Review the current code for security issues and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'security
   "Security"
   callback))

(defun expose-performance ()
  "Review the current code for performance issues asynchronously."

  (interactive)

  (expose-run-performance))

(defun expose-performance-async (callback)
  "Review the current code for performance issues and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'performance
   "Performance"
   callback))

(defun expose-tests ()
  "Suggest focused tests for the current code asynchronously."

  (interactive)

  (expose-run-tests))

(defun expose-tests-async (callback)
  "Suggest focused tests and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'tests
   "Tests"
   callback))

(defun expose-edge-cases ()
  "Identify important edge cases asynchronously."

  (interactive)

  (expose-run-edge-cases))

(defun expose-edge-cases-async (callback)
  "Identify important edge cases and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'edge-cases
   "Edge Cases"
   callback))

(defun expose-flow ()
  "Explain code flow asynchronously."

  (interactive)

  (expose-run-flow))

(defun expose-flow-async (callback)
  "Explain code flow and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'flow
   "Flow"
   callback))

(defun expose-usage ()
  "Explain usage asynchronously."

  (interactive)

  (expose-run-usage))

(defun expose-usage-async (callback)
  "Explain usage and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'usage
   "Usage"
   callback))

(defun expose-docstring ()
  "Suggest a docstring/comment asynchronously."

  (interactive)

  (expose-run-docstring))

(defun expose-docstring-async (callback)
  "Suggest a docstring/comment and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'docstring
   "Docstring"
   callback))

(defun expose-summary ()
  "Summarize the current code asynchronously."

  (interactive)

  (expose-run-summary))

(defun expose-summary-async (callback)
  "Summarize the current code and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'summary
   "Summary"
   callback))

(defun expose-types ()
  "Explain types asynchronously."

  (interactive)

  (expose-run-types))

(defun expose-types-async (callback)
  "Explain types and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'types
   "Types"
   callback))

;;; ---------------------------------------------------------------------------
;;; Actions
;;; ---------------------------------------------------------------------------

(defun expose-register-default-actions ()
  "Register Expose default popup actions."

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
   :async t)

  (expose-popup-register-action
   ?f
   "Fix"
   'view
   #'expose-fix-async
   :async t)

  (expose-popup-register-action
   ?R
   "Refactor"
   'view
   #'expose-refactor-async
   :async t)

  (expose-popup-register-action
   ?s
   "Security"
   'view
   #'expose-security-async
   :async t)

  (expose-popup-register-action
   ?p
   "Performance"
   'view
   #'expose-performance-async
   :async t)

  (expose-popup-register-action
   ?t
   "Tests"
   'view
   #'expose-tests-async
   :async t)

  (expose-popup-register-action
   ?x
   "Edge Cases"
   'view
   #'expose-edge-cases-async
   :async t)

  (expose-popup-register-action
   ?w
   "Flow"
   'view
   #'expose-flow-async
   :async t)

  (expose-popup-register-action
   ?u
   "Usage"
   'view
   #'expose-usage-async
   :async t)

  (expose-popup-register-action
   ?D
   "Docstring"
   'view
   #'expose-docstring-async
   :async t)

  (expose-popup-register-action
   ?m
   "Summary"
   'view
   #'expose-summary-async
   :async t)

  (expose-popup-register-action
   ?T
   "Types"
   'view
   #'expose-types-async
   :async t))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-review-self-test ()
  "Exercise the Expose review pipeline."

  (interactive)

  (expose-review)

  (message "Expose review pipeline started"))

(provide 'expose-commands)
