;;; expose-diagram-test.el --- Tests for expose-diagram -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-diagram)

;;; ---------------------------------------------------------------------------
;;; expose-diagram-base-class-node-p
;;; ---------------------------------------------------------------------------

(ert-deftest expose-diagram-test-base-class-node-p-matches-record-label ()
  (should
   (expose-diagram-base-class-node-p
    "n1" "label=\"{TimestampedModel|created_at: DateTime\\l}\""
    '("TimestampedModel"))))

(ert-deftest expose-diagram-test-base-class-node-p-matches-node-name ()
  (should
   (expose-diagram-base-class-node-p
    "TimestampedModel" "label=\"something else\"" '("TimestampedModel"))))

(ert-deftest expose-diagram-test-base-class-node-p-nil-when-not-in-list ()
  (should-not
   (expose-diagram-base-class-node-p
    "n1" "label=\"{Comment|text: str\\l}\"" '("TimestampedModel"))))

(ert-deftest expose-diagram-test-base-class-node-p-nil-with-empty-list ()
  (should-not
   (expose-diagram-base-class-node-p "n1" "label=\"{TimestampedModel|}\"" nil)))

;;; ---------------------------------------------------------------------------
;;; expose-diagram-style-statement: base-class coloring
;;; ---------------------------------------------------------------------------

(ert-deftest expose-diagram-test-style-statement-colors-a-base-class-node ()
  (let* ((result
          (expose-diagram-style-statement
           nil "n1" "shape=Mrecord label=\"{TimestampedModel|}\""
           nil '("TimestampedModel")))
         (fill (cdr (assq 'base-class expose-diagram-palette))))

    (should (string-match-p (regexp-quote (format "fillcolor=\"%s\"" (nth 0 fill))) result))))

(ert-deftest expose-diagram-test-style-statement-leaves-other-nodes-classified-normally ()
  "A node that isn't in BASE-CLASSES gets the ordinary shape-based color,
unaffected by the new parameter's mere presence."

  (let* ((result
          (expose-diagram-style-statement
           nil "n1" "shape=Mrecord label=\"{Comment|}\""
           nil '("TimestampedModel")))
         (normal (cdr (assq 'normal expose-diagram-palette))))

    (should (string-match-p (regexp-quote (format "fillcolor=\"%s\"" (nth 0 normal))) result))))

(ert-deftest expose-diagram-test-style-statement-base-classes-nil-unaffected ()
  "Every other diagram type never passes BASE-CLASSES -- confirm the
5-argument call sites still behave exactly as the 4-argument form did."

  (should
   (equal
    (expose-diagram-style-statement nil "n1" "shape=Mrecord label=\"{Comment|}\"" nil)
    (expose-diagram-style-statement nil "n1" "shape=Mrecord label=\"{Comment|}\"" nil nil))))

(ert-deftest expose-diagram-test-style-statement-focused-base-class-still-bold ()
  "A base class can be both colored distinctly AND the focused node --
not true in practice for this feature (a model is never its own base),
but the two flags are independent and must compose without error."

  (let ((result
         (expose-diagram-style-statement
          nil "Event" "shape=Mrecord label=\"{Event|}\""
          "Event" '("Event"))))

    (should (string-match-p "style=\"filled,rounded,bold\"" result))))

;;; ---------------------------------------------------------------------------
;;; expose-diagram-color-statements: threading BASE-CLASSES through
;;; ---------------------------------------------------------------------------

(ert-deftest expose-diagram-test-color-statements-threads-base-classes ()
  (let* ((dot "digraph { n1 [shape=Mrecord label=\"{TimestampedModel|}\"]; }")
         (colored (expose-diagram-color-statements dot nil '("TimestampedModel")))
         (fill (cdr (assq 'base-class expose-diagram-palette))))

    (should (string-match-p (regexp-quote (format "fillcolor=\"%s\"" (nth 0 fill))) colored))))

(provide 'expose-diagram-test)

;;; expose-diagram-test.el ends here
