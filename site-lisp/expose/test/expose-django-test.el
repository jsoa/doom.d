;;; expose-django-test.el --- Tests for expose-django -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-django)

;;; ---------------------------------------------------------------------------
;;; expose-django-find-settings-file
;;; ---------------------------------------------------------------------------

(ert-deftest expose-django-test-find-settings-file-locates-by-content ()
  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "MIDDLEWARE = [\n    'a.b.C',\n]\n")
            (write-file (expand-file-name "settings.py" dir)))
          (should (equal (expand-file-name "settings.py" dir)
                          (expose-django-find-settings-file dir))))
      (delete-directory dir t))))

(ert-deftest expose-django-test-find-settings-file-nil-when-absent ()
  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "DEBUG = True\n")
            (write-file (expand-file-name "settings.py" dir)))
          (should-not (expose-django-find-settings-file dir)))
      (delete-directory dir t))))

;;; ---------------------------------------------------------------------------
;;; expose-django-root-urlconf
;;; ---------------------------------------------------------------------------

(ert-deftest expose-django-test-root-urlconf-parses-the-value ()
  (let ((file (make-temp-file "expose-django-test" nil ".py"
                              "ROOT_URLCONF = \"proj.urls\"\n")))
    (unwind-protect
        (should (equal "proj.urls" (expose-django-root-urlconf file)))
      (delete-file file))))

(ert-deftest expose-django-test-root-urlconf-single-quotes ()
  (let ((file (make-temp-file "expose-django-test" nil ".py"
                              "ROOT_URLCONF = 'proj.urls'\n")))
    (unwind-protect
        (should (equal "proj.urls" (expose-django-root-urlconf file)))
      (delete-file file))))

(ert-deftest expose-django-test-root-urlconf-nil-when-absent ()
  (let ((file (make-temp-file "expose-django-test" nil ".py" "DEBUG = True\n")))
    (unwind-protect
        (should-not (expose-django-root-urlconf file))
      (delete-file file))))

(ert-deftest expose-django-test-root-urlconf-nil-for-nil-file ()
  (should-not (expose-django-root-urlconf nil)))

;;; ---------------------------------------------------------------------------
;;; expose-django-resolve-module
;;; ---------------------------------------------------------------------------

(ert-deftest expose-django-test-resolve-module-direct-under-root ()
  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "proj" dir))
          (with-temp-buffer (write-file (expand-file-name "proj/urls.py" dir)))
          (should (equal (expand-file-name "proj/urls.py" dir)
                          (expose-django-resolve-module "proj.urls" dir))))
      (delete-directory dir t))))

(ert-deftest expose-django-test-resolve-module-src-layout ()
  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "src/proj" dir) t)
          (with-temp-buffer (write-file (expand-file-name "src/proj/urls.py" dir)))
          (should (equal (expand-file-name "src/proj/urls.py" dir)
                          (expose-django-resolve-module "proj.urls" dir))))
      (delete-directory dir t))))

(ert-deftest expose-django-test-resolve-module-disambiguates-by-suffix ()
  "The critical case this whole function exists for: more than one
`urls.py' under the project, at different nesting depths, resolving a
dotted path must find the RIGHT one rather than whichever `find'
happens to list first."

  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "proj/blog" dir) t)
          (make-directory (expand-file-name "proj/api" dir) t)
          (with-temp-buffer (write-file (expand-file-name "proj/urls.py" dir)))
          (with-temp-buffer (write-file (expand-file-name "proj/blog/urls.py" dir)))
          (with-temp-buffer (write-file (expand-file-name "proj/api/urls.py" dir)))
          (should (equal (expand-file-name "proj/blog/urls.py" dir)
                          (expose-django-resolve-module "blog.urls" dir)))
          (should (equal (expand-file-name "proj/api/urls.py" dir)
                          (expose-django-resolve-module "api.urls" dir))))
      (delete-directory dir t))))

(ert-deftest expose-django-test-resolve-module-prunes-git-and-node-modules ()
  "A stray match inside `.git' or `node_modules' must not be returned
as if it were the real module."

  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git/blog" dir) t)
          (with-temp-buffer (write-file (expand-file-name ".git/blog/urls.py" dir)))
          (should-not (expose-django-resolve-module "blog.urls" dir)))
      (delete-directory dir t))))

(ert-deftest expose-django-test-resolve-module-nil-when-not-found ()
  (let ((dir (make-temp-file "expose-django-test" t)))
    (unwind-protect
        (should-not (expose-django-resolve-module "nonexistent.urls" dir))
      (delete-directory dir t))))

(ert-deftest expose-django-test-resolve-module-nil-for-nil-inputs ()
  (should-not (expose-django-resolve-module nil "/tmp"))
  (should-not (expose-django-resolve-module "a.b" nil)))

(provide 'expose-django-test)

;;; expose-django-test.el ends here
