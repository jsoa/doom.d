;;; expose.el -*- lexical-binding: t; -*-

(require 'expose-log)
(require 'expose-review)

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
               :desc "Scroll Down"      "j" #'expose-popup-scroll-down
               :desc "Scroll Up"        "k" #'expose-popup-scroll-up
               :desc "Close"            "q" #'expose-close
               :desc "Review"           "r" #'expose-run-review
               :desc "Diagnostics"      "d" #'expose-run-diagnostics
               :desc "Explain"          "e" #'expose-run-explain
               :desc "Fix"              "f" #'expose-run-fix
               :desc "Refactor"         "F" #'expose-run-refactor
               :desc "Security"         "s" #'expose-run-security
               :desc "Performance"      "p" #'expose-run-performance
               :desc "Tests"            "t" #'expose-run-tests
               :desc "Edge Cases"       "x" #'expose-run-edge-cases
               :desc "Flow"             "w" #'expose-run-flow
               :desc "Usage"            "u" #'expose-run-usage
               :desc "Docstring"        "D" #'expose-run-docstring
               :desc "Summary"          "m" #'expose-run-summary
               :desc "Types"            "T" #'expose-run-types
               :desc "Concurrency"      "C" #'expose-run-concurrency
               :desc "Invariants"       "i" #'expose-run-invariants
               :desc "Risks"            "!" #'expose-run-risks
               :desc "Why"              "Y" #'expose-run-why
               :desc "Mental Model"     "M" #'expose-run-mental-model
               :desc "Commit Message"   "g" #'expose-run-commit-message
               :desc "Changelog"        "n" #'expose-run-changelog
               :desc "Copy"             "y" #'expose-popup-copy
               :desc "History"          "h" #'expose-history-open
               :desc "Open"             "o" #'expose-popup-open
               :desc "Log"              "l" #'expose-log-open
               :desc "Clear Log"        "L" #'expose-log-clear
               :desc "Debug Buffer"     "?" #'expose-hover-debug-current-buffer
               :desc "Review Session"   "R" #'expose-review-open-or-start
               ))))))

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
