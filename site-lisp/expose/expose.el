;;; expose.el -*- lexical-binding: t; -*-

(require 'expose-log)

(defgroup expose nil
  "Expose code context and actions."
  :group 'tools)

(defcustom expose-key-prefix
  "c h"
  "Leader key prefix used by Expose."
  :type 'string
  :group 'expose)

(require 'expose-popup)
(require 'expose-hover)
(require 'expose-commands)

;;; ---------------------------------------------------------------------------
;;; Keybindings
;;; ---------------------------------------------------------------------------

(defun expose-key-prefix-binding ()
  "Return the current Doom leader binding for `expose-key-prefix'."

  (when (boundp 'doom-leader-map)
    (lookup-key
     doom-leader-map
     (kbd expose-key-prefix))))

(defun expose-key-prefix-conflict-p ()
  "Return non-nil if `expose-key-prefix' is already a non-prefix binding."

  (let ((binding
         (expose-key-prefix-binding)))

    (and
     binding
     (not (numberp binding))
     (not (keymapp binding)))))

(defun expose-install-keybindings ()
  "Install Expose keybindings when Doom's `map!' is available."

  (if (not (fboundp 'map!))

      (expose-log
       "Expose"
       "Skipping keybindings because Doom `map!' is unavailable.")

    (if (expose-key-prefix-conflict-p)

        (expose-log
         "Expose"
         "Skipping keybindings because SPC %s is already bound to %s."
         expose-key-prefix
         (expose-key-prefix-binding))

      (expose-log
       "Expose"
       "Installing keybindings under SPC %s."
       expose-key-prefix)

      (eval
       `(map! :leader
              (:prefix (,expose-key-prefix . "expose")
               :desc "Scroll Down" "j" #'expose-popup-scroll-down
               :desc "Scroll Up"   "k" #'expose-popup-scroll-up
               :desc "Close"       "q" #'expose-close
               :desc "Review"      "r" #'expose-run-review
               :desc "Diagnostics" "d" #'expose-run-diagnostics
               :desc "Explain"     "e" #'expose-run-explain
               :desc "Copy"        "y" #'expose-popup-copy
               :desc "History"     "h" #'expose-history-open
               :desc "Open"        "o" #'expose-popup-open
               :desc "Log"         "l" #'expose-log-open
               :desc "Debug Buffer" "?" #'expose-hover-debug-current-buffer
               :desc "Clear Log"   "L" #'expose-log-clear))))))

;;; ---------------------------------------------------------------------------
;;; Mode
;;; ---------------------------------------------------------------------------

(define-minor-mode expose-mode
  "Expose code context and actions."
  :global t

  (if expose-mode
      (expose-hover-mode 1)
    (expose-hover-mode -1)))

;;; ---------------------------------------------------------------------------
;;; Bootstrap
;;; ---------------------------------------------------------------------------

(expose-register-default-actions)

(expose-install-keybindings)

(provide 'expose)
