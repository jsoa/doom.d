;;; expose-urls.el -*- lexical-binding: t; -*-

;;; The Django URL routing tree -- every `path()'/`re_path()'/`url()'
;;; entry and DRF router registration, followed recursively through
;;; `include()' from the project's `ROOT_URLCONF' down.
;;;
;;; Parsed, not generated: routing is declarative, mechanically regular
;;; Python, spread across as many files as the project has `include()'d
;;; -- exactly the shape a parser reconstructs exactly and a provider,
;;; shown only one urls.py at a time, cannot.
;;;
;;; Shares the underlying Django knowledge `expose-callers.el' already
;;; has for the test graph's route matching (how DRF derives a
;;; basename when `router.register' is called without one, the
;;; `app_name' namespacing rule) rather than the code itself: that
;;; answers "what URL names route to THIS one view", found one symbol
;;; at a time from wherever point happens to be; this answers "what
;;; does the whole tree look like", which needs its own top-down walk
;;; from the project's actual root rather than that reverse lookup, so
;;; it is a new walk, not a reuse -- the same reason
;;; `expose-usages.el' duplicates `expose-callers.el''s own root-
;;; finding preamble rather than sharing it.

(require 'cl-lib)
(require 'subr-x)
(require 'expose-log)
(require 'expose-django)

(defgroup expose-urls nil
  "Django URL routing tree for Expose."
  :group 'expose)

(defcustom expose-urls-max-depth 6
  "How many levels of `include()' to follow.

Bounded independently of `expose-urls-max-nodes': a project with a
deep `include()' chain but few routes per level would otherwise exceed
neither cap and still recurse far past anything useful to look at."
  :type 'integer
  :group 'expose-urls)

(defcustom expose-urls-max-nodes 80
  "Maximum route entries to draw before the walk stops.

When this trims anything, the diagram's own title says so rather than
silently drawing a partial tree that looks complete."
  :type 'integer
  :group 'expose-urls)

;;; ---------------------------------------------------------------------------
;;; Parsing one file's urlpatterns
;;; ---------------------------------------------------------------------------

(defun expose-urls-list-bounds ()
  "Return (START . END) bounding the current buffer's
`urlpatterns = [...]' list, or nil.

Bounded by `forward-sexp' on the opening `[', which Emacs's standard
syntax table already gives bracket semantics -- not a real parse, but
enough to find where the list actually ends regardless of how it's
laid out across lines."

  (goto-char (point-min))
  (when (re-search-forward "^urlpatterns[ \t]*\\(?:\\+?=\\)[ \t]*\\[" nil t)
    (let ((start (point)))
      (goto-char (1- start))
      (condition-case nil
          (progn (forward-sexp 1) (cons start (1- (point))))
        (error nil)))))

(defun expose-urls-top-level-calls (start end)
  "Return (NAME . ARGS-STRING) for each top-level call between START
and END -- one per `path()'/`re_path()'/`url()' entry in a
`urlpatterns' list, in the order written.

A call nested inside another (a `path()' whose own args happen to
contain a call) is not matched again at this level: `forward-sexp' on
the outer call's own parens jumps straight past its entire span, args
and all, before the next search resumes."

  (save-excursion
    (goto-char start)
    (let (calls)
      (while (re-search-forward "\\([A-Za-z_][A-Za-z0-9_.]*\\)(" end t)
        (let ((name (match-string 1))
              (open (1- (point))))
          (goto-char open)
          (condition-case nil
              (let ((close (progn (forward-sexp 1) (point))))
                (when (<= close end)
                  (push (cons name (buffer-substring-no-properties (1+ open) (1- close))) calls))
                (goto-char close))
            (error (goto-char (1+ open))))))
      (nreverse calls))))

(defun expose-urls-router-registrations (start end)
  "Return (PREFIX . VIEWSET-NAME) pairs for `....register(...)' calls
between START and END -- a DRF router's own registrations, which
normally sit as module-level statements rather than inside
`urlpatterns' itself (`urlpatterns' instead includes `router.urls')."

  (save-excursion
    (goto-char start)
    (let (found)
      (while (re-search-forward
              "\\.register([ \t\n]*[\"']\\([^\"']*\\)[\"'][ \t\n]*,[ \t\n]*\\([A-Za-z_][A-Za-z0-9_.]*\\)"
              end t)
        (push (cons (match-string 1) (match-string 2)) found))
      (nreverse found))))

(defun expose-urls-first-string-arg (args)
  "Return the first quoted string literal in ARGS, or nil."

  (when (string-match "[\"']\\([^\"']*\\)[\"']" args)
    (match-string 1 args)))

(defun expose-urls-keyword-string (args keyword)
  "Return ARGS's KEYWORD=\"...\" string value, or nil."

  (when (string-match
         (format "\\b%s[ \t\n]*=[ \t\n]*[\"']\\([^\"']*\\)[\"']" (regexp-quote keyword))
         args)
    (match-string 1 args)))

(defun expose-urls-include-target (args)
  "Return the dotted module path ARGS's `include(...)' names, or nil
when ARGS does not contain a simple string-form `include(\"...\")'.

Only that common shape is followed. `include(router.urls)' -- a bare
name, not a string -- routes through `expose-urls-router-registrations'
instead (see there); the 2-arg tuple form
(`include((patterns, app_name), namespace=...)') inlines a urlpatterns
list rather than naming a module to recurse into at all, and is left
alone. Real, stated limits, not silent ones."

  (when (string-match "include([ \t\n]*[\"']\\([A-Za-z0-9_.]+\\)[\"']" args)
    (match-string 1 args)))

(defun expose-urls-view-label (args)
  "Return a best-effort label for what ARGS's `path()' routes to.

Not a real parse: the route pattern (ARGS's own first quoted string)
is skipped past, then the first `Name.as_view' or bare dotted
identifier found after it is taken as the view. Good enough to read at
a glance, not guaranteed exact for every call shape -- a view built by
a more unusual expression may come back nil, in which case only the
route pattern and (if given) `name=' are shown."

  (let ((after-route
         (if (string-match "[\"'][^\"']*[\"']" args)
             (substring args (match-end 0))
           args)))
    (cond
     ((string-match "\\([A-Za-z_][A-Za-z0-9_.]*\\)\\.as_view" after-route)
      (match-string 1 after-route))
     ((string-match "\\([A-Za-z_][A-Za-z0-9_.]*\\)" after-route)
      (match-string 1 after-route)))))

;;; ---------------------------------------------------------------------------
;;; DOT
;;; ---------------------------------------------------------------------------

(defun expose-urls-escape (text)
  "Escape TEXT for use inside a quoted DOT label."

  (replace-regexp-in-string "\"" "\\\\\"" (or text "")))

(defun expose-urls-sanitize-id (text)
  "Return TEXT usable as (part of) a DOT identifier."

  (replace-regexp-in-string "[^A-Za-z0-9_]" "_" (or text "x")))

(defun expose-urls-route-label (route)
  "Return ROUTE, escaped, or \"(empty)\" for the common `path(\"\", ...)'
index-route case -- a blank label reads as a rendering mistake, not as
the actual empty route it is."

  (if (string-empty-p route) "(empty)" (expose-urls-escape route)))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun expose-urls-build-dot (&optional root-file)
  "Return DOT for the project's URL routing tree, starting from
ROOT-FILE (the resolved `ROOT_URLCONF' when omitted).

Signals a `user-error' naming what's missing -- no project, no
settings file, no resolvable `ROOT_URLCONF' -- rather than drawing an
empty tree."

  (let* ((project-root (or (expose-django-project-root) (user-error "Not inside a project")))
         (root-file
          (or root-file
              (let* ((settings (expose-django-find-settings-file project-root))
                     (urlconf (and settings (expose-django-root-urlconf settings))))
                (and urlconf (expose-django-resolve-module urlconf project-root))))))

    (unless root-file
      (user-error "Could not resolve `ROOT_URLCONF' to a real urls.py under %s" project-root))

    (expose-log "Urls" "Building URL tree from %s." root-file)

    (let ((node-count 0)
          (visited nil)
          (truncated nil))

      (cl-labels
          ((budget-left-p ()
             (< node-count expose-urls-max-nodes))

           (render-file (file depth)
             (cond
              ((not (and file (file-readable-p file)))
               (if file
                   (format "  n%d [shape=note,label=\"%s\\n(file not found)\"];"
                           (cl-incf node-count) (expose-urls-escape file))
                 ""))

              ((member file visited)
               "")

              ;; Strictly greater, not `>=': DEPTH counts hops already
              ;; taken via `include()', and the root call starts at 0
              ;; -- `>=' here would refuse to read even the root file's
              ;; own direct routes the moment `expose-urls-max-depth'
              ;; was 0, when 0 hops of `include()' followed is exactly
              ;; what that setting asks for, not zero files read at all.
              ((> depth expose-urls-max-depth)
               (setq truncated t)
               "")

              ((not (budget-left-p))
               (setq truncated t)
               "")

              (t
               (push file visited)

               (with-temp-buffer
                 (insert-file-contents file)

                 (let* ((bounds (expose-urls-list-bounds))
                        (calls (and bounds (expose-urls-top-level-calls (car bounds) (cdr bounds))))
                        (registrations
                         (expose-urls-router-registrations (point-min) (point-max)))
                        (parts nil))

                   (dolist (call calls)
                     (if (budget-left-p)
                         (let ((rendered (render-call call depth)))
                           (when rendered (push rendered parts)))
                       (setq truncated t)))

                   (dolist (reg registrations)
                     (if (budget-left-p)
                         (push (render-router reg) parts)
                       (setq truncated t)))

                   (mapconcat #'identity (nreverse parts) "\n"))))))

           (render-call (call depth)
             (let* ((name (car call))
                    (args (cdr call)))
               (when (member name '("path" "re_path" "url"))
                 (let* ((route (or (expose-urls-first-string-arg args) "?"))
                        (target (expose-urls-include-target args)))
                   (cond
                    (target (render-include route target depth))

                    ;; `include(router.urls)' or any other bare-
                    ;; identifier `include(...)' this can't resolve to
                    ;; a module (see `expose-urls-include-target'): not
                    ;; a real view to name -- `expose-urls-view-label'
                    ;; would otherwise read the literal word `include'
                    ;; off the call and draw it as if it were one. For
                    ;; the common `router.urls' case this file's own
                    ;; `render-router' registrations already draw the
                    ;; real information, so nothing is lost by leaving
                    ;; this one undrawn rather than mislabeling it.
                    ((string-match-p "\\binclude(" args) nil)

                    (t (render-entry route args)))))))

           (render-entry (route args)
             (cl-incf node-count)
             (let* ((id (format "n%d" node-count))
                    (view (expose-urls-view-label args))
                    (name (expose-urls-keyword-string args "name"))
                    (label
                     (concat
                      (expose-urls-route-label route)
                      (when view (format "\\n%s" (expose-urls-escape view)))
                      (when name (format "\\nname=%s" (expose-urls-escape name))))))
               (format "  %s [shape=box,label=\"%s\"];" id label)))

           (render-router (reg)
             (cl-incf node-count)
             (let* ((id (format "n%d" node-count))
                    (prefix (car reg))
                    (viewset (cdr reg))
                    (label
                     (format "%s\\n%s (router)"
                             (expose-urls-escape prefix)
                             (expose-urls-escape viewset))))
               (format "  %s [shape=component,label=\"%s\"];" id label)))

           (render-include (route target depth)
             ;; `render-file' can come back empty for three different
             ;; reasons -- the module genuinely couldn't be found, it
             ;; was already drawn once elsewhere in the tree, or
             ;; `expose-urls-max-depth'/`expose-urls-max-nodes' cut the
             ;; walk off before it got there -- and those are different
             ;; enough answers that lumping them into one "(not
             ;; resolved)" note would misreport a real find as a
             ;; failure.
             (let ((target-file (expose-django-resolve-module target project-root)))
               (cond
                ((not target-file)
                 (cl-incf node-count)
                 (format "  n%d [shape=note,label=\"%s\\ninclude(%s)\\n(module not found)\"];"
                         node-count (expose-urls-route-label route) (expose-urls-escape target)))

                ((member target-file visited)
                 (cl-incf node-count)
                 (format "  n%d [shape=note,label=\"%s\\ninclude(%s)\\n(already drawn elsewhere)\"];"
                         node-count (expose-urls-route-label route) (expose-urls-escape target)))

                (t
                 (let ((inner (render-file target-file (1+ depth))))
                   (if (string-empty-p (string-trim (or inner "")))
                       (progn
                         (cl-incf node-count)
                         (format "  n%d [shape=note,label=\"%s\\ninclude(%s)\\n(depth/node limit reached)\"];"
                                 node-count (expose-urls-route-label route) (expose-urls-escape target)))
                     (format "  subgraph cluster_%s_%d {\n    label=\"%s -> %s\";\n%s\n  }"
                             (expose-urls-sanitize-id target) depth
                             (expose-urls-route-label route) (expose-urls-escape target)
                             inner))))))))

        (let ((body (render-file root-file 0)))

          (unless (> node-count 0)
            (user-error "No routes found in %s" root-file))

          (expose-log "Urls" "Found %d route entr%s." node-count (if (= node-count 1) "y" "ies"))

          (concat
           "digraph urls {\n"
           "  rankdir=LR;\n"
           (format "  label=\"URL routes (%d)%s\";\n"
                   node-count
                   (if truncated
                       " -- truncated, see expose-urls-max-nodes/expose-urls-max-depth"
                     ""))
           body
           "\n}"))))))

(provide 'expose-urls)

;;; expose-urls.el ends here
