;;; review/jsoa-transport.el -*- lexical-binding: t; -*-

(require 'jsoa-document)
(require 'jsoa-provider)

;;; ---------------------------------------------------------------------------
;;; Transport
;;; ---------------------------------------------------------------------------

(defun jsoa-transport-send (type provider)
  "Build a TYPE document and send it using PROVIDER.

Returns the provider response."

  (let ((document
         (jsoa-document-build type)))

    (jsoa-provider-send
     provider
     document)))

(defun jsoa-transport-send-async (type provider callback)
  "Asynchronously send TYPE to PROVIDER."

  (let ((document
         (jsoa-document-build type)))

    (pcase provider

      ('codex
       (jsoa-provider-codex-send-async
        document
        callback))

      (_
       (error
        "Provider %s does not support async"
        provider)))))

(provide 'jsoa-transport)
