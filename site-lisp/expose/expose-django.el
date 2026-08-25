;;; expose-django.el -*- lexical-binding: t; -*-

;;; Small, shared Django-project facts -- where settings.py lives and
;;; what it points `ROOT_URLCONF' at -- used by more than one Expose
;;; feature (`expose-middleware.el', `expose-urls.el') that each need
;;; to resolve the same things. Kept in its own file rather than
;;; either duplicating this or having one feature depend on the other
;;; for it: neither is really about the other, both are really about
;;; this.

(require 'seq)
(require 'subr-x)
(require 'project)

(defun expose-django-project-root ()
  "Return the current project root, or nil."

  (when-let ((project (project-current nil)))
    (expand-file-name (project-root project))))

(defun expose-django-find-settings-file (project-root)
  "Return the settings.py-shaped file under PROJECT-ROOT that defines
`MIDDLEWARE', or nil.

Located by content, not by the filename `settings.py' -- large
projects routinely split settings across `base.py'/`dev.py'/`prod.py',
and this only needs whichever one actually defines the base
`MIDDLEWARE'/`ROOT_URLCONF' values. Only the first file found is used;
a project that builds either dynamically across more than one file (an
environment-specific override) is a real, stated limit, not a silent
one."

  (when project-root
    (with-temp-buffer
      (let ((status
             (ignore-errors
               (call-process
                "grep" nil t nil
                "-rlE" "--include=*.py" "--"
                "^MIDDLEWARE[ \t]*="
                project-root))))
        (when (eq status 0)
          (car (split-string (buffer-string) "\n" t)))))))

(defun expose-django-root-urlconf (settings-file)
  "Return the dotted module path in SETTINGS-FILE's `ROOT_URLCONF', or nil."

  (when (and settings-file (file-readable-p settings-file))
    (with-temp-buffer
      (insert-file-contents settings-file)
      (goto-char (point-min))
      (when (re-search-forward
             "^ROOT_URLCONF[ \t]*=[ \t]*[\"']\\([A-Za-z0-9_.]+\\)[\"']"
             nil t)
        (match-string 1)))))

(defun expose-django-resolve-module (dotted-path project-root)
  "Return the `.py' file under PROJECT-ROOT for DOTTED-PATH, or nil.

`a.b.c' resolves to `.../a/b/c.py'. Tried at the project root itself
and one level of `src'-style nesting first, since those cover most
real layouts cheaply without a subprocess. The last resort searches by
the dotted path's own directory *suffix* (`find ... -path \"*/a/b/c.py\"'),
not by the bare filename alone -- a project with more than one
`urls.py' (routinely one per app, which is exactly the shape this
exists to walk) would otherwise resolve every `include(\"app.urls\")'
to whichever `urls.py' `find' happened to list first, silently
recursing into the wrong app's routes. A Django project's importable
root is not always the same as its checkout root, so even the suffix
search can still miss a genuinely unusual layout -- a real, stated
limit, not a silent one."

  (when (and dotted-path project-root)
    (let* ((relative (concat (replace-regexp-in-string "\\." "/" dotted-path) ".py"))
           (candidates
            (list
             (expand-file-name relative project-root)
             (expand-file-name relative (expand-file-name "src" project-root)))))
      (or
       (seq-find #'file-readable-p candidates)
       (with-temp-buffer
         (let ((status
                (ignore-errors
                  (call-process
                   "find" nil t nil
                   project-root
                   "(" "-name" ".git" "-o" "-name" "node_modules"
                   "-o" "-name" "venv" "-o" "-name" ".venv" ")" "-prune"
                   "-o" "-path" (concat "*/" relative) "-print"))))
           (when (eq status 0)
             (car (split-string (buffer-string) "\n" t)))))))))

(provide 'expose-django)

;;; expose-django.el ends here
