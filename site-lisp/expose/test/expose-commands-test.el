;;; expose-commands-test.el --- Tests for expose-commands -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-commands)

;;; ---------------------------------------------------------------------------
;;; expose-commands-view-body-text
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-view-body-text-string ()
  (should
   (equal
    (expose-commands-view-body-text "plain text")
    "plain text")))

(ert-deftest expose-commands-test-view-body-text-plist ()
  (should
   (equal
    (expose-commands-view-body-text '(:title "T" :body "body text"))
    "body text")))

;;; ---------------------------------------------------------------------------
;;; expose-commands-clean-insert-text
;;;
;;; The fence-stripping here is a defensive last resort for a response that
;;; is *entirely* a fenced block, matched only at the absolute start/end of
;;; the (trimmed) string. It intentionally does not strip a fence preceded
;;; by other content, e.g. a Markdown heading -- that case is prevented
;;; upstream instead, by requesting raw output in the first place (see
;;; expose-request-commit-message's `raw' argument). These tests pin both
;;; halves of that contract down.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-clean-insert-text-plain-text-passthrough ()
  (should
   (equal
    (expose-commands-clean-insert-text "feat: add debugpy-enabled dev service")
    "feat: add debugpy-enabled dev service")))

(ert-deftest expose-commands-test-clean-insert-text-strips-whole-fence ()
  (should
   (equal
    (expose-commands-clean-insert-text "```\nfeat: add debugpy-enabled dev service\n```")
    "feat: add debugpy-enabled dev service")))

(ert-deftest expose-commands-test-clean-insert-text-strips-fence-with-language-tag ()
  (should
   (equal
    (expose-commands-clean-insert-text "```text\nfeat: add debugpy-enabled dev service\n```")
    "feat: add debugpy-enabled dev service")))

(ert-deftest expose-commands-test-clean-insert-text-does-not-strip-opening-fence-after-heading ()
  ;; Known/accepted limitation: the opening-fence pattern is anchored to the
  ;; absolute start of the (trimmed) string, so a fence preceded by other
  ;; content -- e.g. a Markdown heading -- is left in place. The closing
  ;; fence is anchored independently to the end of the string and is
  ;; stripped regardless, since it can't tell "the whole response is one
  ;; fenced block" from "some earlier content happens to end right before a
  ;; trailing fence". Preventing this shape from occurring at all is handled
  ;; upstream by requesting raw output in the first place (see
  ;; expose-request-commit-message's `raw' argument); this test just pins
  ;; down what the fallback cleanup itself actually does today.
  (let ((input
         "## Commit Message\n\n```\nfeat: add debugpy-enabled dev service\n```"))

    (should
     (equal
      (expose-commands-clean-insert-text input)
      "## Commit Message\n\n```\nfeat: add debugpy-enabled dev service"))))

(ert-deftest expose-commands-test-clean-insert-text-trims-surrounding-whitespace ()
  (should
   (equal
    (expose-commands-clean-insert-text "\n\n  feat: tidy things up  \n\n")
    "feat: tidy things up")))

(ert-deftest expose-commands-test-clean-insert-text-nil-input ()
  (should
   (equal
    (expose-commands-clean-insert-text nil)
    "")))

;;; ---------------------------------------------------------------------------
;;; expose-commands-show-action-view
;;;
;;; The wiring that redirects `SPC c h h' results into the persistent
;;; action buffer -- and, since that bypasses `expose-popup-show-view'
;;; (the function `expose-history-add' used to piggyback on), the place
;;; that has to add them to history itself instead.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-show-action-view-shows-and-records ()
  (let ((shown nil) (recorded nil)
        (view (expose-popup-view-create "Explain" "the answer")))
    (cl-letf (((symbol-function 'expose-action-buffer-show)
               (lambda (v _sw) (setq shown v)))
              ((symbol-function 'expose-history-add)
               (lambda (v) (setq recorded v))))
      (expose-commands-show-action-view view 'a-window)
      (should (eq shown view))
      (should (eq recorded view)))))

(ert-deftest expose-commands-test-show-action-view-skips-history-for-loading-view ()
  "The transient `Loading...' placeholder (`:history nil') is shown but
must not be recorded -- only the real result should be."

  (let ((recorded nil)
        (view (expose-popup-loading-view "Explain")))
    (cl-letf (((symbol-function 'expose-action-buffer-show) (lambda (&rest _) nil))
              ((symbol-function 'expose-history-add) (lambda (v) (setq recorded v))))
      (expose-commands-show-action-view view 'a-window)
      (should-not recorded))))

(ert-deftest expose-commands-test-action-buffer-shows-loading-before-async-result ()
  "The action buffer opens immediately with a loading message, before an
async action's result arrives -- not just once the response lands.

Exercised through the real pipeline (`expose-popup-run-action', not
`expose-commands-show-action-view' directly) since that loading call is
`expose-popup-run-view-action's responsibility, not this wrapper's; this
test is about the two staying wired together correctly."

  (let (pending-cb)
    (unwind-protect
        (progn
          (expose-popup-register-action
           ?Q "QuickTest" 'view
           (lambda (cb) (setq pending-cb cb))
           :async t)
          (expose-popup-run-action ?Q)

          (should pending-cb)
          (with-current-buffer (get-buffer expose-action-buffer-name)
            (should (string-match-p "Loading" (buffer-string))))

          (funcall pending-cb (expose-popup-view-create "QuickTest" "the real answer"))
          (with-current-buffer expose-action-buffer-name
            (should (string-match-p "the real answer" (buffer-string)))
            (should-not (string-match-p "Loading" (buffer-string)))))
      (kill-buffer (get-buffer-create expose-action-buffer-name)))))

(ert-deftest expose-commands-test-view-display-function-is-wired ()
  "`expose-commands' is the module that redirects `SPC c h h' results
away from `expose-popup-show-view' -- confirm it actually did, since a
load-order slip here would silently leave results going to the hover."

  (should (eq expose-popup-view-display-function #'expose-commands-show-action-view)))

(provide 'expose-commands-test)

;;; expose-commands-test.el ends here
