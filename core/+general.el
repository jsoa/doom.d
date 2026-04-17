;;; ~/.doom.d/+general.el -*- lexical-binding: t; -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; NOTE: General configurations                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;; allow remembering risky variables
;; https://emacs.stackexchange.com/questions/10983/remember-permission-to-execute-risky-local-variables
;; (defun risky-local-variable-p (sym &optional _ignored) nil)
(advice-add 'risky-local-variable-p :override #'ignore)

;; Modeline filename
(after! doom-modeline
  (setq doom-modeline-buffer-file-name-style 'truncate-all))

;; Default aspell language
;; REF: https://github.com/hlissner/doom-emacs/issues/4509
(setq ispell-dictionary "en_US")

(setq doom-watch-inotify t)

(add-to-list 'initial-frame-alist '(fullscreen . maximized))
(add-to-list 'default-frame-alist '(fullscreen . maximized))
