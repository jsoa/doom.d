;;; expose-orm-test.el --- Tests for expose-orm -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-orm)

;;; ---------------------------------------------------------------------------
;;; expose-orm-strip-binding
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-strip-binding-single-name ()
  (should
   (equal "Event.objects.all()"
          (expose-orm-strip-binding "qs = Event.objects.all()"))))

(ert-deftest expose-orm-test-strip-binding-tuple-unpacking ()
  "Regression: `order, _ = Order.objects.get_or_create(...)' -- the
standard way to call `get_or_create'/`update_or_create', both of which
return a 2-tuple -- used to reach `ast.parse' in `eval' mode still
carrying its own `order, _ =' binding, which is a statement, not an
expression, and always failed with a bare syntax error that gave no
hint why."

  (should
   (equal "Order.objects.get_or_create(x=1)"
          (expose-orm-strip-binding "order, _ = Order.objects.get_or_create(x=1)"))))

(ert-deftest expose-orm-test-strip-binding-three-way-tuple-unpacking ()
  (should
   (equal "something()"
          (expose-orm-strip-binding "a, b, c = something()"))))

(ert-deftest expose-orm-test-strip-binding-return ()
  (should
   (equal "Event.objects.all()"
          (expose-orm-strip-binding "return Event.objects.all()"))))

(ert-deftest expose-orm-test-strip-binding-does-not-touch-a-comparison ()
  "`a == b' must not be mistaken for an assignment to strip -- the
capture group's own `[^=]' right after the matched `=' is what
prevents this: the second `=' of `==' can never satisfy it."

  (should
   (equal "a == b" (expose-orm-strip-binding "a == b"))))

(ert-deftest expose-orm-test-strip-binding-does-not-touch-le-ge ()
  (should (equal "a <= b" (expose-orm-strip-binding "a <= b")))
  (should (equal "a >= b" (expose-orm-strip-binding "a >= b"))))

(ert-deftest expose-orm-test-strip-binding-multiline-tuple-unpacking ()
  (should
   (equal "Order.objects.get_or_create(\n    x=1,\n)"
          (expose-orm-strip-binding
           "order, _ = Order.objects.get_or_create(\n    x=1,\n)"))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-display / expose-orm-display-plan: placement only -- see
;;; expose-side-panel-test.el for the underlying algorithm's own
;;; coverage. The subprocess machinery in expose-orm-run is not
;;; exercised here (no real project/Python fixture); these call the
;;; two display functions directly, which is where SOURCE-WINDOW
;;; actually gets used.
;;; ---------------------------------------------------------------------------

(defmacro expose-orm-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-orm-buffer)
       (kill-buffer expose-orm-buffer))))

(ert-deftest expose-orm-test-display-places-beside-source ()
  (expose-orm-test-with-clean-frame
    (delete-other-windows)
    (let ((source (progn (switch-to-buffer (get-buffer-create "eot-src.py")) (selected-window))))
      (expose-orm-display
       '((model . "Widget") (table . "widgets") (sql . "SELECT 1"))
       "Widget.objects.all()"
       source)
      (should (equal "eot-src.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-orm-buffer
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
      (should (equal expose-orm-buffer (buffer-name (current-buffer)))))))

(ert-deftest expose-orm-test-display-plan-no-plan-falls-back-beside-source ()
  "Both no-plan branches (an explicit plan_error, and simply no plan)
delegate to expose-orm-display -- confirming SOURCE-WINDOW reaches it
through that indirection, not just when called directly."

  (expose-orm-test-with-clean-frame
    (delete-other-windows)
    (let ((source (progn (switch-to-buffer (get-buffer-create "eot-src2.py")) (selected-window))))
      (expose-orm-display-plan
       '((error . "no database configured"))
       "Widget.objects.all()"
       source)
      (should (equal expose-orm-buffer
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
      (should (equal "eot-src2.py" (buffer-name (window-buffer (frame-first-window))))))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-enclosing-class / expose-orm-resolve-self
;;;
;;; `self.queryset.filter(...)' -- the standard DRF/CBV shape -- always
;;; failed with a bare NameError before this, since the analysis runs in
;;; a plain module namespace with no `self' to be found. Resolving a
;;; leading `self.' to the enclosing class turns that into something
;;; that actually inspects the class-level `queryset' attribute the
;;; overwhelming majority of that code is written against.
;;; ---------------------------------------------------------------------------

(defun expose-orm-test-python-buffer (text needle)
  "Insert TEXT into a new python-mode buffer, leave point at NEEDLE, return it."

  (let ((buffer (generate-new-buffer " *expose-orm-test-py*" t)))
    (with-current-buffer buffer
      (python-mode)
      (insert text)
      (goto-char (point-min))
      (search-forward needle))
    buffer))

(ert-deftest expose-orm-test-enclosing-class-inside-a-method ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    queryset = Widget.objects.all()\n\n    def get_something(self):\n        return self.queryset.filter(name=\"foo\")\n"
          "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "WidgetViewSet" (expose-orm-enclosing-class))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-enclosing-class-nested-class ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class Outer:\n    class Inner:\n        def method(self):\n            return self.queryset\n"
          "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "Outer.Inner" (expose-orm-enclosing-class))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-enclosing-class-nil-at-module-level ()
  (let ((buffer
         (expose-orm-test-python-buffer "x = Widget.objects.all()\n" "Widget")))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (expose-orm-enclosing-class)))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-enclosing-class-nil-inside-plain-function ()
  "A module-level function is a defun with no dot in its qualified name --
nothing to resolve `self' against, since it has no enclosing class at
all (and referencing `self' there would itself be a bug in the code
being inspected, not something this should paper over)."

  (let ((buffer
         (expose-orm-test-python-buffer
          "def helper():\n    return Widget.objects.all()\n"
          "Widget")))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (expose-orm-enclosing-class)))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-self-substitutes-enclosing-class ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_something(self):\n        return self.queryset.filter(name=\"foo\")\n"
          "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "WidgetViewSet.queryset.filter(name=\"foo\")"
                  (expose-orm-resolve-self "self.queryset.filter(name=\"foo\")"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-self-works-across-multiple-lines ()
  "Regression: `.' does not match a newline in Emacs regexps, and the
first version of this function's own regex used `.*' unguarded --
silently failing to match, and so silently leaving `self.' unresolved,
for any selection whose arguments wrapped onto their own line. Which
is completely ordinary formatting for a `.filter()' call with more
than one keyword argument, not an edge case."

  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_something(self):\n        return self.queryset.filter(\n            name=\"foo\", state=1\n        )\n"
          "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "WidgetViewSet.queryset.filter(\n            name=\"foo\", state=1\n        )"
                  (expose-orm-resolve-self
                   "self.queryset.filter(\n            name=\"foo\", state=1\n        )"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-self-only-resolves-the-leading-one ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_something(self):\n        return self.queryset\n"
          "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "WidgetViewSet.queryset.filter(x=self.kwargs['id'])"
                  (expose-orm-resolve-self
                   "self.queryset.filter(x=self.kwargs['id'])"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-self-unchanged-without-enclosing-class ()
  (let ((buffer
         (expose-orm-test-python-buffer "x = self.queryset\n" "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "self.queryset.filter(x=1)"
                  (expose-orm-resolve-self "self.queryset.filter(x=1)"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-self-unchanged-when-not-leading ()
  (should
   (equal "Widget.objects.filter(x=1)"
          (expose-orm-resolve-self "Widget.objects.filter(x=1)"))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-local-self-alias / expose-orm-resolve-local-alias
;;;
;;; `queryset = self.queryset' followed later by `queryset.filter(...)'
;;; -- the standard shape of a `get_queryset' override that narrows the
;;; class's own `queryset' -- is one hop further back than
;;; `self.queryset.filter(...)' itself, but resolvable the same way.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-local-self-alias-finds-simple-assignment ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_queryset(self):\n        queryset = self.queryset\n        return queryset.filter(x=1)\n"
          "return queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "queryset" (expose-orm-local-self-alias "queryset"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-local-self-alias-nil-for-unknown-name ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_queryset(self):\n        queryset = self.queryset\n        return queryset.filter(x=1)\n"
          "return queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (expose-orm-local-self-alias "not_a_real_name")))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-local-self-alias-ignores-a-further-reassignment ()
  "A later `queryset = queryset.filter(...)' does not match the simple
`NAME = self.ATTR' shape this looks for, so it is not mistaken for the
alias itself -- the original assignment further up is still what gets
found."

  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_queryset(self):\n        queryset = self.queryset\n        queryset = queryset.filter(x=1)\n        return queryset.filter(y=2)\n"
          "return queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "queryset" (expose-orm-local-self-alias "queryset"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-local-self-alias-nil-outside-a-method ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "queryset = self.queryset\nx = queryset.filter(y=1)\n"
          "queryset.filter")))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (expose-orm-local-self-alias "queryset")))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-local-alias-substitutes-self-form ()
  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_queryset(self):\n        queryset = self.queryset\n        return queryset.filter(x=1)\n"
          "return queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "self.queryset.filter(x=1)"
                  (expose-orm-resolve-local-alias "queryset.filter(x=1)"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-local-alias-unchanged-without-an-alias ()
  (let ((buffer
         (expose-orm-test-python-buffer "x = Widget.objects.all()\n" "Widget")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "Widget.objects.filter(x=1)"
                  (expose-orm-resolve-local-alias "Widget.objects.filter(x=1)"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-resolve-local-alias-does-not-touch-bare-self ()
  "`self' itself must go through `expose-orm-resolve-self', not be
treated as a local name needing its own alias lookup."

  (let ((buffer
         (expose-orm-test-python-buffer
          "class WidgetViewSet:\n    def get_queryset(self):\n        return self.queryset.filter(x=1)\n"
          "self.queryset")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "self.queryset.filter(x=1)"
                  (expose-orm-resolve-local-alias "self.queryset.filter(x=1)"))))
      (kill-buffer buffer))))

(ert-deftest expose-orm-test-expression-resolves-alias-across-branches ()
  "End to end, through `expose-orm-expression': the exact shape a
`get_queryset' override narrowing by an `if'/`else' branch has --
`queryset = self.queryset' at the top, each branch building on it
differently further down."

  (let ((buffer
         (expose-orm-test-python-buffer
          (concat
           "class EventViewSet:\n"
           "    def get_queryset(self):\n"
           "        queryset = self.queryset\n"
           "        if condition:\n"
           "            queryset = queryset.filter(x=1)\n"
           "        else:\n"
           "            queryset = queryset.filter(y=2)\n"
           "        return queryset\n")
          "queryset = queryset.filter(y=2)")))
    (unwind-protect
        (with-current-buffer buffer
          (beginning-of-line)
          (should
           (equal "EventViewSet.queryset.filter(y=2)" (expose-orm-expression))))
      (kill-buffer buffer))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-render-sql / the buffer's title
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-render-sql-applies-real-faces ()
  "A real `sql-mode' font-lock pass, not a hand-rolled keyword list --
verified by checking an actual face landed, not just that the text
came back unchanged."

  (let ((rendered (expose-orm-render-sql "SELECT id FROM widgets WHERE x = 1")))
    (should (equal "SELECT id FROM widgets WHERE x = 1" (substring-no-properties rendered)))
    (should (text-property-not-all 0 (length rendered) 'face nil rendered))))

(ert-deftest expose-orm-test-insert-shows-a-title ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert
     '((model . "app.Widget") (table . "app_widget") (sql . "SELECT 1"))
     "Widget.objects.all()")
    (should (string-match-p "\\`Queryset SQL" (buffer-string)))))

(ert-deftest expose-orm-test-insert-colorizes-the-sql ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert
     '((model . "app.Widget") (table . "app_widget") (sql . "SELECT id FROM widgets"))
     "Widget.objects.all()")
    (goto-char (point-min))
    (search-forward "SELECT")
    (should (eq 'font-lock-keyword-face (get-text-property (- (point) 6) 'face)))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-no-result-error
;;;
;;; `docker exec' against a container that does not exist on this
;;; machine -- a `.dir-locals.el' name that only ever matched one
;;; developer's `docker-compose' naming -- fails before the Python
;;; script even starts, so there is no result to find in its output at
;;; all: just Docker's own complaint, buried in an otherwise-generic
;;; "produced no result" unless called out specifically.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-no-result-error-names-a-missing-container ()
  (let ((message (expose-orm-no-result-error
                  "Error response from daemon: No such container: myproject-app-1\n"
                  "myproject-app-1"
                  "`expose-orm-container'")))
    (should (string-match-p "myproject-app-1" message))
    (should (string-match-p "expose-orm-container" message))
    (should (string-match-p "docker ps" message))))

(ert-deftest expose-orm-test-no-result-error-names-the-jump-container-source ()
  (let ((message (expose-orm-no-result-error
                  "Error response from daemon: No such container: x\n"
                  "x"
                  "`jsoa/docker-jump-container'")))
    (should (string-match-p "jsoa/docker-jump-container" message))))

(ert-deftest expose-orm-test-no-result-error-generic-without-a-container ()
  "Running locally (no container at all): the Docker-specific message
must not fire just because the raw text happens to mention containers
for some unrelated reason -- CONTAINER itself has to be set too."

  (let ((message (expose-orm-no-result-error "" nil nil)))
    (should (string-match-p "produced no result" message))
    (should (string-match-p "printed nothing at all" message))))

(ert-deftest expose-orm-test-no-result-error-generic-for-unrelated-failures ()
  "A container IS configured, but the failure is something else
entirely (an ImportError, say) -- must not be misdiagnosed as a
missing container just because one happens to be set."

  (let ((message (expose-orm-no-result-error
                  "Traceback (most recent call last):\nImportError: no module named foo\n"
                  "myproject-app-1"
                  "`expose-orm-container'")))
    (should (string-match-p "produced no result" message))
    (should (string-match-p "ImportError" message))
    (should-not (string-match-p "does not exist here" message))))

(ert-deftest expose-orm-test-no-result-error-includes-raw-output-for-generic-case ()
  (let ((message (expose-orm-no-result-error "some raw traceback text" nil nil)))
    (should (string-match-p "some raw traceback text" message))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-missing-indexes / expose-orm-insert-indexes
;;;
;;; No new Python here: `analyse' in expose-orm.py already computes
;;; `indexed'/`why' for every filter and ordering term (the same data
;;; `expose-orm-findings' surfaces as warnings in the full SQL view),
;;; so this is pure Elisp filtering of an already-real result shape.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-missing-indexes-filters-to-unindexed ()
  (let* ((result '((filters . (((table . "app_widget") (column . "name") (lookup . "exact") (indexed . t))
                                ((table . "app_widget") (column . "color") (lookup . "exact") (indexed . nil))))
                    (ordering . (((term . "color") (source . "order_by()") (indexed . nil) (why . "no index"))
                                 ((term . "id") (source . "order_by()") (indexed . t) (why . "primary key"))))))
         (missing (expose-orm-missing-indexes result)))
    (should (= 1 (length (car missing))))
    (should (equal "color" (alist-get 'column (car (car missing)))))
    (should (= 1 (length (cdr missing))))
    (should (equal "color" (alist-get 'term (car (cdr missing)))))))

(ert-deftest expose-orm-test-missing-indexes-ignores-ordering-with-no-why ()
  "A `__' traversal's ordering term has `why' left nil (see
`describe-ordering' in expose-orm.py -- whether it's indexed is a
question about a different model), and must not be reported as
missing rather than simply unknown."

  (let* ((result '((filters . nil)
                    (ordering . (((term . "author__name") (source . "order_by()") (indexed . nil) (why . nil))))))
         (missing (expose-orm-missing-indexes result)))
    (should-not (cdr missing))))

(ert-deftest expose-orm-test-missing-indexes-empty-when-all-indexed ()
  (let* ((result '((filters . (((table . "app_widget") (column . "id") (lookup . "exact") (indexed . t))))
                    (ordering . nil)))
         (missing (expose-orm-missing-indexes result)))
    (should-not (car missing))
    (should-not (cdr missing))))

(ert-deftest expose-orm-test-insert-indexes-shows-title-and-model ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-indexes
     '((model . "app.Widget") (filters . nil) (ordering . nil))
     "Widget.objects.all()")
    (should (string-match-p "\\`Missing Indexes" (buffer-string)))
    (should (string-match-p "app.Widget" (buffer-string)))
    (should (string-match-p "Every filter and ordering term here is indexed" (buffer-string)))))

(ert-deftest expose-orm-test-insert-indexes-lists-unindexed-terms ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-indexes
     '((model . "app.Widget")
       (filters . (((table . "app_widget") (column . "color") (lookup . "exact") (indexed . nil) (why . "no index"))))
       (ordering . nil))
     "Widget.objects.filter(color=1)")
    (should (string-match-p "filters app_widget.color" (buffer-string)))
    (should (string-match-p "no index" (buffer-string)))))

(ert-deftest expose-orm-test-insert-indexes-shows-refused ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-indexes
     '((error . "`.delete()' writes to the database.") (refused . t))
     "Widget.objects.all().delete()")
    (should (string-match-p "Refused" (buffer-string)))))

;;; ---------------------------------------------------------------------------
;;; expose-orm-n-plus-one-source: region takes priority, then the
;;; enclosing scope, matching expose-orm-expression's own priority.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-n-plus-one-source-uses-active-region ()
  (with-temp-buffer
    (python-mode)
    (insert "for e in Event.objects.all():\n    print(e.category)\n")
    (let ((transient-mark-mode t))
      (set-mark (point-min))
      (goto-char (point-max))
      (activate-mark)
      (should (string-match-p "for e in Event" (expose-orm-n-plus-one-source)))
      (deactivate-mark))))

(ert-deftest expose-orm-test-n-plus-one-source-errors-without-region-or-scope ()
  "The enclosing-function fallback (`expose-context-scope-code', Tree-
sitter based) is not exercised here -- same reason the rest of this
suite leaves Tree-sitter out: no grammar is guaranteed present in a
batch test environment. Verified live instead. This only confirms the
no-region/no-scope case fails loudly rather than inspecting nothing."

  (with-temp-buffer
    (fundamental-mode)
    (insert "not python at all")
    (should-error (expose-orm-n-plus-one-source) :type 'user-error)))

;;; ---------------------------------------------------------------------------
;;; expose-orm-insert-n-plus-one
;;; ---------------------------------------------------------------------------

(ert-deftest expose-orm-test-insert-n-plus-one-no-loops-found ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-n-plus-one
     '((loops_checked . 0) (unresolved_loops . 0) (findings . nil))
     "def f():\n    return 1\n")
    (should (string-match-p "\\`N\\+1 Query Check" (buffer-string)))
    (should (string-match-p "No `for' loop or comprehension" (buffer-string)))))

(ert-deftest expose-orm-test-insert-n-plus-one-clean-loop ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-n-plus-one
     '((loops_checked . 1) (unresolved_loops . 0) (findings . nil))
     "for e in Event.objects.select_related('category'):\n    print(e.category)\n")
    (should (string-match-p "Checked 1 loop" (buffer-string)))
    (should (string-match-p "No unfetched relation access found" (buffer-string)))))

(ert-deftest expose-orm-test-insert-n-plus-one-lists-findings ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-n-plus-one
     '((loops_checked . 1) (unresolved_loops . 0)
       (findings . (((line . 2) (attribute . "category") (relation . "ForeignKey")
                     (suggestion . "select_related('category')") (loop_line . 1)))))
     "for e in Event.objects.all():\n    print(e.category)\n")
    (should (string-match-p "line 2" (buffer-string)))
    (should (string-match-p "`.category'" (buffer-string)))
    (should (string-match-p "select_related" (buffer-string)))))

(ert-deftest expose-orm-test-insert-n-plus-one-unresolved-loops-only ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-n-plus-one
     '((loops_checked . 0) (unresolved_loops . 2) (findings . nil))
     "for e in self.get_queryset():\n    print(e.category)\n")
    (should (string-match-p "Found 2 loops" (buffer-string)))
    (should (string-match-p "none could be resolved statically" (buffer-string)))))

(ert-deftest expose-orm-test-insert-n-plus-one-shows-refused ()
  (with-temp-buffer
    (special-mode)
    (expose-orm-insert-n-plus-one
     '((error . "not valid Python: invalid syntax") (refused . t))
     "def f(:\n")
    (should (string-match-p "Refused" (buffer-string)))))

(provide 'expose-orm-test)

;;; expose-orm-test.el ends here
