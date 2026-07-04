;;; review/request.el -*- lexical-binding: t; -*-

(require 'subr-x)

(require 'jsoa-context)

(provide 'jsoa-request)

(defun jsoa-context-root-node ()
  "Return the Tree-sitter root node for the current buffer."

  (ignore-errors
    (treesit-buffer-root-node)))

(defun jsoa-request--section (title body)
  "Return a formatted section."

  (concat
   title
   ":\n"
   body
   "\n\n"))

(defun jsoa-request--imports (imports)
  "Return formatted imports."

  (if imports
      (string-join imports "\n")
    "(none)"))

(defun jsoa-request--diagnostics (diagnostics)
  "Return formatted diagnostics."

  (if diagnostics
      (mapconcat
       (lambda (diag)
         (format
          "[%s] %s"
          (plist-get diag :level)
          (plist-get diag :message)))
       diagnostics
       "\n")
    "(none)"))

(defun jsoa-request-build (context)
  "Return a review request for CONTEXT."

  (concat

   "You are an experienced software engineer performing a code review."

   "Review Goal:"

   "Review only the current scope."

   "Assume the surrounding code is correct unless it is directly relevant."

   "Focus on correctness, readability, maintainability, and performance."

   "Do not review the entire file."

   (jsoa-request--section
    "Project"
    (jsoa-context-get context :project))

   (jsoa-request--section
    "Language"
    (jsoa-context-get context :language))

   (jsoa-request--section
    "File"
    (jsoa-context-get context :file))

   (jsoa-request--section
    "Current Symbol"
    (or
     (jsoa-context-get context :symbol)
     "(none)"))

   (jsoa-request--section
    "Current Scope"
    (or
     (jsoa-context-get context :scope-name)
     "(none)"))

   (jsoa-request--section
    "Parent Scope"
    (or
     (jsoa-context-get context :parent-scope)
     "(none)"))

   (jsoa-request--section
    "Imports"
    (jsoa-request--imports
     (jsoa-context-get context :imports)))

   (jsoa-request--section
    "Diagnostics"
    (jsoa-request--diagnostics
     (jsoa-context-get context :diagnostics)))

   "Code:\n\n"

   (jsoa-context-get context :code)

   "\n"))

(defun jsoa-request-debug ()
  (interactive)

  (let* ((context (jsoa-context-build))
         (request (jsoa-request-build context)))

    (with-current-buffer
        (get-buffer-create "*JSOA Request*")

      (erase-buffer)

      (insert request)

      (goto-char (point-min))

      (pop-to-buffer (current-buffer)))))
