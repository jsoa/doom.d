;;; expose-clipboard.el -*- lexical-binding: t; -*-

(require 'expose-log)

(defun expose-provider-clipboard-send (document)
  "Copy DOCUMENT to the system clipboard."

  (expose-log
   "Clipboard"
   "Copied %d bytes."
   (length document))

  (kill-new document)

  (message "Expose request copied to clipboard"))

(defun expose-provider-clipboard-send-async (document callback)
  "Copy DOCUMENT to clipboard and call CALLBACK with a placeholder response."

  (kill-new document)
  (message "Expose request copied to clipboard")

  (funcall
   callback
   "Expose request copied to clipboard.

Paste it into your AI provider manually, then paste the response back into Expose when manual response support exists."))

(provide 'expose-clipboard)
