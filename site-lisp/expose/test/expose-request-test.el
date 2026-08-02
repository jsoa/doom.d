;;; expose-request-test.el --- Tests for expose-request -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-request)

;;; ---------------------------------------------------------------------------
;;; expose-request-create: raw vs Markdown output instruction
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-create-default-appends-markdown-instruction ()
  (let ((request
         (expose-request-create 'explain 'xml "Explain this." nil)))

    (should
     (string-match-p
      (regexp-quote expose-request-output-instruction)
      (plist-get request :instruction)))
    (should-not
     (string-match-p
      (regexp-quote expose-request-raw-output-instruction)
      (plist-get request :instruction)))))

(ert-deftest expose-request-test-create-raw-appends-raw-instruction ()
  (let ((request
         (expose-request-create 'commit-message 'xml "Write a commit message." nil t)))

    (should
     (string-match-p
      (regexp-quote expose-request-raw-output-instruction)
      (plist-get request :instruction)))
    (should-not
     (string-match-p
      (regexp-quote expose-request-output-instruction)
      (plist-get request :instruction)))))

(ert-deftest expose-request-test-create-preserves-type-format-and-context ()
  (let ((request
         (expose-request-create
          'review 'xml "Review this." '(:file "app.py"))))

    (should
     (eq (plist-get request :type) 'review))
    (should
     (eq (plist-get request :document-format) 'xml))
    (should
     (equal (plist-get request :context) '(:file "app.py")))))

;;; ---------------------------------------------------------------------------
;;; Regression: commit-message must be raw, changelog must not be.
;;;
;;; This is the exact mismatch that used to corrupt commit messages inserted
;;; directly into a buffer -- they'd come back wrapped in a Markdown heading
;;; and code fence because the shared, popup-oriented output instruction was
;;; applied to a direct-insert request type. Changelog is popup-only, so it
;;; must keep the Markdown instruction.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-commit-message-is-raw ()
  (cl-letf (((symbol-function 'expose-context-with-git)
             (lambda (context) context)))

    (let ((request
           (expose-request-commit-message '(:project "demo"))))

      (should
       (string-match-p
        (regexp-quote expose-request-raw-output-instruction)
        (plist-get request :instruction)))
      (should-not
       (string-match-p
        (regexp-quote expose-request-output-instruction)
        (plist-get request :instruction))))))

(ert-deftest expose-request-test-changelog-is-not-raw ()
  (cl-letf (((symbol-function 'expose-context-with-git)
             (lambda (context) context)))

    (let ((request
           (expose-request-changelog '(:project "demo"))))

      (should
       (string-match-p
        (regexp-quote expose-request-output-instruction)
        (plist-get request :instruction)))
      (should-not
       (string-match-p
        (regexp-quote expose-request-raw-output-instruction)
        (plist-get request :instruction))))))

;;; ---------------------------------------------------------------------------
;;; expose-request-select / expose-request-select-with-git
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-select-copies-only-requested-keys ()
  (should
   (equal
    (expose-request-select
     '(:project "demo" :file "app.py" :secret "x")
     :project :file)
    '(:project "demo" :file "app.py"))))

(ert-deftest expose-request-test-select-omits-nil-values ()
  (should
   (equal
    (expose-request-select
     '(:project "demo" :file nil)
     :project :file)
    '(:project "demo"))))

(ert-deftest expose-request-test-select-with-git-includes-git-keys ()
  (cl-letf (((symbol-function 'expose-context-with-git)
             (lambda (context)
               (plist-put
                (plist-put context :git-status "clean")
                :git-diff "diff --git a/x b/x"))))

    (should
     (equal
      (expose-request-select-with-git '(:project "demo") :project)
      '(:project "demo" :git-status "clean" :git-diff "diff --git a/x b/x")))))

(provide 'expose-request-test)

;;; expose-request-test.el ends here
