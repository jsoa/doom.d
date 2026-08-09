;;; expose.el -*- lexical-binding: t; -*-

(require 'expose-log)
(require 'expose-review)
(require 'expose-review-region)
(require 'expose-continue)
(require 'expose-review-archive)
(require 'expose-watch)

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
(require 'expose-review-source)

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

               ;; Keep these directly under SPC c h.
               :desc "Continue at point" "c" #'expose-continue-at-point
               :desc "Commit Message"    "g" #'expose-run-commit-message
               :desc "Changelog"         "n" #'expose-run-changelog

               :desc "Popup scroll down" "j" #'expose-popup-scroll-down
               :desc "Popup scroll up"   "k" #'expose-popup-scroll-up
               :desc "Popup quit"        "q" #'expose-popup-hide
               :desc "Copy popup"        "y" #'expose-popup-copy
               :desc "History"           "H" #'expose-history-open
               :desc "Open popup"        "o" #'expose-popup-open
               :desc "Log"               "l" #'expose-log-open
               :desc "Clear Log"         "L" #'expose-log-clear
               :desc "Debug Buffer"      "?" #'expose-hover-debug-current-buffer

               ;; Thing-at-point actions.
               (:prefix-map ("h" . "Thing at Point")
                :desc "Review"           "r" #'expose-run-review
                :desc "Comment"          "#" #'expose-run-code-comment
                :desc "Diagnostics"      "d" #'expose-run-diagnostics
                :desc "Explain"          "e" #'expose-run-explain
                :desc "Fix"              "f" #'expose-run-fix
                :desc "Refactor"         "R" #'expose-run-refactor
                :desc "Security"         "s" #'expose-run-security
                :desc "Performance"      "p" #'expose-run-performance
                :desc "Tests"            "t" #'expose-run-tests
                :desc "Edge Cases"       "x" #'expose-run-edge-cases
                :desc "Flow"             "F" #'expose-run-flow
                :desc "Usage"            "u" #'expose-run-usage
                :desc "Docstring"        "D" #'expose-run-docstring
                :desc "Summary"          "S" #'expose-run-summary
                :desc "Types"            "T" #'expose-run-types
                :desc "Concurrency"      "c" #'expose-run-concurrency
                :desc "Invariants"       "i" #'expose-run-invariants
                :desc "Risks"            "!" #'expose-run-risks
                :desc "Why"              "y" #'expose-run-why
                :desc "Mental Model"     "m" #'expose-run-mental-model
                :desc "Debug Buffer"     "?" #'expose-hover-debug-current-buffer)

               ;; Rendered diagrams. Their own group rather than more
               ;; entries under "Thing at Point": they answer with a
               ;; picture in a dedicated buffer instead of popup text,
               ;; and the reverse call graph isn't a provider action at
               ;; all.
               (:prefix-map ("G" . "Diagrams")
                :desc "Control flow"      "c" #'expose-run-control-flow-diagram
                :desc "Call flow"         "C" #'expose-run-call-flow-diagram
                :desc "Data flow"         "d" #'expose-run-data-flow-diagram
                :desc "Request flow"      "R" #'expose-run-request-flow-diagram
                :desc "Side effects"      "s" #'expose-run-side-effects-diagram
                :desc "Import graph"      "m" #'expose-run-import-graph
                :desc "Tests for this"    "t" #'expose-run-test-graph
                :desc "Entity relations"  "e" #'expose-run-er-diagram
                :desc "Reverse call graph" "r" #'expose-run-reverse-call-graph)

               (:prefix-map ("R" . "Full Review")
                :desc "Open/start review" "r" #'expose-review-open-or-start
                :desc "Review archives"   "a" #'expose-review-archive-open-full)

               (:prefix-map ("M" . "Region Review")
                :desc "Review region"     "m" #'expose-review-region
                :desc "View full review"  "v" #'expose-review-region-show-full-at-point
                :desc "Complete review"   "c" #'expose-review-region-complete-at-point
                :desc "Cancel review"     "q" #'expose-review-region-cancel-at-point
                :desc "Region archives"   "a" #'expose-review-archive-open-region)

               (:prefix-map ("W" . "Watch")
                :desc "Watch current buffer"       "w" #'expose-watch-current-buffer
                :desc "Unwatch current buffer"     "u" #'expose-watch-unwatch-current-buffer
                :desc "Review changed hunks now"   "r" #'expose-watch-review-current-buffer
                :desc "Open watch list"            "l" #'expose-watch-open-list
                :desc "Clear current buffer"       "c" #'expose-watch-clear-current-buffer
                :desc "Clear project comments"     "C" #'expose-watch-clear-project
                :desc "Toggle project auto-arm"    "a" #'expose-watch-toggle-project-auto
                :desc "Active items"               "A" #'expose-watch-open-active-list
                :desc "Toggle hidden markers"      "h" #'expose-watch-toggle-hidden)

               ))))))

;;; ---------------------------------------------------------------------------
;;; Mode
;;; ---------------------------------------------------------------------------

(define-minor-mode expose-mode
  "Expose code context and actions."
  :global t

  (if expose-mode

      (progn
        (expose-hover-mode 1)
        (expose-review-source-global-mode 1)
        (expose-review-region-source-global-mode 1)
        (expose-watch-global-mode 1))

    (expose-hover-mode -1)
    (expose-review-source-global-mode -1)
    (expose-review-region-source-global-mode -1)
    (expose-watch-global-mode -1)))

;;; ---------------------------------------------------------------------------
;;; Bootstrap
;;; ---------------------------------------------------------------------------

(expose-register-default-actions)

(expose-install-keybindings)

(provide 'expose)
