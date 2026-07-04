;;; review/context.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'projectile)
(require 'thingatpt)
(require 'treesit)

;;; ---------------------------------------------------------------------------
;;; Tree-sitter Primitives
;;; ---------------------------------------------------------------------------

(defun jsoa-context-root-node ()
  "Return the Tree-sitter root node for the current buffer."

  (ignore-errors
    (treesit-buffer-root-node)))

(defun jsoa-context-current-node ()
  "Return the Tree-sitter node at point."

  (ignore-errors
    (treesit-node-at (point))))

(defun jsoa-context-parent (node)
  "Return NODE's parent."

  (when node
    (treesit-node-parent node)))

(defun jsoa-context-node-type (node)
  "Return NODE's type."

  (when node
    (treesit-node-type node)))

(defun jsoa-context-node-text (node)
  "Return NODE's source text."

  (when node
    (substring-no-properties
     (treesit-node-text node))))

(defun jsoa-context-child (node type)
  "Return the first child of NODE whose type is TYPE."

  (when node
    (catch 'found
      (dotimes (i (treesit-node-child-count node))
        (let ((child (treesit-node-child node i)))
          (when (string=
                 (treesit-node-type child)
                 type)
            (throw 'found child)))))))

(defun jsoa-context-children (node type)
  "Return all children of NODE whose type is TYPE."

  (let (children)

    (when node
      (dotimes (i (treesit-node-child-count node))
        (let ((child (treesit-node-child node i)))
          (when (string=
                 (treesit-node-type child)
                 type)
            (push child children)))))

    (nreverse children)))

(defun jsoa-context-find-parent (node types)
  "Return the first ancestor of NODE whose type is in TYPES."

  (while (and node
              (not (member
                    (treesit-node-type node)
                    types)))
    (setq node
          (treesit-node-parent node)))

  node)

(defun jsoa-context-find-all (node type)
  "Return every descendant of NODE whose type is TYPE."

  (let (results)

    (cl-labels
        ((walk (node)
           (when (string=
                  (treesit-node-type node)
                  type)
             (push node results))

           (dotimes (i (treesit-node-child-count node))
             (walk
              (treesit-node-child node i)))))

      (when node
        (walk node)))

    (nreverse results)))

;;; ---------------------------------------------------------------------------
;;; Scope
;;; ---------------------------------------------------------------------------

(defun jsoa-context-scope-node-types ()
  "Return the Tree-sitter node types that define semantic scopes."

  (pcase major-mode
    ((or 'python-mode
         'python-ts-mode)
     '("function_definition"
       "class_definition"))

    ((or 'js-ts-mode
         'typescript-ts-mode
         'tsx-ts-mode)
     '("function_declaration"
       "method_definition"
       "class_declaration"))

    ('emacs-lisp-mode
     '("list"))

    (_
     '("function_declaration"
       "function_definition"
       "method_definition"
       "class_declaration"
       "class_definition"))))

(defun jsoa-context-scope-node ()
  "Return the enclosing semantic scope."

  (jsoa-context-find-parent
   (jsoa-context-current-node)
   (jsoa-context-scope-node-types)))

(defun jsoa-context-scope-name ()
  "Return the current scope's name."

  (when-let* ((scope (jsoa-context-scope-node))
              (identifier
               (jsoa-context-child
                scope
                "identifier")))
    (jsoa-context-node-text identifier)))

(defun jsoa-context-scope-code ()
  "Return the source for the current semantic scope."

  (when-let ((scope (jsoa-context-scope-node)))
    (jsoa-context-node-text scope)))

(defun jsoa-context-scope ()
  "Return the current semantic scope."

  (list
   :name
   (jsoa-context-scope-name)

   :code
   (jsoa-context-scope-code)))

(defun jsoa-context-parent-scope-node ()
  "Return the parent semantic scope."

  (when-let ((scope (jsoa-context-scope-node)))
    (jsoa-context-find-parent
     (jsoa-context-parent scope)
     (jsoa-context-scope-node-types))))

(defun jsoa-context-parent-scope-name ()
  "Return the parent scope's name."

  (when-let* ((scope (jsoa-context-parent-scope-node))
              (identifier
               (jsoa-context-child
                scope
                "identifier")))
    (jsoa-context-node-text identifier)))

(defun jsoa-context-parent-scope-code ()
  "Return the source for the parent semantic scope."

  (when-let ((scope (jsoa-context-parent-scope-node)))
    (jsoa-context-node-text scope)))

(defun jsoa-context-parent-scope ()
  "Return the parent semantic scope."

  (list
   :name
   (jsoa-context-parent-scope-name)

   :code
   (jsoa-context-parent-scope-code)))

;;; ---------------------------------------------------------------------------
;;; Project
;;; ---------------------------------------------------------------------------

(defun jsoa-context-project ()
  "Return the current project name."

  (when (projectile-project-p)
    (projectile-project-name)))

(defun jsoa-context-project-root ()
  "Return the current project root."

  (when (projectile-project-p)
    (projectile-project-root)))

(defun jsoa-context-relative-file ()
  "Return the current file relative to the project."

  (if-let ((root (jsoa-context-project-root))
           (file buffer-file-name))
      (file-relative-name file root)
    (or buffer-file-name "")))

;;; ---------------------------------------------------------------------------
;;; Language
;;; ---------------------------------------------------------------------------

(defun jsoa-context-language ()
  "Return the current language."

  (pcase major-mode
    ((or 'python-mode
         'python-ts-mode)
     "Python")

    ((or 'js-mode
         'js-ts-mode)
     "JavaScript")

    ('typescript-ts-mode
     "TypeScript")

    ('tsx-ts-mode
     "TypeScript (React)")

    ('emacs-lisp-mode
     "Emacs Lisp")

    (_
     (symbol-name major-mode))))

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

(defun jsoa-context-diagnostics ()
  "Return Flycheck diagnostics at point."

  (when (fboundp 'flycheck-overlay-errors-at)
    (mapcar
     (lambda (err)
       (list
        :level
        (symbol-name (flycheck-error-level err))

        :message
        (flycheck-error-message err)))
     (flycheck-overlay-errors-at (point)))))

;;; ---------------------------------------------------------------------------
;;; Imports
;;; ---------------------------------------------------------------------------

(defun jsoa-context-import-nodes ()
  "Return all import statements."

  (when-let ((root (jsoa-context-root-node)))
    (jsoa-context-find-all
     root
     "import_statement")))

(defun jsoa-context-imports ()
  "Return all imports."

  (mapcar
   #'jsoa-context-node-text
   (jsoa-context-import-nodes)))

;;; ---------------------------------------------------------------------------
;;; Focus
;;; ---------------------------------------------------------------------------

(defun jsoa-context-symbol ()
  "Return the symbol at point."

  (thing-at-point 'symbol t))

(defun jsoa-context-find-parent-text (types)
  "Return the source text for the first parent node in TYPES."

  (when-let ((node
              (jsoa-context-find-parent
               (jsoa-context-current-node)
               types)))
    (jsoa-context-node-text node)))

(defun jsoa-context-focus-identifier ()
  "Return the identifier at point."

  (thing-at-point 'symbol t))

(defun jsoa-context-focus-expression ()
  "Return the enclosing expression."

  (pcase major-mode
    ((or 'js-ts-mode
         'typescript-ts-mode
         'tsx-ts-mode)
     (jsoa-context-find-parent-text
      '("call_expression"
        "member_expression"
        "new_expression")))

    ((or 'python-mode
         'python-ts-mode)
     (jsoa-context-find-parent-text
      '("call"
        "attribute")))))

(defun jsoa-context-focus-construct ()
  "Return the enclosing semantic construct."

  (pcase major-mode
    ((or 'js-ts-mode
         'typescript-ts-mode
         'tsx-ts-mode)
     (jsoa-context-find-parent-text
      '("call_expression"
        "jsx_element"
        "return_statement"
        "if_statement"
        "variable_declarator")))

    ((or 'python-mode
         'python-ts-mode)
     (jsoa-context-find-parent-text
      '("call"
        "assignment"
        "return_statement"
        "if_statement"
        "for_statement"
        "expression_statement")))))

(defun jsoa-context-focus ()
  "Return the semantic focus at point."

  (list
   :identifier
   (jsoa-context-focus-identifier)

   :expression
   (jsoa-context-focus-expression)

   :construct
   (jsoa-context-focus-construct)))

;;; ---------------------------------------------------------------------------
;;; Context Builder
;;; ---------------------------------------------------------------------------

(defun jsoa-context-build ()
  "Return the semantic context surrounding point."

  (list
   :project
   (jsoa-context-project)

   :language
   (jsoa-context-language)

   :file
   (jsoa-context-relative-file)

   :symbol
   (jsoa-context-symbol)

   :scope
   (jsoa-context-scope)

   :parent-scope
   (jsoa-context-parent-scope)

   :diagnostics
   (jsoa-context-diagnostics)

   :imports
   (jsoa-context-imports)

   :focus
   (jsoa-context-focus)

   :code
   (jsoa-context-scope-code)))

(defun jsoa-context-get (context key)
  "Return KEY from CONTEXT."

  (plist-get context key))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun jsoa-context-debug ()
  "Pretty print the current context."

  (interactive)

  (pp
   (jsoa-context-build)
   (get-buffer-create "*JSOA Context*"))

  (pop-to-buffer "*JSOA Context*"))

(defun jsoa-context-debug-node ()
  "Display the Tree-sitter node hierarchy at point."

  (interactive)

  (let ((node (jsoa-context-current-node)))

    (with-current-buffer (get-buffer-create "*JSOA Context*")

      (erase-buffer)

      (while node
        (insert
         (format "%s\n"
                 (treesit-node-type node)))

        (setq node
              (treesit-node-parent node)))

      (pop-to-buffer (current-buffer)))))

(defun jsoa-context-debug-scope ()
  "Display the current and parent scopes."

  (interactive)

  (message
   "Scope=%s Parent=%s"

   (plist-get
    (jsoa-context-scope)
    :name)

   (or
    (plist-get
     (jsoa-context-parent-scope)
     :name)
    "<none>")))

(defun jsoa-context-debug-imports ()
  "Display all imports in the current buffer."

  (interactive)

  (with-current-buffer (get-buffer-create "*JSOA Imports*")

    (erase-buffer)

    (dolist (import (jsoa-context-imports))
      (insert "========================================\n")
      (insert import)
      (insert "\n\n"))

    (pop-to-buffer (current-buffer))))

(defun jsoa-context-debug-symbol ()
  "Display the symbol at point."

  (interactive)

  (message "%s"
           (jsoa-context-symbol)))

(defun jsoa-context-debug-focus ()
  "Pretty print the current semantic focus."

  (interactive)

  (pp
   (jsoa-context-focus)
   (get-buffer-create "*JSOA Focus*"))

  (pop-to-buffer "*JSOA Focus*"))

(provide 'jsoa-context)
