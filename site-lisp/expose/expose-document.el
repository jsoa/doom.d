;;; expose-document.el -*- lexical-binding: t; -*-

(require 'expose-request)
(require 'expose-xml)

;;; ---------------------------------------------------------------------------
;;; Builder
;;; ---------------------------------------------------------------------------

(defun expose-document-build (type &optional context)
  "Build a document for request TYPE.

CONTEXT is passed through to `expose-request-build' unchanged -- see
there for when to supply one."

  (let ((request
          (expose-request-build type context)))

    (expose-document-render request)))

;;; ---------------------------------------------------------------------------
;;; Renderer
;;; ---------------------------------------------------------------------------

(defun expose-document-render (request)
  "Render REQUEST into a document."

  (pcase (plist-get request :document-format)

    ('xml
     (expose-renderer-xml request))

    (_
     (error
      "Unknown document format: %s"
      (plist-get request :document-format)))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun expose-document-pretty-print ()
  "Pretty-print the current document."

  (nxml-mode)

  (indent-region
   (point-min)
   (point-max)))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-document-debug (type)
  "Display the rendered document."

  (interactive)

  (let ((document
         (expose-document-build type)))

    (with-current-buffer
        (get-buffer-create "*EXPOSE Document*")

      (erase-buffer)

      (insert document)

      (expose-document-pretty-print)

      (goto-char (point-min))

      (pop-to-buffer
       (current-buffer)))))

(provide 'expose-document)
