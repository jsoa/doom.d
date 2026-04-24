;;; init.el -*- lexical-binding: t; -*-

;; This file controls what Doom modules are enabled and what order they load in.
;; Remember to run 'doom sync' after modifying it!

;; NOTE Press 'SPC h d h' (or 'C-h d h' for non-vim users) to access Doom's
;;      documentation. There you'll find information about all of Doom's modules
;;      and what flags they support.

;; NOTE Move your cursor over a module's name (or its flags) and press 'K' (or
;;      'C-c g k' for non-vim users) to view its documentation. This works on
;;      flags as well (those symbols that start with a plus).
;;
;;      Alternatively, press 'gd' (or 'C-c g d') on a module to browse its
;;      directory (for easy access to its source code).

(doom! :input

       :completion
       (corfu +orderless)
       (vertico +icons +syntax)

       :ui
       doom
       doom-dashboard
       hl-todo
       modeline
       nav-flash
       ophints
       (popup +all +defaults)
       (treemacs +icons)
       (vc-gutter +pretty)
       vi-tilde-fringe
       workspaces

       :editor
       (evil +everywhere)
       file-templates
       fold
       (format +onsave)
       multiple-cursors
       rotate-text
       snippets
       (whitespace +guess +trim)

       :emacs
       (dired +icons)
       electric
       (ibuffer +icons)
       (undo +tree)
       vc

       :term
       eshell

       :checkers
       syntax
       (spell +flycheck)

       :tools
       ansible
       docker
       (eval +overlay)
       lookup
       (lsp +peek)
       magit
       rgb
       tree-sitter

       :os
       (:if (featurep :system 'macos) macos)

       :lang
       data
       emacs-lisp
       (html)
       (json +lsp)
       (javascript +lsp +tree-sitter)
       markdown
       (org +present)
       (python +lsp +pyright +tree-sitter)
       rest
       (sh +lsp)
       (typescript +tree-sitter)
       (web +lsp)
       (yaml +lsp)

       :email

       :app

       :config
       (default +bindings +smartparens))
