;;; expose-orm.el -*- lexical-binding: t; -*-

;;; What a Django queryset will ask the database for.
;;;
;;; Computed, not generated, and for once not even by reading source: the
;;; expression is handed to the project's own Python, where Django compiles
;;; it exactly as it would at runtime. The SQL is therefore the real SQL,
;;; not a plausible reconstruction of it -- which matters, because the
;;; question people ask of a queryset ("does this hit an index", "how many
;;; joins is this") is worthless answered approximately.
;;;
;;; `expose-orm-inspect' does not connect to a database. `str(queryset.query)'
;;; compiles SQL through the backend without opening a connection, and every
;;; finding comes from the query object or the model's metadata. That is what
;;; makes it safe to run against a project whose DB_HOST points somewhere you
;;; would rather not send a query -- see `expose-orm.py', which also refuses
;;; to evaluate an expression containing a write, and refuses a real
;;; connection outright for the duration of evaluation regardless of what
;;; code path might have opened one (a denylist of dangerous method names
;;; can never be complete -- Django's own contrib apps have methods that
;;; connect for real without looking dangerous by name).
;;;
;;; `expose-orm-explain' is the exception and the only thing here that
;;; connects, because a plan is the planner's opinion and only the planner
;;; holds it. It can be pointed at a replica (`expose-orm-dsn',
;;; `expose-orm-database'), always rolls back, and always sets a statement
;;; timeout.

(require 'json)
(require 'subr-x)
(require 'python)
(require 'sql)
(require 'expose-log)
(require 'expose-side-panel)
(require 'expose-diagram)
(require 'expose-orm-plan)

(defgroup expose-orm nil
  "Django queryset inspection for Expose."
  :group 'expose)

(defcustom expose-orm-container nil
  "Docker container to run the project's Python in, or nil for local.

Set per project in `.dir-locals.el'. When nil, this falls back to
`jsoa/docker-jump-container' if that is set, so a project already
configured for remote jump-to-definition needs no second setting."
  :type '(choice (const :tag "Run locally" nil) string)
  :safe #'string-or-null-p
  :group 'expose-orm)

(defcustom expose-orm-workdir nil
  "Working directory inside `expose-orm-container'.

Nil uses the image's own WORKDIR, which is correct for most Django
images. Set it when `manage.py' is not there."
  :type '(choice (const :tag "Image default" nil) string)
  :safe #'string-or-null-p
  :group 'expose-orm)

(defcustom expose-orm-python "python"
  "Python executable used to run `manage.py shell'."
  :type 'string
  :safe #'stringp
  :group 'expose-orm)

(defcustom expose-orm-database nil
  "Django DATABASES alias to take query plans from, or nil for \"default\".

Set this in `.dir-locals.el' to a read-only replica or a dev copy when
the default connection is one you would rather not plan against."
  :type '(choice (const :tag "default" nil) string)
  :safe #'string-or-null-p
  :group 'expose-orm)

(defcustom expose-orm-dsn nil
  "Connection string to take query plans from, bypassing Django settings.

The SQL is still compiled by the project's Django, so it is the real
query; only the connection it is explained against differs. Use this
when the database you want a plan from is not in DATABASES at all."
  :type '(choice (const :tag "Use Django's connection" nil) string)
  :safe #'string-or-null-p
  :group 'expose-orm)

(defcustom expose-orm-statement-timeout 10000
  "Milliseconds a plan query may run before the database cancels it.

Applies to EXPLAIN ANALYZE, which actually executes the query -- without
a timeout, explaining a bad query means waiting out the bad query."
  :type 'integer
  :group 'expose-orm)

(defconst expose-orm-script
  (expand-file-name "expose-orm.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The analysis script run inside the project's environment.")

(defconst expose-orm-begin "<<<EXPOSE-ORM-BEGIN>>>")
(defconst expose-orm-end "<<<EXPOSE-ORM-END>>>")

(defvar expose-orm-buffer "*EXPOSE ORM*")

;;; ---------------------------------------------------------------------------
;;; Locating the expression and its module
;;; ---------------------------------------------------------------------------

(defun expose-orm-strip-binding (text)
  "Return TEXT without a leading assignment or `return'.

Selecting the line you are looking at usually catches `qs = Event...'
or `order, _ = Order.objects.get_or_create(...)', and the binding is
not part of the expression Python must evaluate -- `order, _ = X' is
a statement, and `ast.parse' in `eval' mode rejects any statement
outright, tuple-unpacking assignment very much included."

  (let ((trimmed (string-trim text)))
    (cond
     ((string-match "\\`return[ \t\n]+\\(\\(?:.\\|\n\\)+\\)\\'" trimmed)
      (string-trim (match-string 1 trimmed)))
     ;; One or more comma-separated names -- a single `qs =' or a
     ;; tuple-unpacking `order, _ =' alike -- then `=' that is not
     ;; `==', `<=' and so on.
     ((string-match
       "\\`[A-Za-z_][A-Za-z0-9_]*\\(?:[ \t]*,[ \t]*[A-Za-z_][A-Za-z0-9_]*\\)*[ \t]*=[ \t\n]*\\([^=]\\(?:.\\|\n\\)*\\)\\'"
       trimmed)
      (string-trim (match-string 1 trimmed)))
     (t trimmed))))

(defun expose-orm-enclosing-class ()
  "Return the name of the Python class enclosing point, or nil.

`self' only resolves to something inspectable when the selection came
from inside a class's own method -- `python-info-current-defun' already
knows this shape (\"ClassName.method_name\", however many levels of
nesting deep, e.g. \"Outer.Inner.method_name\"), so this only has to
drop the last component."

  (when-let ((defun-name (python-info-current-defun)))
    (let ((parts (split-string defun-name "\\.")))
      (when (> (length parts) 1)
        (string-join (butlast parts) ".")))))

(defun expose-orm-resolve-self (expression)
  "Return EXPRESSION with a leading `self.' resolved to its enclosing class.

`self.queryset.filter(...)' is the standard DRF/CBV shape for a
queryset expression, and unresolvable as written: the analysis runs in
a plain module namespace with no request in flight to have built a
`self' from. `self.queryset', though, is ordinarily the exact same
object as the class's own `queryset = Model.objects.filter(...)'
attribute -- so substituting the enclosing class name in for `self'
turns an expression that always failed with a bare `NameError' into
one that actually inspects something, for what is likely the single
most common reason `expose-orm-inspect' was refusing real code.

Only the *leading* `self.', deliberately: `self.queryset.filter(x=
self.kwargs[\"id\"])' has a second `self' this does not touch, since
`kwargs' is real per-request state with no class-level equivalent --
resolving only what is genuinely the same object as a class attribute,
not guessing at instance state generally.

Assumes the named attribute is set at the class level, not only ever
assigned per-instance in `__init__' or computed by a `@property' --
true for the common case this is aimed at, but not guaranteed; when it
is not, the class-level lookup fails with its own clear error (an
`AttributeError', not a silently wrong result) rather than pretending
to work."

  (if-let* (;; `.' does not match a newline in Emacs regexps, and a
            ;; selection wrapping its arguments onto their own line --
            ;; `self.queryset.filter(\n  x=1\n)' -- is completely
            ;; ordinary formatting, not an edge case. `(?:.\|\n)*'
            ;; is `expose-orm-strip-binding''s own fix for the exact
            ;; same trap, right above this function; that one and this
            ;; one only ever failed together, silently, once anything
            ;; past the first line existed.
            ((string-match "\\`self\\.\\(\\(?:.\\|\n\\)*\\)\\'" expression))
            (rest (match-string 1 expression))
            (class (expose-orm-enclosing-class)))

      (progn
        (expose-log
         "orm"
         "Resolved leading `self.' to `%s.' (from %s)"
         class
         expression)
        (concat class "." rest))

    expression))

(defun expose-orm-local-self-alias (name)
  "Return the `self.ATTR' NAME is a simple alias for, or nil.

Looks for a `NAME = self.ATTR' assignment -- a bare attribute access,
no further chaining -- earlier in the enclosing method: the
`queryset = self.queryset' line a `get_queryset' override that narrows
the class's own `queryset' typically begins with. Nothing more general
than that one shape is attempted -- a further reassignment
(`queryset = queryset.filter(...)') does not match it, so this always
finds the *original* alias regardless of how many chained
reassignments came after it in the same method (including across an
`if'/`else' that each build on it differently, exactly the shape a
`get_queryset' override narrowing by branch tends to have), and never
mistakes an intermediate one for it."

  (when (expose-orm-enclosing-class)
    (save-excursion
      (let ((search-end (point))
            found)
        (beginning-of-defun)
        (while (re-search-forward
                (concat "^[ \t]*" (regexp-quote name)
                        "[ \t]*=[ \t]*self\\.\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*$")
                search-end t)
          (setq found (match-string 1)))
        found))))

(defun expose-orm-resolve-local-alias (expression)
  "Return EXPRESSION with a leading local alias for `self.ATTR' resolved.

`queryset = self.queryset' followed later by `queryset.filter(...)' is
the standard shape of a `get_queryset' override that starts from the
class's own queryset and narrows it from there -- resolvable the same
way a direct `self.queryset.filter(...)' already is, one hop further
back: find where the leading name was assigned from a bare
`self.ATTR' earlier in the same method (see
`expose-orm-local-self-alias'), and splice that in for it, leaving
`expose-orm-resolve-self' to take it the rest of the way to the
enclosing class."

  (if-let* (((string-match "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)\\." expression))
            (name (match-string 1 expression))
            ((not (equal name "self")))
            ;; Captured before calling `expose-orm-local-self-alias':
            ;; its own `re-search-forward' (over the buffer, not this
            ;; string) clobbers the global match data the `string-match'
            ;; above set, so `(match-end 1)' read afterward would name a
            ;; *buffer* position instead of an offset into EXPRESSION --
            ;; wildly out of range for `substring' below, when it
            ;; doesn't just silently splice the wrong thing in.
            (rest (substring expression (length name)))
            (attr (expose-orm-local-self-alias name)))

      (concat "self." attr rest)

    expression))

(defun expose-orm-expression ()
  "Return the queryset expression to inspect.

The region when there is one, otherwise the whole statement at point --
which is what you want for a chain wrapped across several lines, where
the current line alone is a fragment. A leading local alias for
`self.ATTR' is resolved first (see `expose-orm-resolve-local-alias'),
then a leading `self.' is resolved to its enclosing class (see
`expose-orm-resolve-self') -- in that order, since the alias
resolution's own job is turning the first shape into the second."

  (expose-orm-resolve-self
   (expose-orm-resolve-local-alias
    (expose-orm-strip-binding
     (if (use-region-p)
         (buffer-substring-no-properties (region-beginning) (region-end))
       (save-excursion
         (let ((start (progn (python-nav-beginning-of-statement) (point)))
               (end (progn (python-nav-end-of-statement) (point))))
           (buffer-substring-no-properties start end))))))))

(defun expose-orm-project-root ()
  "Return the directory holding `manage.py', or nil."

  (when buffer-file-name
    (locate-dominating-file buffer-file-name "manage.py")))

(defun expose-orm-module ()
  "Return the dotted module path of the current file, or nil.

Derived from the path below `manage.py', which is the same layout the
container sees -- the code is mounted at a different absolute path, but
the package structure, and so the importable name, is identical."

  (when-let* ((root (expose-orm-project-root))
              (file buffer-file-name)
              ((string-suffix-p ".py" file)))
    (let* ((relative (file-relative-name (file-name-sans-extension file) root))
           (dotted (replace-regexp-in-string "/" "." relative)))
      (unless (string-prefix-p "." dotted)
        (replace-regexp-in-string "\\.__init__\\'" "" dotted)))))

;;; ---------------------------------------------------------------------------
;;; Running it in the project's environment
;;; ---------------------------------------------------------------------------

(defun expose-orm-target-container ()
  "Return the container to run in, or nil to run locally."

  (or expose-orm-container
      (bound-and-true-p jsoa/docker-jump-container)))

(defun expose-orm-command (payload)
  "Return the command list that runs the analysis, given PAYLOAD as JSON."

  (let ((container (expose-orm-target-container)))
    (if container
        (append (list "docker" "exec" "-i"
                      "-e" (concat "EXPOSE_ORM_PAYLOAD=" payload))
                (when expose-orm-workdir (list "-w" expose-orm-workdir))
                (list container expose-orm-python "manage.py" "shell"))
      (list expose-orm-python "manage.py" "shell"))))

(defun expose-orm-extract (output)
  "Return the JSON object between the markers in OUTPUT, or nil.

Delimited rather than parsed whole because `manage.py shell' is free to
print banners, warnings and deprecation notices around it."

  (when (and (string-match (regexp-quote expose-orm-begin) output)
             (string-match (regexp-quote expose-orm-end) output))
    (let* ((start (+ (string-match (regexp-quote expose-orm-begin) output)
                     (length expose-orm-begin)))
           (end (string-match (regexp-quote expose-orm-end) output start)))
      (ignore-errors
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-false nil)
              (json-null nil))
          (json-read-from-string (substring output start end)))))))

;;; ---------------------------------------------------------------------------
;;; Presentation
;;; ---------------------------------------------------------------------------

(defun expose-orm-findings (result)
  "Return a list of (LEVEL . TEXT) read off RESULT.

Ordered worst first. The findings are the point of the command: the SQL
alone tells you what will run, but not which part of it is the problem."

  (let ((findings nil)
        (filters (alist-get 'filters result))
        (ordering (alist-get 'ordering result))
        (joins (alist-get 'joins result))
        (relations (alist-get 'relations result))
        (selected (alist-get 'select_related_fields result)))

    (dolist (filter filters)
      (unless (alist-get 'indexed filter)
        (push (cons 'warn
                    (format "filters %s.%s (%s) -- %s"
                            (alist-get 'table filter)
                            (alist-get 'column filter)
                            (alist-get 'lookup filter)
                            (alist-get 'why filter)))
              findings)))

    (dolist (term ordering)
      (when (eq (alist-get 'indexed term) nil)
        (when (alist-get 'why term)
          (push (cons 'warn
                      (format "orders by %s (%s) -- %s"
                              (alist-get 'term term)
                              (alist-get 'source term)
                              (alist-get 'why term)))
                findings))))

    ;; An unbounded query is fine until the table grows, which is exactly
    ;; when nobody is looking at the queryset any more.
    (unless (alist-get 'high_mark result)
      (push (cons 'warn "no LIMIT -- fetches every matching row") findings))

    ;; Only worth raising when nothing is being pulled in already: a
    ;; queryset with select_related has clearly had the thought.
    (when (and relations (not selected))
      (push (cons 'note
                  (format "no select_related; touching %s per row is a query each"
                          (string-join relations ", ")))
            findings))

    (when (and (alist-get 'distinct result) joins)
      (push (cons 'note "distinct() over a join -- often masking row duplication")
            findings))

    (nreverse findings)))

(defun expose-orm-render-sql (sql)
  "Return SQL fontified via `sql-mode'.

The same trick `expose-popup-render-body' uses for Markdown: insert
into a temp buffer already in the real major mode, `font-lock-ensure'
it, and take the propertized text back out -- a real mode's own
font-lock, not a hand-rolled keyword list to keep in sync with
whatever SQL Django's next version starts generating."

  (with-temp-buffer
    (delay-mode-hooks
      (sql-mode))

    (font-lock-mode 1)

    (insert sql)

    (font-lock-ensure (point-min) (point-max))

    (buffer-string)))

(defun expose-orm-insert (result expression)
  "Render RESULT for EXPRESSION into the current buffer."

  (let ((inhibit-read-only t))
    (erase-buffer)

    (insert (propertize "Queryset SQL" 'face 'bold))
    (insert "\n")
    (insert (propertize (make-string 60 ?─) 'face 'shadow))
    (insert "\n\n")

    (insert (propertize expression 'face 'font-lock-string-face) "\n\n")

    (if-let ((error-text (alist-get 'error result)))
        (progn
          (insert (propertize
                   (if (alist-get 'refused result) "Refused\n" "Failed\n")
                   'face 'error))
          (insert "  " error-text "\n"))

      (insert (format "%s  ->  %s\n"
                      (propertize (alist-get 'model result) 'face 'font-lock-type-face)
                      (alist-get 'table result)))

      (dolist (finding (expose-orm-findings result))
        (insert (propertize (if (eq (car finding) 'warn) "  ! " "  - ")
                            'face (if (eq (car finding) 'warn) 'warning 'shadow))
                (cdr finding) "\n"))

      (when-let ((joins (alist-get 'joins result)))
        (insert "\n")
        (dolist (join joins)
          (insert (format "  %s %s\n"
                          (propertize (alist-get 'type join) 'face 'shadow)
                          (alist-get 'table join)))))

      (insert "\n")
      (if-let ((sql (alist-get 'sql result)))
          (insert (expose-orm-render-sql sql) "\n")
        (insert (propertize (or (alist-get 'sql_note result) "no SQL") 'face 'shadow)
                "\n")))

    (when-let ((note (alist-get 'note result)))
      (insert "\n" (propertize (concat "note: " note) 'face 'shadow) "\n"))

    (goto-char (point-min))))

(defun expose-orm-display (result expression source-window)
  "Show RESULT for EXPRESSION in the Expose ORM buffer.

Placed beside SOURCE-WINDOW -- see `expose-side-panel-place' -- the
window the query was inspected from, captured well before this runs:
the subprocess this is a callback for is asynchronous, so the selected
window by the time a result comes back may be anywhere."

  (let ((buffer (get-buffer-create expose-orm-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (expose-orm-insert result expression))
    (select-window (expose-side-panel-place source-window buffer))))

;;; ---------------------------------------------------------------------------
;;; Command
;;; ---------------------------------------------------------------------------

(defun expose-orm-run (extra source-window callback)
  "Analyse the queryset at point, adding EXTRA to the payload.

CALLBACK receives the parsed result, the expression, and SOURCE-WINDOW
(passed through unchanged, for CALLBACK to place its own result
beside -- this function has no display of its own to place). Shared by
`expose-orm-inspect' and `expose-orm-explain', which differ only in what
they ask for and what they do with the answer."

  (let ((root (expose-orm-project-root)))
    (unless root
      (user-error "No manage.py above %s -- not a Django project"
                  (or buffer-file-name "this buffer")))

    (let* ((expression (expose-orm-expression))
           (module (expose-orm-module))
           (payload (json-encode
                     (append `((expression . ,expression) (module . ,module))
                             extra)))
           (command (expose-orm-command payload))
           (script (with-temp-buffer
                     (insert-file-contents expose-orm-script)
                     (buffer-string)))
           (output "")
           (default-directory root)
           ;; Only meaningful when running locally; the container gets it
           ;; through `docker exec -e' instead.
           (process-environment
            (cons (concat "EXPOSE_ORM_PAYLOAD=" payload) process-environment)))

      (when (string-empty-p (string-trim expression))
        (user-error "Nothing to inspect at point"))

      (expose-log "orm" "Inspecting %s (module %s)" expression (or module "none"))

      (let ((process
             (make-process
              :name "expose-orm"
              :buffer nil
              :noquery t
              :connection-type 'pipe
              :command command
              :filter (lambda (_process chunk) (setq output (concat output chunk)))
              :sentinel
              (lambda (_process event)
                (when (string-match-p "\\`\\(finished\\|exited\\|deleted\\)" event)
                  ;; Deferred out of the sentinel: the callback may render a
                  ;; diagram, and running a subprocess from inside a
                  ;; sentinel deadlocks on the thread holding this one.
                  (let ((result (expose-orm-extract output))
                        (raw output))
                    (run-at-time
                     0 nil
                     (lambda ()
                       (if result
                           (funcall callback result expression source-window)
                         (expose-log "orm" "No result in output: %s" raw)
                         (expose-orm-display
                          `((error . ,(format "the project's Python produced no result.%s"
                                              (if (string-empty-p (string-trim raw))
                                                  " It printed nothing at all."
                                                (concat "\n\n" (string-trim raw))))))
                          expression
                          source-window))))))))))

        (process-send-string process script)
        (process-send-eof process)))))

;;;###autoload
(defun expose-orm-inspect ()
  "Show the SQL a Django queryset compiles to, and what will make it slow.

Uses the region when there is one, otherwise the statement at point.
Runs in the project's own Python -- inside `expose-orm-container' when
one is configured -- so the SQL is Django's, not a reconstruction.

No database connection is opened, and expressions containing writes are
refused rather than evaluated."

  (interactive)

  (message "Expose ORM: compiling...")
  (expose-orm-run nil (selected-window) #'expose-orm-display))

;;;###autoload
(defun expose-orm-explain (&optional analyze)
  "Draw the query plan for the Django queryset at point.

With a prefix argument, ANALYZE: the query is actually executed, and the
plan carries real row counts and timings instead of the planner's
estimates -- which is the only way to see where an estimate was wrong,
and the reason most bad plans are bad.

Unlike `expose-orm-inspect', this connects: EXPLAIN needs the planner's
statistics. It runs against `expose-orm-dsn' if set, otherwise the
`expose-orm-database' alias, so the plan can be taken from a replica
rather than whatever the project's settings point at. The transaction is
rolled back either way, and `expose-orm-statement-timeout' bounds it."

  (interactive "P")

  (unless (executable-find expose-diagram-dot-executable)
    (user-error "Graphviz `%s' not found on PATH; needed to draw the plan"
                expose-diagram-dot-executable))

  (when (and analyze
             (not (yes-or-no-p
                   "EXPLAIN ANALYZE runs the query for real. Continue? ")))
    (user-error "Cancelled"))

  (message "Expose ORM: asking the database for a plan...")

  (expose-orm-run
   `((explain . t)
     (analyze . ,(if analyze t :json-false))
     (database . ,expose-orm-database)
     (dsn . ,expose-orm-dsn)
     (timeout_ms . ,expose-orm-statement-timeout))
   (selected-window)
   #'expose-orm-display-plan))

(defun expose-orm-display-plan (result expression source-window)
  "Draw the plan in RESULT for EXPRESSION, or explain why there isn't one.

SOURCE-WINDOW is only used by the fallback-to-static-view paths below,
via `expose-orm-display' -- the successful, diagram-drawing path is
unaffected by any of this and keeps its own full-frame display."

  (let ((plan (alist-get 'plan result))
        (plan-error (or (alist-get 'plan_error result) (alist-get 'error result))))

    (cond
     ((and (null plan) plan-error)
      ;; Falling back to the static view rather than only an error: the
      ;; SQL and findings are still there, and are what you would have
      ;; asked for next anyway.
      (expose-orm-display
       (cons (cons 'note (format "no plan: %s" plan-error)) result)
       expression
       source-window)
      (message "Expose ORM: no plan (%s)" plan-error))

     ((null plan)
      (expose-orm-display result expression source-window)
      (message "Expose ORM: the database returned no plan"))

     (t
      (let* ((analyzed (alist-get 'analyzed result))
             (total (expose-orm-plan-total-time plan))
             (title (format "%s%s%s"
                            (or (alist-get 'model result) "query")
                            (if analyzed "  -- analyzed" "  -- estimated")
                            (if total (format ", %.1f ms" total) "")))
             (dot (expose-orm-plan-to-dot plan title))
             (origin (list (current-buffer) (point) #'expose-orm-explain))
             (rendered (expose-diagram-render-svg dot nil "BT")))

        (if (car rendered)
            (progn
              (expose-diagram-display (cdr rendered) dot "Query Plan" origin)
              (message "Expose ORM: plan drawn"))

          (expose-log "orm" "Plan: dot failed: %s" (cdr rendered))
          (expose-diagram-display-failure dot (cdr rendered) "Query Plan")
          (message "Expose ORM: dot failed")))))))

(provide 'expose-orm)
