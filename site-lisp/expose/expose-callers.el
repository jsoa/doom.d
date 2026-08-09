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
              (lsp-request "textDocument/prepareCallHierarchy"
                           (lsp--text-document-position-params))))
    (mapcar
     (lambda (item)
       (append (expose-callers-lsp-item-to-node item)
               (list :item item)))
     (append items nil))))

(defun expose-callers-lsp-incoming (node)
  "Return the callers of NODE via LSP, as node plists.

NODE must carry the raw `:item' it came from; call hierarchy is
stateful in that the server hands back opaque items to ask about."

  (when-let* ((item (plist-get node :item))
              (calls (lsp-request "callHierarchy/incomingCalls"
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
              (lsp-request "textDocument/references"
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
    (push "  rankdir=BT;" lines)
    (push (format "  label=\"callers of %s%s\";"
                  (expose-callers-escape (plist-get root :name))
                  (if exact "" "  (from references -- may include non-calls)"))
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
    (push "  rankdir=BT;" lines)
    (push (format "  label=\"%d test%s reaching %s\";"
                  test-count
                  (if (= test-count 1) "" "s")
                  (expose-callers-escape (plist-get root :name)))
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

             ('mention
              (format "  %s -> %s [style=dotted,label=\"mentions\",color=\"#8b94a3\",fontcolor=\"#8b94a3\"];"
                      from to))

             (_ (format "  %s -> %s;" from to)))
           lines))))

    (push "}" lines)

    (cons (mapconcat #'identity (nreverse lines) "\n") test-count)))

(defun expose-callers-build-tests-dot ()
  "Return (DOT ROOT-NAME TEST-COUNT) for the tests reaching the symbol at point.

Signals a `user-error' naming the symbol when nothing tests it -- that
being the answer worth stating plainly rather than drawing an empty
graph."

  (let* ((use-lsp (expose-callers-lsp-available-p))

         (root
          (if use-lsp
              (car (expose-callers-lsp-prepare))
            (let ((name (or (thing-at-point 'symbol t)
                            (user-error "No symbol at point"))))
              (list :name name
                    :file (buffer-file-name)
                    :line (line-number-at-pos))))))

    (unless root
      (user-error "Nothing callable at point"))

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
      (dolist (mention (expose-callers-test-mentions (plist-get root :name)))
        (let ((key (expose-callers-node-key mention)))
          (unless (or (equal key root-key) (gethash key nodes))
            (puthash key mention nodes)
            (cl-pushnew (list key root-key 'mention) edges :test #'equal))))

      (let* ((keep (expose-callers-test-reachable nodes edges root-key))
             (rendered (expose-callers-tests-to-dot nodes edges root keep)))

        (expose-log "Callers" "Tests reaching %s: %d (from %d nodes)."
                    (plist-get root :name) (cdr rendered) (hash-table-count nodes))

        (when (zerop (cdr rendered))
          (user-error
           (concat "No test reaches %s: no call path, no reference, "
                   "and no test file mentions it%s")
           (plist-get root :name)
           (if use-lsp
               ""
             " (LSP unavailable, so call paths were not searched)")))

        (list (car rendered) (plist-get root :name) (cdr rendered))))))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun expose-callers-build-dot ()
  "Return (DOT . ROOT-NAME) for the reverse call graph of the symbol at point.

Signals a `user-error' when there is nothing to start from, or when
neither source can answer."

  (let* ((use-lsp (expose-callers-lsp-available-p))

         (root
          (if use-lsp
              (car (expose-callers-lsp-prepare))

            (let ((name (or (thing-at-point 'symbol t)
                            (user-error "No symbol at point"))))
              (list :name name
                    :file (buffer-file-name)
                    :line (line-number-at-pos))))))

    (unless root
      (user-error "Nothing callable at point"))

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
        (user-error
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
