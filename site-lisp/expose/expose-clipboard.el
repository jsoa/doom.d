;;; expose-clipboard.el -*- lexical-binding: t; -*-

(require 'expose-log)

(defun expose-provider-clipboard-send (document)
  "Copy DOCUMENT to the system clipboard."

  (expose-log
   "Clipboard"
   "Copied %d bytes."
   (length document))

  (kill-new document)

  (message "Review copied to clipboard"))

(provide 'expose-clipboard)
