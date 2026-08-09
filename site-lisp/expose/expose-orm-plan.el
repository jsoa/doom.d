;;; expose-orm-plan.el -*- lexical-binding: t; -*-

;;; A Postgres query plan, drawn.
;;;
;;; EXPLAIN output is a tree printed as indented text, which is the one
;;; shape terminals render badly: the nesting that says which node feeds
;;; which is carried entirely by leading whitespace, and the numbers that
;;; say where the time went are scattered across the lines rather than
;;; compared. Drawing it puts the tree back and lets the expensive path be
;;; coloured rather than counted.
;;;
;;; Bottom to top, because that is the direction data moves: scans at the
;;; bottom feed joins feed the result at the top. It also suits the shape --
;;; plans are deep and narrow, and a deep tree laid out left to right is a
;;; ribbon.

(require 'cl-lib)
(require 'subr-x)

(defgroup expose-orm-plan nil
  "Query plan rendering for Expose."
  :group 'expose-orm)

(defcustom expose-orm-plan-misestimate-factor 10
  "How far the planner's row estimate may be out before it is flagged.

The gap between estimated and actual rows is the single most useful
number in an ANALYZE, because almost every bad plan is a good plan
chosen from a bad estimate."
  :type 'number
  :group 'expose-orm-plan)

(defcustom expose-orm-plan-misestimate-floor 1000
  "Rows a node must involve before a bad row estimate is worth reporting.

A ten-fold error on fifty rows is still fifty rows: it cannot change
which plan wins, and reporting it buries the misestimates that can. The
factor alone is not enough -- small tables produce large ratios all the
time, particularly when they have never been ANALYZEd."
  :type 'integer
  :group 'expose-orm-plan)

(defconst expose-orm-plan-colors
  '((scan     "#fdeceb" "#c0544b" "#75211b")
    (index    "#e9f6ec" "#4f9d69" "#1d4a2d")
    (join     "#e8f0fe" "#4a7fd4" "#1b3c66")
    (sort     "#fff5e2" "#cf9a3c" "#5c4310")
    (other    "#f4f6f8" "#c2cad4" "#1f2933"))
  "Fill, border and text color per kind of plan node.

Grouped by what the node costs you rather than by what it is called. Red
is reserved for nodes that actually merit attention -- see
`expose-orm-plan-alarming-p' -- because a sequential scan over a small
table is the correct plan and marking every one of them red would say
nothing. Index scans are green, joins structural blue, and sorts and
hashes amber for the rows they buffer.")

(defcustom expose-orm-plan-large-scan-rows 10000
  "Rows a sequential scan may read before it is treated as a problem.

Below this a sequential scan is usually the *right* plan -- reading a
small table end to end beats an index lookup, and the planner knows it."
  :type 'integer
  :group 'expose-orm-plan)

(defun expose-orm-plan-alarming-p (node)
  "Return non-nil if NODE is worth drawing attention to.

A sequential scan is not a problem by itself: on a small table it is the
correct plan, and colouring every one of them red says nothing except
that the query touched a table. What is worth flagging is a scan that
reads a lot, or any node that produced a warning."

  (or (expose-orm-plan-warnings node)
      (and (string-match-p "Seq Scan" (or (expose-orm-plan-get node "Node Type") ""))
           (let ((rows (or (expose-orm-plan-get node "Actual Rows")
                           (expose-orm-plan-get node "Plan Rows"))))
             (and (numberp rows) (> rows expose-orm-plan-large-scan-rows))))))

(defun expose-orm-plan-kind (node)
  "Classify NODE into one of `expose-orm-plan-colors'."

  (let ((type (or (expose-orm-plan-get node "Node Type") "")))
    (cond
     ((expose-orm-plan-alarming-p node) 'scan)
     ((string-match-p "Index Only Scan\\|Index Scan\\|Bitmap Index" type) 'index)
     ((string-match-p "Join\\|Nested Loop" type) 'join)
     ((string-match-p "Sort\\|Hash\\|Aggregate\\|Group\\|Materialize\\|Memoize" type) 'sort)
     (t 'other))))

(defun expose-orm-plan-get (node key)
  "Return KEY from plan NODE, which is an alist from the JSON."

  (alist-get (intern key) node))

(defun expose-orm-plan-escape (text)
  (let ((escaped (format "%s" (or text ""))))
    (setq escaped (replace-regexp-in-string "&" "&amp;" escaped t t))
    (setq escaped (replace-regexp-in-string "<" "&lt;" escaped t t))
    (setq escaped (replace-regexp-in-string ">" "&gt;" escaped t t))
    escaped))

(defun expose-orm-plan-truncate (text width)
  (let ((body (format "%s" (or text ""))))
    (if (<= (length body) width)
        body
      (concat (substring body 0 width) "..."))))

(defun expose-orm-plan-number (value)
  "Format VALUE with thousands separators, since plan rows run large."

  (when (numberp value)
    (let* ((rounded (round value))
           (text (number-to-string (abs rounded)))
           (grouped ""))
      (while (> (length text) 3)
        (setq grouped (concat "," (substring text -3) grouped)
              text (substring text 0 -3)))
      (concat (if (< rounded 0) "-" "") text grouped))))

(defun expose-orm-plan-warnings (node)
  "Return the notable facts about NODE, worst first.

These are the reasons to look at a node at all. A plan is mostly
unremarkable and highlighting everything would say nothing."

  (let ((warnings nil)
        (planned (expose-orm-plan-get node "Plan Rows"))
        (actual (expose-orm-plan-get node "Actual Rows"))
        (removed (expose-orm-plan-get node "Rows Removed by Filter"))
        (sort-method (expose-orm-plan-get node "Sort Method"))
        (type (expose-orm-plan-get node "Node Type")))

    ;; Nearly every bad plan is a good plan chosen from a bad estimate, so
    ;; this is the first thing to look at when a query is slow but the
    ;; shape of the plan looks reasonable.
    (when (and (numberp planned) (numberp actual)
               (> planned 0) (> actual 0)
               (>= (max planned actual) expose-orm-plan-misestimate-floor)
               (or (> (/ (float actual) planned) expose-orm-plan-misestimate-factor)
                   (> (/ (float planned) actual) expose-orm-plan-misestimate-factor)))
      (push (format "estimate off %.0fx (planned %s, actual %s)"
                    (if (> actual planned)
                        (/ (float actual) planned)
                      (/ (float planned) actual))
                    (expose-orm-plan-number planned)
                    (expose-orm-plan-number actual))
            warnings))

    ;; Rows read and then thrown away are the clearest possible statement
    ;; that an index is missing, and unlike a cost number it needs no
    ;; interpretation.
    (when (and (numberp removed) (> removed 1000))
      (push (format "%s rows read then discarded" (expose-orm-plan-number removed))
            warnings))

    (when (and sort-method (string-match-p "disk\\|Disk" sort-method))
      (push (format "sort spilled to disk (%s)" sort-method) warnings))

    (when (and (equal type "Seq Scan") (numberp actual) (> actual 10000))
      (push (format "scans %s rows" (expose-orm-plan-number actual)) warnings))

    (nreverse warnings)))

(defun expose-orm-plan-rows (node)
  "Return the label rows describing NODE."

  (let* ((planned (expose-orm-plan-get node "Plan Rows"))
         (actual (expose-orm-plan-get node "Actual Rows"))
         (time (expose-orm-plan-get node "Actual Total Time"))
         (cost (expose-orm-plan-get node "Total Cost"))
         (relation (expose-orm-plan-get node "Relation Name"))
         (index (expose-orm-plan-get node "Index Name"))
         (condition (or (expose-orm-plan-get node "Index Cond")
                        (expose-orm-plan-get node "Filter")
                        (expose-orm-plan-get node "Hash Cond")
                        (expose-orm-plan-get node "Join Filter")))
         (rows nil))

    (when relation (push (cons "on" relation) rows))
    (when index (push (cons "using" index) rows))

    (push (cons "rows"
                (cond
                 ((and (numberp actual) (numberp planned))
                  (format "%s (est %s)"
                          (expose-orm-plan-number actual)
                          (expose-orm-plan-number planned)))
                 ((numberp planned) (format "est %s" (expose-orm-plan-number planned)))
                 (t "?")))
          rows)

    (cond
     ((numberp time) (push (cons "time" (format "%.1f ms" time)) rows))
     ((numberp cost) (push (cons "cost" (expose-orm-plan-number cost)) rows)))

    (when condition
      (push (cons "cond" (expose-orm-plan-truncate condition 46)) rows))

    (nreverse rows)))

(defun expose-orm-plan-node (node id)
  "Return the DOT statement for plan NODE with node name ID."

  (let* ((type (or (expose-orm-plan-get node "Node Type") "Node"))
         (kind (expose-orm-plan-kind node))
         (colors (alist-get kind expose-orm-plan-colors))
         (warnings (expose-orm-plan-warnings node))
         (rows (expose-orm-plan-rows node))
         (parallel (expose-orm-plan-get node "Parallel Aware")))

    (format
     "  %s [shape=plaintext label=<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"3\" BGCOLOR=\"%s\" STYLE=\"ROUNDED\">
%s
%s
%s      </TABLE>>];"
     id
     (nth 0 colors)

     (format "        <TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"%s\"><B>%s%s</B></FONT></TD></TR>"
             (nth 2 colors)
             (expose-orm-plan-escape type)
             (if (eq parallel t) " (parallel)" ""))

     (mapconcat
      (lambda (row)
        (format "        <TR><TD ALIGN=\"LEFT\"><FONT POINT-SIZE=\"9\" COLOR=\"%s\">%s %s</FONT></TD></TR>"
                (nth 2 colors)
                (expose-orm-plan-escape (car row))
                (expose-orm-plan-escape (cdr row))))
      rows
      "\n")

     ;; Warnings last and in red: they are what makes a node worth reading,
     ;; and putting them above the facts would bury the facts instead.
     (if warnings
         (concat
          (mapconcat
           (lambda (warning)
             (format "        <TR><TD ALIGN=\"LEFT\"><FONT POINT-SIZE=\"9\" COLOR=\"#a3231b\">! %s</FONT></TD></TR>"
                     (expose-orm-plan-escape warning)))
           warnings
           "\n")
          "\n")
       ""))))

(defun expose-orm-plan-walk (node id statements edges counter)
  "Walk NODE, pushing DOT statements and edges. Returns the updated COUNTER."

  (push (expose-orm-plan-node node id) (cdr statements))

  (let ((next (car counter)))
    (dolist (child (expose-orm-plan-get node "Plans"))
      (let ((child-id (format "n%d" next)))
        (setcar counter (1+ next))
        ;; Child to parent: rows flow up into the node that consumes them.
        (push (format "  %s -> %s;" child-id id) (cdr edges))
        (expose-orm-plan-walk child child-id statements edges counter)
        (setq next (car counter)))))

  counter)

(defun expose-orm-plan-to-dot (plan title)
  "Return DOT source drawing PLAN, labelled TITLE.

PLAN is the object Postgres returns for EXPLAIN (FORMAT JSON) -- either
the outer one-element list or the object inside it."

  (let* ((root (cond
                ((and (listp plan) (alist-get 'Plan plan)) (alist-get 'Plan plan))
                ((and (listp plan) (listp (car plan)) (alist-get 'Plan (car plan)))
                 (alist-get 'Plan (car plan)))
                (t plan)))
         (statements (cons 'statements nil))
         (edges (cons 'edges nil))
         (counter (list 1)))

    (expose-orm-plan-walk root "n0" statements edges counter)

    (string-join
     (append
      (list "digraph plan {"
            "  rankdir=BT;"
            "  bgcolor=\"transparent\";"
            "  node [fontname=\"Helvetica\" fontsize=10];"
            "  edge [color=\"#8a94a6\" arrowsize=0.7];"
            (format "  labelloc=\"t\"; label=<<FONT POINT-SIZE=\"11\">%s</FONT>>;"
                    (expose-orm-plan-escape title)))
      (nreverse (cdr statements))
      (nreverse (cdr edges))
      (list "}"))
     "\n")))

(defun expose-orm-plan-total-time (plan)
  "Return the total execution time reported in PLAN, if it was analyzed."

  (let ((outer (if (and (listp plan) (listp (car plan)) (alist-get 'Plan (car plan)))
                   (car plan)
                 plan)))
    (or (alist-get 'Execution\ Time outer)
        (alist-get (intern "Execution Time") outer))))

(provide 'expose-orm-plan)
