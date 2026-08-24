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

(provide 'expose-orm-test)

;;; expose-orm-test.el ends here
