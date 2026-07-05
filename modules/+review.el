;;; modules/+review.el -*- lexical-binding: t; -*-

(defconst jsoa-review-directory
  (file-name-directory
   (or load-file-name
       buffer-file-name)))

(add-to-list
 'load-path
 (expand-file-name
  "review"
  jsoa-review-directory))

(add-to-list
 'load-path
 (expand-file-name
  "review/renderer"
  jsoa-review-directory))


(add-to-list
 'load-path
 (expand-file-name
  "review/provider"
  jsoa-review-directory))

(require 'jsoa-context)
(require 'jsoa-request)
(require 'jsoa-document)
(require 'jsoa-renderer-xml)

(require 'jsoa-provider)
(require 'jsoa-transport)
(require 'jsoa-commands)

(provide '+review)
