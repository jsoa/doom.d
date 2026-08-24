;;; expose-find-tests-test.el --- Tests for expose-find-tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-find-tests)

;;; ---------------------------------------------------------------------------
;;; expose-callers-collect-tests itself is not exercised here -- it
;;; depends on LSP/xref backends this suite has no fixture for, and is
;;; not what changed here. These tests go straight at rendering,
;;; navigation, and visiting, with synthetic node data of the same
;;; shape expose-callers-tests-in already returns (see there):
;;; (:name :file :line).
;;; ---------------------------------------------------------------------------

(defmacro expose-find-tests-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-find-tests-buffer-name)
       (kill-buffer expose-find-tests-buffer-name))))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(ert-deftest expose-find-tests-test-insert-groups-by-file-in-order ()
  (with-temp-buffer
    (expose-find-tests-mode)
    (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
      (expose-find-tests-insert
       "widget_at_point"
       (list
        (list :name "test_a" :file "/proj/test_widgets.py" :line 10)
        (list :name "test_b" :file "/proj/test_widgets.py" :line 20)
        (list :name "test_c" :file "/proj/test_other.py" :line 5))
       nil))
    (should (string-match-p "Tests covering widget_at_point" (buffer-string)))
    (should (string-match-p "3 tests found" (buffer-string)))
    ;; Grouped: both test_widgets.py lines appear before test_other.py's.
    (should (< (string-match "test_a\\|10" (buffer-string))
               (string-match "test_other" (buffer-string))))
    (should (string-match-p "test_other" (buffer-string)))))

(ert-deftest expose-find-tests-test-insert-shows-failures ()
  (with-temp-buffer
    (expose-find-tests-mode)
    (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
      (expose-find-tests-insert "foo" nil '("some-lookup-failure")))
    (should (string-match-p "incomplete: 1 lookup failed" (buffer-string)))))

(ert-deftest expose-find-tests-test-insert-no-tests ()
  (with-temp-buffer
    (expose-find-tests-mode)
    (expose-find-tests-insert "foo" nil nil)
    (should (string-match-p "No tests found" (buffer-string)))
    (should (string-match-p "0 tests found" (buffer-string)))))

(ert-deftest expose-find-tests-test-insert-falls-back-to-name-without-source-text ()
  "A file that has moved on since the walk (or isn't readable) still
shows something meaningful, not a blank line."

  (with-temp-buffer
    (expose-find-tests-mode)
    (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
      (expose-find-tests-insert
       "foo" (list (list :name "test_gone" :file "/proj/gone.py" :line 3)) nil))
    (should (string-match-p "test_gone" (buffer-string)))))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun expose-find-tests-test-sample-buffer ()
  "Render two tests into the current buffer and return it."

  (expose-find-tests-mode)
  (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
    (expose-find-tests-insert
     "foo"
     (list
      (list :name "test_a" :file "/proj/test_a.py" :line 1)
      (list :name "test_b" :file "/proj/test_b.py" :line 2))
     nil))
  (current-buffer))

(ert-deftest expose-find-tests-test-next-and-previous-item ()
  (with-temp-buffer
    (expose-find-tests-test-sample-buffer)
    (goto-char (point-min))

    (expose-find-tests-next-item)
    (should (equal "test_a" (plist-get (expose-find-tests-current-item) :name)))

    (expose-find-tests-next-item)
    (should (equal "test_b" (plist-get (expose-find-tests-current-item) :name)))

    (should-not (expose-find-tests-next-item-position))

    (expose-find-tests-previous-item)
    (should (equal "test_a" (plist-get (expose-find-tests-current-item) :name)))))

(ert-deftest expose-find-tests-test-current-item-nil-outside-any-item ()
  (with-temp-buffer
    (expose-find-tests-test-sample-buffer)
    (goto-char (point-min))
    (should-not (expose-find-tests-current-item))))

;;; ---------------------------------------------------------------------------
;;; Visiting: real window/file operations. Real temp files, not mocked
;;; -- the whole point is *which* window a real find-file lands in.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-find-tests-test-visit-opens-to-the-left-keeping-list ()
  (expose-find-tests-test-with-clean-frame
    (let* ((file (make-temp-file "expose-find-tests-test" nil ".py" "line one\nline two\nline three\n"))
           (source-window (progn (delete-other-windows)
                                  (switch-to-buffer (get-buffer-create "efvt-src.py"))
                                  (selected-window))))
      (unwind-protect
          (progn
            ;; Real placement, real rendering of a real item pointing at
            ;; a real temp file -- not hand-patched text properties --
            ;; so this exercises the same path expose-find-tests-open
            ;; does, just without the expose-callers search itself.
            (select-window
             (expose-side-panel-place source-window (get-buffer-create expose-find-tests-buffer-name)))

            (unless (derived-mode-p 'expose-find-tests-mode)
              (expose-find-tests-mode))

            (cl-letf (((symbol-function 'expose-callers-line-text) (lambda (&rest _) nil)))
              (expose-find-tests-insert
               "foo" (list (list :name "test_x" :file file :line 2)) nil))

            (goto-char (point-min))
            (expose-find-tests-next-item)
            (expose-find-tests-visit)

            (should (equal (file-truename file) (file-truename (buffer-file-name))))
            (should (= 2 (line-number-at-pos)))
            (should (equal expose-find-tests-buffer-name
                           (buffer-name (window-buffer (window-in-direction 'right (selected-window)))))))
        (delete-file file)))))

(ert-deftest expose-find-tests-test-visit-refuses-missing-file ()
  (with-temp-buffer
    (expose-find-tests-mode)
    (let ((inhibit-read-only t))
      (insert "line\n")
      (add-text-properties
       (point-min) (point-max)
       (list 'expose-find-tests-item (list :name "gone" :file "/no/such/file.py" :line 1))))
    (goto-char (point-min))
    (should-error (expose-find-tests-visit) :type 'user-error)))

(ert-deftest expose-find-tests-test-visit-refuses-with-no-item-on-line ()
  (with-temp-buffer
    (expose-find-tests-mode)
    (let ((inhibit-read-only t))
      (insert "not an item\n"))
    (goto-char (point-min))
    (should-error (expose-find-tests-visit) :type 'user-error)))

(provide 'expose-find-tests-test)

;;; expose-find-tests-test.el ends here
