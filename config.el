;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; refresh' after modifying this file!


;; These are used for a number of things, particularly for GPG configuration,
;; some email clients, file templates and snippets.
(setq user-full-name "Jose Soares"
      user-mail-address "jose@linux.com")

;; Doom exposes five (optional) variables for controlling fonts in Doom. Here
;; are the three important ones:
;;
;; + `doom-font'
;; + `doom-variable-pitch-font'
;; + `doom-big-font' -- used for `doom-big-font-mode'
;;
;; They all accept either a font-spec, font string ("Input Mono-12"), or xlfd
;; font string. You generally only need these two:
;; (setq doom-font (font-spec :family "monospace" :size 14))
(setq doom-font (font-spec :family "JetBrainsMono" :size 14 :weight 'regular)
      doom-variable-pitch-font (font-spec :family "sans" :size 15))

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. These are the defaults.
(setq doom-theme 'doom-one)

;; If you intend to use org, it is recommended you change this!
(setq org-directory "~/org/")

;; If you want to change the style of line numbers, change this to `relative' or
;; `nil' to disable it:
(setq display-line-numbers-type t)




;; Here are some additional functions/macros that could help you configure Doom:
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', where Emacs
;;   looks when you load packages with `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c g k').
;; This will open documentation for it, including demos of how they are used.
;;
;; You can also try 'gd' (or 'C-c g d') to jump to their definition and see how
;; they are implemented.



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                            ;;
;; NOTE: This section decribes some notes about various modes, functions,     ;;
;; bindings, etc                                                              ;;
;;                                                                            ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; UNDO-TREE
;; http://www.dr-qubit.org/Lost_undo-tree_history.html
;; 


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                            ;;
;; NOTE: This section holds extra custom functionality such as custom         ;;
;; functions, custom bindings and configurations                              ;;
;;                                                                            ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;



;; Custom functions and bindings
(load! "core/+functions")
(load! "core/+bindings")
(load! "core/+general")

;; Custom modules
(load! "modules/+large-file")
(load! "modules/+dashboard")

;; General configurations
(load! "modules/+vertico")
(load! "modules/+corfu")
(load! "modules/+dired")
(load! "modules/+evil")
(load! "modules/+org")
(load! "modules/+projectile")
(load! "modules/+avy")
(load! "modules/+spell")
(load! "modules/+prettier")

;; AI
(load! "modules/+copilot")

;; Pre programming mode configurations
(load! "modules/+fci")
(load! "modules/+flycheck")
(load! "modules/+compilation")
(load! "modules/+ediff")
(load! "modules/+lsp")
(load! "modules/+magit")

;; Programming mode configuration
(load! "modules/+groovy")
(load! "modules/+python")
(load! "modules/+typescript")
(load! "modules/+html")

;; Private locals
(when (file-exists-p "~/.doom.d/private/vars.el")
  (load-file "~/.doom.d/private/vars.el"))
