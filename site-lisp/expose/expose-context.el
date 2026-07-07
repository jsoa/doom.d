;;; expose-context.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'projectile)
(require 'thingatpt)
(require 'treesit)

;;; ---------------------------------------------------------------------------
;;; Tree-sitter Primitives
;;; ---------------------------------------------------------------------------

(defun expose-context-root-node ()
  "Return the Tree-sitter root node for the current buffer."

  (ignore-errors
    (treesit-buffer-root-node)))

(defun expose-context-current-node ()
  "Return the Tree-sitter node at point."

  (ignore-errors
    (treesit-node-at (point))))

(defun expose-context-parent (node)
  "Return NODE's parent."

  (when node
    (treesit-node-parent node)))

(defun expose-context-node-type (node)
  "Return NODE's type."

  (when node
    (treesit-node-type node)))

(defun expose-context-node-text (node)
  "Return NODE's source text."

  (when node
    (substring-no-properties
     (treesit-node-text node))))

(defun expose-context-child (node type)
  "Return the first child of NODE whose type is TYPE."

  (when node
    (catch 'found
      (dotimes (i (treesit-node-child-count node))
        (let ((child (treesit-node-child node i)))
          (when (string=
                 (treesit-node-type child)
                 type)
            (throw 'found child)))))))

(defun expose-context-children (node type)
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

(defun expose-context-find-parent (node types)
  "Return the first ancestor of NODE whose type is in TYPES."

  (while (and node
              (not (member
                    (treesit-node-type node)
                    types)))
    (setq node
          (treesit-node-parent node)))

  node)

(defun expose-context-find-all (node type)
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

(defun expose-context-scope-node-types ()
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

(defun expose-context-scope-node ()
  "Return the enclosing semantic scope."

  (expose-context-find-parent
   (expose-context-current-node)
   (expose-context-scope-node-types)))

(defun expose-context-scope-name ()
  "Return the current scope's name."

  (when-let* ((scope (expose-context-scope-node))
              (identifier
               (expose-context-child
                scope
                "identifier")))
    (expose-context-node-text identifier)))

(defun expose-context-scope-code ()
  "Return the source for the current semantic scope."

  (when-let ((scope (expose-context-scope-node)))
    (expose-context-node-text scope)))

(defun expose-context-scope ()
  "Return the current semantic scope."

  (list
   :name
   (expose-context-scope-name)

   :code
   (expose-context-scope-code)))

(defun expose-context-parent-scope-node ()
  "Return the parent semantic scope."

  (when-let ((scope (expose-context-scope-node)))
    (expose-context-find-parent
     (expose-context-parent scope)
     (expose-context-scope-node-types))))

(defun expose-context-parent-scope-name ()
  "Return the parent scope's name."

  (when-let* ((scope (expose-context-parent-scope-node))
              (identifier
               (expose-context-child
                scope
                "identifier")))
    (expose-context-node-text identifier)))

(defun expose-context-parent-scope-code ()
  "Return the source for the parent semantic scope."

  (when-let ((scope (expose-context-parent-scope-node)))
    (expose-context-node-text scope)))

(defun expose-context-parent-scope ()
  "Return the parent semantic scope."

  (list
   :name
   (expose-context-parent-scope-name)

   :code
   (expose-context-parent-scope-code)))

;;; ---------------------------------------------------------------------------
;;; Project
;;; ---------------------------------------------------------------------------

(defun expose-context-project ()
  "Return the current project name."

  (when (projectile-project-p)
    (projectile-project-name)))

(defun expose-context-project-root ()
  "Return the current project root."

  (when (projectile-project-p)
    (projectile-project-root)))

(defun expose-context-relative-file ()
  "Return the current file relative to the project."

  (if-let ((root (expose-context-project-root))
           (file buffer-file-name))
      (file-relative-name file root)
    (or buffer-file-name "")))

;;; ---------------------------------------------------------------------------
;;; Language
;;; ---------------------------------------------------------------------------

(defun expose-context-language ()
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

(defun expose-context-diagnostics ()
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

(defun expose-context-import-nodes ()
  "Return all import statements."

  (when-let ((root (expose-context-root-node)))
    (expose-context-find-all
     root
     "import_statement")))

(defun expose-context-imports ()
  "Return all imports."

  (mapcar
   #'expose-context-node-text
   (expose-context-import-nodes)))

;;; ---------------------------------------------------------------------------
;;; Focus
;;; ---------------------------------------------------------------------------

(defun expose-context-symbol ()
  "Return the symbol at point."

  (thing-at-point 'symbol t))

(defun expose-context-find-parent-text (types)
  "Return the source text for the first parent node in TYPES."

  (when-let ((node
              (expose-context-find-parent
               (expose-context-current-node)
               types)))
    (expose-context-node-text node)))

(defun expose-context-focus-identifier ()
  "Return the identifier at point."

  (thing-at-point 'symbol t))

(defun expose-context-focus-expression ()
  "Return the enclosing expression."

  (pcase major-mode
    ((or 'js-ts-mode
         'typescript-ts-mode
         'tsx-ts-mode)
     (expose-context-find-parent-text
      '("call_expression"
        "member_expression"
        "new_expression")))

    ((or 'python-mode
         'python-ts-mode)
     (expose-context-find-parent-text
      '("call"
        "attribute")))))

(defun expose-context-focus-construct ()
  "Return the enclosing semantic construct."

  (pcase major-mode
    ((or 'js-ts-mode
         'typescript-ts-mode
         'tsx-ts-mode)
     (expose-context-find-parent-text
      '("call_expression"
        "jsx_element"
        "return_statement"
        "if_statement"
        "variable_declarator")))

    ((or 'python-mode
         'python-ts-mode)
     (expose-context-find-parent-text
      '("call"
        "assignment"
        "return_statement"
        "if_statement"
        "for_statement"
        "expression_statement")))))

(defun expose-context-focus ()
  "Return the semantic focus at point."

  (list
   :identifier
   (expose-context-focus-identifier)

   :expression
   (expose-context-focus-expression)

   :construct
   (expose-context-focus-construct)))

;;; ---------------------------------------------------------------------------
;;; Context Builder
;;; ---------------------------------------------------------------------------

(defun expose-context-build ()
  "Return the semantic context surrounding point."

  (list
   :project
   (expose-context-project)

   :language
   (expose-context-language)

   :file
   (expose-context-relative-file)

   :symbol
   (expose-context-symbol)

   :scope
   (expose-context-scope)

   :parent-scope
   (expose-context-parent-scope)

   :diagnostics
   (expose-context-diagnostics)

   :imports
   (expose-context-imports)

   :focus
   (expose-context-focus)

   :code
   (expose-context-scope-code)))

(defun expose-context-get (context key)
  "Return KEY from CONTEXT."

  (plist-get context key))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-context-debug ()
  "Pretty print the current context."

  (interactive)

  (pp
   (expose-context-build)
   (get-buffer-create "*EXPOSE Context*"))

  (pop-to-buffer "*EXPOSE Context*"))

(defun expose-context-debug-node ()
  "Display the Tree-sitter node hierarchy at point."

  (interactive)

  (let ((node (expose-context-current-node)))

    (with-current-buffer (get-buffer-create "*EXPOSE Context*")

      (erase-buffer)

      (while node
        (insert
         (format "%s\n"
                 (treesit-node-type node)))

        (setq node
              (treesit-node-parent node)))

      (pop-to-buffer (current-buffer)))))

(defun expose-context-debug-scope ()
  "Display the current and parent scopes."

  (interactive)

  (message
   "Scope=%s Parent=%s"

   (plist-get
    (expose-context-scope)
    :name)

   (or
    (plist-get
     (expose-context-parent-scope)
     :name)
    "<none>")))

(defun expose-context-debug-imports ()
  "Display all imports in the current buffer."

  (interactive)

  (with-current-buffer (get-buffer-create "*EXPOSE Imports*")

    (erase-buffer)

    (dolist (import (expose-context-imports))
      (insert "========================================\n")
      (insert import)
      (insert "\n\n"))

    (pop-to-buffer (current-buffer))))

(defun expose-context-debug-symbol ()
  "Display the symbol at point."

  (interactive)

  (message "%s"
           (expose-context-symbol)))

(defun expose-context-debug-focus ()
  "Pretty print the current semantic focus."

  (interactive)

  (pp
   (expose-context-focus)
   (get-buffer-create "*EXPOSE Focus*"))

  (pop-to-buffer "*EXPOSE Focus*"))

(provide 'expose-context)
