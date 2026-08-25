;;; expose-middleware-test.el --- Tests for expose-middleware -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-middleware)

;;; ---------------------------------------------------------------------------
;;; expose-middleware-parse-list
;;; ---------------------------------------------------------------------------

(ert-deftest expose-middleware-test-parse-list-reads-entries-in-order ()
  (let ((file (make-temp-file "expose-middleware-test" nil ".py"
                              (concat "MIDDLEWARE = [\n"
                                      "    'a.b.First',\n"
                                      "    'a.b.Second',\n"
                                      "    'a.b.Third',\n"
                                      "]\n"))))
    (unwind-protect
        (should (equal '("a.b.First" "a.b.Second" "a.b.Third")
                        (expose-middleware-parse-list file)))
      (delete-file file))))

(ert-deftest expose-middleware-test-parse-list-single-line ()
  (let ((file (make-temp-file "expose-middleware-test" nil ".py"
                              "MIDDLEWARE = ['a.One', 'a.Two']\n")))
    (unwind-protect
        (should (equal '("a.One" "a.Two") (expose-middleware-parse-list file)))
      (delete-file file))))

(ert-deftest expose-middleware-test-parse-list-mixed-quotes ()
  (let ((file (make-temp-file "expose-middleware-test" nil ".py"
                              "MIDDLEWARE = [\n    \"a.One\",\n    'a.Two',\n]\n")))
    (unwind-protect
        (should (equal '("a.One" "a.Two") (expose-middleware-parse-list file)))
      (delete-file file))))

(ert-deftest expose-middleware-test-parse-list-nil-without-middleware ()
  (let ((file (make-temp-file "expose-middleware-test" nil ".py" "DEBUG = True\n")))
    (unwind-protect
        (should-not (expose-middleware-parse-list file))
      (delete-file file))))

(ert-deftest expose-middleware-test-parse-list-does-not-read-past-the-list ()
  "A second, unrelated list later in the file must not bleed into the
entries found for MIDDLEWARE."

  (let ((file (make-temp-file "expose-middleware-test" nil ".py"
                              (concat "MIDDLEWARE = [\n    'a.One',\n]\n\n"
                                      "INSTALLED_APPS = [\n    'a.NotMiddleware',\n]\n"))))
    (unwind-protect
        (should (equal '("a.One") (expose-middleware-parse-list file)))
      (delete-file file))))

(ert-deftest expose-middleware-test-parse-list-nil-for-unreadable-file ()
  (should-not (expose-middleware-parse-list "/no/such/file.py")))

;;; ---------------------------------------------------------------------------
;;; expose-middleware-local-location / -class-docstring / -describe
;;; ---------------------------------------------------------------------------

(ert-deftest expose-middleware-test-describe-third-party-is-not-local ()
  (let ((dir (make-temp-file "expose-middleware-test" t)))
    (unwind-protect
        (let ((entry (expose-middleware-describe "django.middleware.common.CommonMiddleware" dir)))
          (should (equal "CommonMiddleware" (plist-get entry :name)))
          (should-not (plist-get entry :local))
          (should-not (plist-get entry :doc)))
      (delete-directory dir t))))

(ert-deftest expose-middleware-test-describe-project-local-with-docstring ()
  (let ((dir (make-temp-file "expose-middleware-test" t)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class RequestLoggingMiddleware:\n"
                    "    \"\"\"Log every request.\"\"\"\n"
                    "\n"
                    "    def __init__(self, get_response):\n"
                    "        pass\n")
            (write-file (expand-file-name "middleware.py" dir)))

          (let ((entry (expose-middleware-describe "app.middleware.RequestLoggingMiddleware" dir)))
            (should (plist-get entry :local))
            (should (equal "Log every request." (plist-get entry :doc)))))
      (delete-directory dir t))))

(ert-deftest expose-middleware-test-describe-project-local-without-docstring ()
  (let ((dir (make-temp-file "expose-middleware-test" t)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class CurrentUserMiddleware:\n    def __init__(self, get_response):\n        pass\n")
            (write-file (expand-file-name "middleware.py" dir)))

          (let ((entry (expose-middleware-describe "app.middleware.CurrentUserMiddleware" dir)))
            (should (plist-get entry :local))
            (should-not (plist-get entry :doc))))
      (delete-directory dir t))))

;;; ---------------------------------------------------------------------------
;;; expose-middleware-to-dot: the onion shape
;;; ---------------------------------------------------------------------------

(ert-deftest expose-middleware-test-to-dot-onion-edges-both-directions ()
  (let* ((dir (make-temp-file "expose-middleware-test" t))
         (dot (unwind-protect
                  (expose-middleware-to-dot '("a.One" "a.Two" "a.Three") dir)
                (delete-directory dir t))))

    ;; Request direction: forward through the list, then into the view.
    (should (string-match-p "mw0 -> mw1 \\[label=\"request\"" dot))
    (should (string-match-p "mw1 -> mw2 \\[label=\"request\"" dot))
    (should (string-match-p "mw2 -> view \\[label=\"request\"" dot))

    ;; Response direction: back out through the same list, reversed.
    (should (string-match-p "view -> mw2 \\[label=\"response\"" dot))
    (should (string-match-p "mw2 -> mw1 \\[label=\"response\"" dot))
    (should (string-match-p "mw1 -> mw0 \\[label=\"response\"" dot))))

(ert-deftest expose-middleware-test-to-dot-empty-list-still-valid ()
  (let ((dot (expose-middleware-to-dot nil "/tmp")))
    (should (string-match-p "digraph middleware" dot))
    (should (string-match-p "view \\[shape=ellipse" dot))
    (should-not (string-match-p "request" dot))))

;;; ---------------------------------------------------------------------------
;;; expose-middleware-build-dot: entry point errors
;;; ---------------------------------------------------------------------------

(ert-deftest expose-middleware-test-build-dot-refuses-without-a-project ()
  (cl-letf (((symbol-function 'expose-django-project-root) (lambda () nil)))
    (should-error (expose-middleware-build-dot) :type 'user-error)))

(ert-deftest expose-middleware-test-build-dot-refuses-without-settings ()
  (cl-letf (((symbol-function 'expose-django-project-root) (lambda () "/tmp"))
            ((symbol-function 'expose-django-find-settings-file) (lambda (_root) nil)))
    (should-error (expose-middleware-build-dot) :type 'user-error)))

(provide 'expose-middleware-test)

;;; expose-middleware-test.el ends here
