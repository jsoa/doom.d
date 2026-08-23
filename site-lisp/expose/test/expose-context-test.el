;;; expose-context-test.el --- Tests for expose-context -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-context)

;;; ---------------------------------------------------------------------------
;;; Regression: `git diff HEAD' mixed staged and unstaged changes into every
;;; request that folds in git context, including commit-message -- so a file
;;; edited but never `git add'ed showed up as part of the change a commit
;;; message was written to describe. `expose-context-git-staged-only' scopes
;;; both status and diff to what is actually staged, and only when bound.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-context-test-diff-defaults-to-head ()
  (let (seen-args)
    (cl-letf (((symbol-function 'expose-context-git-root) (lambda () "/p/"))
              ((symbol-function 'expose-context-call-git)
               (lambda (_root &rest args) (setq seen-args args) "")))

      (expose-context-git-diff)

      (should (member "HEAD" seen-args))
      (should-not (member "--cached" seen-args)))))

(ert-deftest expose-context-test-diff-uses-cached-when-staged-only ()
  (let (seen-args
        (expose-context-git-staged-only t))
    (cl-letf (((symbol-function 'expose-context-git-root) (lambda () "/p/"))
              ((symbol-function 'expose-context-call-git)
               (lambda (_root &rest args) (setq seen-args args) "")))

      (expose-context-git-diff)

      (should (member "--cached" seen-args))
      (should-not (member "HEAD" seen-args)))))

(ert-deftest expose-context-test-status-line-unstaged-p ()
  ;; Column 1 is the index (staged) status; a space or `?' there means
  ;; nothing about the file is staged yet.
  (should (expose-context-git-status-line-unstaged-p " M unstaged.py"))
  (should (expose-context-git-status-line-unstaged-p "?? untracked.py"))
  (should-not (expose-context-git-status-line-unstaged-p "M  staged.py"))
  (should-not (expose-context-git-status-line-unstaged-p "A  new-file.py"))
  ;; Staged AND further edited on top: still counts as staged, since some
  ;; part of it will be in the commit.
  (should-not (expose-context-git-status-line-unstaged-p "MM both.py")))

(ert-deftest expose-context-test-filter-git-status-default-keeps-everything ()
  (cl-letf (((symbol-function 'expose-context-git-status-line-excluded-p)
             (lambda (&rest _) nil)))

    (should
     (equal
      "M  staged.py\n M unstaged.py"
      (expose-context-filter-git-status
       "M  staged.py\n M unstaged.py" "/p/")))))

(ert-deftest expose-context-test-filter-git-status-staged-only-drops-unstaged ()
  (let ((expose-context-git-staged-only t))
    (cl-letf (((symbol-function 'expose-context-git-status-line-excluded-p)
               (lambda (&rest _) nil)))

      (should
       (equal
        "M  staged.py"
        (expose-context-filter-git-status
         "M  staged.py\n M unstaged.py\n?? untracked.py" "/p/"))))))

(ert-deftest expose-context-test-staged-only-does-not-override-exclusion ()
  "A staged file that is also redaction-excluded must still be dropped."

  (let ((expose-context-git-staged-only t))
    (cl-letf (((symbol-function 'expose-context-git-status-line-excluded-p)
               (lambda (line _root) (string-match-p "secrets" line))))

      (should
       (equal
        "M  staged.py"
        (expose-context-filter-git-status
         "M  staged.py\nM  secrets.env" "/p/"))))))

(ert-deftest expose-context-test-staged-only-does-not-leak ()
  "The dynamic scope must not survive past its own `let'."

  (should-not expose-context-git-staged-only)

  (let ((expose-context-git-staged-only t))
    (should expose-context-git-staged-only))

  (should-not expose-context-git-staged-only))
