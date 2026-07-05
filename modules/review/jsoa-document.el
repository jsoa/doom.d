;;; review/document.el -*- lexical-binding: t; -*-

(require 'jsoa-request)
(require 'jsoa-renderer-xml)

;;; ---------------------------------------------------------------------------
;;; Builder
;;; ---------------------------------------------------------------------------

(defun jsoa-document-build (type)
  "Build a document for request TYPE."

  (let ((request
          (jsoa-request-build type)))

    (jsoa-document-render request)))

;;; ---------------------------------------------------------------------------
;;; Renderer
;;; ---------------------------------------------------------------------------

(defun jsoa-document-render (request)
  "Render REQUEST into a document."

  (pcase (plist-get request :document-format)

    ('xml
     (jsoa-renderer-xml request))

    ;; ('markdown
    ;;  (jsoa-renderer-markdown request))

    ;; ('json
    ;;  (jsoa-renderer-json request))

    (_
     (error
      "Unknown document format: %s"
      (plist-get request :document-format)))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun jsoa-document-pretty-print ()
  "Pretty-print the current document."

  (nxml-mode)

  (indent-region
   (point-min)
   (point-max)))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun jsoa-document-debug (type)
  "Display the rendered document."

  (interactive)

  (let ((document
         (jsoa-document-build type)))

    (with-current-buffer
        (get-buffer-create "*JSOA Document*")

      (erase-buffer)

      (insert document)

      (jsoa-document-pretty-print)

      (goto-char (point-min))

      (pop-to-buffer
       (current-buffer)))))

(provide 'jsoa-document)
