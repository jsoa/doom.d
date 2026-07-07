;;; expose-request.el -*- lexical-binding: t; -*-

(require 'expose-context)

(defcustom expose-request-output-instruction
  "Return the response as concise Markdown. Do not return XML, HTML, JSON, or custom tags. Do not mirror the request document structure. Use headings, bullet lists, and fenced code blocks when useful."
  "Instruction appended to every Expose request to control provider output format."
  :type 'string
  :group 'expose)

;;; ---------------------------------------------------------------------------
;;; Request
;;; ---------------------------------------------------------------------------


(defun expose-request-create (type document-format instruction context)
  "Return a request object."

  (list
   :type type
   :document-format document-format
   :instruction
   (string-join
    (list
     instruction
     expose-request-output-instruction)
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

;;; ---------------------------------------------------------------------------
;;; Builders
;;; ---------------------------------------------------------------------------

(defun expose-request-review (context)
  "Build a code review request."

  (expose-request-create
   'review
   'xml

   "Review the current implementation for correctness, readability, maintainability, and potential bugs."

   (expose-request-select
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

   "Review the current code for security issues. Focus on authentication, authorization, permissions, injection risks, unsafe deserialization, file handling, secrets, user-controlled input, redirects, token handling, CSRF, XSS, SSRF, path traversal, and data exposure. Be specific. If there is no meaningful security concern, say so clearly."

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

(defun expose-request-performance (context)
  "Build a performance review request."

  (expose-request-create
   'performance
   'xml

   "Review the current code for performance issues. Focus on unnecessary work, repeated computation, inefficient queries, N+1 query patterns, blocking I/O, excessive allocations, avoidable re-renders, expensive loops, missing batching, missing caching, and scalability concerns. Prefer practical fixes over theoretical micro-optimizations. If performance is already reasonable, say so clearly."

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
        mental-model)))))

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
