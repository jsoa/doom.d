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
;;; expose-request-extra-instructions: the seam a refinement injects
;;; through, without threading a parameter through every
;;; `expose-request-TYPE' builder -- same technique as
;;; `expose-context-git-staged-only'.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-extra-instructions-absent-by-default ()
  (let ((request
         (expose-request-create 'explain 'xml "Explain this." nil)))

    (should
     (equal
      (concat "Explain this." "\n\n" expose-request-output-instruction)
      (plist-get request :instruction)))))

(ert-deftest expose-request-test-extra-instructions-appended-between-base-and-output ()
  (let ((expose-request-extra-instructions "Also cover the empty case."))
    (let ((request
           (expose-request-create 'explain 'xml "Explain this." nil)))

      (should
       (equal
        (concat
         "Explain this." "\n\n"
         "Also cover the empty case." "\n\n"
         expose-request-output-instruction)
        (plist-get request :instruction))))))

(ert-deftest expose-request-test-extra-instructions-also-applies-when-raw ()
  (let ((expose-request-extra-instructions "Also cover the empty case."))
    (let ((request
           (expose-request-create 'commit-message 'xml "Write a commit message." nil t)))

      (should
       (string-match-p
        (regexp-quote "Also cover the empty case.")
        (plist-get request :instruction))))))

;;; ---------------------------------------------------------------------------
;;; expose-request-build: an explicit CONTEXT is used as-is instead of
;;; calling expose-context-build -- what lets a refinement rebuild a
;;; request against the code as it was when the action first ran,
;;; rather than wherever point has drifted to since.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-build-defaults-to-fresh-context ()
  (cl-letf (((symbol-function 'expose-context-build)
             (lambda () '(:file "fresh.py"))))

    (should
     (equal
      '(:file "fresh.py")
      (plist-get (expose-request-build 'explain) :context)))))

(ert-deftest expose-request-test-build-reuses-explicit-context ()
  ;; Stubbed to error rather than return something plausible: proves
  ;; expose-context-build is genuinely never called when an explicit
  ;; CONTEXT is given, not just that its result happens to be ignored.
  (cl-letf (((symbol-function 'expose-context-build)
             (lambda () (error "must not be called when context is explicit"))))

    (should
     (equal
      '(:file "stale.py")
      (plist-get
       (expose-request-build 'explain '(:file "stale.py"))
       :context)))))

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
;;; Regression: commit-message must scope git context to staged changes only.
;;;
;;; `expose-context-git-diff'/`expose-context-git-status' compared against
;;; HEAD by default, which mixes in whatever is edited-but-not-staged in the
;;; working tree -- so a commit message described changes that would not
;;; actually be part of the commit. `expose-request-commit-message' binds
;;; `expose-context-git-staged-only' around building its context; every
;;; other request type must NOT.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-commit-message-scopes-to-staged-only ()
  (let (staged-only-during-call)
    (cl-letf (((symbol-function 'expose-context-with-git)
               (lambda (context)
                 (setq staged-only-during-call expose-context-git-staged-only)
                 context)))

      (expose-request-commit-message '(:project "demo"))

      (should staged-only-during-call))))

;;; ---------------------------------------------------------------------------
;;; expose-request-buffer-review: driven by :buffer-diff, not point/
;;; selection -- unlike expose-request-review, which this otherwise
;;; parallels.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-request-test-buffer-review-includes-the-diff ()
  "The diff text itself travels in :context (rendered into its own XML
tag), not inlined into :instruction -- same split as every other
request type."

  (let ((request
         (expose-request-buffer-review
          (list :project "demo" :language "Python" :file "widgets.py"
                :buffer-diff "@@ -1,2 +1,3 @@\n+# a change"))))

    (should (eq 'buffer-review (plist-get request :type)))
    (should (string-match-p "diff" (plist-get request :instruction)))
    (should (equal "@@ -1,2 +1,3 @@\n+# a change"
                    (plist-get (plist-get request :context) :buffer-diff)))))

(ert-deftest expose-request-test-buffer-review-selects-only-the-relevant-keys ()
  "Point/selection-shaped keys (:scope, :focus, ...) have no meaning for
a whole-buffer diff review and must not leak in even if present on the
context passed in."

  (let ((request
         (expose-request-buffer-review
          (list :project "demo" :file "widgets.py" :buffer-diff "diff text"
                :scope "should not appear" :focus "should not appear either"))))

    (should (equal '(:project "demo" :file "widgets.py" :buffer-diff "diff text")
                    (plist-get request :context)))))

(ert-deftest expose-request-test-build-dispatches-buffer-review ()
  (let ((request
         (expose-request-build 'buffer-review '(:project "demo" :buffer-diff "diff text"))))

    (should (eq 'buffer-review (plist-get request :type)))))

(ert-deftest expose-request-test-review-does-not-scope-to-staged-only ()
  (let (staged-only-during-call)
    (cl-letf (((symbol-function 'expose-context-with-git)
               (lambda (context)
                 (setq staged-only-during-call expose-context-git-staged-only)
                 context)))

      (expose-request-review '(:project "demo"))

      (should-not staged-only-during-call))))

(ert-deftest expose-request-test-commit-message-staged-only-does-not-leak ()
  "Building a commit-message request must not affect the next request built."

  (cl-letf (((symbol-function 'expose-context-with-git)
             (lambda (context) context)))
    (expose-request-commit-message '(:project "demo")))

  (should-not expose-context-git-staged-only)

  (let (staged-only-during-call)
    (cl-letf (((symbol-function 'expose-context-with-git)
               (lambda (context)
                 (setq staged-only-during-call expose-context-git-staged-only)
                 context)))
      (expose-request-review '(:project "demo"))
      (should-not staged-only-during-call))))

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
