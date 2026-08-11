;;; expose-diagram.el -*- lexical-binding: t; -*-

;;; Render an AI-generated Graphviz DOT graph and show it as an image.
;;;
;;; Graphviz rather than Mermaid/PlantUML/D2 because `dot' is the one
;;; renderer that doesn't drag in a new toolchain: no node/npm, no JVM.
;;; SVG rather than PNG because Emacs renders it natively (there's no
;;; imagemagick here to rescale a bitmap), so the diagram stays sharp at
;;; any size.
;;;
;;; Like everything else in Expose this is advisory: the graph is the
;;; model's reading of code it can only partly see. A picture reads as
;;; more authoritative than a paragraph does, which is exactly why the
;;; request instruction pins it to visible control flow and why the DOT
;;; source is always one keypress away (`s') for checking.

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'expose-log)

;; Defined in expose-commands.el, which requires this file -- called only
;; at runtime (from `expose-diagram-regenerate'), by which point it
;; exists, so declaring it here avoids a load-time cycle.
(declare-function expose-run-control-flow-diagram "expose-commands")

(defgroup expose-diagram nil
  "Diagram rendering for Expose."
  :group 'expose)

(defcustom expose-diagram-dot-executable "dot"
  "Graphviz `dot' executable used to render Expose diagrams."
  :type 'string
  :group 'expose-diagram)

(defcustom expose-diagram-font "DejaVu Sans"
  "Font family used for diagram labels.

Graphviz defaults to `Times,serif', which the SVG renderer here has to
substitute -- the result renders thin and washed out, which is what
prompted setting this at all. A real installed sans face fixes it."
  :type 'string
  :group 'expose-diagram)

(defcustom expose-diagram-apply-theme t
  "Whether to restyle generated diagrams before rendering.

When nil, the provider's DOT is rendered exactly as written, which means
Graphviz's stock Times-on-white."
  :type 'boolean
  :group 'expose-diagram)

(defcustom expose-diagram-palette
  '((canvas      . "#fcfcfd")
    (edge        . "#8b94a3")
    (edge-label  . "#5f6b7a")
    (error-edge  . "#c0544b")

    ;; ER relationship edges, distinguished by kind. Hues echo the node
    ;; classes (violet/teal) so the whole thing reads as one palette,
    ;; and the commonest relation -- the foreign key -- gets the
    ;; quietest color so a page full of them doesn't shout.
    (fk-edge     . "#5a7fa8")
    (m2m-edge    . "#8b6fc4")
    (o2o-edge    . "#4a99a4")

    ;; The model the command was invoked from.
    (focus-edge  . "#1f6feb")

    ;; Pipeline layer boxes (request flow).
    (cluster-border . "#d6dbe2")
    (cluster-label  . "#7b8794")

    ;; (fill . border . text) per semantic class. Muted rather than
    ;; saturated: on a flowchart the color is a category label, not
    ;; emphasis, and a dozen loud nodes stop distinguishing anything.
    (entry       . ("#e8f0fe" "#4a7fd4" "#1b3c66"))
    (condition   . ("#fff5e2" "#cf9a3c" "#5c4310"))
    (error       . ("#fdeceb" "#c0544b" "#75211b"))
    (exit        . ("#e9f6ec" "#4f9d69" "#1d4a2d"))

    ;; Call-flow only: a dependency you don't own, and a call that
    ;; leaves the process. Both are worth spotting at a glance --
    ;; they're where the surprises live.
    (external    . ("#f4eefb" "#8b6fc4" "#3d2a63"))
    (io          . ("#e6f4f6" "#4a99a4" "#11434a"))

    (normal      . ("#f4f6f8" "#c2cad4" "#1f2933")))
  "Colors used when restyling diagrams.

Light on purpose, independent of the Emacs theme: these diagrams get
exported, pasted into tickets, and printed, and a dark canvas travels
badly. Semantic classes come from `expose-diagram-classify'."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'expose-diagram)

(defconst expose-diagram-buffer-name "*EXPOSE Diagram*")
(defconst expose-diagram-source-buffer-name "*EXPOSE Diagram Source*")

(defvar-local expose-diagram-source nil
  "DOT source that produced the diagram in this buffer.")

(defvar-local expose-diagram-svg nil
  "Raw SVG data for the diagram in this buffer.

Kept so the image can be rebuilt at a different size without re-running
`dot' -- see `expose-diagram-refresh-image'.")

(defvar-local expose-diagram-scale nil
  "Display scale for the diagram in this buffer.

nil means fit the whole graph inside the window, which is the default:
these graphs are routinely taller than the frame, and an image is a
single glyph, so an unscaled oversized image can't be scrolled into --
you'd see the top-left corner and nothing else. A number is an explicit
zoom factor relative to the image's natural size.")

(defvar-local expose-diagram-origin nil
  "Where the diagram in this buffer came from: (BUFFER POSITION COMMAND).

Recorded so `expose-diagram-regenerate' can re-run against the same
code: the diagram buffer is a `special-mode' buffer with no file and no
context of its own, so re-running from here would otherwise fail or
describe the diagram buffer itself. COMMAND is kept too, so `g'
reproduces the same *kind* of diagram rather than defaulting to one.")

;;; ---------------------------------------------------------------------------
;;; Extraction
;;; ---------------------------------------------------------------------------

(defun expose-diagram-extract-dot (response)
  "Return the DOT source in RESPONSE, or nil if there is none.

The request already asks for bare DOT (see
`expose-request-control-flow-diagram'), but providers wrap output in
Markdown fences often enough that stripping them is worth doing rather
than failing on an otherwise-valid graph. Falls back to scanning for the
outermost `digraph ... {' block so leading commentary doesn't matter
either."

  (when (stringp response)

    (let ((text (string-trim response)))

      ;; ```dot / ```graphviz / ``` fenced block
      (when (string-match
             "```[[:alpha:]]*[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)```"
             text)
        (setq text (string-trim (match-string 1 text))))

      ;; Trim anything before the graph itself. Matching a full graph
      ;; *declaration* -- keyword, optional name, then the opening brace --
      ;; rather than the bare word `graph', which otherwise matches inside
      ;; ordinary prose like "Here is the graph:" and trims to nonsense.
      (when (string-match
             (concat "\\(?:strict[ \t\n]+\\)?\\(?:di\\)?graph\\b[ \t\n]*"
                     "\\(?:[A-Za-z_][A-Za-z0-9_]*\\|\"[^\"]*\"\\)?[ \t\n]*{")
             text)
        (setq text (substring text (match-beginning 0))))

      (when (string-match-p
             (concat "\\`\\(?:strict[ \t\n]+\\)?\\(?:di\\)?graph\\b[ \t\n]*"
                     "\\(?:[A-Za-z_][A-Za-z0-9_]*\\|\"[^\"]*\"\\)?[ \t\n]*{")
             text)

        ;; Repaired here rather than at render time so every consumer sees
        ;; the same source: what gets rendered, what `s' shows, and what
        ;; `w' exports would otherwise disagree.
        (expose-diagram-repair-dot text)))))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defconst expose-diagram-formats
  '(("svg" . "svg")
    ("png" . "png")
    ("jpg" . "jpg")
    ("jpeg" . "jpg")
    ("pdf" . "pdf"))
  "Map of file extension to the `dot -T' format that produces it.

All of these were confirmed working with the local Graphviz; `dot'
renders each directly from the same DOT source, so exporting is a
re-render rather than a conversion of the displayed SVG.")

;;; ---------------------------------------------------------------------------
;;; Theming
;;; ---------------------------------------------------------------------------

(defun expose-diagram-color-to-rgb (color)
  "Return COLOR as a list of three floats in 0..1, or nil.

Parses `#rrggbb' directly rather than going through
`color-name-to-rgb' for it: that function resolves colors against the
display, so with no frame attached it returns nonsense for hex strings
\(`#1c1f26' comes back as pure blue), which silently wrecks every blend
derived from it. Named colors still fall through to it."

  (when (stringp color)
    (if (string-match "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\'"
                      color)
        (list
         (/ (float (string-to-number (match-string 1 color) 16)) 255.0)
         (/ (float (string-to-number (match-string 2 color) 16)) 255.0)
         (/ (float (string-to-number (match-string 3 color) 16)) 255.0))

      (color-name-to-rgb color))))

(defun expose-diagram-blend (from to alpha)
  "Blend colors FROM and TO, ALPHA being how much of TO to mix in.

Used to derive fills and borders that sit a measured distance from the
theme's own background, so the diagram reads as part of the editor
rather than a pasted-in white rectangle -- and so it tracks whatever
theme is active instead of hardcoding a palette."

  (let ((a (expose-diagram-color-to-rgb from))
        (b (expose-diagram-color-to-rgb to)))

    (if (not (and a b))
        to
      (apply
       #'color-rgb-to-hex
       (append
        (cl-mapcar
         (lambda (x y) (+ (* x (- 1.0 alpha)) (* y alpha)))
         a b)
        (list 2))))))

(defun expose-diagram-face-color (face attribute fallback)
  "Return FACE's ATTRIBUTE as a color, or FALLBACK when it isn't a real one."

  (let ((color (face-attribute face attribute nil t)))
    (if (and (stringp color)
             (color-defined-p color))
        color
      fallback)))

(defun expose-diagram-repair-dot (dot)
  "Return DOT with known provider malformations corrected.

Currently one, because it was observed rather than imagined: asked to
mark a node, providers sometimes append the marker *after* a label's
closing quote --

  label=\"do_thing\" (unresolved)\"\"

-- which Graphviz rejects outright (\"syntax error near \='('\"), taking the
whole diagram with it. The text belongs inside the quotes, so that's
where this puts it.

The request instruction now asks for `style=dashed' instead of label
text, which avoids the hazard entirely; this stays because a provider
that ignores that instruction shouldn't cost a whole render."

  (replace-regexp-in-string
   "\"\\([^\"\n]*\\)\"[ \t]*(\\([^)\n]*\\))[ \t]*\"\""
   "\"\\1 (\\2)\""
   dot))

(defun expose-diagram-color (class)
  "Return the (FILL BORDER TEXT) triple for semantic CLASS."

  (or (cdr (assq class expose-diagram-palette))
      (cdr (assq 'normal expose-diagram-palette))))

(defun expose-diagram-attribute (attrs name)
  "Return attribute NAME from a DOT ATTRS string, or nil.

Handles both quoted and bare values; for quoted ones it allows escaped
quotes inside, which node labels routinely contain (`raise
Exception(\\\"...\\\")')."

  (cond
   ((string-match
     (format "\\b%s[ \t]*=[ \t]*\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\"" (regexp-quote name))
     attrs)
    (match-string 1 attrs))

   ((string-match
     (format "\\b%s[ \t]*=[ \t]*\\([A-Za-z0-9_.]+\\)" (regexp-quote name))
     attrs)
    (match-string 1 attrs))))

(defun expose-diagram-classify (attrs)
  "Return the semantic class of a node whose attributes are ATTRS.

Keyed off the shapes the request instructions already pin (see
`expose-request-control-flow-diagram' and
`expose-request-call-flow-diagram'), so this doesn't ask the provider to
also produce colors -- which it would apply inconsistently run to run.
The label is only consulted to separate the two things that share the
`doubleoctagon' terminal shape: an ordinary return, and a raise.

Both diagram types share this classifier; the shapes they each use
don't overlap, so the extra call-flow cases are inert for control flow
and vice versa."

  (let* ((shape (or (expose-diagram-attribute attrs "shape") ""))
         (label (or (expose-diagram-attribute attrs "label") ""))
         (shape (downcase shape))
         (label (downcase label)))

    (cond
     ((string-match-p "\\braise\\b\\|\\bexcept\\|\\berror\\b\\|\\bfail" label)
      'error)

     ((string-match-p "doubleoctagon\\|octagon\\|doublecircle" shape)
      'exit)

     ((string-match-p "diamond\\|rhombus" shape)
      'condition)

     ;; Call flow: I/O -- `cylinder' is Graphviz's datastore shape.
     ((string-match-p "cylinder\\|note\\|folder" shape)
      'io)

     ;; Call flow: third-party/stdlib dependency.
     ((string-match-p "component\\|box3d\\|tab\\b" shape)
      'external)

     ((string-match-p "ellipse\\|oval\\|circle" shape)
      'entry)

     (t 'normal))))

(defun expose-diagram-classify-edge (attrs)
  "Return the relationship kind of an edge with ATTRS, or nil.

Read from the arrowheads the ER instruction already pins (crow for
foreign keys, crow at both ends for many-to-many, tee for one-to-one),
so relation coloring needs nothing new from the provider -- the same
trick the node classifier uses with shapes. Order matters: a
many-to-many carries a crow arrowhead too, so it has to be tested
before the foreign-key case."

  (let ((head (or (expose-diagram-attribute attrs "arrowhead") ""))
        (tail (or (expose-diagram-attribute attrs "arrowtail") "")))

    (cond
     ((string-match-p "crow" tail) 'm2m)
     ((string-match-p "tee\\|none\\|odot" head) 'o2o)
     ((string-match-p "crow" head) 'fk))))

(defun expose-diagram-focus-node-p (name attrs focus)
  "Return non-nil if the node NAME/ATTRS is the model named FOCUS.

Matched against the record label's leading model name (`{Order|...')
as well as the node's own identifier, because providers name nodes
inconsistently -- sometimes the model, sometimes a snake_case variant."

  (when (and focus (not (string-empty-p focus)))
    (let* ((label (or (expose-diagram-attribute attrs "label") ""))

           ;; Labels routinely carry a second line -- `name\\nfile' in the
           ;; reverse call graph, `name\\ndescription' in data flow -- so
           ;; comparing the whole thing never matches. Take the first
           ;; segment, splitting on DOT's own line escapes.
           ;;
           ;; `car' can be nil here, and was: an HTML-like label
           ;; (`label=<<TABLE ...>>', which the migration tables use) is
           ;; neither quoted nor bare, so `expose-diagram-attribute' reads
           ;; no value and the label defaults to "". Splitting "" with
           ;; OMIT-NULLS yields no elements at all, and `string-trim' of
           ;; nil signalled. It only surfaced for tables containing no
           ;; brackets, because a `choices=[...]' anywhere in the label
           ;; stops the statement regex matching the node in the first
           ;; place -- so whether this crashed depended on whether the
           ;; model happened to have a field with choices.
           (first-line
            (string-trim (or (car (split-string label "\\\\[nlr]" t)) ""))))

      (or
       (string-equal-ignore-case name focus)
       ;; `{ModelName|field...' -- the record label's header cell.
       (and (string-match "\\`{[ \t]*\\([A-Za-z_][A-Za-z0-9_.]*\\)" label)
            (string-equal-ignore-case (match-string 1 label) focus))
       ;; Plain label, or the first line of a multi-line one.
       (string-equal-ignore-case first-line focus)))))

(defun expose-diagram-style-statement (arrow name attrs &optional focus)
  "Return a restyled `NAME [ATTRS]' statement, or nil to leave it alone.

ARROW is non-nil when this is an edge target (`a -> b [...]') rather
than a node declaration."

  (cond
   ;; `node [...]' / `edge [...]' / `graph [...]' set defaults; they
   ;; aren't things to color -- and this must skip them, or it would
   ;; re-match the default block injected by `expose-diagram-style-dot'.
   ((member (downcase name) '("node" "edge" "graph"))
    nil)

   ;; Edge. Two independent reasons to color one: it's an error path (in
   ;; the flow diagrams), or it's a particular kind of relationship (in
   ;; ER). Everything else stays the neutral default, so a page of
   ;; ordinary arrows doesn't compete with the ones worth noticing.
   (arrow
    (let* ((label
            (downcase (or (expose-diagram-attribute attrs "label") "")))

           (color
            (cond
             ((string-match-p "\\bexcept\\|\\berror\\b\\|\\braise\\b\\|\\bfail" label)
              (cdr (assq 'error-edge expose-diagram-palette)))

             ((pcase (expose-diagram-classify-edge attrs)
                ('m2m (cdr (assq 'm2m-edge expose-diagram-palette)))
                ('o2o (cdr (assq 'o2o-edge expose-diagram-palette)))
                ('fk (cdr (assq 'fk-edge expose-diagram-palette)))
                (_ nil))))))

      (when color
        (format "%s%s [%s color=\"%s\" fontcolor=\"%s\"]"
                arrow name attrs color color))))

   ;; A node that already states its own fill means it by something the
   ;; shape can't express -- the coverage graph's red-to-green gradient,
   ;; for instance. Overwriting it with a class color would throw that
   ;; information away, so explicit fills win.
   ((expose-diagram-attribute attrs "fillcolor")
    nil)

   ;; Node declaration.
   (t
    (let* ((colors (expose-diagram-color (expose-diagram-classify attrs)))

           (focused
            (expose-diagram-focus-node-p name attrs focus))

           ;; A bare `style=dashed' -- how call flow marks a callee whose
           ;; body wasn't visible -- would replace the default
           ;; "filled,rounded" wholesale and lose the fill, since the
           ;; last `style' in an attribute list wins. Re-state it
           ;; combined so the node keeps its color and reads as dashed.
           (dashed
            (string-match-p
             "\\bdashed\\b"
             (or (expose-diagram-attribute attrs "style") "")))

           (style
            (when (or dashed focused)
              (format " style=\"filled,rounded%s%s\""
                      (if dashed ",dashed" "")
                      (if focused ",bold" ""))))

           ;; The model this was invoked from: a heavier, colored border
           ;; rather than a different fill, so it stands out without
           ;; being mistaken for a different *kind* of node.
           (emphasis
            (when focused
              (format " color=\"%s\" penwidth=2.6"
                      (cdr (assq 'focus-edge expose-diagram-palette))))))

      (format "%s [%s fillcolor=\"%s\" color=\"%s\" fontcolor=\"%s\"%s%s]"
              name attrs
              (nth 0 colors) (nth 1 colors) (nth 2 colors)
              (or style "")
              ;; Last, so it overrides the border color set just above.
              (or emphasis ""))))))

(defun expose-diagram-style-clusters (dot)
  "Return DOT with consistent styling applied to each `subgraph cluster'.

Clusters are how the request-flow diagram draws pipeline layers. Graphviz
has no default-setting statement for them the way it does for nodes and
edges, so the attributes are injected into each one directly -- otherwise
they render as hard black rectangles that overpower the nodes inside.

Injected immediately after the opening brace, so anything the provider
set on a specific cluster still wins."

  (let ((border (cdr (assq 'cluster-border expose-diagram-palette)))
        (label (cdr (assq 'cluster-label expose-diagram-palette))))

    (replace-regexp-in-string
     "\\(subgraph[ \t]+cluster[A-Za-z0-9_]*[ \t\n]*{\\)"
     (lambda (match)
       (concat match
               (format
                " graph [style=rounded,color=\"%s\",fontcolor=\"%s\",fontsize=10,penwidth=1.0,margin=10];"
                border label)))
     dot t t)))

(defun expose-diagram-color-statements (dot &optional focus)
  "Return DOT with per-node and error-edge colors applied.

Done in a temp buffer rather than with `replace-regexp-in-string' and a
function replacement: there, match-data indices are absolute against the
whole string while the function only receives the matched substring, so
reading groups out of it silently yields wrong offsets and splices the
replacement into the middle of the match. In a buffer, `match-string'
and `replace-match' agree on positions."

  (with-temp-buffer
    (insert dot)
    (goto-char (point-min))

    (while (re-search-forward
            (concat "\\(->[ \t]*\\)?"
                    "\\([A-Za-z_][A-Za-z0-9_]*\\|\"[^\"]*\"\\)"
                    "[ \t\n]*\\[\\([^][]*\\)\\]")
            nil t)

      ;; Groups are read first, then the replacement is computed under
      ;; `save-match-data': classifying a node runs `string-match' on its
      ;; attributes, which would otherwise clobber the match data this
      ;; loop's `replace-match' depends on -- leaving it to splice text in
      ;; at stale positions, move point backwards, and re-match the same
      ;; statement forever.
      (let* ((arrow (match-string 1))
             (name (match-string 2))
             (attrs (match-string 3))

             (replacement
              (save-match-data
                (expose-diagram-style-statement arrow name attrs focus))))

        (when replacement
          ;; LITERAL: labels carry escaped quotes, which would otherwise
          ;; be read as replacement syntax.
          (replace-match replacement t t))))

    (buffer-string)))

(defun expose-diagram-force-direction (dot direction)
  "Return DOT with its `rankdir' replaced by DIRECTION.

Orientation is asked for in each request's instruction, but an
instruction is a request, not a guarantee, and the difference between a
readable diagram and an unreadable ribbon is too large to leave to
compliance. Stripped and re-stated for the same reason `bgcolor' is:
whichever the provider chose, this is the one that applies."

  (if (not direction)
      dot

    (let ((stripped
           (replace-regexp-in-string
            "[ \t]*rankdir[ \t]*=[ \t]*\"?[A-Za-z]+\"?[ \t]*;?"
            ""
            dot)))

      (if (string-match
           (concat "\\(?:strict[ \t\n]+\\)?\\(?:di\\)?graph\\b[ \t\n]*"
                   "\\(?:[A-Za-z_][A-Za-z0-9_]*\\|\"[^\"]*\"\\)?[ \t\n]*{")
           stripped)

          (concat (substring stripped 0 (match-end 0))
                  (format "\n  rankdir=%s;" direction)
                  (substring stripped (match-end 0)))

        stripped))))

(defun expose-diagram-style-dot (dot &optional focus direction)
  "Return DOT restyled: graph-wide defaults plus per-node semantic colors.

Two passes. First the defaults (font, spacing, canvas) go in right after
the opening brace, where they apply to everything declared after them.
Then each node gets fill/border/text colors for what it represents --
entry, condition, error, exit, or plain step -- classified by
`expose-diagram-classify'. Explicit attributes are appended last so they
win over the defaults.

Any `bgcolor' the provider set is stripped: a hardcoded canvas defeats
the point of controlling the palette here.

Returns DOT unchanged when `expose-diagram-apply-theme' is nil, or when
the graph header can't be located."

  (if (not expose-diagram-apply-theme)
      (expose-diagram-force-direction dot direction)

    (let* ((dot (expose-diagram-force-direction dot direction))
           (canvas (cdr (assq 'canvas expose-diagram-palette)))
           (edge (cdr (assq 'edge expose-diagram-palette)))
           (edge-label (cdr (assq 'edge-label expose-diagram-palette)))
           (normal (expose-diagram-color 'normal))

           ;; Case-sensitively: this removes the *graph* attribute, which
           ;; DOT writes lowercase, and must not touch the `BGCOLOR' of
           ;; an HTML-like label's table cells, which is how the
           ;; migration diagram colours individual fields. With
           ;; `case-fold-search' left at its default this stripped those
           ;; too, silently discarding the only thing that made those
           ;; tables readable.
           (stripped
            (let ((case-fold-search nil))
              (replace-regexp-in-string
               "[ \t]*bgcolor[ \t]*=[ \t]*\"?[^\";,]*\"?[ \t]*;?"
               ""
               dot)))

           ;; Color the individual statements first: doing it after the
           ;; defaults are injected would mean re-matching those very
           ;; `node ['/`edge [' lines.
           (colored
            (expose-diagram-style-clusters
             (expose-diagram-color-statements stripped focus)))

           (defaults
            (mapconcat
             #'identity
             (list
              ""
              (format "  bgcolor=\"%s\";" canvas)
              "  pad=0.4;"
              "  nodesep=0.45;"
              "  ranksep=0.55;"
              (format "  fontname=\"%s\";" expose-diagram-font)
              (format "  fontcolor=\"%s\";" edge-label)
              "  fontsize=11;"
              (format
               (concat "  node [fontname=\"%s\" fontsize=11 shape=box "
                       "style=\"filled,rounded\" penwidth=1.2 margin=\"0.18,0.10\" "
                       "fillcolor=\"%s\" color=\"%s\" fontcolor=\"%s\"];")
               expose-diagram-font (nth 0 normal) (nth 1 normal) (nth 2 normal))
              (format
               (concat "  edge [fontname=\"%s\" fontsize=9 color=\"%s\" "
                       "fontcolor=\"%s\" penwidth=1.1 arrowsize=0.7];")
               expose-diagram-font edge edge-label)
              "")
             "\n")))

      (if (string-match
           (concat "\\(?:strict[ \t\n]+\\)?\\(?:di\\)?graph\\b[ \t\n]*"
                   "\\(?:[A-Za-z_][A-Za-z0-9_]*\\|\"[^\"]*\"\\)?[ \t\n]*{")
           colored)

          (concat
           (substring colored 0 (match-end 0))
           defaults
           (substring colored (match-end 0)))

        colored))))

(defun expose-diagram-render (dot format &optional focus direction)
  "Render DOT source using Graphviz output FORMAT (a `dot -T' name).

Returns (t . DATA-STRING) on success, or (nil . STDERR-STRING) when
`dot' rejects the source -- which happens often enough with generated
DOT (unescaped labels, mismatched braces) that the caller is expected to
surface the error rather than treat it as a dead end.

Reads output as binary: png/jpg/pdf are raster/binary formats that
Emacs' default decoding would corrupt, and SVG is unaffected by being
read as raw bytes (which is what `create-image' wants anyway)."

  (let ((stderr-file (make-temp-file "expose-diagram-err-")))

    (unwind-protect
        (with-temp-buffer
          (set-buffer-multibyte nil)

          (let* ((coding-system-for-read 'binary)
                 (status
                  (call-process-region
                   (expose-diagram-style-dot dot focus direction) nil
                   expose-diagram-dot-executable
                   nil
                   (list t stderr-file)
                   nil
                   (concat "-T" format))))

            (if (eq status 0)
                (cons t (buffer-string))

              (cons
               nil
               (string-trim
                (with-temp-buffer
                  (insert-file-contents stderr-file)
                  (buffer-string)))))))

      (delete-file stderr-file))))

(defun expose-diagram-render-svg (dot &optional focus direction)
  "Render DOT source to SVG. See `expose-diagram-render'."

  (expose-diagram-render dot "svg" focus direction))

;;; ---------------------------------------------------------------------------
;;; Display
;;; ---------------------------------------------------------------------------

(defvar expose-diagram-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'expose-diagram-show-source)
    (define-key map (kbd "g") #'expose-diagram-regenerate)
    (define-key map (kbd "w") #'expose-diagram-write-file)
    (define-key map (kbd "+") #'expose-diagram-zoom-in)
    (define-key map (kbd "=") #'expose-diagram-zoom-in)
    (define-key map (kbd "-") #'expose-diagram-zoom-out)
    (define-key map (kbd "0") #'expose-diagram-zoom-fit)
    (define-key map (kbd "1") #'expose-diagram-zoom-actual)
    (define-key map (kbd "q") #'quit-window)

    ;; Explicit horizontal panning. `truncate-lines' makes sideways
    ;; scrolling possible, but nothing binds it by default in a
    ;; `special-mode' buffer, and Evil's own `zl'/`zh' are awkward here.
    (define-key map (kbd "L") #'expose-diagram-scroll-right)
    (define-key map (kbd "H") #'expose-diagram-scroll-left)
    map)
  "Keymap for `expose-diagram-mode'.")

;;; ---------------------------------------------------------------------------
;;; Sizing
;;; ---------------------------------------------------------------------------

(defun expose-diagram-refresh-image ()
  "Redraw this buffer's diagram at `expose-diagram-scale'.

Rebuilt from the stored SVG rather than by re-running `dot': the vector
source is already here, and Emacs renders SVG at whatever size is asked
for, so zooming stays sharp and costs no subprocess."

  (unless expose-diagram-svg
    (user-error "No diagram in this buffer"))

  (let* ((inhibit-read-only t)

         (window
          (get-buffer-window (current-buffer) t))

         ;; Leave room for the two header lines, and a little slack so
         ;; the fitted image doesn't itself force a scrollbar.
         (max-width
          (when window
            (- (window-body-width window t) 20)))

         (max-height
          (when window
            (- (window-body-height window t)
               (* 3 (line-pixel-height)))))

         (image
          (apply
           #'create-image
           expose-diagram-svg 'svg t

           (cond
            ;; Explicit zoom factor.
            (expose-diagram-scale
             (list :scale expose-diagram-scale))

            ;; Fit: cap both dimensions, preserving aspect ratio. Only
            ;; shrinks -- `:max-*' never enlarges a small graph.
            ((and max-width max-height
                  (> max-width 0) (> max-height 0))
             (list :max-width max-width :max-height max-height))

            (t nil)))))

    (save-excursion
      (goto-char (point-min))

      ;; Replace just the image, keeping the header lines intact.
      (when (re-search-forward "\n\n" nil t)
        (delete-region (point) (point-max))
        (expose-diagram-insert-sliced image)))))

(defun expose-diagram-insert-sliced (image)
  "Insert IMAGE sliced into character-sized cells.

A whole image is one buffer position, so no amount of scrolling moves
*within* it: zoomed in past the window edge, the rest of the graph is
simply unreachable. `insert-sliced-image' splits it into a grid where
each slice is its own character, so ordinary vertical scrolling and
horizontal `scroll-left'/`scroll-right' traverse the image the way they
traverse text.

Slices are sized to roughly one character cell so that scroll granularity
matches text scrolling, but the grid is capped: a big graph at high zoom
would otherwise mean tens of thousands of slices, and past a point the
extra precision buys nothing while redisplay gets slower."

  (let* ((size
          (ignore-errors (image-size image t)))

         (line-height
          (max 1 (line-pixel-height)))

         (char-width
          (max 1 (frame-char-width)))

         (rows
          (if size
              (min 300 (max 1 (ceiling (cdr size) line-height)))
            40))

         (cols
          (if size
              (min 300 (max 1 (ceiling (car size) char-width)))
            40)))

    (insert-sliced-image image nil nil rows cols)))

(defun expose-diagram-zoom-set (scale)
  "Redraw the diagram at SCALE, or fit it to the window when SCALE is nil."

  (setq expose-diagram-scale scale)
  (expose-diagram-refresh-image)

  (message
   "Expose diagram: %s"
   (if scale (format "%.0f%%" (* 100 scale)) "fit to window")))

(defun expose-diagram-current-scale ()
  "Return the current explicit scale, defaulting to 1.0 when fitted."

  (or expose-diagram-scale 1.0))

(defun expose-diagram-zoom-in ()
  "Zoom the diagram in."
  (interactive)
  (expose-diagram-zoom-set (* (expose-diagram-current-scale) 1.25)))

(defun expose-diagram-zoom-out ()
  "Zoom the diagram out."
  (interactive)
  (expose-diagram-zoom-set (max 0.05 (/ (expose-diagram-current-scale) 1.25))))

(defun expose-diagram-zoom-fit ()
  "Fit the whole diagram inside the window."
  (interactive)
  (expose-diagram-zoom-set nil))

(defun expose-diagram-zoom-actual ()
  "Show the diagram at its natural size."
  (interactive)
  (expose-diagram-zoom-set 1.0))

(defun expose-diagram-scroll-right ()
  "Pan the diagram right by most of a window width."
  (interactive)
  (scroll-left (max 1 (/ (window-body-width) 2)) t))

(defun expose-diagram-scroll-left ()
  "Pan the diagram left by most of a window width."
  (interactive)
  (scroll-right (max 1 (/ (window-body-width) 2)) t))

(define-derived-mode expose-diagram-mode special-mode "Expose-Diagram"
  "Major mode for a rendered Expose diagram."
  (setq buffer-read-only t)
  (setq cursor-type nil)

  ;; Required for horizontal panning: the image is inserted as a grid of
  ;; slices (see `expose-diagram-insert-sliced'), so each row is a long
  ;; line of slice-characters. Wrapping those would stack the pieces of
  ;; one row on top of each other instead of letting them scroll sideways.
  (setq truncate-lines t)

  ;; Complements the slicing for smooth vertical movement.
  (when (fboundp 'pixel-scroll-precision-mode)
    (pixel-scroll-precision-mode 1)))

;; Evil's own state keymaps are consulted ahead of the major mode map, so
;; the bindings above are invisible under Evil: in normal state `s' is
;; `evil-substitute', `w' is `evil-forward-word-begin', and `g' is a
;; prefix. (`q' appeared to work only because evil-collection already
;; maps it to `quit-window' in special-mode buffers.) Re-declaring them
;; per-state is how the rest of Expose handles this -- see
;; `expose-watch-active-mode' and `expose-review-buffer-mode'.
(with-eval-after-load 'evil
  (dolist (state '(normal motion))
    (evil-define-key* state expose-diagram-mode-map
      (kbd "s") #'expose-diagram-show-source
      (kbd "g") #'expose-diagram-regenerate
      (kbd "w") #'expose-diagram-write-file
      (kbd "+") #'expose-diagram-zoom-in
      (kbd "=") #'expose-diagram-zoom-in
      (kbd "-") #'expose-diagram-zoom-out
      (kbd "0") #'expose-diagram-zoom-fit
      (kbd "1") #'expose-diagram-zoom-actual
      (kbd "L") #'expose-diagram-scroll-right
      (kbd "H") #'expose-diagram-scroll-left
      (kbd "q") #'quit-window))

  (evil-set-initial-state 'expose-diagram-mode 'normal))

(defun expose-diagram-show-source ()
  "Show the DOT source behind the current diagram."

  (interactive)

  (let ((dot expose-diagram-source))

    (unless dot
      (user-error "No DOT source recorded for this diagram"))

    (with-current-buffer (get-buffer-create expose-diagram-source-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert dot)
        (goto-char (point-min))
        (when (fboundp 'graphviz-dot-mode)
          (graphviz-dot-mode))
        (view-mode 1))
      (display-buffer (current-buffer)))))

(defun expose-diagram-write-file (file)
  "Write the current diagram to FILE, in the format its extension names.

Supported extensions are the keys of `expose-diagram-formats' (svg, png,
jpg/jpeg, pdf). The file is re-rendered from the original DOT source at
the requested format rather than converted from the SVG on screen, so a
PNG is a real Graphviz raster rather than a rasterized copy of something
already rendered."

  (interactive "FWrite diagram to (.svg/.png/.jpg/.pdf): ")

  (let* ((dot expose-diagram-source)

         (extension
          (downcase (or (file-name-extension file) "")))

         (format
          (cdr (assoc extension expose-diagram-formats))))

    (unless dot
      (user-error "No DOT source recorded for this diagram"))

    (unless format
      (user-error
       "Don't know how to write `%s'; use one of: %s"
       (if (string-empty-p extension) file extension)
       (string-join (mapcar #'car expose-diagram-formats) ", ")))

    (let ((result (expose-diagram-render dot format)))

      (unless (car result)
        (user-error "Graphviz failed writing %s: %s" format (cdr result)))

      ;; `write-region' with binary coding: png/jpg/pdf are binary, and
      ;; letting Emacs pick an encoding here would corrupt them.
      (let ((coding-system-for-write 'binary))
        (write-region (cdr result) nil file))

      (message "Wrote %s (%s, %d bytes)"
               file format (length (cdr result))))))

(defun expose-diagram-regenerate ()
  "Re-run the diagram against the code it was generated from."

  (interactive)

  (let ((origin expose-diagram-origin))

    (unless (and origin (buffer-live-p (nth 0 origin)))
      (user-error "The buffer this diagram came from is gone"))

    (with-current-buffer (nth 0 origin)
      (save-excursion
        (goto-char (min (nth 1 origin) (point-max)))
        (call-interactively
         (or (nth 2 origin) #'expose-run-control-flow-diagram))))))

(defun expose-diagram-display (svg dot title &optional origin)
  "Display SVG, produced from DOT, in the Expose diagram buffer under TITLE.

ORIGIN is a (BUFFER POSITION COMMAND) list naming the code this depicts
and how it was produced, kept for `expose-diagram-regenerate'."

  (let ((buffer (get-buffer-create expose-diagram-buffer-name)))

    (with-current-buffer buffer

      (unless (derived-mode-p 'expose-diagram-mode)
        (expose-diagram-mode))

      (let ((inhibit-read-only t))
        (erase-buffer)

        (insert (propertize (concat title "\n") 'face 'bold))

        (insert
         (propertize
          "+/- zoom   0 fit   1 actual   H/L pan   s source   g regenerate   w write   q quit\n\n"
          'face 'shadow)))

      (setq expose-diagram-svg svg)
      (setq expose-diagram-source dot)
      (setq expose-diagram-origin origin)
      (setq expose-diagram-scale nil)
      (goto-char (point-min)))

    ;; Whole frame: these graphs get big, and a diagram squeezed into a
    ;; split is unreadable in exactly the cases it's most needed. Doom's
    ;; `(popup +all)' would otherwise route a `special-mode' buffer like
    ;; this into a small side popup, so the rule registered at the bottom
    ;; of this file opts out of that.
    ;;
    ;; `display-buffer-full-frame' records the previous layout in the
    ;; window's quit-restore parameter, so `q' (`quit-window') puts the
    ;; frame back the way it was rather than leaving the diagram's window
    ;; filling everything.
    (select-window
     (display-buffer buffer '(display-buffer-full-frame)))

    ;; Only now: fitting needs the window's real pixel dimensions, which
    ;; don't exist until the buffer is actually on screen.
    (with-current-buffer buffer
      (expose-diagram-refresh-image)
      (goto-char (point-min)))

    buffer))

(defun expose-diagram-display-failure (dot stderr title)
  "Show DOT and Graphviz's STDERR when rendering TITLE failed.

Deliberately not a bare error message: generated DOT is usually wrong in
one small, obvious way, so showing the source next to the parser's
complaint makes it a one-character fix rather than a regenerate-and-hope."

  (let ((buffer (get-buffer-create expose-diagram-source-buffer-name)))

    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)

        (insert (propertize (concat title " -- render failed\n\n") 'face 'error))
        (insert (propertize "Graphviz said:\n" 'face 'bold))
        (insert stderr "\n\n")
        (insert (propertize "DOT source:\n" 'face 'bold))
        (insert (or dot "(none)"))

        (goto-char (point-min))
        (view-mode 1))

      (display-buffer buffer))

    buffer))

;;; ---------------------------------------------------------------------------
;;; Doom popup opt-out
;;; ---------------------------------------------------------------------------

;; With Doom's `(popup +all)', a `special-mode' buffer like the diagram
;; would be captured into a small bottom popup, which fights the
;; full-frame display above. `:ignore t' tells Doom's popup system to
;; leave this buffer to `display-buffer' entirely.
;;
;; Guarded: Expose shouldn't hard-require Doom just for this.
(when (fboundp 'set-popup-rule!)
  (set-popup-rule! (regexp-quote expose-diagram-buffer-name) :ignore t))

(provide 'expose-diagram)
