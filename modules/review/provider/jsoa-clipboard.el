;;; modules/review/provider/jsoa-clipboard.el -*- lexical-binding: t; -*-

(defun jsoa-provider-clipboard-send (document)
  "Copy DOCUMENT to the system clipboard."

  (kill-new document)

  (message "Review copied to clipboard"))

(provide 'jsoa-clipboard)
