;;; expose-review-region.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'markdown-mode nil t)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-provider)
(require 'expose-redact)
(require 'expose-transport)
(require 'expose-hover)
(require 'expose-review-request)

(defgroup expose-review-region nil
  "Review region for selected regions."
  :group 'expose-review)

(defcustom expose-review-region-context-lines 20
  "Number of surrounding context lines included with region review."
  :type 'integer
  :group 'expose-review-region)

(defcustom expose-review-region-provider-timeout-seconds 180
  "Seconds to wait for an AI region review provider before failing the review."
  :type 'integer
  :group 'expose-review-region)

(defcustom expose-review-region-stale-active-seconds 3600
  "Seconds after which a still-\"running\" Expose region review is orphaned.

A review normally reaches a terminal state (ready/failed) well within
`expose-review-region-provider-timeout-seconds'. If it is still \"running\"
far longer than that -- typically because Emacs or the provider process was
killed mid-review, leaving nothing left to complete it or time it out --
treat it as abandoned so it does not block new reviews on the same location
or accumulate in the active directory forever."
  :type 'integer
  :group 'expose-review-region)

(defvar expose-provider-default)

(defvar expose-review-region-active-processes
  (make-hash-table :test 'equal)
  "Map of active Expose region review session IDs to their live provider process.

This is intentionally not part of the persisted session plist: process
objects are only meaningful within the current Emacs session, so tracking
them here (rather than in the on-disk `.eld' session) lets both the timeout
handler and manual cancellation terminate the right process without trying
to serialize it.")

(defun expose-review-region-register-process (id process)
  "Record PROCESS as the live provider process for region review ID."

  (if (and process
           (processp process))

      (puthash id process expose-review-region-active-processes)

    (remhash id expose-review-region-active-processes)))

(defun expose-review-region-forget-process (id)
  "Stop tracking the provider process for region review ID."

  (remhash id expose-review-region-active-processes))

(defun expose-review-region-kill-process (id)
  "Terminate the live provider process tracked for region review ID, if any."

  (let ((process
         (gethash id expose-review-region-active-processes)))

    (when (and process
               (processp process)
               (process-live-p process))

      (expose-log
       "ReviewRegion"
       "Killing provider process for %s."
       id)

      (delete-process process))

    (expose-review-region-forget-process id)))

(defvar-local expose-review-region-source-overlays nil
  "Overlays for active Expose region reviews in the current buffer.")

(defvar-local expose-review-region-hover-timer nil
  "Idle timer for Expose region review item hovers.")

(defface expose-review-region-range-face
  '((t (:background "#262b33" :extend t)))
  "Subtle face for the full active region review range."
  :group 'expose-review-region)

(defface expose-review-region-item-face
  '((t (:underline (:color "#51afef" :style wave) :extend nil)))
  "Face for lines with concrete region review items.

A squiggly underline in doom-one's blue, rather than filled with a
background, so it reads as \"annotated\" without competing with syntax
highlighting, and stands out more than a plain line underline would.
`:extend nil' keeps the underline from bleeding across the blank tail
of each line -- the source overlay this face is applied to spans full
lines (including each trailing newline) to cover multi-line items, and
without this the underline would stretch to the window's right edge on
every line instead of stopping at the actual code.

Blue is region review's own color in this scheme -- Watch uses magenta
(`expose-watch-item-face') and full review uses teal
(`expose-review-source-patch-target-face') -- so which of the three
flagged a given line is visible at a glance."
  :group 'expose-review-region)

(defface expose-review-region-fringe-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for right-fringe active region review markers."
  :group 'expose-review-region)

(defun expose-review-region-apply-faces ()
  "Force Expose region review faces to current theme values."

  (set-face-attribute
   'expose-review-region-fringe-face
   nil
   :foreground 'unspecified
   :inherit 'font-lock-function-name-face))

(define-fringe-bitmap
  'expose-review-region-fringe-bitmap
  [#b00000000
   #b01110000
   #b01110000
   #b01110000
   #b01110000
   #b01110000
   #b00000000
   #b00000000]
  nil
  nil
  'center)

(expose-review-region-apply-faces)

(defun expose-review-region-current-project-root ()
  "Return current project root, or nil."

  (when-let ((project
              (project-current nil)))

    (file-name-as-directory
     (project-root project))))

(defun expose-review-region-source-add-range-fringe-overlays (session)
  "Add right-fringe markers for the full active region review SESSION."

  (let ((line-start
         (expose-review-region-session-line-start session))

        (line-end
         (expose-review-region-session-line-end session)))

    (dotimes (offset
              (1+
               (- line-end
                  line-start)))

      (let* ((line
              (+ line-start offset))

             (position
              (expose-review-region-line-start-position line))

             (overlay
              (make-overlay position position nil t nil)))

        (overlay-put overlay 'priority 46)
        (overlay-put overlay 'evaporate nil)
        (overlay-put overlay 'help-echo "Expose Region Review")
        (overlay-put overlay 'expose-review-region-session session)
        (overlay-put overlay 'expose-review-region-fringe t)

        (overlay-put
         overlay
         'before-string
         (propertize
          " "
          'display
          '(right-fringe
            expose-review-region-fringe-bitmap
            expose-review-region-fringe-face)))

        (push overlay expose-review-region-source-overlays)))))

(defun expose-review-region-deactivate-selection ()
  "Deactivate the active region or Evil visual selection."

  ;; Evil visual selection needs to leave visual state.
  (when (and
         (bound-and-true-p evil-local-mode)
         (fboundp 'evil-normal-state))
    (evil-normal-state))

  ;; Normal Emacs active region.
  (when (region-active-p)
    (deactivate-mark t)))

(defun expose-review-region-now ()
  "Return current timestamp."

  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun expose-review-region-project-root ()
  "Return current project root."

  (if-let ((project
            (project-current nil)))

      (file-name-as-directory
       (project-root project))

    (user-error "Expose region review requires a project")))

(defvar expose-review-region--store-root-cache
  (make-hash-table :test 'equal)
  "Cache of PROJECT-ROOT to resolved region-review store root.

This resolution is stable for the life of the Emacs session, but it is
looked up on every `find-file' via `expose-review-region-source-global-mode',
so caching it avoids spawning a git process on every single file open in
every project, most of which have never used Expose Region Review at all.")

(defun expose-review-region-store-root (project-root)
  "Return region review store root for PROJECT-ROOT."

  (or
   (gethash project-root expose-review-region--store-root-cache)

   (let ((default-directory project-root))

     (with-temp-buffer
       (let ((status
              (call-process
               "git"
               nil
               t
               nil
               "rev-parse"
               "--git-path"
               "expose/region-reviews")))

         (unless (= status 0)
           (user-error "Expose region review requires a git repository"))

         (puthash
          project-root
          (expand-file-name
           (string-trim
            (buffer-string))
           project-root)
          expose-review-region--store-root-cache))))))

(defun expose-review-region-active-dir (project-root)
  "Return active region review directory for PROJECT-ROOT."

  (expand-file-name
   "active"
   (expose-review-region-store-root project-root)))

(defun expose-review-region-history-dir (project-root)
  "Return region review history directory for PROJECT-ROOT."

  (expand-file-name
   "history"
   (expose-review-region-store-root project-root)))

(defun expose-review-region-session-id (file line-start line-end)
  "Return stable session id for FILE from LINE-START to LINE-END."

  (secure-hash
   'sha1
   (format "%s:%s:%s"
           file
           line-start
           line-end)))

(defun expose-review-region-active-path (project-root id)
  "Return active session path for PROJECT-ROOT and ID."

  (expand-file-name
   (concat id ".eld")
   (expose-review-region-active-dir project-root)))

(defun expose-review-region-read-file (path)
  "Read region review session from PATH."

  (when (file-readable-p path)

    (condition-case error-data

        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (read (current-buffer)))

      (error
       (expose-log
        "ReviewRegion"
        "Failed to read region review %s: %s"
        path
        (error-message-string error-data))

       nil))))

(defun expose-review-region-write-file (path session)
  "Write SESSION to PATH."

  (make-directory
   (file-name-directory path)
   t)

  (with-temp-file path
    (let ((print-length nil)
          (print-level nil)
          (print-circle t))

      (prin1
       (expose-transport-readable-value session)
       (current-buffer)))))

(defun expose-review-region-save-active (session)
  "Save active region review SESSION."

  (expose-review-region-write-file
   (expose-review-region-active-path
    (plist-get session :project-root)
    (plist-get session :id))
   session))

(defun expose-review-region-read-active-by-id (project-root id)
  "Read active region review ID for PROJECT-ROOT."

  (expose-review-region-read-file
   (expose-review-region-active-path project-root id)))

(defun expose-review-region-parse-timestamp (value)
  "Return VALUE (an Expose timestamp string) as float seconds, or nil."

  (when (stringp value)
    (ignore-errors
      (float-time
       (date-to-time value)))))

(defun expose-review-region-session-orphaned-p (session)
  "Return non-nil when SESSION looks abandoned rather than genuinely running.

See `expose-review-region-stale-active-seconds'."

  (and
   (eq (plist-get session :state) 'running)

   (let ((updated
          (expose-review-region-parse-timestamp
           (or
            (plist-get session :updated-at)
            (plist-get session :created-at)))))

     (and updated
          (> (- (float-time) updated)
             expose-review-region-stale-active-seconds)))))

(defun expose-review-region-active-sessions (project-root)
  "Return all active region review sessions for PROJECT-ROOT.

Sessions stuck in a non-terminal state far longer than a review should ever
take are archived as failed and excluded from the result here, instead of
permanently blocking new reviews on the same location or accumulating in
the active directory forever. See
`expose-review-region-session-orphaned-p'."

  (let ((dir
         (expose-review-region-active-dir project-root)))

    (when (file-directory-p dir)

      (let ((sessions
             (delq
              nil
              (mapcar
               #'expose-review-region-read-file
               (directory-files
                dir
                t
                "\\.eld\\'")))))

        (seq-remove
         (lambda (session)
           (when (expose-review-region-session-orphaned-p session)

             (expose-log
              "ReviewRegion"
              "Archiving orphaned region review %s (stuck running since %s)."
              (plist-get session :id)
              (plist-get session :updated-at))

             (expose-review-region-archive-session
              (plist-put
               session
               :error
               "Abandoned: Emacs or the provider process was killed before this review completed.")
              'failed)

             t))
         sessions)))))

(defun expose-review-region-line-after-position (line)
  "Return buffer position at beginning of the line after LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0 line))
    (point)))

(defun expose-review-region-line-content-bounds (line)
  "Return (START . END) bounding LINE's non-blank content, or nil if blank.

START skips leading indentation; END stops before trailing whitespace.
Used to keep item source overlays hugging real code instead of
underlining indentation or trailing blank space -- unlike the full-range
overlay, which deliberately does cover blank lines/line endings."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))

    (let ((eol
           (line-end-position)))

      (skip-chars-forward " \t" eol)

      (unless (= (point) eol)

        (let ((start
               (point)))

          (goto-char eol)
          (skip-chars-backward " \t" start)
          (cons start (point)))))))

(defun expose-review-region-session-line-start (session)
  "Return SESSION start line."

  (or
   (plist-get session :region-line-start)
   (plist-get session :line-start)))

(defun expose-review-region-session-line-end (session)
  "Return SESSION end line."

  (or
   (plist-get session :region-line-end)
   (plist-get session :line-end)))

(defun expose-review-region-ranges-overlap-p (a-start a-end b-start b-end)
  "Return non-nil when two line ranges overlap."

  (and
   (<= a-start b-end)
   (<= b-start a-end)))

(defun expose-review-region-conflicting-active-session
    (project-root file line-start line-end)
  "Return active session conflicting with FILE LINE-START to LINE-END."

  (seq-find
   (lambda (session)
     (and
      (string=
       file
       (plist-get session :file))

      (expose-review-region-ranges-overlap-p
       line-start
       line-end
       (expose-review-region-session-line-start session)
       (expose-review-region-session-line-end session))))
   (expose-review-region-active-sessions project-root)))

(defun expose-review-region-archive-session (session archive-state)
  "Archive SESSION with ARCHIVE-STATE and remove it from active reviews."

  (let* ((project-root
          (plist-get session :project-root))

         (id
          (plist-get session :id))

         (active-path
          (expose-review-region-active-path project-root id))

         (history-dir
          (expose-review-region-history-dir project-root))

         (history-path
          (expand-file-name
           (format "%s-%s.eld"
                   (format-time-string "%Y%m%dT%H%M%S")
                   id)
           history-dir)))

    (setq session
          (plist-put session :state archive-state))

    (setq session
          (plist-put session :archived-at
                     (expose-review-region-now)))

    (expose-review-region-write-file history-path session)

    (when (file-exists-p active-path)
      (delete-file active-path))

    history-path))

(defun expose-review-region-buffer-line-count ()
  "Return number of lines in the current buffer."

  (line-number-at-pos
   (point-max)))

(defun expose-review-region-context-start-line (start)
  "Return first surrounding context line for START."

  (max
   1
   (-
    (expose-review-region-line-number-at start)
    expose-review-region-context-lines)))

(defun expose-review-region-context-end-line (start end)
  "Return last surrounding context line for region START to END."

  (min
   (expose-review-region-buffer-line-count)
   (+
    (expose-review-region-line-number-at
     (expose-review-region-inclusive-end start end))
    expose-review-region-context-lines)))

(defun expose-review-region-numbered-text (text start-line)
  "Return TEXT with line numbers starting at START-LINE."

  (let* ((lines
          (split-string
           (or text "")
           "\n"))

         (end-line
          (+ start-line
             (max 0
                  (1- (length lines)))))

         (width
          (length
           (number-to-string end-line)))

         (line-number
          (1- start-line)))

    (mapconcat
     (lambda (line)
       (setq line-number
             (1+ line-number))

       (format
        (format "%%%dd | %%s" width)
        line-number
        line))
     lines
     "\n")))

(defun expose-review-region-inclusive-end (start end)
  "Return inclusive END position for region START to END."

  (max start
       (1- end)))

(defun expose-review-region-provider ()
  "Return provider used for region reviews."

  (if (boundp 'expose-provider-default)
      expose-provider-default
    'clipboard))

(defun expose-review-region-line-number-at (position)
  "Return one-based line number at POSITION."

  (save-excursion
    (goto-char position)
    (line-number-at-pos)))

(defun expose-review-region-escape (text)
  "Escape TEXT for XML-ish request documents."

  (let ((result
         (or text "")))

    (setq result
          (replace-regexp-in-string "&" "&amp;" result t t))

    (setq result
          (replace-regexp-in-string "<" "&lt;" result t t))

    (setq result
          (replace-regexp-in-string ">" "&gt;" result t t))

    result))

(defun expose-review-region-buffer-file ()
  "Return current buffer file display name."

  (or
   (when-let ((file
               (buffer-file-name)))
     (if-let ((project
               (project-current nil)))
         (file-relative-name
          file
          (project-root project))
       file))
   (buffer-name)))

(defun expose-review-region-text (start end)
  "Return selected text from START to END."

  (string-trim-right
   (buffer-substring-no-properties start end)))

(defun expose-review-region-context (start end)
  "Return surrounding context around START and END."

  (let* ((context-start-line
          (expose-review-region-context-start-line start))

         (context-end-line
          (expose-review-region-context-end-line start end))

         (context-start
          (expose-review-region-line-start-position context-start-line))

         (context-end
          (expose-review-region-line-end-position context-end-line)))

    (buffer-substring-no-properties
     context-start
     context-end)))

(defun expose-review-region-diagnostics (start end)
  "Return compact diagnostics between START and END."

  (when (and
         (bound-and-true-p flycheck-mode)
         (fboundp 'flycheck-overlay-errors-in))

    (let ((errors
           (flycheck-overlay-errors-in
            start
            (expose-review-region-inclusive-end start end))))

      (when errors
        (string-join
         (mapcar
          (lambda (error)
            (format
             "line %s [%s] %s"
             (line-number-at-pos
              (flycheck-error-pos error))
             (flycheck-error-level error)
             (flycheck-error-message error)))
          errors)
         "\n")))))

(defun expose-review-region-first-symbol-position (start end)
  "Return first symbol position between START and END, or nil."

  (save-excursion
    (goto-char start)

    (catch 'found
      (while (< (point) end)
        (when (thing-at-point 'symbol t)
          (throw 'found (point)))
        (forward-char 1))

      nil)))

(defun expose-review-region-focus-position (start end)
  "Return best position for symbol/type context between START and END."

  (cond
   ((and
     (>= (point) start)
     (<= (point) end)
     (thing-at-point 'symbol t))
    (point))

   ((expose-review-region-first-symbol-position start end))

   (t
    start)))

(defun expose-review-region-lsp-hover-signature ()
  "Return compact LSP hover signature at point, or nil."

  (condition-case error-data

      (when (and
             (fboundp 'lsp-feature?)
             (fboundp 'lsp-request)
             (fboundp 'lsp--text-document-position-params)
             (lsp-feature? "textDocument/hover"))

        (when-let* ((hover
                     (lsp-request
                      "textDocument/hover"
                      (lsp--text-document-position-params)))

                    (value
                     (expose-hover-hover-value hover))

                    (signature
                     (expose-hover-clean-signature value)))

          signature))

    (error
     (expose-log
      "ReviewRegion"
      "Failed to read LSP hover signature: %s"
      (error-message-string error-data))

     nil)))

(defun expose-review-region-eldoc-signature ()
  "Return compact Eldoc signature at point, or nil."

  (condition-case error

      (when (and
             (fboundp 'expose-hover-eldoc-available-p)
             (expose-hover-eldoc-available-p))

        (let ((result nil))

          (catch 'done
            (dolist (function
                     (expose-hover-eldoc-functions))

              (expose-hover-call-eldoc-function
               function
               (lambda (documentation &rest properties)
                 (ignore properties)

                 (when-let* ((text
                              (expose-hover-normalize-eldoc-documentation
                               documentation))

                             (signature
                              (expose-hover-clean-signature text)))

                   (setq result signature)
                   (throw 'done result))))))

          result))

    (error
     (expose-log
      "ReviewRegion"
      "Failed to read Eldoc signature: %s"
      (error-message-string error))

     nil)))

(defun expose-review-region-symbol-context (start end)
  "Return symbol/type context for selected region START to END."

  (save-excursion
    (goto-char
     (expose-review-region-focus-position start end))

    (let ((symbol
           (thing-at-point 'symbol t))

          (signature
           (or
            (expose-review-region-lsp-hover-signature)
            (expose-review-region-eldoc-signature))))

      (string-trim
       (string-join
        (delq
         nil
         (list
          (when symbol
            (format "Symbol: %s" symbol))

          (when signature
            (format "Type:\n%s" signature))))
        "\n\n")))))

(defun expose-review-region-request (start end)
  "Build persistent region review request for region START to END."

  (let* ((file
          (expose-review-region-buffer-file))

         (line-start
          (expose-review-region-line-number-at start))

         (line-end
          (expose-review-region-line-number-at
           (expose-review-region-inclusive-end start end)))

         (context-line-start
          (expose-review-region-context-start-line start))

         (context-line-end
          (expose-review-region-context-end-line start end))

         (code
          (expose-review-region-text start end))

         (numbered-code
          (expose-review-region-numbered-text
           code
           line-start))

         (context
          (expose-review-region-context start end))

         (numbered-context
          (expose-review-region-numbered-text
           context
           context-line-start))

         (symbol-context
          (or
           (expose-review-region-symbol-context start end)
           ""))

         (diagnostics
          (or
           (expose-review-region-diagnostics start end)
           "")))

    (format
     "<expose-region-review-request>
  <instruction>
    You are performing a focused senior-engineer code review of only the selected region.

    Review the selected code for correctness, maintainability, security, data integrity,
    edge cases, typing, performance, testability, and integration with nearby code.

    Use the surrounding context and symbol/type context only as supporting context.
    Report findings against the selected region unless surrounding context is necessary
    to explain the issue.

    Important:
    - The code blocks include real file line numbers in the format LINE | code.
    - Use real file line numbers from the numbered code blocks.
    - Every review item must include line_start and line_end.
    - Prefer the smallest accurate line range for each finding.
    - Do not create findings outside the selected region unless the issue is caused
      directly by the selected region.
    - If a finding applies to the whole selected region, use line_start=%s and line_end=%s.
    - Do not copy the JSON schema/example from this prompt.
    - Never return placeholder values like 123, 126, \"Short title\", \"Review comment.\", or \"high|medium|low|info\".
    - Prefer the most important, highest-impact findings. Prioritize high/medium severity
      over low/info; skip minor findings rather than padding toward a higher count.
    - Do not create filler findings.
    - Keep each comment to 1-2 sentences.
    - Keep suggestion text to 1-2 sentences; only include a patch when a small, precise
      diff is clearly better than prose.

    Return valid JSON only.
    Do not return Markdown.
    Do not wrap the JSON in code fences.
    Do not include commentary outside the JSON.

    Use exactly this shape:

    {
      \"summary\": \"Short summary of the selected region review.\",
      \"items\": [
        {
          \"id\": \"RR1\",
          \"severity\": \"high|medium|low|info\",
          \"category\": \"correctness|security|performance|maintainability|tests|typing|style\",
          \"file\": \"%s\",
          \"line_start\": 123,
          \"line_end\": 126,
          \"title\": \"Short title\",
          \"comment\": \"Review comment.\",
          \"anchor_text\": \"Relevant source line or phrase.\",
          \"suggestion\": {
            \"kind\": \"none|text|patch\",
            \"text\": \"Suggested fix or implementation direction.\",
            \"patch\": \"\"
          }
        }
      ]
    }

    If there are no findings, return:

    {
      \"summary\": \"No findings.\",
      \"items\": []
    }
  </instruction>

  <location file=\"%s\" line_start=\"%s\" line_end=\"%s\" major_mode=\"%s\" />

  <selected-code numbered=\"true\" line_start=\"%s\" line_end=\"%s\">
%s
  </selected-code>

  <surrounding-context numbered=\"true\" line_start=\"%s\" line_end=\"%s\">
%s
  </surrounding-context>

  <symbol-context>
%s
  </symbol-context>

  <diagnostics>
%s
  </diagnostics>
</expose-region-review-request>"
     line-start
     line-end
     (expose-review-region-escape file)

     (expose-review-region-escape file)
     line-start
     line-end
     major-mode

     line-start
     line-end
     (expose-review-region-escape numbered-code)

     context-line-start
     context-line-end
     (expose-review-region-escape numbered-context)

     (expose-review-region-escape symbol-context)
     (expose-review-region-escape diagnostics))))

(defun expose-review-region-render-markdown (text)
  "Return TEXT fontified as Markdown when possible."

  (if (not
       (fboundp 'markdown-mode))

      text

    (with-temp-buffer
      (delay-mode-hooks
        (markdown-mode))

      (font-lock-mode 1)

      (insert
       (string-trim-right
        (or text "")))

      (font-lock-ensure
       (point-min)
       (point-max))

      (buffer-string))))

(defun expose-review-region-item-line-start (item fallback)
  "Return ITEM start line or FALLBACK."

  (or
   (plist-get item :line-start)
   (plist-get item :line_start)
   fallback))

(defun expose-review-region-item-line-end (item fallback)
  "Return ITEM end line or FALLBACK."

  (or
   (plist-get item :line-end)
   (plist-get item :line_end)
   fallback))

(defun expose-review-region-format-location (file line-start line-end)
  "Format FILE LINE-START LINE-END."

  (format
   "%s:%s%s"
   file
   line-start
   (if (= line-start line-end)
       ""
     (format "-%s" line-end))))

(defun expose-review-region-suggestion-text (item)
  "Return ITEM suggestion text."

  (let* ((suggestion
          (plist-get item :suggestion))

         (text
          (or
           (plist-get suggestion :text)
           ""))

         (patch
          (or
           (plist-get suggestion :patch)
           "")))

    (cond
     ((not
       (string-empty-p
        (string-trim text)))
      text)

     ((not
       (string-empty-p
        (string-trim patch)))
      patch)

     (t
      ""))))

(defun expose-review-region-render-item-markdown (item session)
  "Return Markdown for single region review ITEM in SESSION."

  (let* ((file
          (or
           (plist-get item :file)
           (plist-get session :file)))

         (fallback-start
          (expose-review-region-session-line-start session))

         (line-start
          (expose-review-region-item-line-start item fallback-start))

         (line-end
          (expose-review-region-item-line-end item line-start))

         (severity
          (or
           (plist-get item :severity)
           "info"))

         (title
          (or
           (plist-get item :title)
           "Review item"))

         (comment
          (or
           (plist-get item :comment)
           ""))

         (anchor
          (or
           (plist-get item :anchor-text)
           (plist-get item :anchor_text)
           ""))

         (suggestion
          (expose-review-region-suggestion-text item)))

    (string-join
     (delq
      nil
      (list
       (format
        "- **Lines:** `%s`"
        (expose-review-region-format-location
         file
         line-start
         line-end))

       (format "  **Severity:** %s" severity)

       (format "  **Issue:** %s" title)

       (unless (string-empty-p comment)
         (format "  **Why it matters:** %s" comment))

       (unless (string-empty-p anchor)
         (format "  **Anchor:** `%s`" anchor))

       (unless (string-empty-p suggestion)
         (format "  **Suggested change:** %s" suggestion))))
     "\n")))

(defun expose-review-region-full-markdown (session)
  "Return Markdown for full region review SESSION."

  (let* ((file
          (plist-get session :file))

         (line-start
          (expose-review-region-session-line-start session))

         (line-end
          (expose-review-region-session-line-end session))

         (items
          (plist-get session :items))

         (state
          (plist-get session :state)))

    (cond
     ((eq state 'running)
      (format
       "## Region Review\n\n`%s`\n\nReview is still running..."
       (expose-review-region-format-location file line-start line-end)))

     ((eq state 'failed)
      (format
       "## Region Review Failed\n\n`%s`\n\n%s"
       (expose-review-region-format-location file line-start line-end)
       (or
        (plist-get session :error)
        "Unknown error")))

     ((null items)
      (format
       "## Region Review\n\n`%s`\n\nNo findings."
       (expose-review-region-format-location file line-start line-end)))

     (t
      (concat
       (format
        "## Region Review\n\n`%s`\n\n"
        (expose-review-region-format-location file line-start line-end))

       (string-join
        (mapcar
         (lambda (item)
           (expose-review-region-render-item-markdown item session))
         items)
        "\n\n"))))))

(defun expose-review-region-show-full-session (session)
  "Show full region review SESSION."

  (expose-popup-show-view
   (list
    :title "Region Review"
    :body
    (expose-review-region-render-markdown
     (expose-review-region-full-markdown session))
    :history t))

  (when (eq (plist-get session :state) 'running)
    (expose-popup-set-mode-line "Loading Region Review")))

(defun expose-review-region-source-clear ()
  "Clear active region review overlays in current buffer."

  (when (timerp expose-review-region-hover-timer)
    (cancel-timer expose-review-region-hover-timer))

  (setq expose-review-region-hover-timer nil)

  (mapc
   #'delete-overlay
   expose-review-region-source-overlays)

  (setq expose-review-region-source-overlays nil))

(defun expose-review-region-line-start-position (line)
  "Return buffer position at beginning of LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))
    (point)))

(defun expose-review-region-line-end-position (line)
  "Return buffer position at end of LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))
    (line-end-position)))

(defun expose-review-region-source-current-file ()
  "Return current file relative to project."

  (when buffer-file-name
    (expose-review-region-buffer-file)))

(defun expose-review-region-source-sessions ()
  "Return active region review sessions for current buffer."

  (when-let* ((file-name
               buffer-file-name)

              (project-root
               (expose-review-region-current-project-root))

              (file
               (expose-review-region-source-current-file)))

    (seq-filter
     (lambda (session)
       (string=
        file
        (plist-get session :file)))
     (expose-review-region-active-sessions project-root))))

(defun expose-review-region-source-add-range-overlay (session)
  "Add subtle full-region overlay for SESSION."

  (let* ((line-start
          (expose-review-region-session-line-start session))

         (line-end
          (expose-review-region-session-line-end session))

         (start
          (expose-review-region-line-start-position line-start))

         ;; Use the beginning of the following line so the overlay covers
         ;; the whole visual region, including empty lines and line endings.
         (end
          (expose-review-region-line-after-position line-end))

         (overlay
          (make-overlay start end nil t nil)))

    (overlay-put overlay 'face 'expose-review-region-range-face)
    (overlay-put overlay 'priority 45)
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'help-echo "Expose Region Review")
    (overlay-put overlay 'expose-review-region-session session)
    (overlay-put overlay 'expose-review-region-range t)

    (push overlay expose-review-region-source-overlays)))

(defun expose-review-region-normalize-line-number (value fallback)
  "Return VALUE as a positive line number, or FALLBACK."

  (let ((number
         (cond
          ((numberp value)
           value)

          ((stringp value)
           (string-to-number value))

          (t
           nil))))

    (if (and number
             (> number 0))
        number
      fallback)))


(defun expose-review-region-item-file-matches-session-p (item session)
  "Return non-nil when ITEM belongs to SESSION's file."

  (let ((item-file
         (plist-get item :file))

        (session-file
         (plist-get session :file)))

    (or
     (not item-file)
     (string-empty-p item-file)
     (string= item-file session-file))))


(defun expose-review-region-item-effective-line-range (item session)
  "Return safe line range cons for ITEM in SESSION."

  (let* ((region-start
          (expose-review-region-session-line-start session))

         (region-end
          (expose-review-region-session-line-end session))

         (line-start
          (expose-review-region-normalize-line-number
           (or
            (plist-get item :line-start)
            (plist-get item :line_start))
           region-start))

         (line-end
          (expose-review-region-normalize-line-number
           (or
            (plist-get item :line-end)
            (plist-get item :line_end))
           line-start)))

    ;; Region Review should highlight inside the reviewed region only.
    ;; This prevents a weird model line number from marking unrelated code.
    (setq line-start
          (max region-start
               (min line-start region-end)))

    (setq line-end
          (max line-start
               (min line-end region-end)))

    (cons line-start line-end)))

(defun expose-review-region-source-add-item-overlay (item session)
  "Add Watch-style source overlay(s) for review ITEM in SESSION.

One overlay per non-blank line in ITEM's effective range, each trimmed
to that line's actual content -- so the underline only covers real
code, never indentation, trailing whitespace, or blank lines inside a
multi-line item.

Walks the range with a single forward pass (one `goto-char' to
LINE-START, then `forward-line' between each line) rather than calling
`expose-review-region-line-content-bounds' per line, which would
independently re-seek from `point-min' every time -- fine for a single
lookup, but quadratic here across a multi-line range."

  (when (expose-review-region-item-file-matches-session-p item session)

    (let* ((line-range
            (expose-review-region-item-effective-line-range item session))

           (line-start
            (car line-range))

           (line-end
            (cdr line-range)))

      (save-excursion
        (goto-char (point-min))
        (forward-line
         (max 0
              (1- line-start)))

        (cl-loop
         for line from line-start to line-end
         do
         (let ((eol
                (line-end-position)))

           (skip-chars-forward " \t" eol)

           (unless (= (point) eol)

             (let* ((start
                     (point))

                    (end
                     (progn
                       (goto-char eol)
                       (skip-chars-backward " \t" start)
                       (point)))

                    (overlay
                     (make-overlay start end nil t nil)))

               (overlay-put overlay 'face 'expose-review-region-item-face)
               (overlay-put overlay 'priority 95)
               (overlay-put overlay 'evaporate nil)
               (overlay-put overlay 'help-echo "Expose Region Review item")
               (overlay-put overlay 'expose-review-region-session session)
               (overlay-put overlay 'expose-review-region-item item)

               (push overlay expose-review-region-source-overlays)))

           (goto-char eol)
           (forward-line 1)))))))

(defun expose-review-region-source-add-session-overlays (session)
  "Add source overlays for region review SESSION."

  ;; Subtle background over the full selected review region.
  (expose-review-region-source-add-range-overlay session)

  ;; Right-fringe markers on every line in the active region.
  (expose-review-region-source-add-range-fringe-overlays session)

  ;; Stronger item overlays only once the review has completed.
  (when (eq (plist-get session :state)
            'ready)

    (dolist (item
             (plist-get session :items))

      (expose-review-region-source-add-item-overlay
       item
       session))))

(defun expose-review-region-source-refresh ()
  "Refresh active region review overlays in current buffer."

  (when expose-review-region-source-mode

    (expose-review-region-source-clear)

    (when buffer-file-name
      (dolist (session
               (expose-review-region-source-sessions))

        (expose-review-region-source-add-session-overlays session)))))

(defun expose-review-region-source-refresh-all ()
  "Refresh active region review overlays in all file buffers."

  (dolist (buffer
           (buffer-list))

    (with-current-buffer buffer
      (when (and buffer-file-name
                 (bound-and-true-p expose-review-region-source-mode))

        (expose-review-region-source-refresh)))))

(defun expose-review-region-session-at-point ()
  "Return active region review session at point."

  (seq-some
   (lambda (overlay)
     (overlay-get overlay 'expose-review-region-session))
   (overlays-at
    (point))))

(defun expose-review-region-item-at-point ()
  "Return active region review item at point."

  (seq-some
   (lambda (overlay)
     (overlay-get overlay 'expose-review-region-item))
   (overlays-at
    (point))))

(defun expose-review-region-source-cancel-hover ()
  "Cancel pending region review hover."

  (when (timerp expose-review-region-hover-timer)
    (cancel-timer expose-review-region-hover-timer))

  (setq expose-review-region-hover-timer nil))

(defun expose-review-region-show-item-hover ()
  "Show review item hover at point."

  (when-let* ((item
               (expose-review-region-item-at-point))

              (session
               (expose-review-region-session-at-point)))

    (expose-popup-show-view
     (list
      :title "Region Review Item"
      :body
      (expose-review-region-render-markdown
       (concat
        "## Region Review Item\n\n"
        (expose-review-region-render-item-markdown item session)))
      :history nil))))

(defun expose-review-region-source-post-command ()
  "Schedule region review item hover when point is on an item overlay."

  (cond
   ((and
     (symbolp this-command)
     (fboundp 'expose-popup-command-p)
     (expose-popup-command-p this-command))

    (expose-review-region-source-cancel-hover))

   ((and
     (expose-review-region-item-at-point)
     (fboundp 'expose-review-region-show-item-hover))

    (expose-review-region-source-cancel-hover)

    (setq expose-review-region-hover-timer
          (run-with-idle-timer
           expose-hover-delay
           nil
           #'expose-review-region-show-item-hover)))

   (t
    (expose-review-region-source-cancel-hover))))

(define-minor-mode expose-review-region-source-mode
  "Show active Expose region reviews in source buffers."

  :lighter " ExposeRegion"

  (if expose-review-region-source-mode

      (progn
        (add-hook
         'post-command-hook
         #'expose-review-region-source-post-command
         nil
         t)

        (expose-review-region-source-refresh))

    (remove-hook
     'post-command-hook
     #'expose-review-region-source-post-command
     t)

    (expose-review-region-source-clear)))

(defun expose-review-region-source-enable-if-file ()
  "Enable region review source mode in file buffers."

  (when buffer-file-name
    (expose-review-region-source-mode 1)))

(define-globalized-minor-mode expose-review-region-source-global-mode
  expose-review-region-source-mode
  expose-review-region-source-enable-if-file)

(defun expose-review-region-show-error (message)
  "Show region review error MESSAGE in popup."

  (expose-popup-show-view
   (list
    :title "Review Region"
    :body message
    :history nil)))

;;;###autoload
(defun expose-review-region (start end)
  "Run a persistent region review for selected region START to END."

  (interactive "r")

  (unless (use-region-p)
    (user-error "Select a region first"))

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-review-region-project-root))

         (file
          (expose-review-region-buffer-file))

         (line-start
          (expose-review-region-line-number-at start))

         (line-end
          (expose-review-region-line-number-at
           (expose-review-region-inclusive-end start end)))

         (conflict
          (expose-review-region-conflicting-active-session
           project-root
           file
           line-start
           line-end)))

    (when (expose-redact-excluded-path-p file project-root)
      (expose-redact-log-excluded-path file project-root)
      (user-error "Expose Region Review refuses to review excluded path: %s" file))

    (when conflict
      (user-error
       "Region review already active for %s:%s-%s"
       (plist-get conflict :file)
       (expose-review-region-session-line-start conflict)
       (expose-review-region-session-line-end conflict)))

    (let* ((id
            (expose-review-region-session-id
             file
             line-start
             line-end))

           (provider
            (expose-review-region-provider))

           (document
            (expose-review-region-request start end))

           (session
            (list
             :id id
             :kind 'region-review
             :state 'running
             :provider provider
             :project-root project-root
             :file file
             :region-line-start line-start
             :region-line-end line-end
             :created-at (expose-review-region-now)
             :updated-at (expose-review-region-now)
             :items nil
             :response nil
             :error nil))

           (completed nil)
           timeout-timer)

      (expose-review-region-save-active session)
      (expose-review-region-source-refresh-all)

      (expose-popup-show-view
       (list
        :title "Region Review"
        :body
        (format
         "Reviewing `%s`..."
         (expose-review-region-format-location
          file
          line-start
          line-end))
        :history nil))

      (expose-popup-set-mode-line "Loading Region Review")

      (expose-log
       "ReviewRegion"
       "Started region review %s for %s:%s-%s using %s."
       id
       file
       line-start
       line-end
       provider)

      (setq timeout-timer
            (run-at-time
             expose-review-region-provider-timeout-seconds
             nil
             (lambda ()
               (unless completed
                 (setq completed t)

                 (expose-review-region-kill-process id)

                 (let ((latest-session
                        (or
                         (expose-review-region-read-active-by-id
                          project-root
                          id)
                         session)))

                   (setq latest-session
                         (plist-put latest-session :state 'failed))

                   (setq latest-session
                         (plist-put
                          latest-session
                          :error
                          (format
                           "AI provider timed out after %d seconds while using %s."
                           expose-review-region-provider-timeout-seconds
                           provider)))

                   (setq latest-session
                         (plist-put latest-session :updated-at
                                    (expose-review-region-now)))

                   (expose-review-region-save-active latest-session)
                   (expose-review-region-source-refresh-all)

                   (when (buffer-live-p source-buffer)
                     (with-current-buffer source-buffer
                       (expose-review-region-deactivate-selection)

                       (expose-review-region-show-full-session
                        latest-session))))))))

      (expose-review-region-register-process
       id
       (expose-transport-send-document-async
        provider
        document

        (lambda (response-text)

          (unless completed
            (setq completed t)

            (when (timerp timeout-timer)
              (cancel-timer timeout-timer))

            (expose-review-region-forget-process id))

          (let ((latest-session
                 (expose-review-region-read-active-by-id
                  project-root
                  id)))

            ;; Ignore stale response if user completed/canceled while provider
            ;; was still running.
            (when latest-session

              (condition-case parse-error

                  (let ((items
                         (expose-review-request-parse-items response-text)))

                    (setq latest-session
                          (plist-put latest-session :state 'ready))

                    (setq latest-session
                          (plist-put
                           latest-session
                           :items
                           (expose-transport-readable-value items)))

                    (setq latest-session
                          (plist-put latest-session :response response-text))

                    (setq latest-session
                          (plist-put latest-session :updated-at
                                     (expose-review-region-now)))

                    (expose-review-region-save-active latest-session)
                    (expose-review-region-source-refresh-all)

                    (when (buffer-live-p source-buffer)
                      (with-current-buffer source-buffer
                        (expose-review-region-deactivate-selection)

                        (expose-review-region-show-full-session
                         latest-session)))

                    (expose-log
                     "ReviewRegion"
                     "Region review %s completed with %d items."
                     id
                     (length items)))

                (error
                 (setq latest-session
                       (plist-put latest-session :state 'failed))

                 (setq latest-session
                       (plist-put latest-session :error
                                  (error-message-string parse-error)))

                 (setq latest-session
                       (plist-put latest-session :response response-text))

                 (setq latest-session
                       (plist-put latest-session :updated-at
                                  (expose-review-region-now)))

                 (expose-review-region-save-active latest-session)
                 (expose-review-region-source-refresh-all)

                 (when (buffer-live-p source-buffer)
                   (with-current-buffer source-buffer
                     (expose-review-region-deactivate-selection)

                     (expose-review-region-show-full-session
                      latest-session))))))))

        project-root

        (lambda (error-data)

          (unless completed
            (setq completed t)

            (when (timerp timeout-timer)
              (cancel-timer timeout-timer))

            (expose-review-region-forget-process id))

          (let ((latest-session
                 (or
                  (expose-review-region-read-active-by-id
                   project-root
                   id)
                  session)))

            (setq latest-session
                  (plist-put latest-session :state 'failed))

            (setq latest-session
                  (plist-put latest-session :error
                             (error-message-string error-data)))

            (setq latest-session
                  (plist-put latest-session :updated-at
                             (expose-review-region-now)))

            (expose-review-region-save-active latest-session)
            (expose-review-region-source-refresh-all)

            (when (buffer-live-p source-buffer)
              (with-current-buffer source-buffer
                (expose-review-region-deactivate-selection)

                (expose-review-region-show-full-session
                 latest-session)))

            (message
             "Expose region review failed: %s"
             (error-message-string error-data)))))))))

;;;###autoload
(defun expose-review-region-show-full-at-point ()
  "Show the full active region review at point."

  (interactive)

  (let ((session
         (expose-review-region-session-at-point)))

    (unless session
      (user-error "Point is not inside an active Expose region review"))

    (expose-review-region-show-full-session session)))

;;;###autoload
(defun expose-review-region-complete-at-point ()
  "Complete and archive the active region review at point."

  (interactive)

  (let ((session
         (expose-review-region-session-at-point)))

    (unless session
      (user-error "Point is not inside an active Expose region review"))

    (when (yes-or-no-p
           (format
            "Complete region review %s? "
            (expose-review-region-format-location
             (plist-get session :file)
             (expose-review-region-session-line-start session)
             (expose-review-region-session-line-end session))))

      (let ((history-path
             (expose-review-region-archive-session
              session
              'completed)))

        (expose-review-region-source-refresh-all)

        (when (fboundp 'expose-popup-hide)
          (expose-popup-hide))

        (message
         "Expose region review completed: %s"
         history-path)))))

;;;###autoload
(defun expose-review-region-cancel-at-point ()
  "Cancel and archive the active region review at point."

  (interactive)

  (let ((session
         (expose-review-region-session-at-point)))

    (unless session
      (user-error "Point is not inside an active Expose region review"))

    (when (yes-or-no-p
           (format
            "Cancel region review %s? "
            (expose-review-region-format-location
             (plist-get session :file)
             (expose-review-region-session-line-start session)
             (expose-review-region-session-line-end session))))

      (expose-review-region-kill-process
       (plist-get session :id))

      (let ((history-path
             (expose-review-region-archive-session
              session
              'canceled)))

        (expose-review-region-source-refresh-all)

        (when (fboundp 'expose-popup-hide)
          (expose-popup-hide))

        (message
         "Expose region review canceled: %s"
         history-path)))))

(provide 'expose-review-region)
