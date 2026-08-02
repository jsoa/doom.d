;;; dashboard-test.el --- Tests for the project dashboard -*- lexical-binding: t; -*-

(require 'ert)
(require 'dashboard)

;;; ---------------------------------------------------------------------------
;;; Fixture
;;;
;;; Git-backed functions shell out to a real `git' in a disposable temp
;;; repo rather than mocking that layer away, matching the convention
;;; already used by the Expose test suite.
;;; ---------------------------------------------------------------------------

(defmacro jsoa-test-with-project (&rest body)
  "Run BODY with PROJECT-ROOT bound to a fresh temp git repo."
  (declare (indent 0))
  `(let* ((project-root
           (file-name-as-directory
            (make-temp-file "jsoa-dashboard-test-" t))))

     (unwind-protect
         (let ((default-directory project-root))
           (call-process "git" nil nil nil "init" "-q")
           (call-process "git" nil nil nil "config" "user.email" "test@example.com")
           (call-process "git" nil nil nil "config" "user.name" "Dashboard Test")
           ,@body)

       (delete-directory project-root t))))

(defun jsoa-test-write-file (root name content)
  "Write CONTENT to NAME under ROOT, creating parent directories as needed."
  (let ((path (expand-file-name name root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content))
    path))

(defun jsoa-test-commit-all (root message)
  (let ((default-directory root))
    (call-process "git" nil nil nil "add" "-A")
    (call-process "git" nil nil nil "commit" "-q" "-m" message)))

;;; ---------------------------------------------------------------------------
;;; Pure formatting helpers
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-format-number-adds-thousands-separators ()
  (should (equal "1,234" (jsoa/format-number 1234)))
  (should (equal "1,234,567" (jsoa/format-number 1234567)))
  (should (equal "42" (jsoa/format-number 42))))

(ert-deftest jsoa-test-format-loc-uses-k-and-m-suffixes ()
  (should (equal "42" (jsoa/format-loc 42)))
  (should (equal "1.5k" (jsoa/format-loc 1500)))
  (should (equal "2.0M" (jsoa/format-loc 2000000))))

(ert-deftest jsoa-test-short-path-keeps-last-two-segments ()
  (should
   (equal "b/c.py"
          (jsoa/short-path "/root/a/b/c.py" "/root")))
  (should
   (equal "c.py"
          (jsoa/short-path "/root/c.py" "/root"))))

(ert-deftest jsoa-test-safe-str-nil-becomes-empty-string ()
  (should (equal "" (jsoa/safe-str nil)))
  (should (equal "x" (jsoa/safe-str "x"))))

;;; ---------------------------------------------------------------------------
;;; jsoa/git-status-face
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-git-status-face-dirty-repo-is-error ()
  (should (eq 'error (jsoa/git-status-face 0 0 3))))

(ert-deftest jsoa-test-git-status-face-diverged-is-warning ()
  (should (eq 'warning (jsoa/git-status-face 2 0 0)))
  (should (eq 'warning (jsoa/git-status-face 0 2 0))))

(ert-deftest jsoa-test-git-status-face-clean-is-success ()
  (should (eq 'success (jsoa/git-status-face 0 0 0))))

(ert-deftest jsoa-test-git-status-face-dirty-takes-priority-over-diverged ()
  ;; Dirty (uncommitted changes) should win even if also diverged --
  ;; the dirty check comes first in the `cond'.
  (should (eq 'error (jsoa/git-status-face 1 1 1))))

;;; ---------------------------------------------------------------------------
;;; jsoa/parse-loc-output / jsoa/prepare-loc-breakdown
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-parse-loc-output-counts-lines-by-extension ()
  (let ((result
         (jsoa/parse-loc-output
          "src/a.py:1:x\nsrc/b.py:2:y\nsrc/c.js:1:z\n")))

    (should (equal 2 (cdr (assoc "PY" result))))
    (should (equal 1 (cdr (assoc "JS" result))))))

(ert-deftest jsoa-test-parse-loc-output-ignores-junk-extensions ()
  (let ((result
         (jsoa/parse-loc-output
          "package-lock.lock:1:x\nfoo.map:1:y\nreal.py:1:z\n")))

    (should (null (assoc "LOCK" result)))
    (should (null (assoc "MAP" result)))
    (should (equal 1 (cdr (assoc "PY" result))))))

(ert-deftest jsoa-test-parse-loc-output-files-without-extension-are-noext ()
  (let ((result
         (jsoa/parse-loc-output "Makefile:1:x\n")))

    (should (equal 1 (cdr (assoc "NOEXT" result))))))

(ert-deftest jsoa-test-prepare-loc-breakdown-collapses-rest-into-other ()
  (let* ((data
          '(("PY" . 100) ("JS" . 80) ("TS" . 60) ("CSS" . 40)
            ("HTML" . 10) ("MD" . 5)))
         (prepared
          (jsoa/prepare-loc-breakdown data)))

    ;; Top 4 kept individually, remaining two collapsed into OTHER.
    (should (= 5 (length prepared)))
    (should (equal 15 (cdr (assoc "OTHER" prepared))))
    (should (equal 100 (cdr (assoc "PY" prepared))))))

(ert-deftest jsoa-test-prepare-loc-breakdown-no-other-when-four-or-fewer ()
  (let* ((data '(("PY" . 10) ("JS" . 5)))
         (prepared (jsoa/prepare-loc-breakdown data)))

    (should (= 2 (length prepared)))
    (should (null (assoc "OTHER" prepared)))))

;;; ---------------------------------------------------------------------------
;;; jsoa/ext-label / jsoa/ext-to-glob
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-ext-label-known-extension-is-friendly-name ()
  (should (equal "Python" (jsoa/ext-label "PY"))))

(ert-deftest jsoa-test-ext-label-unknown-extension-passes-through ()
  (should (equal "RS" (jsoa/ext-label "RS"))))

(ert-deftest jsoa-test-ext-to-glob-formats-ripgrep-glob ()
  (should (equal "-g \"*.py\"" (jsoa/ext-to-glob "PY"))))

(ert-deftest jsoa-test-ext-to-glob-noext-is-empty ()
  (should (equal "" (jsoa/ext-to-glob "noext"))))

;;; ---------------------------------------------------------------------------
;;; Diagnostics parsing
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-count-diagnostics-counts-errors-and-warnings ()
  (let ((counts
         (jsoa/count-diagnostics
          (list (list :severity "error")
                (list :severity "error")
                (list :severity "warning")
                (list :severity "information")))))

    (should (equal 2 (car counts)))
    (should (equal 1 (cdr counts)))))

(ert-deftest jsoa-test-parse-pyright-output-invalid-json-is-error ()
  (should (eq :error (jsoa/parse-pyright-output "not json"))))

(ert-deftest jsoa-test-parse-pyright-output-parses-diagnostics ()
  (let* ((json
          (json-serialize
           (list :generalDiagnostics
                 (vector
                  (list :file "foo.py"
                        :range (list :start (list :line 4))
                        :message "bad thing"
                        :severity "error")))))
         (result (jsoa/parse-pyright-output json)))

    (should (listp result))
    (should (= 1 (length result)))
    (let ((d (car result)))
      (should (equal "foo.py" (plist-get d :file)))
      (should (equal 5 (plist-get d :line))) ;; 1-indexed from 0-indexed range
      (should (equal "bad thing" (plist-get d :message)))
      (should (equal "error" (plist-get d :severity))))))

(ert-deftest jsoa-test-parse-tsc-output-extracts-file-and-line ()
  (let* ((output "src/app.ts(12,5): error TS2322: Type mismatch.")
         (result (jsoa/parse-tsc-output output)))

    (should (= 1 (length result)))
    (let ((d (car result)))
      (should (equal "src/app.ts" (plist-get d :file)))
      (should (equal 12 (plist-get d :line)))
      (should (equal "error" (plist-get d :severity))))))

(ert-deftest jsoa-test-parse-tsc-output-ignores-unrelated-lines ()
  (should
   (null
    (jsoa/parse-tsc-output "Found 0 errors.\n"))))

;;; ---------------------------------------------------------------------------
;;; jsoa/project-type / jsoa/find-readme
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-project-type-detects-node-from-package-json ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "package.json" "{}")
    (should (eq 'node (jsoa/project-type project-root)))))

(ert-deftest jsoa-test-project-type-detects-python-from-pyproject ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "pyproject.toml" "")
    (should (eq 'python (jsoa/project-type project-root)))))

(ert-deftest jsoa-test-project-type-angular-takes-priority-over-node ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "package.json" "{}")
    (jsoa-test-write-file project-root "angular.json" "{}")
    (should (eq 'angular (jsoa/project-type project-root)))))

(ert-deftest jsoa-test-project-type-defaults-to-generic ()
  (jsoa-test-with-project
    (should (eq 'generic (jsoa/project-type project-root)))))

(ert-deftest jsoa-test-find-readme-returns-first-match ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "README.md" "# hi")
    (should (equal "README.md" (jsoa/find-readme project-root)))))

(ert-deftest jsoa-test-find-readme-nil-when-absent ()
  (jsoa-test-with-project
    (should (null (jsoa/find-readme project-root)))))

;;; ---------------------------------------------------------------------------
;;; Git-backed data providers
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-git-status-lines-reflects-working-tree ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "a.txt" "1\n")
    (jsoa-test-commit-all project-root "init")
    (jsoa-test-write-file project-root "a.txt" "2\n")
    (jsoa-test-write-file project-root "b.txt" "new\n")

    (let ((lines (jsoa/git-status-lines project-root)))
      (should (= 2 (length lines))))))

(ert-deftest jsoa-test-git-status-lines-empty-when-clean ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "a.txt" "1\n")
    (jsoa-test-commit-all project-root "init")

    (should (null (jsoa/git-status-lines project-root)))))

(ert-deftest jsoa-test-git-recent-files-data-lists-committed-files ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "a.txt" "1\n")
    (jsoa-test-commit-all project-root "add a")

    (let ((items (jsoa/git-recent-files-data project-root)))
      (should (= 1 (length items)))
      (should (equal "a.txt" (plist-get (car items) :file)))
      (should (equal "add a" (plist-get (car items) :msg))))))

;;; ---------------------------------------------------------------------------
;;; jsoa/project-info-section: `du' must not block
;;;
;;; Regression test for the fix that moved `du -sh .' off the main thread
;;; (previously a fully synchronous `shell-command-to-string' that could
;;; freeze Emacs for as long as the recursive tree walk took on a large
;;; project or slow filesystem).
;;; ---------------------------------------------------------------------------

(ert-deftest jsoa-test-project-info-section-does-not-block-on-du ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "a.txt" "1\n")
    (jsoa-test-commit-all project-root "init")

    (with-temp-buffer
      (setq-local jsoa/dashboard-render-token (gensym "dash-"))

      (let* ((default-directory project-root)
             (status-lines (jsoa/git-status-lines project-root))
             (ahead-behind (jsoa/git-ahead-behind project-root))
             (start-time (float-time)))

        (jsoa/project-info-section project-root status-lines ahead-behind)

        (should (< (- (float-time) start-time) 1.0))
        (should (string-match-p "Size: *Scanning\\.\\.\\." (buffer-string)))))))

(ert-deftest jsoa-test-project-info-section-fills-in-real-size-async ()
  (jsoa-test-with-project
    (jsoa-test-write-file project-root "a.txt" "1\n")
    (jsoa-test-commit-all project-root "init")

    (with-temp-buffer
      (setq-local jsoa/dashboard-render-token (gensym "dash-"))

      (let* ((default-directory project-root)
             (status-lines (jsoa/git-status-lines project-root))
             (ahead-behind (jsoa/git-ahead-behind project-root)))

        (jsoa/project-info-section project-root status-lines ahead-behind)

        (let ((deadline (+ (float-time) 5)))
          (while (and (< (float-time) deadline)
                      (string-match-p "Scanning\\.\\.\\." (buffer-string)))
            (accept-process-output nil 0.05)))

        (should-not (string-match-p "Scanning\\.\\.\\." (buffer-string)))
        (should (string-match-p "Size: *[0-9.]+[KMGB]?" (buffer-string)))
        ;; Content rendered *after* the async Size placeholder (Branch)
        ;; must survive the marker-based region replace untouched.
        (should (string-match-p "Branch:" (buffer-string)))))))

(provide 'dashboard-test)

;;; dashboard-test.el ends here
