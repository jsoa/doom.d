;;; expose-review-request.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'expose-log)

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

  "You are performing a senior-engineer code review of the provided branch diff and local changes.

Review only the supplied context. Do not invent files, functions, APIs, requirements, or behavior that are not present.

Focus on:
- correctness bugs
- security issues
- data integrity risks
- idempotency/retry issues
- transaction/concurrency problems
- performance regressions
- missing tests
- maintainability problems
- confusing or stale comments/docstrings
- small cleanup items when they meaningfully improve the change

Return only valid JSON. Do not return Markdown. Do not wrap the JSON in a code fence.

Use this exact top-level shape:

{
  \"items\": [
    {
      \"id\": \"R1\",
      \"severity\": \"high|medium|low|info\",
      \"category\": \"correctness|security|performance|tests|docs|maintainability|style\",
      \"file\": \"relative/path/from/project/root.py\",
      \"line_start\": 10,
      \"line_end\": 20,
      \"title\": \"Short actionable title\",
      \"comment\": \"Clear review comment explaining the issue and why it matters.\",
      \"anchor_text\": \"Small original code snippet from the affected area when possible.\",
      \"suggestion\": {
        \"kind\": \"none|patch\",
        \"patch\": \"\"
      }
    }
  ]
}

Rules:
- Use stable IDs R1, R2, R3, etc.
- Prefer fewer high-quality findings over noisy comments.
- Line numbers should point to the new/current file when possible.
- Use file paths relative to the project root.
- suggestion.kind should be \"none\" for now unless you are very confident in a small patch.
- If there are no useful findings, return {\"items\": []}.")

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

(defun expose-review-request-normalize-suggestion (raw)
  "Normalize RAW suggestion object."

  (when raw
    (let ((kind
           (expose-review-request-symbol
            (expose-review-request-json-get raw :kind)
            'none))

          (patch
           (or
            (expose-review-request-json-get raw :patch)
            "")))

      (list
       :kind kind
       :patch patch))))

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
