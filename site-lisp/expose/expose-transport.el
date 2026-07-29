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


(defcustom expose-transport-readable-value-max-depth 40
  "Maximum nested depth copied by `expose-transport-readable-value'."
  :type 'integer
  :group 'expose)


(defun expose-transport-readable-value-1 (value seen depth)
  "Return a read-safe copy of VALUE using SEEN and DEPTH."

  (cond
   ((> depth expose-transport-readable-value-max-depth)
    "#<expose max readable depth>")

   ((null value)
    nil)

   ((stringp value)
    (substring-no-properties value))

   ((or
     (numberp value)
     (symbolp value)
     (keywordp value))
    value)

   ((markerp value)
    (format "#<marker %s>" value))

   ((bufferp value)
    (format "#<buffer %s>" (buffer-name value)))

   ((processp value)
    (format "#<process %s>" (process-name value)))

   ((hash-table-p value)
    (if (gethash value seen)

        "#<circular hash-table>"

      (puthash value t seen)

      (let (items)
        (maphash
         (lambda (key val)
           (push
            (cons
             (expose-transport-readable-value-1
              key
              seen
              (1+ depth))
             (expose-transport-readable-value-1
              val
              seen
              (1+ depth)))
            items))
         value)

        (nreverse items))))

   ((vectorp value)
    (if (gethash value seen)

        "#<circular vector>"

      (puthash value t seen)

      (mapcar
       (lambda (item)
         (expose-transport-readable-value-1
          item
          seen
          (1+ depth)))
       (append value nil))))

   ((consp value)
    (if (gethash value seen)

        "#<circular cons>"

      (puthash value t seen)

      (cons
       (expose-transport-readable-value-1
        (car value)
        seen
        (1+ depth))
       (expose-transport-readable-value-1
        (cdr value)
        seen
        (1+ depth)))))

   (t
    (condition-case nil
        (let ((print-circle t)
              (print-length 50)
              (print-level 10))
          (format "%S" value))
      (error
       "#<unreadable value>")))))


(defun expose-transport-readable-value (value)
  "Return a read-safe, cycle-safe copy of VALUE for persistent storage."

  (expose-transport-readable-value-1
   value
   (make-hash-table :test 'eq)
   0))

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
