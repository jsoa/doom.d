;;; expose-provider.el -*- lexical-binding: t; -*-

(require 'expose-log)
(require 'expose-clipboard)
(require 'expose-codex)
(require 'expose-copilot)

;;; ---------------------------------------------------------------------------
;;; Dispatcher
;;; ---------------------------------------------------------------------------

(defun expose-provider-send (provider document)
  "Send DOCUMENT using PROVIDER."

  (expose-log
   "Provider"
   "Dispatching to %s."
   provider)

  (pcase provider
    ('clipboard
     (expose-provider-clipboard-send document))

    ('codex
     (expose-provider-codex-send document))

    ('copilot
     (expose-provider-copilot-send document))

    (_
     (error "Unknown provider: %s" provider))))

(defun expose-provider-send-async (provider document callback)
  "Send DOCUMENT asynchronously using PROVIDER."

  (expose-log
   "Provider"
   "Dispatching asynchronously to %s."
   provider)

  (pcase provider
    ('clipboard
     (expose-provider-clipboard-send-async
      document
      callback))

    ('codex
     (expose-provider-codex-send-async
      document
      callback))

    ('copilot
     (expose-provider-copilot-send-async
      document
      callback))

    (_
     (error
      "Provider %s does not support async."
      provider))))

(provide 'expose-provider)
