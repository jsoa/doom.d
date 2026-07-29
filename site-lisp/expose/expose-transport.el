;;; expose-transport.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'expose-document)
(require 'expose-provider)
(require 'expose-redact)

;;; ---------------------------------------------------------------------------
;;; Provider Response Normalization
;;; ---------------------------------------------------------------------------

(defun expose-transport-string (value)
  "Return VALUE as a display string."

  (cond
   ((null value)
    "")

   ((stringp value)
    (substring-no-properties value))

   ((symbolp value)
    (symbol-name value))

   ((numberp value)
    (number-to-string value))

   (t
    (format "%s" value))))


(defun expose-transport-response-text (response)
  "Return provider RESPONSE as plain text.

Providers normally return strings, but some integrations may return
plists or other structured values."

  (cond
   ((stringp response)
    (substring-no-properties response))

   ((and
     (listp response)
     (plist-member response :body))
    (expose-transport-response-text
     (plist-get response :body)))

   ((and
     (listp response)
     (plist-member response :content))
    (expose-transport-response-text
     (plist-get response :content)))

   ((and
     (listp response)
     (plist-member response :text))
    (expose-transport-response-text
     (plist-get response :text)))

   ((and
     (listp response)
     (plist-member response :response))
    (expose-transport-response-text
     (plist-get response :response)))

   (t
    (expose-transport-string response))))


(defun expose-transport-truncate-string (text max-length)
  "Return TEXT truncated to MAX-LENGTH characters.

When MAX-LENGTH is nil, return TEXT unchanged."

  (if (or
       (not max-length)
       (<= (length text)
           max-length))

      text

    (concat
     (substring text 0 max-length)
     "\n\n[Expose truncated stored provider response.]")))


(defun expose-transport-storage-response (response &optional max-length)
  "Return provider RESPONSE normalized for persistent storage.

When MAX-LENGTH is non-nil, truncate the stored response to that many
characters."

  (expose-transport-truncate-string
   (expose-transport-response-text response)
   max-length))


(defun expose-transport-readable-value (value)
  "Return a read-safe copy of VALUE for persistent storage."

  (cond
   ((null value)
    nil)

   ((stringp value)
    (substring-no-properties value))

   ((or
     (numberp value)
     (symbolp value))
    value)

   ((markerp value)
    (format "%s" value))

   ((bufferp value)
    (format "#<buffer %s>" (buffer-name value)))

   ((processp value)
    (format "#<process %s>" (process-name value)))

   ((hash-table-p value)
    (let (items)
      (maphash
       (lambda (key val)
         (push
          (cons
           (expose-transport-readable-value key)
           (expose-transport-readable-value val))
          items))
       value)
      (nreverse items)))

   ((vectorp value)
    (mapcar
     #'expose-transport-readable-value
     (append value nil)))

   ((consp value)
    (cons
     (expose-transport-readable-value
      (car value))
     (expose-transport-readable-value
      (cdr value))))

   (t
    (format "%s" value))))

;;; ---------------------------------------------------------------------------
;;; Normal Expose Action Transport
;;; ---------------------------------------------------------------------------

(defun expose-transport-send (type provider)
  "Build request document for TYPE and send it to PROVIDER synchronously."

  (let ((document
         (expose-document-build type)))

    (expose-transport-response-text
     (expose-provider-send
      provider
      document))))


(defun expose-transport-send-async (type provider callback)
  "Build request document for TYPE and send it to PROVIDER asynchronously.

CALLBACK receives normalized provider response text."

  (let ((document
         (expose-document-build type)))

    (expose-transport-send-document-async
     provider
     document
     callback
     default-directory)))

;;; ---------------------------------------------------------------------------
;;; Raw Document Transport
;;; ---------------------------------------------------------------------------

(defun expose-transport-send-document (provider document &optional working-directory)
  "Send already-built DOCUMENT to PROVIDER synchronously.

WORKING-DIRECTORY, when non-nil, is used as `default-directory' while
starting the provider call. The return value is normalized response text."

  (let ((default-directory
         (or working-directory
             default-directory))

        (safe-document
         (expose-redact-request-document document working-directory)))

    (expose-transport-response-text
     (expose-provider-send
      provider
      safe-document))))


(defun expose-transport-send-document-async
    (provider document callback &optional working-directory error-callback)
  "Send already-built DOCUMENT to PROVIDER asynchronously.

CALLBACK receives normalized response text.

WORKING-DIRECTORY, when non-nil, is used as `default-directory' while
starting the provider call.

ERROR-CALLBACK, when non-nil, receives the raw Emacs error data if starting
the provider call fails. If ERROR-CALLBACK is nil, errors are re-signaled."

  (condition-case error-data

      (let ((default-directory
             (or working-directory
                 default-directory))

            (safe-document
             (expose-redact-request-document document working-directory)))

        (expose-provider-send-async
         provider
         safe-document

         (lambda (response)
           (funcall
            callback
            (expose-transport-response-text response)))))

    (error
     (if error-callback

         (funcall error-callback error-data)

       (signal
        (car error-data)
        (cdr error-data))))))

(provide 'expose-transport)
