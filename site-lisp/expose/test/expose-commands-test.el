;;; expose-commands-test.el --- Tests for expose-commands -*- lexical-binding: t; -*-

(require 'ert)
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

(provide 'expose-commands-test)

;;; expose-commands-test.el ends here
