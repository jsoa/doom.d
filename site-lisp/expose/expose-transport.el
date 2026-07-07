;;; expose-transport.el -*- lexical-binding: t; -*-

(require 'expose-document)
(require 'expose-provider)
(require 'expose-log)

;;; ---------------------------------------------------------------------------
;;; Transport
;;; ---------------------------------------------------------------------------

(defun expose-transport-send (type provider)
  "Build a TYPE document and send it using PROVIDER.

Returns the provider response."

  (expose-log
   "Transport"
   "Building %s document."
   type)

  (let ((document
         (expose-document-build type)))

    (expose-log
     "Transport"
     "Sending document to %s."
     provider)

    (let ((response
           (expose-provider-send
            provider
            document)))

      (expose-log
       "Transport"
       "Received response from %s."
       provider)

      response)))

(defun expose-transport-send-async
    (type provider callback)
  "Asynchronously send TYPE to PROVIDER, then call CALLBACK with the provider response."

  (expose-log
   "Transport"
   "Building %s document."
   type)

  (let ((document
         (expose-document-build type)))

    (expose-log
     "Transport"
     "Sending document to %s asynchronously."
     provider)

    (expose-provider-send-async
     provider
     document
     (lambda (response)
       (expose-log
        "Transport"
        "Received async response from %s."
        provider)

       (funcall callback response)

       (expose-log
        "Transport"
        "Callback completed.")))))

(provide 'expose-transport)
