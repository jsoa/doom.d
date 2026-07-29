;;; expose-xml.el -*- lexical-binding: t; -*-

(require 'xml)

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun expose-renderer-xml (request)
  "Render REQUEST as XML."

  (with-temp-buffer
    (expose-renderer-xml-node
     "request"
     request)

    (buffer-string)))

;;; ---------------------------------------------------------------------------
;;; Nodes
;;; ---------------------------------------------------------------------------

(defun expose-renderer-xml-node (name value)
  "Render XML node NAME containing VALUE."

  (insert "<" name ">")

  (expose-renderer-xml-value value)

  (insert "</" name ">\n"))

(defun expose-renderer-xml-plist (plist)
  "Render PLIST."

  (while plist
    (let ((key (pop plist))
          (value (pop plist)))

      (unless
          (expose-renderer-xml-empty-p value)

        (expose-renderer-xml-node
         (expose-renderer-xml-tag-name key)
         value)))))

(defun expose-renderer-xml-list (list)
  "Render LIST."

  (dolist (item list)
    (expose-renderer-xml-node
     "item"
     item)))

(defun expose-renderer-xml-value (value)
  "Render VALUE."

  (cond

   ((null value)
    nil)

   ((stringp value)
    (insert
     (expose-renderer-xml-escape value)))

   ((symbolp value)
    (insert
     (expose-renderer-xml-escape
      (symbol-name value))))

   ((and (listp value)
         (keywordp (car value)))
    (expose-renderer-xml-plist value))

   ((listp value)
    (expose-renderer-xml-list value))

   (t
    (insert
     (format "%s" value)))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun expose-renderer-xml-tag-name (key)
  "Return the XML tag name for KEY."

  (string-remove-prefix
   ":"
   (symbol-name key)))

(defun expose-renderer-xml-escape (string)
  "Return TEXT with XML entities escaped."

  (let ((string (or string "")))

    (setq string
          (replace-regexp-in-string "&" "&amp;" string t t))

    (setq string
          (replace-regexp-in-string "<" "&lt;" string t t))

    (setq string
          (replace-regexp-in-string ">" "&gt;" string t t))

    (setq string
          (replace-regexp-in-string "\"" "&quot;" string t t))

    (setq string
          (replace-regexp-in-string "'" "&apos;" string t t))

    string))

(defun expose-renderer-xml-empty-p (value)
  "Return non-nil if VALUE should be omitted."

  (cond

   ((null value)
    t)

   ((and (stringp value)
         (string-empty-p value))
    t)

   ((and (listp value)
         (keywordp (car value)))
    (expose-renderer-xml-plist-empty-p value))

   (t
    nil)))

(defun expose-renderer-xml-plist-empty-p (plist)
  "Return non-nil if every value in PLIST is empty."

  (let ((empty t))

    (while plist
      (pop plist)

      (unless
          (expose-renderer-xml-empty-p
           (pop plist))
        (setq empty nil)
        (setq plist nil)))

    empty))


(provide 'expose-xml)
