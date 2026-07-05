;;; review/renderer/xml.el -*- lexical-binding: t; -*-

(require 'xml)

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun jsoa-renderer-xml (request)
  "Render REQUEST as XML."

  (with-temp-buffer
    (jsoa-renderer-xml-node
     "request"
     request)

    (buffer-string)))

;;; ---------------------------------------------------------------------------
;;; Nodes
;;; ---------------------------------------------------------------------------

(defun jsoa-renderer-xml-node (name value)
  "Render XML node NAME containing VALUE."

  (insert "<" name ">")

  (jsoa-renderer-xml-value value)

  (insert "</" name ">\n"))

(defun jsoa-renderer-xml-plist (plist)
  "Render PLIST."

  (while plist
    (let ((key (pop plist))
          (value (pop plist)))

      (unless
          (jsoa-renderer-xml-empty-p value)

        (jsoa-renderer-xml-node
         (jsoa-renderer-xml-tag-name key)
         value)))))

(defun jsoa-renderer-xml-list (list)
  "Render LIST."

  (dolist (item list)
    (jsoa-renderer-xml-node
     "item"
     item)))

(defun jsoa-renderer-xml-value (value)
  "Render VALUE."

  (cond

   ((null value)
    nil)

   ((stringp value)
    (insert
     (jsoa-renderer-xml-escape value)))

   ((symbolp value)
    (insert
     (jsoa-renderer-xml-escape
      (symbol-name value))))

   ((and (listp value)
         (keywordp (car value)))
    (jsoa-renderer-xml-plist value))

   ((listp value)
    (jsoa-renderer-xml-list value))

   (t
    (insert
     (format "%s" value)))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun jsoa-renderer-xml-tag (tag value)
  "Insert TAG containing VALUE."

  (insert "<" tag ">")
  (insert value)
  (insert "</" tag ">\n"))

(defun jsoa-renderer-xml-tag-name (key)
  "Return the XML tag name for KEY."

  (string-remove-prefix
   ":"
   (symbol-name key)))

(defun jsoa-renderer-xml-escape (string)
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

(defun jsoa-renderer-xml-empty-p (value)
  "Return non-nil if VALUE should be omitted."

  (cond

   ((null value)
    t)

   ((and (stringp value)
         (string-empty-p value))
    t)

   ((and (listp value)
         (keywordp (car value)))
    (jsoa-renderer-xml-plist-empty-p value))

   (t
    nil)))

(defun jsoa-renderer-xml-plist-empty-p (plist)
  "Return non-nil if every value in PLIST is empty."

  (let ((empty t))

    (while plist
      (pop plist)

      (unless
          (jsoa-renderer-xml-empty-p
           (pop plist))
        (setq empty nil)
        (setq plist nil)))

    empty))


(provide 'jsoa-renderer-xml)
