;;; modules/review/provider/jsoa-provider.el -*- lexical-binding: t; -*-

(require 'jsoa-clipboard)

;;; ---------------------------------------------------------------------------
;;; Dispatcher
;;; ---------------------------------------------------------------------------

(defun jsoa-provider-send (provider document)
  "Send DOCUMENT using PROVIDER."
  (pcase provider
    ('clipboard
     (jsoa-provider-clipboard-send document))
    ;; ('codex
    ;;  (jsoa-codex-send document))
    (_
     (error "Unknown provider: %s" provider))))

(provide 'jsoa-provider)
