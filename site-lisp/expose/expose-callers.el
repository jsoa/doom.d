;;; expose-callers.el -*- lexical-binding: t; -*-

;;; Reverse call graph: what calls this, and what calls those.
;;;
;;; Deliberately not AI-generated, unlike the other Expose diagrams.
;;; Those describe the code in front of them; this one has to know the
;;; whole project, which is exactly what a provider can't see -- asked
;;; anyway, it produces confident, plausible, wrong callers. That's the
;;; worst possible failure for a graph whose whole purpose is answering
;;; "is it safe to change this?", so the edges here come from the same
;;; index the editor navigates with, and the result is exact.
;;;
;;; Two sources, in order of preference:
;;;
;;; - LSP call hierarchy (`callHierarchy/incomingCalls'), which means
;;;   actual calls, resolved by the language server.
;;; - `xref-find-references' otherwise: available everywhere, but it
;;;   reports *references*, so an import or a same-named attribute can
;;;   ride along. Marked as such on the graph rather than passed off as
;;;   equivalent.

(require 'cl-lib)
(require 'subr-x)
(require 'xref)
(require 'expose-log)

(declare-function lsp-request "lsp-mode" (method params &rest args))
(declare-function lsp-feature? "lsp-mode" (feature))
(declare-function lsp-get "lsp-protocol" (from key))
(declare-function lsp--text-document-position-params "lsp-mode" ())
(declare-function lsp--make-reference-params "lsp-mode" (&optional td-position exclude-declaration))
(declare-function lsp--uri-to-path "lsp-mode" (uri))

(defgroup expose-callers nil
  "Reverse call graph for Expose."
  :group 'expose)

(defcustom expose-callers-max-depth 3
  "How many levels of callers to walk up.

Kept low on purpose: fan-in grows much faster than fan-out. A leaf
helper has three callers; something like `get_object_or_404' has
hundreds, and every extra level multiplies both the wait and the
unreadability."
  :type 'integer
  :group 'expose-callers)

(defcustom expose-callers-max-nodes 40
  "Maximum functions to include before the walk stops.

A hard stop on the total, separate from `expose-callers-max-depth':
one heavily-called function part-way up would otherwise blow past any
depth limit on its own. Nodes whose callers were cut off are marked on
the graph rather than silently truncated."
  :type 'integer
  :group 'expose-callers)

(defcustom expose-callers-include-references t
  "Whether to include non-call references alongside actual calls.

LSP call hierarchy reports calls only, so a function that is *referenced*
rather than invoked -- registered in a dispatch table, passed as a
callback, listed in `urlpatterns', handed to a decorator -- comes back
with no callers at all and reads as dead code. That's the most dangerous
way for this graph to be wrong, since the whole point is deciding
whether something is safe to change or remove.

These edges are drawn dashed and labelled, never mixed in with resolved
calls: a reference is weaker evidence, and `xref' can't always tell a
genuine usage from a same-named symbol."
  :type 'boolean
  :group 'expose-callers)

(defcustom expose-callers-exclude-regexps
  '("/tests?/"
    "/testing/"
    "/spec/"
    "_test\\.[a-z]+\\'"
    "\\`test_"
    "/test_[^/]*\\'"
    "\\.test\\.[a-z]+\\'"
    "\\.spec\\.[a-z]+\\'"
    "/conftest\\.py\\'"
    "/__tests__/")
  "Paths whose callers are left out of the reverse call graph.

Tests call everything, so including them buries the production call
paths -- which are the ones that answer whether a change is safe --
under a drift of fixtures. Matched against the full path, so a
directory pattern catches everything beneath it."
  :type '(repeat regexp)
  :group 'expose-callers)

(defcustom expose-callers-graph-direction "LR"
  "Graphviz `rankdir' for the caller and test graphs.

`LR' rather than `BT', which reads more naturally for \"callers above,
callee below\" but lays out terribly for the shape these graphs actually
have. Both fan in: many callers converge on one target, and every one of
them lands in the same rank. With `BT' that rank runs along the X axis,
so eighteen tests produced a graph 6686 points wide and 136 tall -- a
ribbon too flat to read at any zoom. The same graph in `LR' is 674 by
998, because the fan becomes a column."
  :type '(choice (const :tag "Left to right" "LR")
                 (const :tag "Bottom to top" "BT")
                 (const :tag "Top to bottom" "TB")
                 (const :tag "Right to left" "RL"))
  :group 'expose-callers)

;;; ---------------------------------------------------------------------------
;;; Nodes
;;; ---------------------------------------------------------------------------

;; A node is a plist: (:name NAME :file FILE :line LINE :truncated BOOL)
;; keyed for identity by `expose-callers-node-key'.

(defun expose-callers-node-key (node)
  "Return a stable identity for NODE.

File plus name rather than name alone: two modules routinely define
`handle' or `save', and collapsing them would invent call paths that
don't exist."

  (format "%s::%s"
          (or (plist-get node :file) "?")
          (or (plist-get node :name) "?")))

(defun expose-callers-excluded-p (file)
  "Return non-nil if FILE is excluded by `expose-callers-exclude-regexps'."

  (when file
    (let ((path (expand-file-name file)))
      (seq-some
       (lambda (regexp) (string-match-p regexp path))
       expose-callers-exclude-regexps))))

(defun expose-callers-test-p (file)
  "Return non-nil if FILE looks like a test.

Deliberately the same patterns as `expose-callers-exclude-regexps': the
list that answers \"leave tests out of the production call graph\" is the
same one that answers \"this is a test\", and keeping a second copy in
sync would be a way to make the two disagree."

  (expose-callers-excluded-p file))

(defun expose-callers-relative-file (file)
  "Return FILE relative to its project root, for display."

  (when file
    (if-let* ((project (project-current nil (file-name-directory file)))
              (root (project-root project)))
        (file-relative-name file root)
      (file-name-nondirectory file))))

;;; ---------------------------------------------------------------------------
;;; Source: LSP call hierarchy
;;; ---------------------------------------------------------------------------

(defun expose-callers-lsp-available-p ()
  "Return non-nil if the language server can answer call hierarchy here."

  (and (bound-and-true-p lsp-mode)
       (fboundp 'lsp-feature?)
       (lsp-feature? "textDocument/prepareCallHierarchy")))

(defun expose-callers-lsp-item-to-node (item)
  "Convert an LSP CallHierarchyItem ITEM to a node plist.

Read with `lsp-get' rather than `gethash': lsp-mode represents protocol
objects as plists when built with `lsp-use-plists' (as this one is) and
as hash tables otherwise, and `lsp-get' takes a keyword and does the
right thing either way. `gethash' works only in the second case, and
fails with a `hash-table-p' type error in the first."

  (let* ((uri (lsp-get item :uri))
         (file (and uri (lsp--uri-to-path uri)))
         (range (or (lsp-get item :selectionRange)
                    (lsp-get item :range)))
         (start (and range (lsp-get range :start))))

    (list :name (lsp-get item :name)
          :file file
          :line (when start (1+ (or (lsp-get start :line) 0))))))

(defun expose-callers-lsp-prepare ()
  "Return the LSP call hierarchy item(s) at point, as node plists.

Each node carries the raw protocol object on `:item': call hierarchy is
stateful, in that the server hands back opaque items it expects to
receive verbatim on the follow-up `incomingCalls' request. Keeping it
here means the walk never has to ask for the same thing twice."

  (when-let ((items
              (expose-callers-lsp-request
               "textDocument/prepareCallHierarchy"
               (lsp--text-document-position-params))))
    (mapcar
     (lambda (item)
       (append (expose-callers-lsp-item-to-node item)
               (list :item item)))
     (append items nil))))

(defvar expose-callers-lsp-failures nil
  "Requests that failed during the current walk, newest first.

Bound around a walk by `expose-callers-collect'. A graph built while
some of these failed is a partial graph, and has to say so.")

(defun expose-callers-incomplete-note ()
  "Return a label fragment naming unanswered requests, or an empty string.

A graph missing branches because the server timed out looks exactly like
a graph with nothing there -- and this one is read to decide whether
something is safe to change, so the difference matters more here than
almost anywhere."

  (if expose-callers-lsp-failures
      (format "  (incomplete: %d lookup%s failed)"
              (length expose-callers-lsp-failures)
              (if (= 1 (length expose-callers-lsp-failures)) "" "s"))
    ""))

(defun expose-callers-signal-nothing (format-string &rest args)
  "Signal that nothing was found -- or that the search never finished.

Those are opposite answers, and the second must never be reported as the
first. \"Nothing calls this\" and \"no test reaches this\" are what
somebody acts on before deleting code, so a search cut short by a server
that stopped answering has to say so rather than return a confident
negative."

  (if expose-callers-lsp-failures
      (user-error "%s -- but %d lookup%s failed, so the search did not finish (see the Expose log)"
                  (apply #'format format-string args)
                  (length expose-callers-lsp-failures)
                  (if (= 1 (length expose-callers-lsp-failures)) "" "s"))
    (user-error "%s" (apply #'format format-string args))))

(defun expose-callers-lsp-request (method params)
  "Send METHOD with PARAMS, returning nil if the server does not answer.

`lsp-request' signals on a timeout, and the call hierarchy walk makes one
request per node -- so a single slow answer aborted the whole command and
threw away every caller already found. On a large project that is the
common case, not the rare one: the widely-called function whose callers
you most want is exactly the one the server takes longest to enumerate.

Failing one branch loses that branch. The count is kept so the graph can
admit what it did not see."

  (condition-case err
      (lsp-request method params)
    (error
     (push (format "%s: %s" method (error-message-string err))
           expose-callers-lsp-failures)
     (expose-log "Callers" "%s failed: %s" method (error-message-string err))
     nil)))

(defun expose-callers-lsp-incoming (node)
  "Return the callers of NODE via LSP, as node plists.

NODE must carry the raw `:item' it came from; call hierarchy is
stateful in that the server hands back opaque items to ask about."

  (when-let* ((item (plist-get node :item))
              (calls (expose-callers-lsp-request "callHierarchy/incomingCalls"
                                                 (list :item item))))
    (delq
     nil
     (mapcar
      (lambda (call)
        (when-let ((from (lsp-get call :from)))
          (append (expose-callers-lsp-item-to-node from)
                  (list :item from))))
      (append calls nil)))))

;;; ---------------------------------------------------------------------------
;;; Source: xref
;;; ---------------------------------------------------------------------------

(defun expose-callers-enclosing-defun (file line)
  "Return the name of the function enclosing LINE in FILE, or nil.

xref reports a position, not a caller, so the calling function has to
be recovered from the buffer. `add-log-current-defun' is what Emacs
already uses for this and is major-mode aware."

  (when (and file (file-readable-p file))
    (with-current-buffer (find-file-noselect file t)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (forward-line (1- (or line 1)))
          (ignore-errors (add-log-current-defun)))))))

(defun expose-callers-location-to-node (location kind)
  "Convert an LSP Location LOCATION to a node plist stamped with KIND.

Attributes the reference to the function containing it, or -- when it
sits outside any function, as a registration like `validators=[fn]'
does -- to the file itself."

  (when-let* ((uri (lsp-get location :uri))
              (file (lsp--uri-to-path uri))
              (range (lsp-get location :range))
              (start (lsp-get range :start))
              (line (1+ (or (lsp-get start :line) 0))))

    (let ((name (expose-callers-enclosing-defun file line)))
      (if name
          (list :name name :file file :line line :kind kind)
        (list :name (file-name-nondirectory file)
              :file file :line line :kind kind :module t)))))

(defun expose-callers-lsp-references ()
  "Return everything referring to the symbol at point, via LSP.

Requests `textDocument/references' directly rather than going through
xref. lsp-mode's xref backend only accepts an identifier string carrying
an `identifier-at-point' text property, or one already in its symbol
cache; handed a plain name it signals \"Unable to find symbol\" -- which
is what made this silently find nothing.

Declarations are excluded at the protocol level, so the definition
doesn't come back as a reference to itself."

  (when-let ((locations
              (expose-callers-lsp-request "textDocument/references"
                           (lsp--make-reference-params nil t))))

    (delq nil
          (mapcar
           (lambda (location)
             (expose-callers-location-to-node location 'reference))
           (append locations nil)))))

(defun expose-callers-xref-nodes (identifier kind)
  "Return the places referring to IDENTIFIER via `xref', as node plists.

KIND is stamped on each result (`call' or `reference') so the caller can
render the two differently.

A reference outside any function -- the module-level `handlers =
[my_function]' case -- becomes a node for the *file* rather than being
dropped. Dropping it is what made a registered-but-never-called function
look uncalled, which is precisely the case this is here to catch."

  (when-let* ((backend (ignore-errors (xref-find-backend)))
              (refs (ignore-errors
                      (xref-backend-references backend identifier))))

    (delq
     nil
     (mapcar
      (lambda (ref)
        (let* ((location (xref-item-location ref))
               (file (ignore-errors (xref-location-group location)))
               (line (ignore-errors (xref-location-line location)))
               (name (and file (expose-callers-enclosing-defun file line))))

          (when file
            (if name
                (list :name name :file file :line line :kind kind)

              ;; Module level: no enclosing function to attribute this to.
              (list :name (file-name-nondirectory file)
                    :file file
                    :line line
                    :kind kind
                    :module t)))))
      refs))))

(defun expose-callers-xref-incoming (identifier)
  "Return callers of IDENTIFIER found via `xref', as node plists."

  (expose-callers-xref-nodes identifier 'call))

;;; ---------------------------------------------------------------------------
;;; Walk
;;; ---------------------------------------------------------------------------

(defun expose-callers-collect (root use-lsp &optional root-references)
  "Walk callers upward from ROOT, returning (NODES . EDGES).

ROOT-REFERENCES are non-call usages of ROOT, gathered by the caller
while point was still on the symbol (see `expose-callers-lsp-references').

Breadth-first so the caps bite evenly across the graph rather than
exhausting themselves down one deep branch. NODES is a hash of key to
node; EDGES is a list of (CALLER-KEY . CALLEE-KEY).

Terminates on three independent conditions, because any one alone is
insufficient: `expose-callers-max-depth', `expose-callers-max-nodes',
and a visited set -- the last being what stops mutual recursion from
looping forever."

  (let ((nodes (make-hash-table :test 'equal))
        (edges nil)
        (queue (list (cons root 0)))
        (visited (make-hash-table :test 'equal)))

    (puthash (expose-callers-node-key root) root nodes)

    (while queue
      (let* ((entry (pop queue))
             (node (car entry))
             (depth (cdr entry))
             (key (expose-callers-node-key node)))

        (unless (or (gethash key visited)
                    (>= depth expose-callers-max-depth))

          (puthash key t visited)

          (let* ((callers
                  (mapcar
                   (lambda (c) (plist-put (copy-sequence c) :kind 'call))
                   (if use-lsp
                       (expose-callers-lsp-incoming node)
                     (expose-callers-xref-incoming (plist-get node :name)))))

                 (call-keys
                  (mapcar #'expose-callers-node-key callers))

                 ;; References that aren't already accounted for by a
                 ;; resolved call.
                 ;;
                 ;; Only for the root, and only from the list gathered
                 ;; before the walk began: `textDocument/references'
                 ;; answers about the symbol at *point*, so asking again
                 ;; from here -- point having never moved -- would return
                 ;; the root's references over and over and attribute
                 ;; them to whichever node was being expanded.
                 (references
                  (when (and expose-callers-include-references
                             (= depth 0))
                    (seq-remove
                     (lambda (r)
                       (member (expose-callers-node-key r) call-keys))
                     root-references))))

            (dolist (caller (append callers references))
              (let ((caller-file (plist-get caller :file))
                    (caller-key (expose-callers-node-key caller)))

                (cond
                 ((expose-callers-excluded-p caller-file)
                  nil)

                 ;; The definition site itself: xref reports it as a
                 ;; reference, which would otherwise draw a self-loop.
                 ((equal caller-key key)
                  nil)

                 ;; Node budget spent: record that this node has more
                 ;; callers rather than implying it has none.
                 ((>= (hash-table-count nodes) expose-callers-max-nodes)
                  (puthash key
                           (plist-put (gethash key nodes) :truncated t)
                           nodes))

                 (t
                  (unless (gethash caller-key nodes)
                    (puthash caller-key caller nodes))

                  (cl-pushnew (list caller-key key (plist-get caller :kind))
                              edges :test #'equal)

                  ;; A module isn't called by anything, so there's
                  ;; nothing above it to walk to.
                  (unless (plist-get caller :module)
                    (push (cons caller (1+ depth)) queue))))))))))

    (cons nodes (nreverse edges))))

;;; ---------------------------------------------------------------------------
;;; DOT
;;; ---------------------------------------------------------------------------

(defun expose-callers-escape (text)
  "Escape TEXT for use inside a quoted DOT label."

  (replace-regexp-in-string "\"" "\\\\\"" (or text "")))

(defun expose-callers-node-id (key)
  "Return a DOT-safe identifier for node KEY."

  (concat "n" (substring (secure-hash 'sha1 key) 0 12)))

(defun expose-callers-to-dot (graph root exact)
  "Render GRAPH (from `expose-callers-collect') as Graphviz DOT.

ROOT is the node the walk started from; EXACT says whether the edges
came from LSP call hierarchy rather than `xref', which is noted on the
graph so a reference-derived approximation is never mistaken for a
resolved call list."

  (let* ((nodes (car graph))
         (edges (cdr graph))
         (root-key (expose-callers-node-key root))
         (lines nil))

    (push "digraph reverse_calls {" lines)
    (push (format "  rankdir=%s;" expose-callers-graph-direction) lines)
    (push (format "  label=\"callers of %s%s%s\";"
                  (expose-callers-escape (plist-get root :name))
                  (if exact "" "  (from references -- may include non-calls)")
                  (expose-callers-incomplete-note))
          lines)

    (maphash
     (lambda (key node)
       (let* ((id (expose-callers-node-id key))
              (file (expose-callers-relative-file (plist-get node :file)))
              (label
               (format "%s\\n%s%s"
                       (expose-callers-escape
                        (if (plist-get node :module)
                            (format "(module level) %s" (plist-get node :name))
                          (plist-get node :name)))
                       (expose-callers-escape (or file "?"))
                       (if (plist-get node :truncated) "\\n(more callers not shown)" "")))

              ;; The starting point gets the entry shape so the existing
              ;; classifier tints it; module-level usage gets the folder
              ;; shape; everything else is a plain step.
              (shape (cond ((equal key root-key) "ellipse")
                           ((plist-get node :module) "folder")
                           (t "box")))

              (style (if (plist-get node :truncated) ",style=dashed" "")))

         (push (format "  %s [shape=%s,label=\"%s\"%s];" id shape label style)
               lines)))
     nodes)

    (dolist (edge edges)
      (let ((from (expose-callers-node-id (nth 0 edge)))
            (to (expose-callers-node-id (nth 1 edge)))
            (kind (nth 2 edge)))

        (push
         (if (eq kind 'reference)
             ;; Dashed and labelled: a reference is weaker evidence than a
             ;; resolved call, and showing them identically would imply a
             ;; confidence this doesn't have.
             (format "  %s -> %s [style=dashed,label=\"references\",color=\"%s\",fontcolor=\"%s\"];"
                     from to "#a2792f" "#a2792f")
           (format "  %s -> %s;" from to))
         lines)))

    (push "}" lines)

    (mapconcat #'identity (nreverse lines) "\n")))

;;; ---------------------------------------------------------------------------
;;; Tests reaching a symbol
;;; ---------------------------------------------------------------------------

(defcustom expose-callers-test-mention-limit 40
  "Maximum textual mentions of a symbol to collect from test files."
  :type 'integer
  :group 'expose-callers)

(defun expose-callers-test-mentions (name)
  "Return test-file nodes that mention NAME textually.

Static analysis misses most of how Django code is actually tested, in
three separate ways:

  self.client.post(url)            reaches a view through runtime URL
                                   resolution -- no call edge exists
  @patch(\"app.utils.thing\")        names its target in a string
  class ThingViewSetTest(...)      never names the thing at all, and is
                                   tied to it only by convention

The last is the common case for DRF viewsets and the one a plain
word-boundary search still misses, since `ThingViewSetTest' is a
different identifier than `Thing ViewSet'. So the pattern also allows a
`Test'/`TestCase' affix on either side.

Deliberately no looser than that: bare substring matching would tie
`send_email' to `send_email_task', which is a different function. This
is weaker evidence than a call either way -- a mention could be a
comment -- so these render distinctly rather than counting as the same
thing."

  (when-let* ((project (project-current nil))
              (root (expand-file-name (project-root project))))

    (with-temp-buffer
      (let ((status
             (ignore-errors
               (call-process
                "grep" nil t nil
                "-rnE"
                "--include=test_*.py" "--include=*_test.py"
                "--include=*.spec.ts" "--include=*.test.ts"
                "--include=*.spec.js" "--include=*.test.js"
                "--include=conftest.py"
                "--"
                (format "\\b(Test)?%s(Test|TestCase|Tests)?\\b"
                        (regexp-quote name))
                root))))

        ;; grep exits 1 for "no matches", which is not an error here.
        (when (memq status '(0 1))
          (let (nodes (count 0))
            (goto-char (point-min))

            (while (and (< count expose-callers-test-mention-limit)
                        (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t))
              (let* ((file (match-string 1))
                     (line (string-to-number (match-string 2)))
                     (enclosing (expose-callers-enclosing-defun file line)))

                (setq count (1+ count))

                (push (list :name (or enclosing (file-name-nondirectory file))
                            :file file
                            :line line
                            :kind 'mention
                            :module (null enclosing))
                      nodes)))

            ;; One node per test function, not per occurrence.
            (cl-remove-duplicates
             (nreverse nodes)
             :test #'equal
             :key #'expose-callers-node-key)))))))

(defun expose-callers-url-names (symbol)
  "Return the URL names that route to SYMBOL, from the project's urls.py files.

The genuinely exact link between a Django test and the view it exercises
is the URL name: the test says `reverse(\"user-event-list\")' and never
names the view, so nothing else here can connect the two with certainty.

Parsed rather than obtained from `manage.py show_urls', which would be
authoritative but needs Django settings, an importable app registry and
usually a database -- in a Dockerised project that means a running
container, and this has to work when it isn't. What it costs is the
dynamic cases: `include()' namespaces and routers built in a loop are
not followed.

Handles DRF `router.register(prefix, ViewSet, basename=...)' -- the
basename, from which DRF derives `-list', `-detail' and friends -- and
plain `path(..., View.as_view(), name=...)'."

  (when-let* ((project (project-current nil))
              (root (expand-file-name (project-root project))))

    (let ((names nil)
          (files (ignore-errors
                   (directory-files-recursively root "\\`urls\\.py\\'"))))

      (dolist (file files)
        (with-temp-buffer
          (insert-file-contents file)

          ;; router.register(prefix, ViewSet, basename="name") -- often
          ;; split across lines, so whitespace is matched permissively.
          (goto-char (point-min))
          (while (re-search-forward
                  (concat "router\\.register([ \t\n]*[^,]+,[ \t\n]*"
                          "\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t\n]*,[ \t\n]*"
                          "basename[ \t\n]*=[ \t\n]*[\"']\\([^\"']+\\)[\"']")
                  nil t)
            (when (equal (match-string 1) symbol)
              (push (match-string 2) names)))

          ;; router.register(prefix, ViewSet) with no basename: DRF derives
          ;; one from the model, so the name exists but is written nowhere.
          (goto-char (point-min))
          (while (re-search-forward
                  (concat "router\\.register([ \t\n]*[^,]+,[ \t\n]*"
                          "\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t\n]*,?[ \t\n]*)")
                  nil t)
            (when (equal (match-string 1) symbol)
              (when-let ((derived (expose-callers-drf-default-basename symbol)))
                (push derived names))))

          ;; Plain Django, which needs no DRF at all:
          ;;   path("x/", views.home, name="home")            function view
          ;;   path("x/", HomeView.as_view(), name="home")    class-based
          ;;   path("x/", V.as_view(url="/"), name="home")    with arguments
          ;;   url(r"^x$", view, name="home")                 pre-2.0
          ;;
          ;; `as_view' takes arguments often enough -- RedirectView and
          ;; DRF-Spectacular's views both do -- that requiring empty
          ;; parentheses silently found nothing for them.
          (goto-char (point-min))
          (while (re-search-forward
                  (concat "\\(?:re_path\\|path\\|url\\)([ \t\n]*[^,]+,[ \t\n]*"
                          "\\(?:[A-Za-z_][A-Za-z0-9_.]*\\.\\)?"
                          "\\([A-Za-z_][A-Za-z0-9_]*\\)"
                          "\\(?:\\.as_view([^)]*)\\)?[ \t\n]*,[ \t\n]*"
                          "name[ \t\n]*=[ \t\n]*[\"']\\([^\"']+\\)[\"']")
                  nil t)
            (when (equal (match-string 1) symbol)
              (push (match-string 2) names)))

          ;; `app_name = "x"' namespaces every name in this file, so tests
          ;; reverse "x:home" rather than "home". Both forms are kept: which
          ;; one applies depends on how the module is include()d, which
          ;; isn't visible from here.
          (goto-char (point-min))
          (when (re-search-forward
                 "^[ \t]*app_name[ \t]*=[ \t]*[\"']\\([^\"']+\\)[\"']" nil t)
            (let ((namespace (match-string 1)))
              (dolist (name (copy-sequence names))
                (unless (string-match-p ":" name)
                  (push (concat namespace ":" name) names)))))))

      (delete-dups (nreverse names)))))

(defun expose-callers-drf-default-basename (symbol)
  "Return the basename DRF derives for viewset SYMBOL, or nil.

When `router.register' is called without `basename', DRF falls back to
`queryset.model._meta.object_name.lower()' -- the model's name,
lowercased, with no separators, so `EventHost' becomes `eventhost' and
not `event-host'. Reproducing that exactly matters: guessing a
hyphenated form would silently match nothing.

Found by locating the class and reading the `queryset' assignment in its
body, stopping at the next top-level definition so a later class's
queryset can't be misattributed."

  (when-let* ((project (project-current nil))
              (root (expand-file-name (project-root project))))

    (with-temp-buffer
      (let ((status
             (ignore-errors
               (call-process
                "grep" nil t nil "-rnE" "--include=*.py" "--"
                (format "^class %s\\b" (regexp-quote symbol))
                root))))

        (when (and (eq status 0)
                   (progn (goto-char (point-min))
                          (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t)))

          (let ((file (match-string 1))
                (line (string-to-number (match-string 2))))

            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (forward-line (1- line))

              (let ((bound (save-excursion
                             (forward-line 1)
                             (if (re-search-forward "^\\(class\\|def\\)\\s-" nil t)
                                 (match-beginning 0)
                               (point-max)))))

                (when (re-search-forward
                       "^[ \t]+queryset[ \t]*=[ \t]*\\([A-Za-z_][A-Za-z0-9_]*\\)\\.objects"
                       bound t)
                  (downcase (match-string 1)))))))))))

(defun expose-callers-test-routes (symbol)
  "Return test nodes that reach SYMBOL through `reverse(URL-NAME)'.

The strongest of the non-call signals: unlike a name match, this is an
actual resolution -- the URL name really does route to this view."

  (when-let ((names (expose-callers-url-names symbol)))

    (when-let* ((project (project-current nil))
                (root (expand-file-name (project-root project))))

      (let (nodes)
        (dolist (name names)
          (with-temp-buffer
            (let ((status
                   (ignore-errors
                     (call-process
                      "grep" nil t nil
                      "-rnE"
                      "--include=test_*.py" "--include=*_test.py"
                      "--include=conftest.py"
                      "--"
                      ;; `-list', `-detail' and custom actions all hang off
                      ;; the basename, so match it as a prefix.
                      (format "reverse\\([\"']%s(-[A-Za-z0-9_-]+)?[\"']"
                              (regexp-quote name))
                      root))))

              (when (memq status '(0 1))
                (goto-char (point-min))
                (while (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t)
                  (let* ((file (match-string 1))
                         (line (string-to-number (match-string 2)))
                         (enclosing (expose-callers-enclosing-defun file line)))

                    (push (list :name (or enclosing (file-name-nondirectory file))
                                :file file
                                :line line
                                :kind 'route
                                :route name
                                :module (null enclosing))
                          nodes)))))))

        (cl-remove-duplicates
         (nreverse nodes)
         :test #'equal
         :key #'expose-callers-node-key)))))

(defun expose-callers-test-reachable (nodes edges root-key)
  "Return the subset of node keys that lie on a path from a test to ROOT-KEY.

Every node in the graph already reaches ROOT-KEY -- the walk built it by
climbing from there -- so the question is only which ones a test reaches
in turn. Anything else is a caller that no test goes through, which is
noise when the question is \"what covers this\"."

  (let ((outgoing (make-hash-table :test 'equal))
        (keep (make-hash-table :test 'equal)))

    (dolist (edge edges)
      (push (nth 1 edge) (gethash (nth 0 edge) outgoing)))

    (puthash root-key t keep)

    (maphash
     (lambda (key node)
       (when (expose-callers-test-p (plist-get node :file))
         ;; Walk down from this test toward the root, keeping the whole
         ;; chain: the intermediate functions are how the test reaches
         ;; the code, which is the part worth seeing.
         (let ((queue (list key))
               (seen (make-hash-table :test 'equal)))

           (while queue
             (let ((current (pop queue)))
               (unless (gethash current seen)
                 (puthash current t seen)
                 (puthash current t keep)
                 (setq queue (append queue (gethash current outgoing)))))))))
     nodes)

    keep))

(defun expose-callers-tests-to-dot (nodes edges root keep)
  "Render the test paths in NODES/EDGES reaching ROOT as Graphviz DOT.

KEEP is the set of node keys from `expose-callers-test-reachable'."

  (let* ((root-key (expose-callers-node-key root))
         (test-count 0)
         (lines nil))

    (maphash
     (lambda (key node)
       (when (and (gethash key keep)
                  (not (equal key root-key))
                  (expose-callers-test-p (plist-get node :file)))
         (setq test-count (1+ test-count))))
     nodes)

    (push "digraph tests {" lines)
    (push (format "  rankdir=%s;" expose-callers-graph-direction) lines)
    (push (format "  label=\"%d test%s reaching %s%s\";"
                  test-count
                  (if (= test-count 1) "" "s")
                  (expose-callers-escape (plist-get root :name))
                  (expose-callers-incomplete-note))
          lines)

    (maphash
     (lambda (key node)
       (when (gethash key keep)
         (let* ((id (expose-callers-node-id key))
                (file (expose-callers-relative-file (plist-get node :file)))
                (test (expose-callers-test-p (plist-get node :file)))

                (label
                 (format "%s\\n%s"
                         (expose-callers-escape (plist-get node :name))
                         (expose-callers-escape (or file "?")))))

           (push
            (cond
             ((equal key root-key)
              (format "  %s [shape=ellipse,label=\"%s\"];" id label))

             ;; Explicit fill rather than a shape class: "this is a test"
             ;; isn't one of the semantic categories the shape vocabulary
             ;; encodes, and the styler now leaves stated fills alone.
             (test
              (format "  %s [shape=box,label=\"%s\",style=\"filled,rounded\",fillcolor=\"#e9f6ec\",color=\"#4f9d69\",fontcolor=\"#1d4a2d\"];"
                      id label))

             (t
              (format "  %s [shape=box,label=\"%s\"];" id label)))
            lines))))
     nodes)

    (dolist (edge edges)
      (when (and (gethash (nth 0 edge) keep)
                 (gethash (nth 1 edge) keep))
        (let ((from (expose-callers-node-id (nth 0 edge)))
              (to (expose-callers-node-id (nth 1 edge))))

          (push
           (pcase (nth 2 edge)
             ;; Each weaker than the last, and drawn so: a call is
             ;; resolved, a reference is a real symbol usage, a mention is
             ;; only text that matched.
             ('reference
              (format "  %s -> %s [style=dashed,label=\"references\",color=\"#a2792f\",fontcolor=\"#a2792f\"];"
                      from to))

             ;; A resolved route: the URL name really does map to this
             ;; view, so this is evidence on a par with a call, and
             ;; labelled with the name that proves it.
             ('route
              (format "  %s -> %s [label=\"reverse(%s)\",color=\"#4f9d69\",fontcolor=\"#4f9d69\"];"
                      from to
                      (expose-callers-escape
                       (or (plist-get (gethash (nth 0 edge) nodes) :route) "url"))))

             ('mention
              (format "  %s -> %s [style=dotted,label=\"mentions\",color=\"#8b94a3\",fontcolor=\"#8b94a3\"];"
                      from to))

             (_ (format "  %s -> %s;" from to)))
           lines))))

    (push "}" lines)

    (cons (mapconcat #'identity (nreverse lines) "\n") test-count)))

(defun expose-callers-tests-in (nodes keep)
  "Return the nodes of NODES in KEEP that are themselves tests, sorted.

The graph keeps the intermediate functions a test reaches through, which
are worth drawing but are not themselves an answer to \"what tests
this\" -- so listing them is a different question from graphing them,
answered from the same walk."

  (let ((tests nil))
    (maphash
     (lambda (key node)
       (when (and (gethash key keep)
                  (expose-callers-test-p (plist-get node :file)))
         (push node tests)))
     nodes)

    (sort tests
          (lambda (a b)
            (let ((file-a (or (plist-get a :file) ""))
                  (file-b (or (plist-get b :file) "")))
              (if (string= file-a file-b)
                  (< (or (plist-get a :line) 0) (or (plist-get b :line) 0))
                (string< file-a file-b)))))))

(defun expose-callers-line-text (file line)
  "Return the text of LINE in FILE, or nil.

Read from a buffer already visiting FILE when there is one, so an
unsaved test shows what it currently says rather than what is on disk."

  (when (and file line (file-readable-p file))
    (let ((buffer (find-buffer-visiting file)))
      (if buffer
          (with-current-buffer buffer
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-min))
                (forward-line (1- line))
                (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position)))))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (forward-line (1- line))
          (buffer-substring-no-properties
           (line-beginning-position) (line-end-position)))))))

(defun expose-callers-test-xrefs (tests)
  "Return TESTS as `xref' items.

Presented through xref rather than as a bespoke buffer so the result
looks and behaves like every other list of search results in Emacs:
grouped under its file, the matching line shown in context, `n' and `p'
to move, RET to visit -- and `M-,' back, since visiting from an xref
buffer pushes the marker itself."

  (mapcar
   (lambda (node)
     (let* ((file (plist-get node :file))
            (line (or (plist-get node :line) 1))
            (text (expose-callers-line-text file line)))
       (xref-make
        ;; The source line is the summary, as in a grep result. Falling
        ;; back to the symbol's own name keeps a row that still says
        ;; something when the file has moved on since the walk.
        (if (and text (not (string-blank-p text)))
            (string-trim-right text)
          (or (plist-get node :name) "?"))
        (xref-make-file-location file line 0))))
   tests))

(defun expose-callers-collect-tests ()
  "Return a plist of the tests reaching the symbol at point.

Keys are `:root', `:nodes', `:edges' and `:keep'. Shared by the test
graph and the test list, which differ only in what they do with it."

  (let* ((expose-callers-lsp-failures nil)
         (use-lsp (expose-callers-lsp-available-p))

         (root
          (if use-lsp
              (car (expose-callers-lsp-prepare))
            (let ((name (or (thing-at-point 'symbol t)
                            (user-error "No symbol at point"))))
              (list :name name
                    :file (buffer-file-name)
                    :line (line-number-at-pos))))))

    (unless root
      (expose-callers-signal-nothing "Nothing callable at point"))

    (let* ((root-references
            (when expose-callers-include-references
              (condition-case err
                  (if use-lsp
                      (expose-callers-lsp-references)
                    (expose-callers-xref-nodes (plist-get root :name) 'reference))
                (error
                 (expose-log "Callers" "Reference lookup failed: %s"
                             (error-message-string err))
                 nil))))

           ;; Tests are what we're looking for here, so the exclusion that
           ;; keeps them out of the production graph has to be lifted --
           ;; otherwise this would search for exactly what it filtered.
           (graph
            (let ((expose-callers-exclude-regexps nil))
              (expose-callers-collect root use-lsp root-references)))

           (nodes (car graph))
           (edges (cdr graph))
           (root-key (expose-callers-node-key root)))

      ;; Textual mentions, added as direct edges to the root. They can't
      ;; be walked -- a mention isn't a call, so there's no chain above it
      ;; to follow -- but without them this reports "untested" for the
      ;; large share of Django tests that go through the test client or
      ;; patch by string.
      ;; Routes first: a test found both ways should be recorded by the
      ;; stronger signal, and `cl-pushnew' keeps whichever landed first.
      (dolist (extra (append (expose-callers-test-routes (plist-get root :name))
                             (expose-callers-test-mentions (plist-get root :name))))
        (let ((key (expose-callers-node-key extra)))
          (unless (or (equal key root-key) (gethash key nodes))
            (puthash key extra nodes)
            (cl-pushnew (list key root-key (plist-get extra :kind))
                        edges :test #'equal))))

      (let ((keep (expose-callers-test-reachable nodes edges root-key)))

        (expose-log "Callers" "Tests reaching %s: %d (from %d nodes)."
                    (plist-get root :name)
                    (length (expose-callers-tests-in nodes keep))
                    (hash-table-count nodes))

        (when (null (expose-callers-tests-in nodes keep))
          ;; "Nothing tests this" and "the search did not finish" are
          ;; opposite answers, and the second must never be reported as
          ;; the first: a confident negative about test coverage is
          ;; exactly what someone acts on before deleting code.
          (expose-callers-signal-nothing
           (concat "No test reaches %s: no call path, no reference, "
                   "and no test file mentions it%s")
           (plist-get root :name)
           (if use-lsp
               ""
             " (LSP unavailable, so call paths were not searched)")))

        ;; Carried out with the result: the binding above ends when this
        ;; returns, and the graph is rendered by the caller -- so without
        ;; this the label could never say the walk was incomplete.
        (list :root root :nodes nodes :edges edges :keep keep
              :failures expose-callers-lsp-failures)))))

(defun expose-callers-build-tests-dot ()
  "Return (DOT ROOT-NAME TEST-COUNT) for the tests reaching the symbol at point.

Signals a `user-error' naming the symbol when nothing tests it -- that
being the answer worth stating plainly rather than drawing an empty
graph."

  (let* ((found (expose-callers-collect-tests))
         (root (plist-get found :root))
         (expose-callers-lsp-failures (plist-get found :failures))
         (rendered (expose-callers-tests-to-dot
                    (plist-get found :nodes)
                    (plist-get found :edges)
                    root
                    (plist-get found :keep))))

    (list (car rendered) (plist-get root :name) (cdr rendered))))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun expose-callers-build-dot ()
  "Return (DOT . ROOT-NAME) for the reverse call graph of the symbol at point.

Signals a `user-error' when there is nothing to start from, or when
neither source can answer."

  (let* ((expose-callers-lsp-failures nil)
         (use-lsp (expose-callers-lsp-available-p))

         (root
          (if use-lsp
              (car (expose-callers-lsp-prepare))

            (let ((name (or (thing-at-point 'symbol t)
                            (user-error "No symbol at point"))))
              (list :name name
                    :file (buffer-file-name)
                    :line (line-number-at-pos))))))

    (unless root
      (expose-callers-signal-nothing "Nothing callable at point"))

    (expose-log
     "Callers"
     "Building reverse call graph for %s via %s (depth %d, max %d nodes)."
     (plist-get root :name)
     (if use-lsp "LSP call hierarchy" "xref")
     expose-callers-max-depth
     expose-callers-max-nodes)

    ;; Gathered here, with point still on the symbol, because that's what
    ;; `textDocument/references' keys off. Failures are logged rather than
    ;; swallowed: an `ignore-errors' here previously turned "the server
    ;; rejected the request" into "this function is never used", which is
    ;; the single most misleading thing this command could report.
    (let* ((root-references
            (when expose-callers-include-references
              (condition-case err
                  (if use-lsp
                      (expose-callers-lsp-references)
                    (expose-callers-xref-nodes (plist-get root :name) 'reference))
                (error
                 (expose-log "Callers" "Reference lookup failed: %s"
                             (error-message-string err))
                 nil))))

           (graph (expose-callers-collect root use-lsp root-references))
           (count (hash-table-count (car graph))))

      (expose-log "Callers" "Found %d raw reference(s)." (length root-references))

      (when (= count 1)
        (expose-callers-signal-nothing
         "No callers or references found for %s%s"
         (plist-get root :name)
         (cond
          ((not use-lsp)
           " (searched references; try again once LSP is running)")
          ((not expose-callers-include-references)
           " (calls only; set `expose-callers-include-references' to also search references)")
          (t ""))))

      (expose-log "Callers" "Found %d nodes, %d edges." count (length (cdr graph)))

      (cons (expose-callers-to-dot graph root use-lsp)
            (plist-get root :name)))))

(provide 'expose-callers)
