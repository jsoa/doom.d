;;; expose-review-request.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'expose-log)

(defun expose-review-request-format-untracked-files (entries)
  "Return untracked file ENTRIES formatted for review request."

  (string-join
   (mapcar
    (lambda (entry)
      (format
       "## %s%s\n\n%s"
       (plist-get entry :file)
       (if (plist-get entry :truncated)
           " [truncated]"
         "")
       (plist-get entry :content)))
    entries)
   "\n\n"))

(defun expose-review-request-format-diagnostic (item)
  "Return diagnostic ITEM formatted for the review request."

  (format
   "%s:%s [%s/%s] %s%s"
   (plist-get item :file)
   (plist-get item :line)
   (plist-get item :tool)
   (plist-get item :severity)
   (plist-get item :message)
   (let ((code
          (plist-get item :code)))

     (if (and code
              (not
               (string-empty-p code)))
         (format " (%s)" code)
       ""))))

(defun expose-review-request-format-diagnostics (diagnostics)
  "Return DIAGNOSTICS formatted for the review request."

  (let ((items
         (plist-get diagnostics :items)))

    (if items

        (string-join
         (mapcar
          #'expose-review-request-format-diagnostic
          items)
         "\n")

      "No diagnostics reported for changed Python files.")))

(defun expose-review-request-format-changed-files (entries)
  "Return tracked changed file ENTRIES formatted for review request."

  (string-join
   (mapcar
    (lambda (entry)
      (format
       "## %s%s\n\n%s"
       (plist-get entry :file)
       (if (plist-get entry :truncated)
           " [truncated]"
         "")
       (plist-get entry :content)))
    entries)
   "\n\n"))

(defun expose-review-request-cdata (text)
  "Return TEXT safe for a CDATA section."

  (replace-regexp-in-string
   "]]>"
   "]]]]><![CDATA[>"
   (or text "")
   t
   t))

(defun expose-review-request-section (name text)
  "Return XML section NAME containing TEXT."

  (format
   "<%s><![CDATA[%s]]></%s>\n"
   name
   (expose-review-request-cdata text)
   name))

(defun expose-review-request-format-list (items)
  "Return ITEMS formatted as lines."

  (if items
      (string-join items "\n")
    ""))

(defun expose-review-request-format-metadata (metadata)
  "Return METADATA formatted for the review request."

  (string-join
   (mapcar
    (lambda (entry)
      (format
       "## %s\n\n%s"
       (plist-get entry :file)
       (plist-get entry :content)))
    metadata)
   "\n\n"))

(defun expose-review-request-instruction ()
  "Return the AI instruction for branch-level code review."

  "You are performing a strict senior-engineer code review of the provided branch diff, staged changes, unstaged changes, full contents of small changed files, untracked file contents, Pyright/Ruff diagnostics from changed Python files, and TypeScript/ESLint diagnostics from changed frontend files.

Review only the supplied context. Do not invent files, functions, APIs, requirements, or behavior that are not present.

Your job is to find actionable issues in this change set. Be thorough. Prefer useful findings over volume, but do not stop after the first few issues if more meaningful issues exist.

Review high, medium, low, and info-level findings.

Review checklist:
- correctness bugs
- broken imports, missing dependencies, or wrong package assumptions
- security issues and secret-handling problems
- data integrity risks
- idempotency, retry, and duplicate-side-effect risks
- transaction, ordering, race-condition, and concurrency problems
- performance regressions, unnecessary queries, or expensive loops
- Dockerfile, docker-compose, and container runtime problems
- local development environment problems such as direnv, pyenv, venv, Pyright, pytest, and editor config
- deployment/configuration risks
- missing or weak tests
- misleading test configuration
- maintainability problems
- confusing names or hidden coupling
- stale, misleading, or missing comments/docstrings
- debug/demo code accidentally left in app code
- import-time side effects
- cleanup items when they meaningfully improve the change
- Pyright/Ruff/TypeScript/ESLint diagnostics from changed files

For each potential issue, ask:
- Is this caused by the supplied change?
- Could this break local development, tests, deployment, runtime behavior, or future maintenance?
- Is there enough evidence in the provided context?
- Can the developer take a concrete action?

Return only valid JSON. Do not return Markdown. Do not wrap the JSON in a code fence.

Use this exact top-level shape:

{
  \"summary\": {
    \"reviewed\": [\"short note about reviewed areas\"],
    \"not_reviewed\": [\"short note about important context not provided, if any\"]
  },
  \"items\": [
    {
      \"id\": \"R1\",
      \"severity\": \"high|medium|low|info\",
      \"category\": \"correctness|security|performance|tests|docs|maintainability|style|dev-environment|docker|configuration\",
      \"file\": \"relative/path/from/project/root.py\",
      \"line_start\": 10,
      \"line_end\": 20,
      \"title\": \"Short actionable title\",
      \"comment\": \"Clear review comment explaining the issue, why it matters, and what to change.\",
      \"anchor_text\": \"Small original code snippet from the affected area when possible.\",
      \"suggestion\": {
        \"kind\": \"none|text|patch\",
        \"text\": \"Concrete sugguested fix or implementation direction.\"
        \"patch\": \"\"
      }
    }
  ]
}

Severity guidance:
- high: likely breakage, security risk, data loss, serious runtime risk, or deploy-blocking problem
- medium: likely bug, bad config, missing dependency, weak test coverage, or important maintainability issue
- low: concrete cleanup, docs, naming, minor config, or weaker but useful concern
- info: optional observation or nice-to-have improvement

Rules:
- Use stable IDs R1, R2, R3, etc.
- Prefer 5 to 15 meaningful findings when issues exist.
- It is okay to return fewer findings if the change set is small or clean.
- Do not create filler findings.
- Line numbers should point to the new/current file when possible.
- Use file paths relative to the project root.
- If there are no useful findings, return {\"summary\":{\"reviewed\":[],\"not_reviewed\":[]},\"items\":[]}.
Suggestion rules:
- Use suggestion.kind \"patch\" whenever the fix is a small, obvious, local edit that can be expressed safely as a minimal unified diff.
- Good patch candidates include typo fixes, copy changes, small config value changes, one-line condition fixes, import fixes, renamed identifiers when the local context is clear, and small test additions.
- Use suggestion.kind \"text\" when the fix requires judgment, broader refactoring, missing context, multiple possible designs, or a patch would be risky.
- Use suggestion.text for a short human-readable fix summary.
- Use suggestion.patch only for unified diff text.
- Use suggestion.kind \"none\" only when there is genuinely no useful suggestion beyond the comment.
- Do not invent large patches.
- Do not suggest applying patches automatically.

Patch format:
- Use a minimal unified diff.
- Include only the affected file.
- Include enough context to identify the edit.
- Prefer patches under 15 changed lines.

Example patch suggestion:

{
  \"kind\": \"patch\",
  \"text\": \"Correct the visible footer typo.\",
  \"patch\": \"--- a/src/app/components/global/footer.tsx\n+++ b/src/app/components/global/footer.tsx\n@@\n-Intagram\n+Instagram\"
}
"
  )

(defun expose-review-request-build-document (context)
  "Build an AI review request document from CONTEXT."

  (concat
   "<expose-code-review-request>\n"

   (expose-review-request-section
    "instruction"
    (expose-review-request-instruction))

   "<context>\n"

   (expose-review-request-section
    "project"
    (format
     "Project: %s\nRoot: %s"
     (plist-get context :project-name)
     (plist-get context :project-root)))

   (expose-review-request-section
    "branch"
    (format
     "Branch: %s\nBase branch: %s\nMerge base: %s"
     (plist-get context :branch)
     (plist-get context :base-branch)
     (or
      (plist-get context :merge-base)
      "")))

   (expose-review-request-section
    "git-status"
    (or
     (plist-get context :git-status)
     ""))

   (expose-review-request-section
    "changed-files"
    (expose-review-request-format-list
     (plist-get context :changed-files)))

   (expose-review-request-section
    "changed-file-contents"
    (expose-review-request-format-changed-files
     (plist-get context :changed-file-contents)))

   (expose-review-request-section
    "commit-log"
    (or
     (plist-get context :commit-log)
     ""))

   (expose-review-request-section
    "branch-diff"
    (or
     (plist-get context :branch-diff)
     ""))

   (expose-review-request-section
    "staged-diff"
    (or
     (plist-get context :staged-diff)
     ""))

   (expose-review-request-section
    "unstaged-diff"
    (or
     (plist-get context :unstaged-diff)
     ""))

   (expose-review-request-section
    "untracked-file-contents"
    (expose-review-request-format-untracked-files
     (plist-get context :untracked-file-contents)))

   (expose-review-request-section
    "diagnostics"
    (expose-review-request-format-diagnostics
     (plist-get context :diagnostics)))

   (expose-review-request-section
    "project-metadata"
    (expose-review-request-format-metadata
     (plist-get context :project-metadata)))

   "</context>\n"
   "</expose-code-review-request>\n"))

(defun expose-review-request-strip-fence (text)
  "Extract JSON from TEXT, removing common Markdown fences."

  (let ((cleaned
         (string-trim
          (substring-no-properties
           (or text "")))))

    (cond
     ((string-match
       "```json[[:space:]\n]*\\(\\(?:.\\|\n\\)*?\\)[[:space:]\n]*```"
       cleaned)
      (string-trim
       (match-string 1 cleaned)))

     ((string-match
       "```[[:space:]\n]*\\(\\(?:.\\|\n\\)*?\\)[[:space:]\n]*```"
       cleaned)
      (string-trim
       (match-string 1 cleaned)))

     (t
      cleaned))))

(defun expose-review-request-extract-json (text)
  "Extract a JSON object string from TEXT."

  (let* ((cleaned
          (expose-review-request-strip-fence text))

         (start
          (string-match "{" cleaned))

         (end
          (cl-position
           ?}
           cleaned
           :from-end t)))

    (unless (and start end)
      (error "Review response did not contain a JSON object"))

    (substring
     cleaned
     start
     (1+ end))))

(defun expose-review-request-json-get (plist &rest keys)
  "Return first non-nil value in PLIST for KEYS."

  (seq-some
   (lambda (key)
     (plist-get plist key))
   keys))

(defun expose-review-request-symbol (value fallback)
  "Return VALUE normalized as a symbol, or FALLBACK."

  (cond
   ((symbolp value)
    value)

   ((stringp value)
    (intern
     (downcase value)))

   (t
    fallback)))

(defun expose-review-request-number (value fallback)
  "Return VALUE as number, or FALLBACK."

  (cond
   ((numberp value)
    value)

   ((stringp value)
    (or
     (string-to-number value)
     fallback))

   (t
    fallback)))

(defun expose-review-request-normalize-suggestion (suggestion)
  "Normalize review SUGGESTION."

  (let* ((kind-value
          (or
           (expose-review-request-json-get suggestion :kind)
           "none"))

         (kind
          (expose-review-request-symbol kind-value 'none))

         (text
          (or
           (expose-review-request-json-get suggestion :text)
           ""))

         (patch
          (or
           (expose-review-request-json-get suggestion :patch)
           "")))

    ;; Be forgiving. If the model provides a patch/text but forgets to set
    ;; the matching kind, preserve the useful suggestion instead of hiding it.
    (cond
     ((and patch
           (not
            (string-empty-p patch)))
      (setq kind 'patch))

     ((and text
           (not
            (string-empty-p text)))
      (setq kind 'text))

     ((not
       (memq kind
             '(none text patch)))
      (setq kind 'none)))

    (list
     :kind kind
     :text text
     :patch patch)))

(defun expose-review-request-normalize-item (raw index)
  "Normalize RAW review item at INDEX."

  (let* ((file
          (expose-review-request-json-get raw :file))

         (title
          (or
           (expose-review-request-json-get raw :title)
           "Untitled review item"))

         (line-start
          (expose-review-request-number
           (expose-review-request-json-get raw :line_start :line-start)
           1))

         (line-end
          (expose-review-request-number
           (expose-review-request-json-get raw :line_end :line-end)
           line-start)))

    (when (and
           (stringp file)
           (not
            (string-empty-p file)))

      (list
       :id
       (or
        (expose-review-request-json-get raw :id)
        (format "R%d" index))

       :severity
       (expose-review-request-symbol
        (expose-review-request-json-get raw :severity)
        'medium)

       :category
       (expose-review-request-symbol
        (expose-review-request-json-get raw :category)
        'maintainability)

       :status 'pending
       :file file
       :line-start line-start
       :line-end line-end
       :title title

       :comment
       (or
        (expose-review-request-json-get raw :comment)
        "")

       :anchor-text
       (or
        (expose-review-request-json-get raw :anchor_text :anchor-text)
        "")

       :suggestion
       (expose-review-request-normalize-suggestion
        (expose-review-request-json-get raw :suggestion))))))

(defun expose-review-request-parse-items (response)
  "Parse review items from provider RESPONSE."

  (let* ((json-string
          (expose-review-request-extract-json response))

         (json-object
          (json-parse-string
           json-string
           :object-type 'plist
           :array-type 'list
           :null-object nil
           :false-object nil))

         (raw-items
          (or
           (plist-get json-object :items)
           nil)))

    (cl-loop
     for raw in raw-items
     for index from 1
     for item = (expose-review-request-normalize-item raw index)
     when item
     collect item)))

(provide 'expose-review-request)
