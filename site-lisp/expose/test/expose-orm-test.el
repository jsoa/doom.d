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

(provide 'expose-orm-test)

;;; expose-orm-test.el ends here
