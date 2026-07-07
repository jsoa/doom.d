;;; expose-request.el -*- lexical-binding: t; -*-

(require 'expose-context)

;;; ---------------------------------------------------------------------------
;;; Request
;;; ---------------------------------------------------------------------------

(defun expose-request-create (type document-format instruction context)
  "Return a request object."

  (list
   :type type
   :document-format document-format
   :instruction instruction
   :context context))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------


(defun expose-request-select (context &rest keys)
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

(defun expose-request-review (context)
  "Build a code review request."

  (expose-request-create
   'review
   'xml

   "Review the current implementation for correctness, readability, maintainability, and potential bugs."

   (expose-request-select
    context
    :project
    :language
    :file
    :scope
    :parent-scope
    :imports
    :focus)))

(defun expose-request-diagnostics (context)
  "Build a diagnostics request."

  (expose-request-create
   'diagnostics
   'xml

   "Explain the diagnostics for the current code, why they occur, and recommend the best fix."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :focus
    :code)))

(defun expose-request-explain (context)
  "Build an explanation request."

  (expose-request-create
   'explain
   'xml

   "Explain the selected symbol or construct in the context of this code."

   (expose-request-select
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

(defun expose-request-build (type)
  "Build a request of TYPE."

  (let ((context (expose-context-build)))

    (pcase type
      ('review
       (expose-request-review context))

      ('diagnostics
       (expose-request-diagnostics context))

      ('explain
       (expose-request-explain context))

      (_
       (error "Unknown request type: %s" type)))))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-request-debug-review ()
  (interactive)

  (pp
   (expose-request-build 'review)
   (get-buffer-create "*EXPOSE Review*"))

  (pop-to-buffer "*EXPOSE Review*"))

(defun expose-request-debug-diagnostics ()
  (interactive)

  (pp
   (expose-request-build 'diagnostics)
   (get-buffer-create "*EXPOSE Diagnostics*"))

  (pop-to-buffer "*EXPOSE Diagnostics*"))

(defun expose-request-debug-explain ()
  (interactive)

  (pp
   (expose-request-build 'explain)
   (get-buffer-create "*EXPOSE Explain*"))

  (pop-to-buffer "*EXPOSE Explain*"))

(provide 'expose-request)
