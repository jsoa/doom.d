;;; expose-middleware.el -*- lexical-binding: t; -*-

;;; The Django middleware stack, in real request order -- the one
;;; layer nothing else in Expose draws. `expose-run-request-flow-
;;; diagram' draws a single view's own pipeline; this is the layer
;;; above it that every request passes through before any view runs at
;;; all, and it lives in one project-wide list in settings.py that no
;;; per-view diagram can show.
;;;
;;; Parsed, not generated: MIDDLEWARE is a literal Python list in the
;;; overwhelming common case, and "what order do these run in" is
;;; exactly the kind of question a parser answers exactly where a
;;; provider could only guess at a settings file it may not even have
;;; been shown.
;;;
;;; Drawn as the "onion" it actually is, not a flat list: Django runs
;;; MIDDLEWARE in list order on the way IN to a view, and in REVERSE
;;; order on the way back OUT -- so the first entry is the outermost
;;; layer, first to see the request and last to see the response. Two
;;; edges per adjacent pair, one each direction, is what actually
;;; states that correctly rather than implying a single straight pipe.

(require 'cl-lib)
(require 'subr-x)
(require 'expose-log)
(require 'expose-django)

(defgroup expose-middleware nil
  "Django middleware pipeline for Expose."
  :group 'expose)

;;; ---------------------------------------------------------------------------
;;; Parsing
;;; ---------------------------------------------------------------------------

(defun expose-middleware-parse-list (file)
  "Return the dotted-path strings in FILE's `MIDDLEWARE = [...]' list.

A plain textual scan bounded by the list's own brackets (`forward-
sexp' on the opening `[', which Emacs's standard syntax table already
gives bracket semantics), not a real parse -- so a dynamically built
list (`MIDDLEWARE = BASE_MIDDLEWARE + [...]', an `if DEBUG:' branch
appending one) is read only as far as the literal strings inside this
one list, not evaluated. A real, stated limit, not a silent one."

  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "^MIDDLEWARE[ \t]*=[ \t]*\\[" nil t)
        (let* ((start (point))
               (end
                (save-excursion
                  (goto-char (1- start))
                  (condition-case nil
                      (progn (forward-sexp 1) (1- (point)))
                    (error (point-max))))))
          (goto-char start)
          (let (entries)
            (while (re-search-forward "[\"']\\([A-Za-z_][A-Za-z0-9_.]*\\)[\"']" end t)
              (push (match-string 1) entries))
            (nreverse entries)))))))

(defun expose-middleware-class-name (dotted-path)
  "Return DOTTED-PATH's trailing class-name component."

  (car (last (split-string dotted-path "\\."))))

(defun expose-middleware-local-location (dotted-path project-root)
  "Return (FILE . LINE) where DOTTED-PATH's class is defined under
PROJECT-ROOT, or nil when it isn't project-local -- a third-party or
Django built-in middleware, which is not in this project's own tree to
find."

  (when project-root
    (let ((class-name (expose-middleware-class-name dotted-path)))
      (with-temp-buffer
        (let ((status
               (ignore-errors
                 (call-process
                  "grep" nil t nil
                  "-rnE" "--include=*.py" "--"
                  (format "^class %s\\b" (regexp-quote class-name))
                  project-root))))
          (when (memq status '(0 1))
            (goto-char (point-min))
            (when (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t)
              (cons (match-string 1) (string-to-number (match-string 2))))))))))

(defun expose-middleware-class-docstring (file line)
  "Return the first line of the class docstring at FILE:LINE, or nil.

Bounded to `expose-middleware-docstring-search-lines' so this can't run
away into a later class's own text when the one at FILE:LINE has no
docstring at all."

  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (forward-line (1- line))
      (forward-line 1)
      (let ((bound (min (point-max) (+ (point) 400))))
        (when (re-search-forward "^[ \t]+\\(\"\"\"\\|'''\\)\\([^\n]*\\)" bound t)
          (let ((quote (match-string 1))
                (rest (string-trim (match-string 2))))
            (if (string-suffix-p quote rest)
                (string-trim (substring rest 0 (- (length rest) (length quote))))
              rest)))))))

(defun expose-middleware-describe (dotted-path project-root)
  "Return a plist describing DOTTED-PATH: `:name', `:local', `:doc'."

  (let* ((location (expose-middleware-local-location dotted-path project-root))
         (doc (and location (expose-middleware-class-docstring (car location) (cdr location)))))
    (list :path dotted-path
          :name (expose-middleware-class-name dotted-path)
          :local (and location t)
          :doc doc)))

;;; ---------------------------------------------------------------------------
;;; DOT
;;; ---------------------------------------------------------------------------

(defun expose-middleware-escape (text)
  "Escape TEXT for use inside a quoted DOT label."

  (replace-regexp-in-string "\"" "\\\\\"" (or text "")))

(defun expose-middleware-node-id (index)
  (format "mw%d" index))

(defun expose-middleware-to-dot (entries project-root)
  "Render ENTRIES (dotted-path strings, in MIDDLEWARE's own order) as
Graphviz DOT."

  (let* ((descriptions
          (mapcar (lambda (path) (expose-middleware-describe path project-root)) entries))
         (count (length descriptions))
         (lines nil))

    (push "digraph middleware {" lines)
    (push "  rankdir=TB;" lines)
    (push (format "  label=\"Middleware pipeline (%d) -- outermost first\";" count) lines)

    (let ((index 0))
      (dolist (entry descriptions)
        (let* ((id (expose-middleware-node-id index))
               (name (plist-get entry :name))
               (doc (plist-get entry :doc))
               (shape (if (plist-get entry :local) "box" "component"))
               (label (if doc
                          (format "%s\\n%s"
                                  (expose-middleware-escape name)
                                  (expose-middleware-escape doc))
                        (expose-middleware-escape name))))
          (push (format "  %s [shape=%s,label=\"%s\"];" id shape label) lines))
        (setq index (1+ index))))

    (push "  view [shape=ellipse,label=\"View\"];" lines)

    (when (> count 0)
      (let ((index 0))
        (while (< index (1- count))
          (push (format "  %s -> %s [label=\"request\",color=\"#4a7fd4\",fontcolor=\"#4a7fd4\"];"
                        (expose-middleware-node-id index)
                        (expose-middleware-node-id (1+ index)))
                lines)
          (setq index (1+ index))))

      (push (format "  %s -> view [label=\"request\",color=\"#4a7fd4\",fontcolor=\"#4a7fd4\"];"
                    (expose-middleware-node-id (1- count)))
            lines)

      (push (format "  view -> %s [label=\"response\",color=\"#4f9d69\",fontcolor=\"#4f9d69\",style=dashed];"
                    (expose-middleware-node-id (1- count)))
            lines)

      (let ((index (1- count)))
        (while (> index 0)
          (push (format "  %s -> %s [label=\"response\",color=\"#4f9d69\",fontcolor=\"#4f9d69\",style=dashed];"
                        (expose-middleware-node-id index)
                        (expose-middleware-node-id (1- index)))
                lines)
          (setq index (1- index)))))

    (push "}" lines)
    (mapconcat #'identity (nreverse lines) "\n")))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun expose-middleware-build-dot ()
  "Return DOT for the current project's middleware pipeline.

Signals a `user-error' naming what's missing -- no project, no
settings file with a `MIDDLEWARE = [...]' list -- rather than drawing
an empty pipeline."

  (let ((root (or (expose-django-project-root) (user-error "Not inside a project"))))

    (expose-log "Middleware" "Reading MIDDLEWARE under %s." root)

    (let ((file (expose-django-find-settings-file root)))
      (unless file
        (user-error "No `MIDDLEWARE = [...]' list found under %s" root))

      (let ((entries (expose-middleware-parse-list file)))
        (unless entries
          (user-error "Found `MIDDLEWARE' in %s, but couldn't read any entries from it"
                      (file-relative-name file root)))

        (expose-log "Middleware" "Found %d entries in %s." (length entries) file)

        (expose-middleware-to-dot entries root)))))

(provide 'expose-middleware)

;;; expose-middleware.el ends here
