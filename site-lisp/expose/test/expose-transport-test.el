;;; expose-transport-test.el --- Tests for expose-transport -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-transport)

;;; ---------------------------------------------------------------------------
;;; expose-transport-response-text
;;; ---------------------------------------------------------------------------

(ert-deftest expose-transport-test-response-text-string-passthrough ()
  (should
   (equal
    (expose-transport-response-text "hello")
    "hello")))

(ert-deftest expose-transport-test-response-text-nil-is-empty-string ()
  (should
   (equal
    (expose-transport-response-text nil)
    "")))

(ert-deftest expose-transport-test-response-text-unwraps-body ()
  (should
   (equal
    (expose-transport-response-text '(:body "hello"))
    "hello")))

(ert-deftest expose-transport-test-response-text-unwraps-content-then-text ()
  (should
   (equal
    (expose-transport-response-text '(:content (:text "hello")))
    "hello")))

(ert-deftest expose-transport-test-response-text-unwraps-response-key ()
  (should
   (equal
    (expose-transport-response-text '(:response "hello"))
    "hello")))

(ert-deftest expose-transport-test-response-text-number-and-symbol ()
  (should
   (equal
    (expose-transport-response-text 42)
    "42"))
  (should
   (equal
    (expose-transport-response-text 'ok)
    "ok")))

;;; ---------------------------------------------------------------------------
;;; expose-transport-truncate-string
;;; ---------------------------------------------------------------------------

(ert-deftest expose-transport-test-truncate-string-nil-max-length-is-noop ()
  (should
   (equal
    (expose-transport-truncate-string "hello world" nil)
    "hello world")))

(ert-deftest expose-transport-test-truncate-string-under-limit-is-noop ()
  (should
   (equal
    (expose-transport-truncate-string "hello" 100)
    "hello")))

(ert-deftest expose-transport-test-truncate-string-over-limit-truncates-and-marks ()
  (let ((result
         (expose-transport-truncate-string "hello world" 5)))

    (should
     (string-prefix-p "hello" result))
    (should
     (string-match-p "truncated" result))))

;;; ---------------------------------------------------------------------------
;;; expose-transport-proper-list-p
;;; ---------------------------------------------------------------------------

(ert-deftest expose-transport-test-proper-list-p-normal-list ()
  (should
   (expose-transport-proper-list-p '(1 2 3))))

(ert-deftest expose-transport-test-proper-list-p-nil-is-a-proper-list ()
  (should
   (expose-transport-proper-list-p nil)))

(ert-deftest expose-transport-test-proper-list-p-dotted-pair-is-not-proper ()
  (should-not
   (expose-transport-proper-list-p (cons 1 2))))

(ert-deftest expose-transport-test-proper-list-p-circular-list-is-not-proper ()
  (let ((circular
         (list 1 2 3)))

    (setcdr (last circular) circular)

    (should-not
     (expose-transport-proper-list-p circular))))

;;; ---------------------------------------------------------------------------
;;; expose-transport-readable-value
;;; ---------------------------------------------------------------------------

(ert-deftest expose-transport-test-readable-value-plain-values-passthrough ()
  (should
   (equal
    (expose-transport-readable-value '(1 "two" three))
    '(1 "two" three))))

(ert-deftest expose-transport-test-readable-value-circular-list-does-not-hang ()
  (let ((circular
         (list 1 2 3)))

    (setcdr (last circular) circular)

    ;; The important assertion is simply that this returns instead of
    ;; looping forever; a bounded, non-nil result confirms that.
    (should
     (expose-transport-readable-value circular))))

(ert-deftest expose-transport-test-readable-value-buffer-becomes-descriptive-string ()
  (let* ((buffer
          (generate-new-buffer "expose-transport-test-buffer"))

         (result
          (expose-transport-readable-value buffer)))

    (unwind-protect
        (should
         (string-match-p "expose-transport-test-buffer" result))

      (kill-buffer buffer))))

(ert-deftest expose-transport-test-readable-value-deep-nesting-is-capped ()
  (let* ((expose-transport-readable-value-max-depth 3)

         (deep
          '(1 (2 (3 (4 (5 6))))))

         (result
          (expose-transport-readable-value deep)))

    ;; The exact shape below `max-depth' isn't the point (that's covered by
    ;; the "not too shallow" test below); what matters is that recursion
    ;; actually stops instead of copying arbitrarily deep/cyclic structures.
    (should
     (string-match-p "max readable depth" (format "%S" result)))
    ;; Structure within the depth budget is still copied faithfully.
    (should
     (equal (car result) 1))
    (should
     (equal (car (cadr result)) 2))))

(ert-deftest expose-transport-test-readable-value-long-flat-plist-not-treated-as-deep ()
  ;; A long flat list should not be rejected as "too deep" just because it
  ;; has many elements -- depth tracks nesting, not list length.
  (let* ((expose-transport-readable-value-max-depth 3)

         (flat
          (number-sequence 1 50))

         (result
          (expose-transport-readable-value flat)))

    (should
     (equal result flat))))

(provide 'expose-transport-test)

;;; expose-transport-test.el ends here
