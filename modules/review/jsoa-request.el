;;; review/request.el -*- lexical-binding: t; -*-

(require 'jsoa-context)

;;; ---------------------------------------------------------------------------
;;; Request
;;; ---------------------------------------------------------------------------

(defun jsoa-request-create (type document-format instruction context)
  "Return a request object."

  (list
   :type type
   :document-format document-format
   :instruction instruction
   :context context))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------


(defun jsoa-request-select (context &rest keys)
  "Return a plist containing KEYS copied from CONTEXT."

  (let (result)

    (dolist (key keys)
      (let ((value
             (plist-get context key)))

        (when value
          (setq result
                (plist-put result key value)))))

    result))

;;; ---------------------------------------------------------------------------
;;; Builders
;;; ---------------------------------------------------------------------------

(defun jsoa-request-review (context)
  "Build a code review request."

  (jsoa-request-create
   'review
   'xml

   "Review the current implementation for correctness, readability, maintainability, and potential bugs."

   (jsoa-request-select
    context
    :project
    :language
    :file
    :scope
    :parent-scope
    :imports
    :focus)))

(defun jsoa-request-diagnostics (context)
  "Build a diagnostics request."

  (jsoa-request-create
   'diagnostics
   'xml

   "Explain the diagnostics for the current code, why they occur, and recommend the best fix."

   (jsoa-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :focus
    :code)))

(defun jsoa-request-explain (context)
  "Build an explanation request."

  (jsoa-request-create
   'explain
   'xml

   "Explain the selected symbol or construct in the context of this code."

   (jsoa-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :code)))

;;; ---------------------------------------------------------------------------
;;; Dispatcher
;;; ---------------------------------------------------------------------------

(defun jsoa-request-build (type)
  "Build a request of TYPE."

  (let ((context (jsoa-context-build)))

    (pcase type
      ('review
       (jsoa-request-review context))

      ('diagnostics
       (jsoa-request-diagnostics context))

      ('explain
       (jsoa-request-explain context))

      (_
       (error "Unknown request type: %s" type)))))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun jsoa-request-debug-review ()
  (interactive)

  (pp
   (jsoa-request-build 'review)
   (get-buffer-create "*JSOA Review*"))

  (pop-to-buffer "*JSOA Review*"))

(defun jsoa-request-debug-diagnostics ()
  (interactive)

  (pp
   (jsoa-request-build 'diagnostics)
   (get-buffer-create "*JSOA Diagnostics*"))

  (pop-to-buffer "*JSOA Diagnostics*"))

(defun jsoa-request-debug-explain ()
  (interactive)

  (pp
   (jsoa-request-build 'explain)
   (get-buffer-create "*JSOA Explain*"))

  (pop-to-buffer "*JSOA Explain*"))

(provide 'jsoa-request)
