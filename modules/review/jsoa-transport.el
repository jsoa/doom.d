;;; review/jsoa-transport.el -*- lexical-binding: t; -*-

(require 'jsoa-document)
(require 'jsoa-provider)

;;; ---------------------------------------------------------------------------
;;; Dispatcher
;;; ---------------------------------------------------------------------------

(defun jsoa-transport-send (type provider)
  "Build TYPE and send it using PROVIDER."

  (let ((document
         (jsoa-document-build type)))

    (jsoa-provider-send
     provider
     document)))

(provide 'jsoa-transport)
