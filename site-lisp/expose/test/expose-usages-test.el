;;; expose-usages-test.el --- Tests for expose-usages -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-usages)
;; For `expose-callers-node-key' only, used to build synthetic
;; `expose-usages-collect'-shaped data with keys that match what
;; `expose-usages-callers' computes for real -- the collection function
;; itself is not exercised here (see the note below).
(require 'expose-callers)

;;; ---------------------------------------------------------------------------
;;; expose-usages-collect itself is not exercised here -- same reason
;;; expose-find-tests-test.el gives for expose-callers-collect-tests: it
;;; depends on LSP/xref backends this suite has no fixture for. These
;;; tests go straight at the pure pieces built on top of it, with
;;; synthetic node data of the shape expose-callers-collect already
;;; returns: (:name :file :line).
;;; ---------------------------------------------------------------------------

(defmacro expose-usages-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-usages-buffer-name)
       (kill-buffer expose-usages-buffer-name))))

;;; ---------------------------------------------------------------------------
;;; expose-usages-callers: sorting, root excluded
;;; ---------------------------------------------------------------------------

(defun expose-usages-test-found (root callers)
  "Build a synthetic `expose-usages-collect'-shaped plist."

  (let ((nodes (make-hash-table :test 'equal)))
    (puthash (expose-callers-node-key root) root nodes)
    (dolist (caller callers)
      (puthash (expose-callers-node-key caller) caller nodes))
    (list :root root :nodes nodes :edges nil :failures nil :use-lsp t)))

(ert-deftest expose-usages-test-callers-excludes-root ()
  (let* ((root (list :name "foo" :file "/proj/a.py" :line 1))
         (caller (list :name "bar" :file "/proj/b.py" :line 2))
         (found (expose-usages-test-found root (list caller))))

    (should
     (equal (list caller) (expose-usages-callers found)))))

(ert-deftest expose-usages-test-callers-sorted-by-file-then-line ()
  (let* ((root (list :name "foo" :file "/proj/a.py" :line 1))
         (c1 (list :name "later" :file "/proj/b.py" :line 20))
         (c2 (list :name "earlier" :file "/proj/b.py" :line 5))
         (c3 (list :name "alpha-file" :file "/proj/a.py" :line 99))
         (found (expose-usages-test-found root (list c1 c2 c3))))

    (should
     (equal '("alpha-file" "earlier" "later")
            (mapcar (lambda (n) (plist-get n :name)) (expose-usages-callers found))))))

(ert-deftest expose-usages-test-callers-empty-when-only-root ()
  (let* ((root (list :name "foo" :file "/proj/a.py" :line 1))
         (found (expose-usages-test-found root nil)))

    (should-not (expose-usages-callers found))))

;;; ---------------------------------------------------------------------------
;;; expose-usages-area
;;; ---------------------------------------------------------------------------

(ert-deftest expose-usages-test-area-returns-top-level-directory ()
  (cl-letf* ((root "/proj/")
             ((symbol-function 'project-current)
              (lambda (&rest _) (cons 'vc root)))
             ((symbol-function 'project-root)
              (lambda (_) root)))

    (should (equal "app" (expose-usages-area "/proj/app/views.py")))
    (should (equal "app" (expose-usages-area "/proj/app/models/user.py")))))

(ert-deftest expose-usages-test-area-nil-at-project-root ()
  (cl-letf* ((root "/proj/")
             ((symbol-function 'project-current)
              (lambda (&rest _) (cons 'vc root)))
             ((symbol-function 'project-root)
              (lambda (_) root)))

    (should-not (expose-usages-area "/proj/settings.py"))))

(ert-deftest expose-usages-test-area-nil-without-a-project ()
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (should-not (expose-usages-area "/tmp/loose-file.py"))))

(ert-deftest expose-usages-test-area-nil-for-nil-file ()
  (should-not (expose-usages-area nil)))

;;; ---------------------------------------------------------------------------
;;; Rendering: dead-code framing
;;; ---------------------------------------------------------------------------

(ert-deftest expose-usages-test-insert-dead-code-no-callers ()
  (with-temp-buffer
    (expose-usages-mode)
    (let ((root (list :name "orphan_fn" :file "/proj/a.py" :line 1)))
      (expose-usages-insert 'dead-code (expose-usages-test-found root nil)))
    (should (string-match-p "Dead code check: orphan_fn" (buffer-string)))
    (should (string-match-p "Nothing calls or references orphan_fn" (buffer-string)))
    (should (string-match-p "only sees this project" (buffer-string)))))

(ert-deftest expose-usages-test-insert-dead-code-with-callers ()
  (with-temp-buffer
    (expose-usages-mode)
    (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
      (let* ((root (list :name "used_fn" :file "/proj/a.py" :line 1))
             (caller (list :name "caller" :file "/proj/b.py" :line 5)))
        (expose-usages-insert 'dead-code (expose-usages-test-found root (list caller)))))
    (should (string-match-p "1 caller/reference found -- likely not dead code" (buffer-string)))
    (should (string-match-p "caller" (buffer-string)))))

(ert-deftest expose-usages-test-insert-dead-code-shows-failures ()
  (with-temp-buffer
    (expose-usages-mode)
    (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
      (let* ((root (list :name "foo" :file "/proj/a.py" :line 1))
             (caller (list :name "bar" :file "/proj/b.py" :line 5))
             (found (expose-usages-test-found root (list caller))))
        (setq found (plist-put found :failures '("lookup failed")))
        (expose-usages-insert 'dead-code found)))
    (should (string-match-p "incomplete: 1 lookup failed" (buffer-string)))))

;;; ---------------------------------------------------------------------------
;;; Rendering: rename-impact framing, OUTSIDE marker
;;; ---------------------------------------------------------------------------

(ert-deftest expose-usages-test-insert-rename-no-callers ()
  (with-temp-buffer
    (expose-usages-mode)
    (let ((root (list :name "safe_fn" :file "/proj/a.py" :line 1)))
      (expose-usages-insert 'rename (expose-usages-test-found root nil)))
    (should (string-match-p "Rename impact: safe_fn" (buffer-string)))
    (should (string-match-p "renaming should be safe here" (buffer-string)))))

(ert-deftest expose-usages-test-insert-rename-marks-outside-callers ()
  "A caller in a different top-level directory than the root's own is
marked OUTSIDE; one in the same directory is not."

  (with-temp-buffer
    (expose-usages-mode)
    (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil))
              ((symbol-function 'project-current)
               (lambda (&rest _) (cons 'vc "/proj/")))
              ((symbol-function 'project-root)
               (lambda (_) "/proj/")))
      (let* ((root (list :name "shared_fn" :file "/proj/app_a/models.py" :line 1))
             (same-area (list :name "sibling" :file "/proj/app_a/views.py" :line 3))
             (other-area (list :name "far_caller" :file "/proj/app_b/views.py" :line 9))
             (found (expose-usages-test-found root (list same-area other-area))))
        (expose-usages-insert 'rename found)))

    ;; The far_caller line carries the OUTSIDE marker; the sibling line
    ;; does not.
    (goto-char (point-min))
    (search-forward "far_caller")
    (should (string-match-p "OUTSIDE" (buffer-substring (line-beginning-position) (line-end-position))))

    (goto-char (point-min))
    (search-forward "sibling")
    (should-not (string-match-p "OUTSIDE" (buffer-substring (line-beginning-position) (line-end-position))))))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun expose-usages-test-sample-buffer ()
  "Render two callers into the current buffer and return it."

  (expose-usages-mode)
  (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
    (let* ((root (list :name "foo" :file "/proj/a.py" :line 1))
           (c1 (list :name "caller_a" :file "/proj/x.py" :line 1))
           (c2 (list :name "caller_b" :file "/proj/y.py" :line 2)))
      (expose-usages-insert 'dead-code (expose-usages-test-found root (list c1 c2)))))
  (current-buffer))

(ert-deftest expose-usages-test-next-and-previous-item ()
  (with-temp-buffer
    (expose-usages-test-sample-buffer)
    (goto-char (point-min))

    (expose-usages-next-item)
    (should (equal "caller_a" (plist-get (expose-usages-current-item) :name)))

    (expose-usages-next-item)
    (should (equal "caller_b" (plist-get (expose-usages-current-item) :name)))

    (should-not (expose-usages-next-item-position))

    (expose-usages-previous-item)
    (should (equal "caller_a" (plist-get (expose-usages-current-item) :name)))))

(ert-deftest expose-usages-test-current-item-nil-outside-any-item ()
  (with-temp-buffer
    (expose-usages-test-sample-buffer)
    (goto-char (point-min))
    (should-not (expose-usages-current-item))))

;;; ---------------------------------------------------------------------------
;;; Visiting: real window/file operations, same style as
;;; expose-find-tests-test.el's -- real temp file, real find-file, the
;;; part worth testing is which window it lands in.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-usages-test-visit-opens-to-the-left-keeping-list ()
  (expose-usages-test-with-clean-frame
    (let* ((file (make-temp-file "expose-usages-test" nil ".py" "line one\nline two\nline three\n"))
           (source-window (progn (delete-other-windows)
                                  (switch-to-buffer (get-buffer-create "eut-src.py"))
                                  (selected-window))))
      (unwind-protect
          (progn
            (select-window
             (expose-side-panel-place source-window (get-buffer-create expose-usages-buffer-name)))

            (unless (derived-mode-p 'expose-usages-mode)
              (expose-usages-mode))

            (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
              (let ((root (list :name "foo" :file "/proj/a.py" :line 1))
                    (caller (list :name "test_x" :file file :line 2)))
                (expose-usages-insert 'dead-code (expose-usages-test-found root (list caller)))))

            (goto-char (point-min))
            (expose-usages-next-item)
            (expose-usages-visit)

            (should (equal (file-truename file) (file-truename (buffer-file-name))))
            (should (= 2 (line-number-at-pos)))
            (should (equal expose-usages-buffer-name
                           (buffer-name (window-buffer (window-in-direction 'right (selected-window)))))))
        (delete-file file)))))

(ert-deftest expose-usages-test-visit-refuses-missing-file ()
  (with-temp-buffer
    (expose-usages-mode)
    (let ((inhibit-read-only t))
      (insert "line\n")
      (add-text-properties
       (point-min) (point-max)
       (list 'expose-usages-item (list :name "gone" :file "/no/such/file.py" :line 1))))
    (goto-char (point-min))
    (should-error (expose-usages-visit) :type 'user-error)))

(ert-deftest expose-usages-test-visit-refuses-with-no-item-on-line ()
  (with-temp-buffer
    (expose-usages-mode)
    (let ((inhibit-read-only t))
      (insert "not an item\n"))
    (goto-char (point-min))
    (should-error (expose-usages-visit) :type 'user-error)))

(provide 'expose-usages-test)

;;; expose-usages-test.el ends here
