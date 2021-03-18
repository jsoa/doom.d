;;; ~/.doom.d/+general.el -*- lexical-binding: t; -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; NOTE: General configurations                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;; allow remembering risky variables
;; https://emacs.stackexchange.com/questions/10983/remember-permission-to-execute-risky-local-variables
;; (defun risky-local-variable-p (sym &optional _ignored) nil)
(advice-add 'risky-local-variable-p :override #'ignore)

;; Modeline filename
(setq doom-modeline-buffer-file-name-style 'truncate-all)
(setq doom-themes-treemacs-theme "doom-colors")

;; Default aspell language
;; REF: https://github.com/hlissner/doom-emacs/issues/4509
(setq ispell-dictionary "en")
