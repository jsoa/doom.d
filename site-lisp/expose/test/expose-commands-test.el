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
;;; Where `SPC c h h' results are shown
;;;
;;; The wiring that redirects `SPC c h h' results into the persistent
;;; action buffer, set directly to `expose-action-buffer-show' (no
;;; wrapper needed -- see the comment above the `setq' in
;;; `expose-commands.el'). What that function itself does with a
;;; view -- placement, rendering, adding to history -- is tested in
;;; `expose-action-buffer-test.el', not duplicated here.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-action-buffer-shows-loading-before-async-result ()
  "The action buffer opens immediately with a loading message, before an
async action's result arrives -- not just once the response lands.

Exercised through the real pipeline (`expose-popup-run-action'), since
that loading call is `expose-popup-run-view-action's responsibility;
this test is about the two staying wired together correctly."

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

  (should (eq expose-popup-view-display-function #'expose-action-buffer-show)))

;;; ---------------------------------------------------------------------------
;;; Refining an action buffer result
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-action-view-carries-refine-when-type-and-context-given ()
  (let ((view (expose-action-view "Tests" "the answer" 'tests '(:file "a.py"))))
    (should
     (equal
      '(:type tests :context (:file "a.py") :refinements nil)
      (plist-get view :refine)))))

(ert-deftest expose-commands-test-action-view-omits-refine-when-type-or-context-missing ()
  "An error response calls `expose-action-view' with neither -- nothing
successful yet exists to build a follow-up on."

  (should-not (plist-get (expose-action-view "Tests" "boom") :refine))
  (should-not (plist-get (expose-action-view "Tests" "boom" 'tests) :refine))
  (should-not (plist-get (expose-action-view "Tests" "boom" nil '(:file "a.py")) :refine)))

(ert-deftest expose-commands-test-action-view-carries-refinements-through ()
  (let ((view
         (expose-action-view "Tests" "the answer" 'tests '(:file "a.py") '("also add C"))))

    (should
     (equal '("also add C") (plist-get (plist-get view :refine) :refinements)))))

(ert-deftest expose-commands-test-refine-instructions-text-is-numbered-and-framed ()
  (let ((text (expose-commands-refine-instructions-text '("also add C" "nvm undo that"))))

    (should (string-match-p "1\\. also add C" text))
    (should (string-match-p "2\\. nvm undo that" text))
    ;; The framing exists specifically so "undo that" resolves reliably
    ;; -- see the discussion this was built from.
    (should (string-match-p "follow-up refinements" text))))

(defmacro expose-commands-test-with-stub-transport (response-var &rest body)
  "Run BODY with `expose-transport-send-document-async' stubbed.

RESPONSE-VAR is bound to a mutable cons `(kind . value)': set it to
`(success . \"text\")' or `(error . \"message\")' before an action runs
to control what the stub hands back. The document actually sent is
recorded into `expose-commands-test-last-document', for assertions
about what a refinement folded into the request."

  (declare (indent 1))
  `(let ((,response-var (cons 'success "stub response"))
         (expose-commands-test-last-document nil))
     (cl-letf (((symbol-function 'expose-transport-send-document-async)
                (lambda (_provider document success-cb _project-root error-cb)
                  (setq expose-commands-test-last-document document)
                  (pcase (car ,response-var)
                    ('success (funcall success-cb (cdr ,response-var)))
                    ('error (funcall error-cb (list 'error (cdr ,response-var)))))
                  'stub-process)))
       ,@body)))

(defmacro expose-commands-test-with-refinable-buffer (&rest body)
  "Run BODY with `expose-action-buffer-name' current, selected, and
showing a refinable result -- as if a real `SPC c h h' action had just
completed. `widgets.py' (a plain buffer, not visiting a real file) is
the source, to its left."

  (declare (indent 0))
  `(let ((response (cons 'success "stub response")))
     ;; Stubbed: real `expose-context-build' reaches out to Projectile,
     ;; Flycheck, imenu and the like, none of which this test suite
     ;; runs against real implementations of (see
     ;; `test/stubs/projectile.el'). These tests are about the refine
     ;; mechanism -- accumulation, undo-by-append, rollback-on-error --
     ;; not about context-building itself, which has its own coverage.
     (cl-letf (((symbol-function 'expose-context-build)
                (lambda () '(:file "ecrt-widgets.py"))))
       (expose-commands-test-with-stub-transport response
         (unwind-protect
             (progn
               (delete-other-windows)
               (switch-to-buffer (get-buffer-create "ecrt-widgets.py"))
               (expose-popup-register-action
                ?T "Tests" 'view
                (lambda (cb) (expose-send-view-action-async 'tests "Tests" cb))
                :async t)
               (expose-popup-run-action ?T)
               (with-selected-window (get-buffer-window expose-action-buffer-name)
                 ,@body))
           (delete-other-windows)
           (when (get-buffer expose-action-buffer-name)
             (kill-buffer expose-action-buffer-name))
           (when (get-buffer "ecrt-widgets.py")
             (kill-buffer "ecrt-widgets.py")))))))

(ert-deftest expose-commands-test-refine-accumulates-and-resends-both-on-undo ()
  "The full round trip: two refinements, the second an \"undo\", both
kept -- nothing is ever popped, matching the design this was built to."

  (expose-commands-test-with-refinable-buffer
    (setq response (cons 'success "tests with C"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "also add a test for C")))
      (call-interactively #'expose-commands-refine-action-buffer))

    (should (equal '("also add a test for C")
                    (plist-get expose-action-buffer-refine :refinements)))

    (setq response (cons 'success "tests without C"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "nvm undo that")))
      (call-interactively #'expose-commands-refine-action-buffer))

    (should (equal '("also add a test for C" "nvm undo that")
                    (plist-get expose-action-buffer-refine :refinements)))
    (should (string-match-p "1\\. also add a test for C" expose-commands-test-last-document))
    (should (string-match-p "2\\. nvm undo that" expose-commands-test-last-document))
    (with-current-buffer expose-action-buffer-name
      (should (string-match-p "tests without C" (buffer-string))))))

(ert-deftest expose-commands-test-refine-empty-input-is-a-noop ()
  (expose-commands-test-with-refinable-buffer
    (let ((before (plist-get expose-action-buffer-refine :refinements)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "   ")))
        (call-interactively #'expose-commands-refine-action-buffer))
      (should (equal before (plist-get expose-action-buffer-refine :refinements))))))

(ert-deftest expose-commands-test-refine-failure-rolls-back-but-stays-refinable ()
  (expose-commands-test-with-refinable-buffer
    (setq response (cons 'success "tests with C"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "also add a test for C")))
      (call-interactively #'expose-commands-refine-action-buffer))

    (setq response (cons 'error "provider exploded"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "this one fails")))
      (call-interactively #'expose-commands-refine-action-buffer))

    (with-current-buffer expose-action-buffer-name
      (should (string-match-p "Refinement failed" (buffer-string)))
      (should expose-action-buffer-refine)
      ;; The failed ask is dropped, not silently kept as if it had
      ;; succeeded -- only the prior, successful one survives.
      (should (equal '("also add a test for C")
                      (plist-get expose-action-buffer-refine :refinements))))))

(ert-deftest expose-commands-test-refine-refuses-without-refine-data ()
  (expose-commands-test-with-refinable-buffer
    (with-current-buffer expose-action-buffer-name
      (setq expose-action-buffer-refine nil))
    (should-error
     (call-interactively #'expose-commands-refine-action-buffer)
     :type 'user-error)))

;;; ---------------------------------------------------------------------------
;;; expose-run-buffer-review / expose-buffer-review-async
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-run-buffer-review-refuses-without-a-file ()
  (with-temp-buffer
    (should-error (expose-run-buffer-review) :type 'user-error)))

(ert-deftest expose-commands-test-run-buffer-review-refuses-with-no-diff ()
  (cl-letf (((symbol-function 'expose-context-git-diff-for-buffer) (lambda () nil)))
    (let ((buffer-file-name "/repo/widgets.py"))
      (should-error (expose-run-buffer-review) :type 'user-error))))

(ert-deftest expose-commands-test-run-buffer-review-refuses-with-blank-diff ()
  (cl-letf (((symbol-function 'expose-context-git-diff-for-buffer) (lambda () "   \n")))
    (let ((buffer-file-name "/repo/widgets.py"))
      (should-error (expose-run-buffer-review) :type 'user-error))))

(ert-deftest expose-commands-test-run-buffer-review-proceeds-with-a-real-diff ()
  (let (ran)
    (cl-letf (((symbol-function 'expose-context-git-diff-for-buffer) (lambda () "@@ real diff @@"))
              ((symbol-function 'expose-popup-run-action) (lambda (key) (setq ran key))))
      (let ((buffer-file-name "/repo/widgets.py"))
        (expose-run-buffer-review))
      (should (eq ?b ran)))))

(ert-deftest expose-commands-test-buffer-review-async-context-carries-the-diff ()
  (let (sent-type sent-title sent-context)
    (cl-letf (((symbol-function 'expose-context-project) (lambda () "demo"))
              ((symbol-function 'expose-context-language) (lambda () "Python"))
              ((symbol-function 'expose-context-relative-file) (lambda () "widgets.py"))
              ((symbol-function 'expose-context-git-diff-for-buffer) (lambda () "@@ the diff @@"))
              ((symbol-function 'expose-send-view-action-async)
               (lambda (type title callback &optional context)
                 (setq sent-type type sent-title title sent-context context)
                 (funcall callback nil))))

      (expose-buffer-review-async #'ignore))

    (should (eq 'buffer-review sent-type))
    (should (equal "Buffer Review" sent-title))
    (should (equal "@@ the diff @@" (plist-get sent-context :buffer-diff)))
    (should (equal "widgets.py" (plist-get sent-context :file)))))

;;; ---------------------------------------------------------------------------
;;; expose-conflict-bounds / expose-conflict-at-point
;;; ---------------------------------------------------------------------------

(defun expose-commands-test-insert-conflict ()
  "Insert a sample merge conflict hunk into the current buffer."

  (insert "before\n<<<<<<< HEAD\nours line\n=======\ntheirs line\n>>>>>>> feature-branch\nafter\n"))

(ert-deftest expose-commands-test-conflict-bounds-point-inside-ours ()
  (with-temp-buffer
    (expose-commands-test-insert-conflict)
    (goto-char (point-min))
    (search-forward "ours line")
    (should (expose-conflict-bounds))))

(ert-deftest expose-commands-test-conflict-bounds-point-inside-theirs ()
  (with-temp-buffer
    (expose-commands-test-insert-conflict)
    (goto-char (point-min))
    (search-forward "theirs line")
    (should (expose-conflict-bounds))))

(ert-deftest expose-commands-test-conflict-bounds-nil-before-conflict ()
  (with-temp-buffer
    (expose-commands-test-insert-conflict)
    (goto-char (point-min))
    (search-forward "before")
    (should-not (expose-conflict-bounds))))

(ert-deftest expose-commands-test-conflict-bounds-nil-after-conflict ()
  (with-temp-buffer
    (expose-commands-test-insert-conflict)
    (goto-char (point-max))
    (search-backward "after")
    (should-not (expose-conflict-bounds))))

(ert-deftest expose-commands-test-conflict-bounds-nil-with-no-conflict-at-all ()
  (with-temp-buffer
    (insert "just ordinary code\n")
    (should-not (expose-conflict-bounds))))

(ert-deftest expose-commands-test-conflict-at-point-extracts-both-sides ()
  (with-temp-buffer
    (expose-commands-test-insert-conflict)
    (goto-char (point-min))
    (search-forward "ours line")
    (let ((conflict (expose-conflict-at-point)))
      (should (equal "ours line\n" (plist-get conflict :ours)))
      (should (equal "theirs line\n" (plist-get conflict :theirs)))
      (should (equal "HEAD" (plist-get conflict :ours-label)))
      (should (equal "feature-branch" (plist-get conflict :theirs-label))))))

(ert-deftest expose-commands-test-conflict-at-point-nil-outside-conflict ()
  (with-temp-buffer
    (insert "no conflict here\n")
    (should-not (expose-conflict-at-point))))

(ert-deftest expose-commands-test-conflict-marker-label-nil-without-a-label ()
  (with-temp-buffer
    (insert "<<<<<<<\nours\n=======\ntheirs\n>>>>>>>\n")
    (goto-char (point-min))
    (should-not (expose-conflict-marker-label (point)))))

;;; ---------------------------------------------------------------------------
;;; expose-run-merge-conflict / expose-merge-conflict-async
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-run-merge-conflict-refuses-outside-a-conflict ()
  (with-temp-buffer
    (insert "plain code, no conflict\n")
    (should-error (expose-run-merge-conflict) :type 'user-error)))

(ert-deftest expose-commands-test-run-merge-conflict-proceeds-inside-a-conflict ()
  (let (ran)
    (cl-letf (((symbol-function 'expose-popup-run-action) (lambda (key) (setq ran key))))
      (with-temp-buffer
        (expose-commands-test-insert-conflict)
        (goto-char (point-min))
        (search-forward "ours line")
        (expose-run-merge-conflict))
      (should (eq ?k ran)))))

(ert-deftest expose-commands-test-merge-conflict-async-context-carries-both-sides ()
  (let (sent-type sent-title sent-context)
    (cl-letf (((symbol-function 'expose-context-project) (lambda () "demo"))
              ((symbol-function 'expose-context-language) (lambda () "Python"))
              ((symbol-function 'expose-context-relative-file) (lambda () "views.py"))
              ((symbol-function 'expose-send-view-action-async)
               (lambda (type title callback &optional context)
                 (setq sent-type type sent-title title sent-context context)
                 (funcall callback nil))))

      (with-temp-buffer
        (expose-commands-test-insert-conflict)
        (goto-char (point-min))
        (search-forward "ours line")
        (expose-merge-conflict-async #'ignore)))

    (should (eq 'merge-conflict sent-type))
    (should (equal "Merge Conflict" sent-title))
    (should (equal "ours line\n" (plist-get sent-context :ours)))
    (should (equal "theirs line\n" (plist-get sent-context :theirs)))
    (should (equal "HEAD" (plist-get sent-context :ours-label)))
    (should (equal "feature-branch" (plist-get sent-context :theirs-label)))))

(ert-deftest expose-commands-test-merge-conflict-async-refuses-outside-a-conflict ()
  (with-temp-buffer
    (insert "no conflict\n")
    (should-error (expose-merge-conflict-async #'ignore) :type 'user-error)))

;;; ---------------------------------------------------------------------------
;;; expose-traceback-*
;;; ---------------------------------------------------------------------------

(ert-deftest expose-commands-test-traceback-raw-frames-parses-python-frames ()
  (let* ((text
          (concat
           "Traceback (most recent call last):\n"
           "  File \"/proj/app/views.py\", line 42, in get_queryset\n"
           "    return self.queryset.filter(x=1)\n"
           "  File \"/proj/app/models.py\", line 10, in save\n"
           "    super().save()\n"
           "ValueError: boom\n"))
         (frames (expose-traceback-raw-frames text)))
    (should (= 2 (length frames)))
    (should (equal "/proj/app/views.py" (plist-get (nth 0 frames) :file)))
    (should (= 42 (plist-get (nth 0 frames) :line)))
    (should (equal "get_queryset" (plist-get (nth 0 frames) :function)))
    (should (equal "/proj/app/models.py" (plist-get (nth 1 frames) :file)))
    (should (= 10 (plist-get (nth 1 frames) :line)))))

(ert-deftest expose-commands-test-traceback-raw-frames-empty-for-non-traceback-text ()
  (should-not (expose-traceback-raw-frames "just some ordinary error text, no frames here")))

(ert-deftest expose-commands-test-traceback-cap-frames-keeps-both-ends ()
  (let* ((expose-traceback-max-frames 4)
         (frames (mapcar (lambda (n) (list :file (format "f%d.py" n) :line n))
                          (number-sequence 1 10)))
         (capped (expose-traceback-cap-frames frames)))
    (should (= 4 (length capped)))
    (should (equal '(1 2 9 10) (mapcar (lambda (f) (plist-get f :line)) capped)))))

(ert-deftest expose-commands-test-traceback-cap-frames-noop-under-the-limit ()
  (let* ((expose-traceback-max-frames 12)
         (frames (list (list :file "a.py" :line 1))))
    (should (equal frames (expose-traceback-cap-frames frames)))))

(ert-deftest expose-commands-test-traceback-frame-file-absolute-and-readable ()
  (let ((file (make-temp-file "expose-traceback-test")))
    (unwind-protect
        (should (equal file (expose-traceback-frame-file file nil)))
      (delete-file file))))

(ert-deftest expose-commands-test-traceback-frame-file-nil-when-unreadable ()
  (should-not (expose-traceback-frame-file "/no/such/file/anywhere.py" nil)))

(ert-deftest expose-commands-test-traceback-frame-file-relative-to-project-root ()
  (let* ((dir (make-temp-file "expose-traceback-test" t))
         (file (expand-file-name "app/views.py" dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-buffer (write-file file))
          (should (equal file (expose-traceback-frame-file "app/views.py" dir))))
      (delete-directory dir t))))

(ert-deftest expose-commands-test-traceback-read-context-centers-on-line ()
  (let ((file (make-temp-file "expose-traceback-test" nil ".py"
                              "one\ntwo\nthree\nfour\nfive\n")))
    (unwind-protect
        (let ((snippet (expose-traceback-read-context file 3 1)))
          (should (equal "two\nthree\nfour\n" snippet)))
      (delete-file file))))

(ert-deftest expose-commands-test-traceback-read-context-nil-for-unreadable-file ()
  (should-not (expose-traceback-read-context "/no/such/file.py" 1 4)))

(ert-deftest expose-commands-test-traceback-parse-frames-resolves-snippet-when-file-exists ()
  (let* ((dir (make-temp-file "expose-traceback-test" t))
         (file (expand-file-name "views.py" dir))
         (text (format "  File \"%s\", line 2, in f\n" file)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "one\ntwo\nthree\n")
            (write-file file))
          (let ((frames (expose-traceback-parse-frames text dir)))
            (should (= 1 (length frames)))
            (should (plist-get (car frames) :snippet))
            (should (string-match-p "two" (plist-get (car frames) :snippet)))))
      (delete-directory dir t))))

(ert-deftest expose-commands-test-traceback-parse-frames-omits-snippet-when-file-missing ()
  (let* ((text "  File \"/no/such/file.py\", line 2, in f\n")
         (frames (expose-traceback-parse-frames text nil)))
    (should (= 1 (length frames)))
    (should-not (plist-get (car frames) :snippet))
    (should (equal "/no/such/file.py" (plist-get (car frames) :file)))))

(provide 'expose-commands-test)

;;; expose-commands-test.el ends here
