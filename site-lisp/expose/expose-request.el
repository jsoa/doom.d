;;; expose-request.el -*- lexical-binding: t; -*-

(require 'expose-context)

(defcustom expose-request-output-instruction
  "Return the response as concise Markdown. Do not return XML, HTML, JSON, or custom tags. Do not mirror the request document structure. Use headings, bullet lists, and fenced code blocks when useful."
  "Instruction appended to every Expose request to control provider output format."
  :type 'string
  :group 'expose)

(defcustom expose-request-raw-output-instruction
  "Return only the raw, ready-to-insert text. Do not return Markdown. Do not add a heading or title. Do not wrap the response in code fences. Do not explain your reasoning or add commentary."
  "Instruction appended to Expose requests whose result is inserted directly
into a buffer (e.g. a commit message) rather than displayed as Markdown in a
popup."
  :type 'string
  :group 'expose)

;;; ---------------------------------------------------------------------------
;;; Request
;;; ---------------------------------------------------------------------------


(defun expose-request-create (type document-format instruction context &optional raw)
  "Return a request object.

When RAW is non-nil, append `expose-request-raw-output-instruction' instead
of `expose-request-output-instruction', for requests whose result is
inserted directly into a buffer rather than displayed as Markdown."

  (list
   :type type
   :document-format document-format
   :instruction
   (string-join
    (list
     instruction
     (if raw
         expose-request-raw-output-instruction
       expose-request-output-instruction))
    "\n\n")
   :context context))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun expose-request-select (context &rest keys)
  "Return a plist containing KEYS copied from CONTEXT."

  (let (result)

    (dolist (key keys)
      (let ((value
             (plist-get context key)))

        (when value
          (setq result
                (plist-put result key value)))))

    result))

(defun expose-request-select-with-git (context &rest keys)
  "Return a plist containing KEYS copied from CONTEXT plus git context."

  (let ((context-with-git
         (expose-context-with-git context))

        (selected-keys
         (delete-dups
          (append
           keys
           '(:git-status :git-diff))))

        result)

    (dolist (key selected-keys)
      (let ((value
             (plist-get context-with-git key)))

        (when value
          (setq result
                (plist-put result key value)))))

    result))

;;; ---------------------------------------------------------------------------
;;; Builders
;;; ---------------------------------------------------------------------------

(defun expose-request-review (context)
  "Build a code review request."

  (expose-request-create
   'review
   'xml

   "Review the current implementation for correctness, readability, maintainability, and potential bugs. Use the git diff/status when it helps explain the current change, but prioritize the focused code context."

   (expose-request-select-with-git
    context
    :project
    :language
    :file
    :scope
    :parent-scope
    :imports
    :focus)))

(defun expose-request-diagnostics (context)
  "Build a diagnostics request."

  (expose-request-create
   'diagnostics
   'xml

   "Explain the diagnostics for the current code, why they occur, and recommend the best fix."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :focus
    :code)))

(defun expose-request-explain (context)
  "Build an explanation request."

  (expose-request-create
   'explain
   'xml

   "Explain the selected symbol or construct in the context of this code."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :code)))

(defun expose-request-fix (context)
  "Build a fix request."

  (expose-request-create
   'fix
   'xml

   "Propose the smallest safe fix for the current code. Prefer a focused patch or replacement snippet. Do not rewrite unrelated code. Explain briefly why the fix is correct."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-refactor (context)
  "Build a refactor request."

  (expose-request-create
   'refactor
   'xml

   "Suggest a behavior-preserving refactor for the current code. Focus on readability, structure, naming, duplication, and maintainability. Do not change behavior. Prefer a concise replacement snippet and briefly explain the improvement."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-security (context)
  "Build a security review request."

  (expose-request-create
   'security
   'xml

   "Review the current code for security issues. Focus on authentication, authorization, permissions, injection risks, unsafe deserialization, file handling, secrets, user-controlled input, redirects, token handling, CSRF, XSS, SSRF, path traversal, and data exposure. Use the git diff/status to understand what changed. Be specific. If there is no meaningful security concern, say so clearly."

   (expose-request-select-with-git
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-performance (context)
  "Build a performance review request."

  (expose-request-create
   'performance
   'xml

   "Review the current code for performance issues. Focus on unnecessary work, repeated computation, inefficient queries, N+1 query patterns, blocking I/O, excessive allocations, avoidable re-renders, expensive loops, missing batching, missing caching, and scalability concerns. Use the git diff/status to understand what changed. Prefer practical fixes over theoretical micro-optimizations. If performance is already reasonable, say so clearly."

   (expose-request-select-with-git
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-tests (context)
  "Build a tests request."

  (expose-request-create
   'tests
   'xml

   "Suggest focused tests for the current code. Prefer practical test cases that cover normal behavior, edge cases, error paths, and regressions. Match the style and likely test framework of the project. Include concise example test code when useful."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-edge-cases (context)
  "Build an edge cases request."

  (expose-request-create
   'edge-cases
   'xml

   "Identify important edge cases for the current code. Focus on boundary inputs, missing or malformed data, empty states, concurrency/race conditions, permission differences, external failures, and surprising user behavior. Explain which cases matter most and why."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-flow (context)
  "Build a flow explanation request."

  (expose-request-create
   'flow
   'xml

   "Explain the execution flow of the current code. Walk through what happens step by step, including inputs, branches, side effects, return values, callbacks, async behavior, and important dependencies. Keep the explanation practical and code-focused."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-control-flow-diagram (context)
  "Build a control-flow diagram request.

Same context selection as `expose-request-flow' -- this is that same
question rendered as a graph rather than prose -- but asks for Graphviz
DOT and nothing else, and so passes RAW so the response isn't wrapped in
Markdown (see `expose-request-raw-output-instruction').

The instruction is deliberately prescriptive about node shapes and about
staying inside the visible code: a diagram reads as more authoritative
than prose does, so an invented edge is more misleading here than a
vague sentence would be."

  (expose-request-create
   'control-flow-diagram
   'xml

   (string-join
    (list
     "Produce a CONTROL FLOW graph of the current code as Graphviz DOT."
     ""
     "Rules:"
     "- Output a single `digraph' and nothing else. No prose, no Markdown, no code fences."
     "- Model control flow only: branches, loops, early returns, raised/caught exceptions, and the paths between them. Do not model the call graph of unrelated functions."
     "- One node per meaningful step. Label nodes with a short paraphrase of the code, not a line number."
     "- Shapes: `diamond' for a condition, `box' for a statement or block, `ellipse' for an entry point, `doubleoctagon' for a return or raise."
     "- Label edges out of a condition with the branch taken (e.g. \"true\"/\"false\", or the matched case)."
     "- Quote every label, and escape any embedded double quotes."
     "- Only include flow you can actually see in the provided code. If a called function's internals are not shown, treat the call as a single step rather than guessing what happens inside it."
     "- Set `rankdir=TB' and give the graph a short `label' naming what it depicts.")
    "\n")

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)

   'raw))

(defun expose-request-call-flow-diagram (context)
  "Build a call-flow diagram request.

Where `expose-request-control-flow-diagram' maps the branches *inside*
one unit of code, this maps outward: what it calls, and what those call
in turn. That's the axis most prone to invention -- a model asked what a
function \"calls\" will happily describe the insides of a dependency it
has never seen -- so the instruction repeatedly pins it to calls
actually present in the provided code, and asks for an explicit
`unresolved' marking rather than a guess."

  (expose-request-create
   'call-flow-diagram
   'xml

   (string-join
    (list
     "Produce a CALL FLOW graph of the current code as Graphviz DOT."
     ""
     "Rules:"
     "- Output a single `digraph' and nothing else. No prose, no Markdown, no code fences."
     "- Model what this code CALLS, and what those call in turn -- not its internal branching."
     "- Include a call only if the call site is visible in the provided code. Never invent a callee's internals; if its body isn't shown, it's a leaf."
     "- Shapes carry meaning, so use exactly these:"
     "  `ellipse' for the entry point being diagrammed;"
     "  `box' for a call to something defined in the provided code;"
     "  `component' for a call into a third-party or standard library;"
     "  `cylinder' for a call that performs I/O -- database, network, filesystem, cache, queue;"
     "  `doubleoctagon' for a raise."
     "- When a call only happens conditionally, label the edge with the condition (e.g. \"if payment completed\")."
     "- For any callee whose body you cannot actually see, add the attribute `style=dashed' to that node instead of guessing what it does. Do not write this into the label text."
     "- Quote every label, and escape any embedded double quotes. A label is a single quoted string: never place text after the closing quote."
     "- Correct: node1 [label=\"do_thing\", shape=box, style=dashed];"
     "- Wrong:   node1 [label=\"do_thing\" (unresolved)\"\", shape=box];"
     "- Set `rankdir=LR' and give the graph a short `label' naming the entry point.")
    "\n")

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)

   'raw))

(defun expose-request-data-flow-diagram (context)
  "Build a data-flow diagram request.

The third axis alongside `expose-request-control-flow-diagram' (when
things run) and `expose-request-call-flow-diagram' (what gets invoked):
where values come from, what reshapes them, and where they end up.

Edges carry the operation rather than nodes carrying a category, so
in-place mutation stays visible. Rebinding a name and mutating the
object it points at look almost identical in source and behave nothing
alike, and that distinction is the main thing this diagram exists to
surface."

  (expose-request-create
   'data-flow-diagram
   'xml

   (string-join
    (list
     "Produce a DATA FLOW graph of the current code as Graphviz DOT."
     ""
     "Rules:"
     "- Output a single `digraph' and nothing else. No prose, no Markdown, no code fences."
     "- Model how VALUES move: where each significant value originates, what derives or reshapes it, and where it finally goes. Not the branching, and not the call graph."
     "- Shapes carry meaning, so use exactly these:"
     "  `ellipse' for a value entering -- a parameter, or something read from outside the function;"
     "  `box' for a value derived inside this code;"
     "  `component' for a reshaping done by a third-party or standard library call;"
     "  `cylinder' for a destination that leaves the process -- database write, network send, file, cache, queue;"
     "  `doubleoctagon' for a value returned to the caller."
     "- Label a node with the value's name, and briefly what it holds when that isn't obvious."
     "- Label every edge with the operation that produces the target from the source: \"assigned\", \"mutated in place\", \"encoded\", \"saved\", \"passed to\", and so on."
     "- Say \"mutated in place\" explicitly when an existing object is modified rather than a new value being bound. Rebinding and mutation read alike in source and behave differently; making that visible is the point of this diagram."
     "- Only values and operations visible in the provided code. If a called function's body isn't shown, treat it as one step and don't invent what it does to the value."
     "- Quote every label, and escape any embedded double quotes. A label is a single quoted string: never place text after the closing quote."
     "- Set `rankdir=LR' and give the graph a short `label' naming what it depicts.")
    "\n")

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)

   'raw))

(defun expose-request-side-effects-diagram (context)
  "Build a side-effects diagram request.

Answers what calling this does to the world, which none of the other
diagrams quite does: control flow shows which paths run, call flow what
gets invoked, data flow where values go. This is about consequences that
outlive the call -- rows written, mail sent, jobs queued, services
called -- including the ones several frames down.

The transaction boundary is drawn because of a specific and common bug:
mail sent or a task enqueued inside `transaction.atomic' is not rolled
back with it, so a failure after that point leaves a notification about
a row that no longer exists. Grouping effects by whether they are inside
the block makes that visible instead of something you have to hold in
your head."

  (expose-request-create
   'side-effects-diagram
   'xml

   (string-join
    (list
     "Produce a SIDE EFFECTS diagram of the current code as Graphviz DOT."
     ""
     "Rules:"
     "- Output a single `digraph' and nothing else. No prose, no Markdown, no code fences."
     "- Show what this code changes outside itself: database writes, mail, queued or background tasks, cache writes, file writes, outbound network calls, signals, and mutation of state that outlives the call. Ignore pure computation and anything that only reads."
     "- Include effects performed by functions this code calls, when their bodies are visible. If a callee's body is not shown, include it as one effect node labelled with the call, and do not guess what it does inside."
     "- Shapes carry meaning, so use exactly these:"
     "  `ellipse' for the entry point;"
     "  `cylinder' for a database, cache or queue write;"
     "  `component' for an outbound call to a third-party or external service;"
     "  `box' for an intermediate step that leads to an effect;"
     "  `diamond' for a condition that decides whether an effect happens;"
     "  `doubleoctagon' for a raise."
     "- Label each effect edge with the operation: \"INSERT\", \"UPDATE\", \"DELETE\", \"sends email\", \"enqueues task\", \"HTTP POST\", \"writes cache\", and so on."
     "- If any effects occur inside a transaction (`transaction.atomic', `atomic()', an equivalent block), put those nodes in `subgraph cluster_transaction' labelled \"transaction.atomic\", and leave the rest outside it."
     "- Effects that cannot be rolled back -- mail, queued tasks, outbound HTTP, file writes -- must keep their own shape wherever they sit. Do not redraw them as database writes because they appear inside the transaction cluster."
     "- Only effects visible in the provided code. Do not infer effects from a function's name alone."
     "- Quote every label, and escape any embedded double quotes. A label is a single quoted string: never place text after the closing quote."
     "- Set `rankdir=TB' and give the graph a short `label' naming what it depicts.")
    "\n")

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)

   'raw))

(defun expose-request-request-flow-diagram (context)
  "Build a Django request-flow diagram request.

Where `expose-request-call-flow-diagram' draws a flat call tree, this
groups the same territory into the layers a request actually passes
through -- view, permissions, validation, domain, data, external -- so
what the request touches and in what order is legible at a glance, and a
missing layer (no permission check, a view reaching straight into the
ORM) shows up as an absence.

Routing is the one part that usually isn't visible: `urls.py' is rarely
the buffer this runs from, and a provider asked to supply the route
anyway will invent a plausible one. The instruction therefore admits
routing only when it's actually in the provided code."

  (expose-request-create
   'request-flow-diagram
   'xml

   (string-join
    (list
     "Produce a DJANGO REQUEST FLOW diagram of the current code as Graphviz DOT."
     ""
     "Rules:"
     "- Output a single `digraph' and nothing else. No prose, no Markdown, no code fences."
     "- Trace one HTTP request through this code, from where it enters to the response, in order."
     "- Group the steps into pipeline layers using `subgraph cluster_<name>' blocks with a `label', including only the layers this code actually has. Typical ones, in order: Routing, Middleware, View, Permissions, Validation, Domain, Data, External, Response."
     "- Shapes carry meaning, so use exactly these:"
     "  `ellipse' for the entry point (the view or handler being traced);"
     "  `diamond' for a gate that can reject the request -- permission, authentication, validation, throttling;"
     "  `box' for an ordinary step;"
     "  `cylinder' for a database, cache, queue or network access;"
     "  `component' for framework or third-party machinery (DRF serializers, middleware you don't own);"
     "  `doubleoctagon' for a response returned or an exception raised."
     "- Label edges with what moves or what decides: \"valid\", \"denied (403)\", \"queryset\", \"serialized\", and so on."
     "- Show the rejection paths, not just the success path. A gate with no failure edge is the most misleading thing this diagram can contain."
     "- Include routing (URL patterns) ONLY if the URL configuration is present in the provided code. If it isn't, start at the view and do not guess the route."
     "- Only steps visible in the provided code. If a called function's body isn't shown, treat it as one step rather than inventing its internals."
     "- Quote every label, and escape any embedded double quotes. A label is a single quoted string: never place text after the closing quote."
     "- Set `rankdir=LR' and give the graph a short `label' naming the endpoint or view being traced.")
    "\n")

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)

   'raw))

(defun expose-request-er-diagram (context)
  "Build an entity-relationship diagram request.

The most trustworthy of the diagram requests, because its source is
declarative: a `ForeignKey' and its `related_name' are written down, not
inferred, so there is far less for the provider to invent than in
`expose-request-call-flow-diagram'.

The record-label escaping rule below matters more than it looks:
Graphviz's record shapes give `{', `}', `|', `<' and `>' structural
meaning, so an unescaped one in a field type silently reshapes the
entire node."

  (expose-request-create
   'er-diagram
   'xml

   (string-join
    (list
     "Produce an ENTITY RELATIONSHIP diagram of the data models in this code, as Graphviz DOT."
     ""
     "Rules:"
     "- Output a single `digraph' and nothing else. No prose, no Markdown, no code fences."
     "- One node per model/entity actually defined or referenced in the provided code. Do not invent models."
     "- Models defined here: `shape=Mrecord', with a record label of the form"
     "  \"{ModelName|field: Type\\lfield: Type\\l}\" -- note the trailing \\l on each field line."
     "- Include the primary key, every foreign/relational key, and the few fields that identify the record. Omit routine bookkeeping fields; a readable node beats a complete one."
     "- Models from outside this code (framework or third-party, e.g. Django's auth user): `shape=component' with just the dotted name as the label, no field list."
     "- Abstract or base models: add `style=dashed'."
     "- One edge per relationship, from the model that DECLARES the field to the model it points at, labelled with the field name:"
     "  ForeignKey / many-to-one: `arrowhead=crow';"
     "  ManyToMany: `dir=both, arrowhead=crow, arrowtail=crow';"
     "  OneToOne: `arrowhead=tee'."
     "- Add \" (nullable)\" to an edge's label when the relation allows null."
     "- Escape any literal `{', `}', `|', `<' or `>' inside a record label as \\{ \\} \\| \\< \\> -- unescaped they are record structure, not text, and will corrupt the node."
     "- Quote every label, and escape any embedded double quotes. A label is a single quoted string: never place text after the closing quote."
     "- Set `rankdir=LR' and give the graph a short `label' naming what it depicts.")
    "\n")

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :code)

   'raw))

(defun expose-request-usage (context)
  "Build a usage request."

  (expose-request-create
   'usage
   'xml

   "Explain how to use the selected symbol, function, class, component, or construct. Include expected inputs, outputs, side effects, important constraints, and one or two realistic usage examples when helpful."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-docstring (context)
  "Build a docstring request."

  (expose-request-create
   'docstring
   'xml

   "Write or improve a docstring/comment for the current code. Match the language and project style. Prefer a concise, useful docstring that explains purpose, important parameters, return value, side effects, and notable exceptions. Return only the suggested docstring/comment unless a brief note is necessary."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-summary (context)
  "Build a summary request."

  (expose-request-create
   'summary
   'xml

   "Summarize the current code clearly and briefly. Explain what it does, why it exists, its important dependencies, and any notable side effects or assumptions. Avoid rewriting the code."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-types (context)
  "Build a types request."

  (expose-request-create
   'types
   'xml

   "Explain the important types involved in the current code. Focus on the selected symbol or construct, inferred types, declared types, generics, nullable/optional values, return types, and any type mismatch risks. Be specific to this language and codebase."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-concurrency (context)
  "Build a concurrency review request."

  (expose-request-create
   'concurrency
   'xml

   "Review the current code for concurrency, ordering, and race-condition risks. Focus on shared mutable state, async callbacks, retries, idempotency, transactions, locks, database consistency, background jobs, request ordering, React effects, stale closures, and external side effects. Explain whether concurrency is actually relevant here. Prefer practical mitigations over speculative concerns."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-invariants (context)
  "Build an invariants request."

  (expose-request-create
   'invariants
   'xml

   "Identify the important invariants in the current code. Explain what must be true before execution, during execution, and after execution. Include assumptions about data shape, state, permissions, transactions, ordering, types, and side effects. Point out any invariant that is not enforced clearly."

   (expose-request-select
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-risks (context)
  "Build a risks request."

  (expose-request-create
   'risks
   'xml

   "Identify practical risks in the current code. Focus on assumptions that could break, hidden coupling, fragile behavior, unclear ownership, maintenance risks, runtime failures, future-change hazards, operational concerns, and user-impacting failure modes. Do not duplicate a generic review; prioritize the risks most likely to matter."

   (expose-request-select-with-git
    context
    :project
    :language
    :file
    :diagnostics
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-why (context)
  "Build a why request."

  (expose-request-create
   'why
   'xml

   "Explain why this code may have been written this way. Focus on likely design intent, tradeoffs, constraints, alternatives that may have been avoided, framework idioms, and project-specific context. Clearly separate confident observations from guesses."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-mental-model (context)
  "Build a mental model request."

  (expose-request-create
   'mental-model
   'xml

   "Build a concise mental model for understanding the current code. Explain the main moving parts, responsibilities, data flow, control flow, dependencies, and how to reason about changes safely. Prefer a clear conceptual map over line-by-line explanation."

   (expose-request-select
    context
    :project
    :language
    :file
    :imports
    :focus
    :scope
    :parent-scope
    :code)))

(defun expose-request-commit-message (context)
  "Build a commit message request.

Scoped to staged changes only (`expose-context-git-staged-only'): a
commit message describes what is about to be committed, and a file
edited but not yet `git add'ed will not be part of that commit, however
current its edits are in the working tree. Every other request that
folds in git context wants the opposite -- the full working-tree diff --
which is why this is a narrow `let' around just this one call rather
than a change to what `expose-context-with-git' does by default."

  (let ((expose-context-git-staged-only t))
    (expose-request-create
     'commit-message
     'xml

     "Write a clear git commit message for the currently staged changes. Use the git diff and status as the primary source of truth -- both describe only what has been staged, not any other edits sitting unstaged in the working tree. Prefer a concise conventional-commit style subject when appropriate, followed by a short body only if useful. Do not invent changes that are not present in the diff."

     (expose-request-select-with-git
      context
      :project
      :language
      :file
      :focus
      :scope)

     t)))

(defun expose-request-changelog (context)
  "Build a changelog request."

  (expose-request-create
   'changelog
   'xml

   "Write a concise changelog entry for the current changes. Use the git diff and status as the primary source of truth. Focus on user-visible behavior, developer-facing changes, fixes, and notable internal improvements. Do not invent changes that are not present in the diff."

   (expose-request-select-with-git
    context
    :project
    :language
    :file
    :focus
    :scope)))

;;; ---------------------------------------------------------------------------
;;; Dispatcher
;;; ---------------------------------------------------------------------------

(defun expose-request-build (type)
  "Build a request of TYPE."

  (let ((context
         (expose-context-build)))

    (pcase type
      ('review
       (expose-request-review context))

      ('diagnostics
       (expose-request-diagnostics context))

      ('explain
       (expose-request-explain context))

      ('fix
       (expose-request-fix context))

      ('refactor
       (expose-request-refactor context))

      ('security
       (expose-request-security context))

      ('performance
       (expose-request-performance context))

      ('tests
       (expose-request-tests context))

      ('edge-cases
       (expose-request-edge-cases context))

      ('flow
       (expose-request-flow context))

      ('control-flow-diagram
       (expose-request-control-flow-diagram context))

      ('call-flow-diagram
       (expose-request-call-flow-diagram context))

      ('er-diagram
       (expose-request-er-diagram context))

      ('data-flow-diagram
       (expose-request-data-flow-diagram context))

      ('request-flow-diagram
       (expose-request-request-flow-diagram context))

      ('side-effects-diagram
       (expose-request-side-effects-diagram context))

      ('usage
       (expose-request-usage context))

      ('docstring
       (expose-request-docstring context))

      ('summary
       (expose-request-summary context))

      ('types
       (expose-request-types context))

      ('concurrency
       (expose-request-concurrency context))

      ('invariants
       (expose-request-invariants context))

      ('risks
       (expose-request-risks context))

      ('why
       (expose-request-why context))

      ('mental-model
       (expose-request-mental-model context))

      ('commit-message
       (expose-request-commit-message context))

      ('changelog
       (expose-request-changelog context))

      (_
       (error "Unknown request type: %s" type)))))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-request-debug (type)
  "Debug request TYPE."

  (interactive
   (list
    (intern
     (completing-read
      "Request type: "
      '(review
        diagnostics
        explain
        fix
        refactor
        security
        performance
        tests
        edge-cases
        flow
        usage
        docstring
        summary
        types
        concurrency
        invariants
        risks
        why
        mental-model
        commit-message
        changelog)))))

  (let ((buffer
         (get-buffer-create
          (format "*EXPOSE %s*"
                  (capitalize
                   (symbol-name type))))))

    (pp
     (expose-request-build type)
     buffer)

    (pop-to-buffer buffer)))

(provide 'expose-request)
