;;; expose-urls-test.el --- Tests for expose-urls -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-urls)

;;; ---------------------------------------------------------------------------
;;; Small parsing primitives
;;; ---------------------------------------------------------------------------

(ert-deftest expose-urls-test-first-string-arg ()
  (should (equal "events/" (expose-urls-first-string-arg "\"events/\", views.list_view")))
  (should (equal "events/" (expose-urls-first-string-arg "'events/', views.list_view")))
  (should-not (expose-urls-first-string-arg "views.list_view")))

(ert-deftest expose-urls-test-keyword-string ()
  (should (equal "event-list" (expose-urls-keyword-string "views.f, name=\"event-list\"" "name")))
  (should-not (expose-urls-keyword-string "views.f" "name"))
  (should-not
   (expose-urls-keyword-string "views.f, basename=\"event-list\"" "name")))

(ert-deftest expose-urls-test-include-target-string-form ()
  (should (equal "blog.urls" (expose-urls-include-target "include(\"blog.urls\")")))
  (should (equal "blog.urls" (expose-urls-include-target "include('blog.urls')"))))

(ert-deftest expose-urls-test-include-target-nil-for-bare-identifier ()
  "`include(router.urls)' names an attribute, not a module string --
this must not be mistaken for one."

  (should-not (expose-urls-include-target "include(router.urls)")))

(ert-deftest expose-urls-test-include-target-nil-without-include ()
  (should-not (expose-urls-include-target "views.detail, name=\"x\"")))

(ert-deftest expose-urls-test-view-label-as-view-form ()
  (should
   (equal "PostDetailView"
          (expose-urls-view-label "\"<int:pk>/\", PostDetailView.as_view(), name=\"post-detail\""))))

(ert-deftest expose-urls-test-view-label-bare-function-form ()
  (should
   (equal "views.post_list"
          (expose-urls-view-label "\"\", views.post_list, name=\"post-list\""))))

(ert-deftest expose-urls-test-view-label-nil-without-a-recognizable-view ()
  (should-not (expose-urls-view-label "\"x/\"")))

;;; ---------------------------------------------------------------------------
;;; expose-urls-top-level-calls: only the top level, not what's nested
;;; inside each call's own arguments
;;; ---------------------------------------------------------------------------

(ert-deftest expose-urls-test-top-level-calls-skips-nested-calls ()
  (with-temp-buffer
    (insert "path(\"x/\", SomeView.as_view(extra=Thing()), name=\"x\"), path(\"y/\", views.y)")
    (let ((calls (expose-urls-top-level-calls (point-min) (point-max))))
      ;; Exactly the two `path(...)' calls -- not `as_view(...)' or
      ;; `Thing()', both nested inside the first `path()''s own args.
      (should (= 2 (length calls)))
      (should (equal "path" (car (nth 0 calls))))
      (should (equal "path" (car (nth 1 calls)))))))

(ert-deftest expose-urls-test-top-level-calls-empty-for-no-calls ()
  (with-temp-buffer
    (insert "   ")
    (should-not (expose-urls-top-level-calls (point-min) (point-max)))))

;;; ---------------------------------------------------------------------------
;;; expose-urls-router-registrations
;;; ---------------------------------------------------------------------------

(ert-deftest expose-urls-test-router-registrations-finds-prefix-and-viewset ()
  (with-temp-buffer
    (insert "router = DefaultRouter()\n"
            "router.register(\"events\", EventViewSet, basename=\"event\")\n"
            "router.register(\"users\", UserViewSet)\n")
    (let ((regs (expose-urls-router-registrations (point-min) (point-max))))
      (should (equal '(("events" . "EventViewSet") ("users" . "UserViewSet")) regs)))))

(ert-deftest expose-urls-test-router-registrations-empty-without-any ()
  (with-temp-buffer
    (insert "urlpatterns = [path(\"x/\", views.x)]\n")
    (should-not (expose-urls-router-registrations (point-min) (point-max)))))

;;; ---------------------------------------------------------------------------
;;; expose-urls-list-bounds
;;; ---------------------------------------------------------------------------

(ert-deftest expose-urls-test-list-bounds-finds-the-list ()
  (with-temp-buffer
    (insert "from django.urls import path\n\nurlpatterns = [\n    path(\"x/\", views.x),\n]\n")
    (let ((bounds (expose-urls-list-bounds)))
      (should bounds)
      (should (equal "\n    path(\"x/\", views.x),\n"
                      (buffer-substring-no-properties (car bounds) (cdr bounds)))))))

(ert-deftest expose-urls-test-list-bounds-nil-without-urlpatterns ()
  (with-temp-buffer
    (insert "DEBUG = True\n")
    (should-not (expose-urls-list-bounds))))

(ert-deftest expose-urls-test-list-bounds-handles-plus-equals ()
  (with-temp-buffer
    (insert "urlpatterns += [\n    path(\"x/\", views.x),\n]\n")
    (should (expose-urls-list-bounds))))

;;; ---------------------------------------------------------------------------
;;; expose-urls-route-label
;;; ---------------------------------------------------------------------------

(ert-deftest expose-urls-test-route-label-empty-route-is-labelled ()
  (should (equal "(empty)" (expose-urls-route-label ""))))

(ert-deftest expose-urls-test-route-label-passes-through-a-real-route ()
  (should (equal "events/" (expose-urls-route-label "events/"))))

;;; ---------------------------------------------------------------------------
;;; expose-urls-build-dot: end to end against real files
;;; ---------------------------------------------------------------------------

(defmacro expose-urls-test-with-project (files &rest body)
  "Create a temp project directory containing FILES ((RELATIVE-PATH
CONTENT) ...), bind `dir' to its root, run BODY, clean up."

  (declare (indent 1))
  `(let ((dir (make-temp-file "expose-urls-test" t)))
     (unwind-protect
         (progn
           (dolist (entry (list ,@(mapcar (lambda (f) `(list ,(car f) ,(cadr f))) files)))
             (let ((path (expand-file-name (car entry) dir)))
               (make-directory (file-name-directory path) t)
               (with-temp-buffer
                 (insert (cadr entry))
                 (write-file path))))
           ,@body)
       (delete-directory dir t))))

(ert-deftest expose-urls-test-build-dot-simple-tree ()
  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path, include\n"
                "urlpatterns = [\n"
                "    path(\"admin/\", admin.site.urls, name=\"admin\"),\n"
                "    path(\"blog/\", include(\"blog.urls\")),\n"
                "]\n"))
       ("proj/blog/urls.py"
        (concat "from django.urls import path\n"
                "from . import views\n"
                "urlpatterns = [\n"
                "    path(\"\", views.post_list, name=\"post-list\"),\n"
                "    path(\"<int:pk>/\", views.PostDetailView.as_view(), name=\"post-detail\"),\n"
                "]\n")))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (let ((dot (expose-urls-build-dot)))
        (should (string-match-p "admin/" dot))
        (should (string-match-p "name=admin" dot))
        (should (string-match-p "subgraph cluster_blog_urls" dot))
        (should (string-match-p "(empty)" dot))
        (should (string-match-p "PostDetailView" dot))
        (should (string-match-p "name=post-detail" dot))
        (should (string-match-p "URL routes (3)" dot))
        (should-not (string-match-p "truncated" dot))))))

(ert-deftest expose-urls-test-build-dot-router-registration-shown-not-mislabeled ()
  "`path(\"\", include(router.urls))' must not draw a node claiming the
view is literally `include' -- the router's own registrations are the
real information and are drawn instead."

  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path, include\n"
                "from rest_framework.routers import DefaultRouter\n"
                "from .views import EventViewSet\n"
                "router = DefaultRouter()\n"
                "router.register(\"events\", EventViewSet, basename=\"event\")\n"
                "urlpatterns = [\n"
                "    path(\"\", include(router.urls)),\n"
                "]\n")))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (let ((dot (expose-urls-build-dot)))
        (should (string-match-p "EventViewSet (router)" dot))
        (should-not (string-match-p "\\\\ninclude\\\\n" dot))
        (should-not (string-match-p "label=\"(empty)\\\\ninclude\"" dot))))))

(ert-deftest expose-urls-test-build-dot-depth-zero-still-reads-root ()
  "A depth cap of 0 means \"follow zero `include()' hops\", not \"read
nothing\" -- the root file's own direct routes must still appear."

  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path, include\n"
                "urlpatterns = [\n"
                "    path(\"admin/\", admin.site.urls, name=\"admin\"),\n"
                "    path(\"blog/\", include(\"blog.urls\")),\n"
                "]\n"))
       ("proj/blog/urls.py"
        "from django.urls import path\nurlpatterns = [path(\"\", views.x, name=\"x\")]\n"))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir))
              (expose-urls-max-depth 0))
      (let ((dot (expose-urls-build-dot)))
        (should (string-match-p "name=admin" dot))
        (should (string-match-p "depth/node limit reached" dot))
        (should-not (string-match-p "cluster_blog_urls" dot))))))

(ert-deftest expose-urls-test-build-dot-node-cap-truncates-and-says-so ()
  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path\n"
                "urlpatterns = [\n"
                "    path(\"a/\", views.a, name=\"a\"),\n"
                "    path(\"b/\", views.b, name=\"b\"),\n"
                "    path(\"c/\", views.c, name=\"c\"),\n"
                "]\n")))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir))
              (expose-urls-max-nodes 2))
      (let ((dot (expose-urls-build-dot)))
        (should (string-match-p "name=a" dot))
        (should (string-match-p "name=b" dot))
        (should-not (string-match-p "name=c" dot))
        (should (string-match-p "truncated" dot))))))

(ert-deftest expose-urls-test-build-dot-diamond-include-drawn-once ()
  "The same app included from two different mount points must be drawn
once, not silently duplicated or treated as a resolution failure the
second time."

  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path, include\n"
                "urlpatterns = [\n"
                "    path(\"blog/\", include(\"blog.urls\")),\n"
                "    path(\"blog-again/\", include(\"blog.urls\")),\n"
                "]\n"))
       ("proj/blog/urls.py"
        "from django.urls import path\nurlpatterns = [path(\"\", views.x, name=\"x\")]\n"))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (let* ((dot (expose-urls-build-dot))
             (count 0)
             (start 0))
        (while (string-match "subgraph cluster_blog_urls" dot start)
          (setq count (1+ count))
          (setq start (match-end 0)))
        (should (= 1 count))
        (should (string-match-p "already drawn elsewhere" dot))))))

(ert-deftest expose-urls-test-build-dot-unresolvable-include-named-honestly ()
  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path, include\n"
                "urlpatterns = [\n"
                "    path(\"x/\", include(\"nonexistent_app.urls\")),\n"
                "]\n")))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (let ((dot (expose-urls-build-dot)))
        (should (string-match-p "module not found" dot))))))

(ert-deftest expose-urls-test-build-dot-refuses-without-root-urlconf ()
  (expose-urls-test-with-project
      (("settings.py" "DEBUG = True\nMIDDLEWARE = []\n"))
    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (should-error (expose-urls-build-dot) :type 'user-error))))

(ert-deftest expose-urls-test-build-dot-refuses-without-a-project ()
  (cl-letf (((symbol-function 'expose-django-project-root) (lambda () nil)))
    (should-error (expose-urls-build-dot) :type 'user-error)))

(ert-deftest expose-urls-test-build-dot-refuses-when-no-routes-found ()
  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py" "urlpatterns = []\n"))
    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (should-error (expose-urls-build-dot) :type 'user-error))))

(ert-deftest expose-urls-test-build-dot-renders-through-graphviz ()
  "Not just well-formed enough to eyeball -- actually valid DOT, run
through the real `dot' binary, when it's available."

  (skip-unless (executable-find "dot"))

  (expose-urls-test-with-project
      (("settings.py" "ROOT_URLCONF = \"proj.urls\"\nMIDDLEWARE = []\n")
       ("proj/urls.py"
        (concat "from django.urls import path, include\n"
                "urlpatterns = [\n"
                "    path(\"admin/\", admin.site.urls, name=\"admin\"),\n"
                "    path(\"blog/\", include(\"blog.urls\")),\n"
                "]\n"))
       ("proj/blog/urls.py"
        "from django.urls import path\nurlpatterns = [path(\"\", views.x, name=\"x\")]\n"))

    (cl-letf (((symbol-function 'expose-django-project-root) (lambda () dir)))
      (let* ((dot (expose-urls-build-dot))
             (dot-file (expand-file-name "out.dot" dir))
             (svg-file (expand-file-name "out.svg" dir)))
        (with-temp-file dot-file (insert dot))
        (should (= 0 (call-process "dot" nil nil nil "-Tsvg" dot-file "-o" svg-file)))
        (should (file-exists-p svg-file))))))

(provide 'expose-urls-test)

;;; expose-urls-test.el ends here
