;;; expose-commands.el -*- lexical-binding: t; -*-

(require 'project)
(require 'subr-x)
(require 'newcomment)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-action-buffer)
(require 'expose-hover)
(require 'expose-transport)
(require 'expose-provider)
(require 'expose-diagram)
(require 'expose-context)
(require 'expose-document)
(require 'expose-request)
;; For base-branch detection only (`expose-review-context-detect-base-branch'
;; and its git-info helpers) -- reused by `expose-pr-description-async'
;; rather than duplicated, since it's the exact same comparison
;; `expose-review-open-pr-diff' already shows locally as a Magit diff.
;; None of the heavier linter/diagnostic machinery this module also
;; contains is touched.
(require 'expose-review-context)

;; Loaded on demand by `expose-run-reverse-call-graph' rather than up
;; front: it pulls in `xref' and only matters if that one command is
;; used.
(declare-function expose-callers-build-dot "expose-callers" ())
(declare-function expose-callers-build-tests-dot "expose-callers" ())
(declare-function expose-imports-build-dot "expose-imports" (&optional show-externals))
(declare-function expose-migrations-build-dot "expose-migrations" ())
(defvar expose-migrations-max-migrations)

;; Loaded on demand by `expose-run-signal-flow-diagram', same reason as
;; the rest of this group.
(declare-function expose-signals-find-receivers "expose-signals" (model-name))

;; Loaded on demand by `expose-run-middleware-diagram'/
;; `expose-run-urls-diagram', same reason as the rest of this group.
(declare-function expose-middleware-build-dot "expose-middleware" ())
(declare-function expose-urls-build-dot "expose-urls" (&optional root-file))

;; Loaded on demand by `expose-run-er-diagram', same reason as the
;; rest of this group.
(declare-function expose-relations-find-referencing-models "expose-relations" (model-name &optional exclude-file))

;; Loaded on demand by `expose-find-tests', same reason as above.
(declare-function expose-find-tests-open "expose-find-tests" (source-window))

(defcustom expose-provider-default
  'codex
  "Default provider used by Expose."
  :type '(choice
          (const clipboard)
          (const codex)
          (const copilot)
          (const claude))
  :group 'expose)

(defun expose-commands-project-root-or-default ()
  "Return current project root, Git root, or `default-directory'."

  (or
   (when-let ((project
               (project-current nil)))

     (file-name-as-directory
      (project-root project)))

   (when (fboundp 'vc-git-root)
     (ignore-errors
       (vc-git-root default-directory)))

   default-directory))


(defun expose-commands-relative-file (project-root)
  "Return current buffer file relative to PROJECT-ROOT, or the buffer name."

  (if buffer-file-name

      (file-relative-name
       buffer-file-name
       project-root)

    (buffer-name)))


(defun expose-commands-line-blank-p ()
  "Return non-nil when the current line is blank."

  (string-empty-p
   (string-trim
    (buffer-substring-no-properties
     (line-beginning-position)
     (line-end-position)))))


(defun expose-commands-target-line-text (target-position)
  "Return source line text at TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (string-trim
     (buffer-substring-no-properties
      (line-beginning-position)
      (line-end-position)))))


(defun expose-commands-target-line-number (target-position)
  "Return line number for TARGET-POSITION."

  (line-number-at-pos target-position))


(defun expose-commands-context-around (target-position context-lines)
  "Return CONTEXT-LINES of source around TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (let* ((target-line
            (line-number-at-pos target-position))

           (start-line
            (max
             1
             (- target-line
                context-lines)))

           (end-line
            (min
             (line-number-at-pos
              (point-max))
             (+ target-line
                context-lines)))

           start
           end)

      (goto-char (point-min))
      (forward-line
       (1- start-line))
      (setq start
            (point))

      (goto-char (point-min))
      (forward-line end-line)
      (setq end
            (point))

      (buffer-substring-no-properties
       start
       end))))


(defun expose-commands-view-body-text (view)
  "Return display body text from VIEW."

  (cond
   ((stringp view)
    view)

   ((and
     (listp view)
     (plist-member view :body))
    (plist-get view :body))

   (t
    (format "%s" view))))


(defun expose-commands-clean-insert-text (text)
  "Clean provider TEXT before inserting it into the current buffer."

  (let ((cleaned
         (substring-no-properties
          (or text ""))))

    (setq cleaned
          (string-trim cleaned))

    ;; Strip a simple surrounding Markdown fence if the model wrapped the
    ;; commit message in one.
    (setq cleaned
          (replace-regexp-in-string
           "\\````[[:alnum:]_-]*[ \t]*\n"
           ""
           cleaned))

    (setq cleaned
          (replace-regexp-in-string
           "\n```\\'"
           ""
           cleaned))

    (string-trim cleaned)))


(defun expose-commands-insert-text-at-marker (buffer marker text label)
  "Insert TEXT into BUFFER at MARKER.

LABEL is used for user-facing status messages."

  (if (not
       (and
        (buffer-live-p buffer)
        (markerp marker)
        (marker-position marker)))

      (message
       "Expose %s result ignored because the original buffer is gone."
       label)

    (with-current-buffer buffer

      (condition-case error-data

          (let* ((cleaned
                  (expose-commands-clean-insert-text text))

                 (move-point
                  (= (point)
                     (marker-position marker)))

                 end-position)

            (if (string-empty-p cleaned)

                (message
                 "Expose %s returned an empty response."
                 label)

              (save-excursion
                (goto-char
                 (marker-position marker))

                (insert cleaned)

                (unless (string-suffix-p "\n" cleaned)
                  (insert "\n"))

                (setq end-position
                      (point)))

              ;; If point is still where the command started, move it after
              ;; the inserted text. If the user moved while waiting, leave
              ;; their point alone.
              (when move-point
                (goto-char end-position))

              (message
               "Expose %s inserted."
               label)))

        (error
         (message
          "Expose failed to insert %s: %s"
          label
          (error-message-string error-data))))))

  (when (markerp marker)
    (set-marker marker nil)))

(defun expose-commands-replace-region-at-markers (buffer start end text label)
  "Replace the region between START and END in BUFFER with TEXT.

START and END bound a temporary placeholder (e.g. \"Loading...\")
inserted synchronously so there's visible feedback while an async
request is in flight; this swaps it for the real result (or an error
message, since callers route both through the same code path) once it
arrives. LABEL is used for user-facing status messages."

  (if (not
       (and
        (buffer-live-p buffer)
        (markerp start)
        (marker-position start)
        (markerp end)
        (marker-position end)))

      (message
       "Expose %s result ignored because the original buffer is gone."
       label)

    (with-current-buffer buffer

      (condition-case error-data

          (let* ((cleaned
                  (expose-commands-clean-insert-text text))

                 ;; If point is still where the placeholder ends, move it
                 ;; after the replacement text. If the user moved while
                 ;; waiting, restore their point via a marker instead of
                 ;; yanking it to the insertion site -- a marker (unlike a
                 ;; plain saved position) correctly tracks through the
                 ;; delete/insert below regardless of exactly where it
                 ;; sat relative to the replaced region.
                 (move-point
                  (= (point)
                     (marker-position end)))

                 (saved-point
                  (copy-marker (point))))

            (delete-region
             (marker-position start)
             (marker-position end))

            (goto-char
             (marker-position start))

            (if (string-empty-p cleaned)

                (message
                 "Expose %s returned an empty response."
                 label)

              (insert cleaned)

              (unless (string-suffix-p "\n" cleaned)
                (insert "\n"))

              (message
               "Expose %s inserted."
               label))

            (unless move-point
              (goto-char (marker-position saved-point)))

            (set-marker saved-point nil))

        (error
         (message
          "Expose failed to insert %s: %s"
          label
          (error-message-string error-data))))))

  (when (markerp start)
    (set-marker start nil))

  (when (markerp end)
    (set-marker end nil)))

;;; ---------------------------------------------------------------------------
;;; Timeout-aware transport
;;; ---------------------------------------------------------------------------

(defcustom expose-commands-provider-timeout-seconds 180
  "Seconds to wait for an AI provider before failing an Expose command."
  :type 'integer
  :group 'expose)

(defun expose-commands-send-document-async
    (label provider document project-root success-callback error-callback)
  "Send DOCUMENT to PROVIDER for LABEL with a client-side timeout.

Calls SUCCESS-CALLBACK with response text on success, or ERROR-CALLBACK with
a human-readable message string on failure or timeout.

If the provider does not respond within
`expose-commands-provider-timeout-seconds', the underlying provider process
is terminated instead of being left to run in the background indefinitely."

  (let ((completed nil)
        timeout-timer
        provider-process)

    (setq timeout-timer
          (run-at-time
           expose-commands-provider-timeout-seconds
           nil
           (lambda ()
             (unless completed
               (setq completed t)

               (when (and provider-process
                          (processp provider-process)
                          (process-live-p provider-process))

                 (expose-log
                  "Command"
                  "Killing provider process for %s after timeout."
                  label)

                 (delete-process provider-process))

               (funcall
                error-callback
                (format
                 "AI provider timed out after %d seconds while using %s."
                 expose-commands-provider-timeout-seconds
                 provider))))))

    (setq provider-process
          (expose-transport-send-document-async
           provider
           document

           (lambda (response-text)
             (unless completed
               (setq completed t)

               (when (timerp timeout-timer)
                 (cancel-timer timeout-timer))

               (funcall success-callback response-text)))

           project-root

           (lambda (error-data)
             (unless completed
               (setq completed t)

               (when (timerp timeout-timer)
                 (cancel-timer timeout-timer))

               (funcall error-callback
                        (error-message-string error-data))))))))

;;; ---------------------------------------------------------------------------
;;; Code Comment
;;; ---------------------------------------------------------------------------

(defcustom expose-code-comment-context-lines 12
  "Number of lines of context to send for generated code comments."
  :type 'integer
  :group 'expose)

(defun expose-code-comment-target-position ()
  "Return position of code to comment.

If point is on a blank line, use the next nonblank line. Otherwise use
the current line."

  (save-excursion
    (beginning-of-line)

    (when (expose-commands-line-blank-p)

      (while (and
              (not
               (eobp))
              (expose-commands-line-blank-p))

        (forward-line 1)))

    (point)))


(defun expose-code-comment-request (target-position project-root)
  "Build AI request for a code comment at TARGET-POSITION in PROJECT-ROOT."

  (let* ((file
          (expose-commands-relative-file project-root))

         (line-number
          (expose-commands-target-line-number target-position))

         (target-line
          (expose-commands-target-line-text target-position))

         (context
          (expose-commands-context-around
           target-position
           expose-code-comment-context-lines)))

    (format
     "<expose-code-comment-request>
  <instruction>
    Generate one useful source-code comment for the target line.

    Rules:
    - Return only the comment text.
    - Do not include Markdown.
    - Do not wrap the response in code fences.
    - Do not include comment delimiters like #, //, /*, or */.
    - Do not explain your reasoning.
    - Avoid obvious comments that simply repeat the code.
    - Prefer a concise comment that explains why the code exists, a non-obvious edge case, or an important behavior.
    - If no useful comment is warranted, return an empty string.
  </instruction>

  <location file=\"%s\" line=\"%s\" major_mode=\"%s\" />

  <target-line>
%s
  </target-line>

  <surrounding-context>
%s
  </surrounding-context>
</expose-code-comment-request>"
     file
     line-number
     major-mode
     target-line
     context)))


(defun expose-code-comment-clean-response (response)
  "Clean provider RESPONSE into raw comment text."

  (let ((text
         (string-trim
          (substring-no-properties
           (format "%s" response)))))

    ;; Strip simple Markdown fences.
    (setq text
          (replace-regexp-in-string
           "\\````[[:alnum:]_-]*[ \t]*\n?"
           ""
           text))

    (setq text
          (replace-regexp-in-string
           "\n?```\\'"
           ""
           text))

    ;; Strip common comment delimiters if the provider ignored instructions.
    (setq text
          (replace-regexp-in-string
           "\\`[ \t]*\\(?:#\\|//\\|--\\|;+\\)[ \t]*"
           ""
           text))

    (setq text
          (replace-regexp-in-string
           "\\`[ \t]*/\\*+[ \t]*"
           ""
           text))

    (setq text
          (replace-regexp-in-string
           "[ \t]*\\*/[ \t]*\\'"
           ""
           text))

    (string-trim text)))


(defun expose-code-comment-target-indentation (target-position)
  "Return indentation string for TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (buffer-substring-no-properties
     (line-beginning-position)
     (progn
       (back-to-indentation)
       (point)))))


(defun expose-code-comment-insert-at-marker (buffer marker target-position response)
  "Insert generated comment into BUFFER at MARKER.

TARGET-POSITION is used to copy indentation."

  (if (not
       (and
        (buffer-live-p buffer)
        (markerp marker)
        (marker-position marker)))

      (message "Expose code comment ignored because the original buffer is gone.")

    (with-current-buffer buffer

      (let ((comment
             (expose-code-comment-clean-response response)))

        (if (string-empty-p comment)

            (message "Expose code comment: no useful comment returned.")

          (let* ((indent
                  (expose-code-comment-target-indentation target-position))

                 start
                 end)

            (save-excursion
              (goto-char
               (marker-position marker))

              (setq start
                    (point))

              (dolist (line
                       (split-string comment "\n"))

                (insert indent)
                (insert line)
                (insert "\n"))

              (setq end
                    (point))

              (comment-region start end))

            (message "Expose code comment inserted."))))))

  (when (markerp marker)
    (set-marker marker nil)))



;;; ---------------------------------------------------------------------------
;;; Docstring Insertion
;;; ---------------------------------------------------------------------------

(defcustom expose-docstring-context-lines 20
  "Number of lines of context to send for generated docstrings."
  :type 'integer
  :group 'expose)

(defun expose-docstring-target-position ()
  "Return position whose surrounding code should be documented.

If point is on a blank line, use the next nonblank line as the target.
Otherwise use the current line."

  (save-excursion
    (beginning-of-line)

    (when (expose-commands-line-blank-p)

      (while (and
              (not
               (eobp))
              (expose-commands-line-blank-p))

        (forward-line 1)))

    (back-to-indentation)
    (point)))


(defun expose-docstring-insert-position (target-position)
  "Return position where the generated docstring should be inserted.

If point is on a blank line, insert at point's line. If point is on code,
insert under TARGET-POSITION."

  (if (expose-commands-line-blank-p)

      (line-beginning-position)

    (save-excursion
      (goto-char target-position)
      (forward-line 1)
      (line-beginning-position))))

(defun expose-docstring-request (target-position project-root)
  "Build AI request for a docstring at TARGET-POSITION in PROJECT-ROOT."

  (let* ((file
          (expose-commands-relative-file project-root))

         (line-number
          (expose-commands-target-line-number target-position))

         (target-line
          (expose-commands-target-line-text target-position))

         (context
          (expose-commands-context-around
           target-position
           expose-docstring-context-lines)))

    (format
     "<expose-docstring-request>
  <instruction>
    Generate one useful docstring or documentation comment for the code at the target line.

    Rules:
    - Return only ready-to-insert source text.
    - Do not return Markdown.
    - Do not wrap the response in code fences.
    - Do not explain your reasoning.
    - Use the correct documentation style for the language and major mode.
    - For Python, prefer triple-quoted docstrings.
    - For JavaScript/TypeScript, prefer JSDoc when documenting functions, classes, methods, or exported values.
    - For Emacs Lisp, prefer a normal Elisp docstring when appropriate.
    - Avoid obvious documentation that simply repeats the symbol name.
    - Prefer concise documentation that explains purpose, arguments, return value, side effects, or non-obvious behavior.
    - If no useful docstring is warranted, return an empty string.
  </instruction>

  <location file=\"%s\" line=\"%s\" major_mode=\"%s\" />

  <target-line>
%s
  </target-line>

  <surrounding-context>
%s
  </surrounding-context>
</expose-docstring-request>"
     file
     line-number
     major-mode
     target-line
     context)))


(defun expose-docstring-clean-response (response)
  "Clean provider RESPONSE into ready-to-insert docstring text."

  (let ((text
         (string-trim
          (substring-no-properties
           (format "%s" response)))))

    ;; Strip simple Markdown fences if the provider ignored instructions.
    (setq text
          (replace-regexp-in-string
           "\\````[[:alnum:]_-]*[ \t]*\n?"
           ""
           text))

    (setq text
          (replace-regexp-in-string
           "\n?```\\'"
           ""
           text))

    (string-trim text)))


(defun expose-docstring-existing-line-indent-string ()
  "Return indentation string from the current line without modifying it."

  (buffer-substring-no-properties
   (line-beginning-position)
   (progn
     (back-to-indentation)
     (point))))


(defun expose-docstring-blank-line-indent-string ()
  "Return indentation string for the current blank line.

This lets the major mode decide indentation, then removes only the
whitespace inserted by indentation. It does not delete real code."

  (let ((start
         (line-beginning-position))

        end
        indent)

    (indent-according-to-mode)

    (setq end
          (point))

    (setq indent
          (buffer-substring-no-properties
           start
           end))

    ;; Only remove the whitespace that `indent-according-to-mode' inserted
    ;; on this blank line.
    (delete-region start end)

    indent))


(defun expose-docstring-line-indent-string-at (position)
  "Return indentation string appropriate at POSITION.

When POSITION is on an existing code line, reuse that line's indentation.
When POSITION is on a blank line, ask the current major mode what the
indentation should be without deleting any real code."

  (save-excursion
    (goto-char position)

    (if (expose-commands-line-blank-p)

        (expose-docstring-blank-line-indent-string)

      (expose-docstring-existing-line-indent-string))))


(defun expose-docstring-insert-text-with-indent (text indent)
  "Insert TEXT with INDENT prefixed to every line."

  (dolist (line
           (split-string text "\n"))

    (insert indent)

    (unless (string-empty-p line)
      (insert line))

    (insert "\n")))


(defun expose-docstring-insert-at-marker (buffer marker target-position response)
  "Insert generated docstring into BUFFER at MARKER.

TARGET-POSITION is cleared after insertion."

  (if (not
       (and
        (buffer-live-p buffer)
        (markerp marker)
        (marker-position marker)))

      (message "Expose docstring ignored because the original buffer is gone.")

    (with-current-buffer buffer

      (let ((docstring
             (expose-docstring-clean-response response)))

        (if (string-empty-p docstring)

            (message "Expose docstring: no useful docstring returned.")

          (let* ((move-point
                  (= (point)
                     (marker-position marker)))

                 end-marker
                 indent)

            (save-excursion
              (goto-char
               (marker-position marker))

              ;; Compute indentation without deleting the insertion line.
              ;; If this line already has code, we reuse its indentation and
              ;; insert the docstring before it.
              (setq indent
                    (expose-docstring-line-indent-string-at
                     (point)))

              (expose-docstring-insert-text-with-indent
               docstring
               indent)

              (setq end-marker
                    (copy-marker
                     (point)
                     t)))

            (when move-point
              (goto-char
               (marker-position end-marker)))

            (set-marker end-marker nil)

            (message "Expose docstring inserted."))))))

  (when (markerp marker)
    (set-marker marker nil))

  (when (markerp target-position)
    (set-marker target-position nil)))

;;; ---------------------------------------------------------------------------
;;; Traceback Explanation
;;; ---------------------------------------------------------------------------
;;
;; The one Expose action whose input is not the buffer at all: a
;; traceback is pasted text, which has no natural single-line prompt the
;; way `expose-commands-refine-action-buffer''s one-line `read-string' has
;; -- so this opens a scratch buffer to paste it into instead, `C-c C-c'
;; to send, `C-c C-k' to cancel.
;;
;; What makes this worth more than pasting the same text at a general
;; chat prompt: every `File "...", line N' frame found in it is resolved
;; against the current project and its actual source read directly off
;; disk (see `expose-traceback-parse-frames'), and sent alongside the raw
;; text. Expose can read the project's files and the model cannot, so
;; whatever this can resolve locally travels as fact rather than being
;; left for the model to invent.

(defcustom expose-traceback-frame-context-lines 4
  "Lines of source context to read around each resolved traceback frame."
  :type 'integer
  :group 'expose)

(defcustom expose-traceback-max-frames 12
  "Maximum traceback frames to resolve real source for.

A traceback through a deep stack, or through library code with a `File'
line for nearly every frame, could otherwise mean reading dozens
of files off disk for one request. Capped to the frames nearest the top
and bottom of the stack -- nearest where the error was raised and where
it was ultimately triggered, which is generally where the interesting
code is on a long one."
  :type 'integer
  :group 'expose)

(defconst expose-traceback-buffer-name "*EXPOSE Traceback*")

(defvar-local expose-traceback-source-window nil
  "The window `expose-run-explain-traceback' was invoked from.")

(defvar-local expose-traceback-source-buffer nil
  "The buffer `expose-run-explain-traceback' was invoked from.

Read for project/language context and to resolve relative frame paths
against the right project root -- not assumed to still be the window's
buffer by the time `C-c C-c' is pressed, since nothing stops switching
buffers in that window in between.")

(defun expose-traceback-frame-file (path project-root)
  "Return a readable local file matching PATH, or nil.

PATH is whatever a traceback's `File \"...\"' names. Tried as an
absolute path first, then relative to PROJECT-ROOT, since a traceback
produced inside Docker or a different checkout will not always share
this machine's exact absolute layout. When neither is a real, readable
file, this returns nil rather than guessing at a match -- see
`expose-traceback-parse-frames'."

  (or
   (and (file-name-absolute-p path)
        (file-readable-p path)
        path)

   (and project-root
        (let ((candidate (expand-file-name path project-root)))
          (and (file-readable-p candidate) candidate)))))

(defun expose-traceback-read-context (file line context-lines)
  "Return CONTEXT-LINES of FILE's source around LINE, or nil."

  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)

      (let* ((total (line-number-at-pos (point-max)))
             (start (max 1 (- line context-lines)))
             (end (min total (+ line context-lines))))

        (goto-char (point-min))
        (forward-line (1- start))

        (let ((from (point)))
          (goto-char (point-min))
          (forward-line end)
          (buffer-substring-no-properties from (point)))))))

(defun expose-traceback-raw-frames (text)
  "Return every `File \"PATH\", line N[, in FUNCTION]' frame in TEXT.

Python only: that frame format is Python's own, and Expose is a
Django-focused tool. Each result is a plist of `:file', `:line',
`:function' -- unresolved against the local disk yet, see
`expose-traceback-parse-frames'."

  (let (frames)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))

      (while (re-search-forward
              "^[ \t]*File \"\\([^\"]+\\)\", line \\([0-9]+\\)\\(?:, in \\(.*\\)\\)?$"
              nil t)

        (push
         (list :file (match-string 1)
               :line (string-to-number (match-string 2))
               :function (match-string 3))
         frames)))

    (nreverse frames)))

(defun expose-traceback-cap-frames (frames)
  "Return at most `expose-traceback-max-frames' of FRAMES.

Keeps the ones nearest either end of the stack when there are more than
that -- see `expose-traceback-max-frames'."

  (if (<= (length frames) expose-traceback-max-frames)
      frames

    (let ((head (/ expose-traceback-max-frames 2)))
      (append
       (seq-take frames head)
       (seq-drop frames (- (length frames) (- expose-traceback-max-frames head)))))))

(defun expose-traceback-parse-frames (text project-root)
  "Return frame plists parsed from traceback TEXT, source resolved
against PROJECT-ROOT where possible.

Each plist carries `:file', `:line', `:function' as named in the
traceback, plus `:snippet' -- real source read off disk (see
`expose-traceback-frame-file'/`expose-traceback-read-context') when the
file could be found locally, omitted rather than fabricated otherwise."

  (mapcar
   (lambda (frame)
     (let* ((path (plist-get frame :file))
            (line (plist-get frame :line))
            (file (expose-traceback-frame-file path project-root))
            (snippet
             (and file line
                  (expose-traceback-read-context
                   file line expose-traceback-frame-context-lines))))

       (append frame (list :snippet snippet))))
   (expose-traceback-cap-frames (expose-traceback-raw-frames text))))

(defvar expose-traceback-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'expose-traceback-submit)
    (define-key map (kbd "C-c C-k") #'expose-traceback-cancel)
    map)
  "Keymap for `expose-traceback-input-mode'.")

(define-derived-mode expose-traceback-input-mode text-mode "Expose-Traceback"
  "Major mode for pasting a traceback for `expose-run-explain-traceback'.")

(defun expose-traceback-cancel ()
  "Cancel the pending traceback explanation."

  (interactive)

  (quit-window t)
  (message "Expose traceback explanation cancelled."))

(defun expose-traceback-submit ()
  "Send the pasted traceback for explanation."

  (interactive)

  (let ((text
         (string-trim (buffer-substring-no-properties (point-min) (point-max))))

        (source-window expose-traceback-source-window)
        (source-buffer expose-traceback-source-buffer))

    (when (string-empty-p text)
      (user-error "Nothing pasted"))

    (quit-window t)

    (let* ((live (buffer-live-p source-buffer))

           (project-root
            (if live
                (with-current-buffer source-buffer
                  (expose-commands-project-root-or-default))
              default-directory))

           (project
            (and live (with-current-buffer source-buffer (expose-context-project))))

           (language
            (and live (with-current-buffer source-buffer (expose-context-language))))

           (frames
            (expose-traceback-parse-frames text project-root))

           (context
            (list :project project :language language
                  :traceback text :frames frames))

           (window
            (if (window-live-p source-window) source-window (selected-window))))

      (message "Expose: explaining traceback...")

      (expose-log
       "Commands"
       "Explaining traceback (%d frame(s) found, %d resolved to real source)."
       (length frames)
       (seq-count (lambda (frame) (plist-get frame :snippet)) frames))

      (expose-action-buffer-show (expose-popup-loading-view "Explain Traceback") window)

      (expose-send-view-action-async
       'explain-traceback
       "Explain Traceback"
       (lambda (view) (expose-action-buffer-show view window))
       context))))

;;;###autoload
(defun expose-run-explain-traceback ()
  "Explain a pasted error/traceback, using real source read off disk.

Opens a scratch buffer to paste the traceback into. `C-c C-c' sends it;
`C-c C-k' cancels without sending anything."

  (interactive)

  (let ((source-window (selected-window))
        (source-buffer (current-buffer))
        (buffer (get-buffer-create expose-traceback-buffer-name)))

    (with-current-buffer buffer
      (unless (derived-mode-p 'expose-traceback-input-mode)
        (expose-traceback-input-mode))

      (erase-buffer)
      (setq expose-traceback-source-window source-window)
      (setq expose-traceback-source-buffer source-buffer))

    (pop-to-buffer buffer)
    (message "Expose: paste the traceback, then `C-c C-c' to explain it (`C-c C-k' to cancel).")))

;;; ---------------------------------------------------------------------------
;;; Popup Commands
;;; ---------------------------------------------------------------------------

(defun expose-close ()
  "Close the Expose popup."

  (interactive)

  (expose-hover-close))

(defun expose-run-review ()
  "Run the registered Expose review action."

  (interactive)

  (expose-popup-run-action ?r))

;;;###autoload
(defun expose-run-buffer-review ()
  "Review the current buffer's uncommitted changes.

Driven by the diff itself, not the code at point the way
`expose-run-review' is -- for \"is what I've just changed here any
good\", asked directly, without needing to select it first.

Refuses up front if there is nothing uncommitted in this file to
review, rather than sending an empty diff and getting back a review of
nothing."

  (interactive)

  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))

  (let ((diff (expose-context-git-diff-for-buffer)))
    (when (or (null diff) (string-blank-p diff))
      (user-error "No uncommitted changes in %s to review"
                  (file-name-nondirectory buffer-file-name))))

  (expose-popup-run-action ?b))

;;; ---------------------------------------------------------------------------
;;; Merge Conflict
;;; ---------------------------------------------------------------------------

(defcustom expose-conflict-context-lines 15
  "Lines of source context to send around a merge conflict hunk."
  :type 'integer
  :group 'expose)

(defun expose-conflict-bounds ()
  "Return (START SEP-START SEP-END END) for the conflict hunk enclosing
point, or nil when point is not inside one.

START is the `<<<<<<<' line's beginning; SEP-START/SEP-END bound the
`=======' line; END is just past the `>>>>>>>' line's newline.

Found by searching backward from point for the nearest `<<<<<<<' --
the innermost enclosing one when hunks are nested inside a larger
conflicted region, not necessarily the first one in the buffer -- then
forward for its own `=======' and `>>>>>>>'. Requiring point to actually
fall within [START, END] afterward is what rejects the case where point
sits *after* an earlier, already-bounded hunk entirely: the backward
search would still find that hunk's `<<<<<<<', but point being past its
`>>>>>>>' means point isn't really inside any conflict at all."

  (save-excursion
    (let ((origin (point)))
      (goto-char origin)
      (end-of-line)

      (when-let* ((start
                   (and (re-search-backward "^<<<<<<<[ \t]?.*$" nil t)
                        (line-beginning-position))))

        (goto-char start)
        (forward-line 1)

        (when-let* ((sep-start
                     (and (re-search-forward "^=======[ \t]*$" nil t)
                          (line-beginning-position)))
                    (sep-end
                     (line-end-position)))

          (forward-line 1)

          (when-let* ((end
                       (and (re-search-forward "^>>>>>>>[ \t]?.*$" nil t)
                            (min (point-max) (1+ (line-end-position))))))

            ;; Strictly less than END, not `<=': END is the position right
            ;; after the `>>>>>>>' line's own newline, which is the same
            ;; position as the *start* of whatever comes next -- and point
            ;; sitting exactly there means point is on that next line, not
            ;; inside the conflict.
            (when (and (<= start origin) (< origin end))
              (list start sep-start sep-end end))))))))

(defun expose-conflict-marker-label (position)
  "Return the branch name on the marker line at POSITION, or nil."

  (save-excursion
    (goto-char position)
    (when (looking-at "^\\(?:<<<<<<<\\|>>>>>>>\\)[ \t]*\\(.*\\)$")
      (let ((label (string-trim (match-string 1))))
        (unless (string-empty-p label) label)))))

(defun expose-conflict-at-point ()
  "Return a plist describing the conflict hunk at point, or nil.

Keys: `:start', `:end', `:ours', `:ours-label', `:theirs',
`:theirs-label'. `:start'/`:end' are kept for
`expose-commands-context-around' to build surrounding context from,
same as any other target position elsewhere in this file."

  (when-let ((bounds (expose-conflict-bounds)))
    (let ((start (nth 0 bounds))
          (sep-start (nth 1 bounds))
          (sep-end (nth 2 bounds))
          (end (nth 3 bounds)))

      (list
       :start start
       :end end

       :ours
       (buffer-substring-no-properties
        (save-excursion (goto-char start) (forward-line 1) (point))
        sep-start)

       :ours-label
       (expose-conflict-marker-label start)

       :theirs
       (buffer-substring-no-properties
        (save-excursion (goto-char sep-end) (forward-line 1) (point))
        (save-excursion (goto-char end) (forward-line -1) (line-beginning-position)))

       :theirs-label
       (expose-conflict-marker-label
        (save-excursion (goto-char end) (forward-line -1) (line-beginning-position)))))))

;;;###autoload
(defun expose-run-merge-conflict ()
  "Explain and propose a resolution for the merge conflict at point.

Refuses up front, like `expose-run-buffer-review', if point is not
inside a `<<<<<<< ... ======= ... >>>>>>>' hunk -- rather than starting
a request with nothing real to explain."

  (interactive)

  (unless (expose-conflict-at-point)
    (user-error "Point is not inside a merge conflict"))

  (expose-popup-run-action ?k))

(defun expose-run-diagnostics ()
  "Run the registered Expose diagnostics action."

  (interactive)

  (expose-popup-run-action ?d))

(defun expose-run-explain ()
  "Run the registered Expose explain action."

  (interactive)

  (expose-popup-run-action ?e))

(defun expose-run-fix ()
  "Run the registered Expose fix action."

  (interactive)

  (expose-popup-run-action ?f))

(defun expose-run-refactor ()
  "Run the registered Expose refactor action."

  (interactive)

  (expose-popup-run-action ?F))

(defun expose-run-security ()
  "Run the registered Expose security action."

  (interactive)

  (expose-popup-run-action ?s))

(defun expose-run-performance ()
  "Run the registered Expose performance action."

  (interactive)

  (expose-popup-run-action ?p))

(defun expose-run-tests ()
  "Run the registered Expose tests action."

  (interactive)

  (expose-popup-run-action ?t))

(defun expose-run-edge-cases ()
  "Run the registered Expose edge cases action."

  (interactive)

  (expose-popup-run-action ?x))

(defun expose-run-flow ()
  "Run the registered Expose flow action."

  (interactive)

  (expose-popup-run-action ?w))

(defun expose-run-usage ()
  "Run the registered Expose usage action."

  (interactive)

  (expose-popup-run-action ?u))

;;;###autoload
(defun expose-run-code-comment ()
  "Generate and insert a useful comment for the code at point."

  (interactive)

  (unless buffer-file-name
    (user-error "Expose code comment requires a file buffer"))

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-commands-project-root-or-default))

         (target-position
          (copy-marker
           (expose-code-comment-target-position)))

         ;; Insert where point is. This lets you stand on the blank line above
         ;; the code and have the comment appear there.
         (insert-marker
          (copy-marker
           (line-beginning-position)))

         (provider
          expose-provider-default)

         (document
          (expose-code-comment-request target-position project-root)))

    (message "Expose code comment: generating...")

    (expose-log
     "Commands"
     "Generating code comment for %s using %s."
     (expose-commands-relative-file project-root)
     provider)

    (expose-commands-send-document-async
     "code comment"
     provider
     document
     project-root

     (lambda (response-text)

       (expose-code-comment-insert-at-marker
        source-buffer
        insert-marker
        target-position
        response-text))

     (lambda (error-message)
       (set-marker insert-marker nil)
       (set-marker target-position nil)

       (message
        "Expose code comment failed: %s"
        error-message)))))

;;;###autoload
(defun expose-run-docstring ()
  "Generate and insert a useful docstring at point."

  (interactive)

  (unless buffer-file-name
    (user-error "Expose docstring requires a file buffer"))

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-commands-project-root-or-default))

         (target-position
          (copy-marker
           (expose-docstring-target-position)))

         ;; Blank line above code -> insert on that blank line.
         ;; Code line -> insert directly below the code line.
         (insert-marker
          (copy-marker
           (expose-docstring-insert-position target-position)))

         (provider
          expose-provider-default)

         (document
          (expose-docstring-request target-position project-root)))

    (message "Expose docstring: generating...")

    (expose-log
     "Commands"
     "Generating docstring for %s using %s."
     (expose-commands-relative-file project-root)
     provider)

    (expose-commands-send-document-async
     "docstring"
     provider
     document
     project-root

     (lambda (response-text)

       (expose-docstring-insert-at-marker
        source-buffer
        insert-marker
        target-position
        response-text))

     (lambda (error-message)
       (set-marker insert-marker nil)
       (set-marker target-position nil)

       (message
        "Expose docstring failed: %s"
        error-message)))))

(defun expose-run-summary ()
  "Run the registered Expose summary action."

  (interactive)

  (expose-popup-run-action ?m))

(defun expose-run-types ()
  "Run the registered Expose types action."

  (interactive)

  (expose-popup-run-action ?T))

(defun expose-run-concurrency ()
  "Run the registered Expose concurrency action."

  (interactive)

  (expose-popup-run-action ?C))

(defun expose-run-invariants ()
  "Run the registered Expose invariants action."

  (interactive)

  (expose-popup-run-action ?i))

(defun expose-run-risks ()
  "Run the registered Expose risks action."

  (interactive)

  (expose-popup-run-action ?!))

(defun expose-run-why ()
  "Run the registered Expose why action."

  (interactive)

  (expose-popup-run-action ?Y))

(defun expose-run-mental-model ()
  "Run the registered Expose mental model action."

  (interactive)

  (expose-popup-run-action ?M))

;;;###autoload
(defun expose-run-commit-message ()
  "Generate a commit message and insert it at point.

Inserts a temporary \"Loading commit message...\" placeholder at point
first, like the same pattern used elsewhere in Expose for other
async scans (see the project dashboard), so it's visible that
something is happening rather than leaving point sitting there with
no feedback until the response arrives -- then replaces the
placeholder with the generated result (or an error message)."

  (interactive)

  (let* ((source-buffer
          (current-buffer))

         ;; Bounds the "Loading..." placeholder, like `expose-continue-at-point'
         ;; anchors at the point where the command was invoked.
         (start
          (point-marker))

         end

         (project-root
          (expose-commands-project-root-or-default)))

    (expose-log
     "Commands"
     "Generating commit message for insertion from %s."
     project-root)

    (message "Expose commit message: generating...")

    (insert "Loading commit message...")

    (setq end
          (point-marker))

    (condition-case error-data

        (let ((default-directory
               project-root))

          (expose-send-view-action-async
           'commit-message
           "Commit Message"

           (lambda (view)
             (expose-commands-replace-region-at-markers
              source-buffer
              start
              end
              (expose-commands-view-body-text view)
              "commit message"))))

      (error
       (set-marker start nil)
       (set-marker end nil)

       (message
        "Expose commit message failed: %s"
        (error-message-string error-data))))))

(defun expose-run-diagram (type title command &optional focus direction context)
  "Request a TYPE diagram, render it, and display it under TITLE.

COMMAND is the interactive command that produced this, recorded so the
diagram buffer's `g' can re-run the right one. FOCUS, when given, names
the node to emphasize -- the model the command was invoked from.
CONTEXT, when given, is used as-is instead of a freshly built
`(expose-context-build)' -- passed straight through to
`expose-send-view-action-async', same meaning as there. Only
`expose-run-signal-flow-diagram' currently passes one, to fold in real
receiver bodies found elsewhere in the project; every other diagram
command omits it and gets the ordinary point-based context.

Shared by every diagram command: the only thing that differs between
them is the request type and what the result is called -- extraction,
rendering, display, and both failure paths are identical."

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (expose-log
   "Commands"
   "Generating %s diagram using provider %s."
   type
   expose-provider-default)

  (message "Expose %s diagram: generating..." (downcase title))

  (let ((origin (list (current-buffer) (point) command)))

    (expose-send-view-action-async
     type
     title

     (lambda (view)
       ;; Deferred out of the provider's process sentinel, which is where
       ;; this callback runs. Rendering shells out to `dot', and starting
       ;; a synchronous subprocess from inside a sentinel can collide with
       ;; whatever else holds a process lock -- native compilation, most
       ;; visibly, which reports "Attempt to accept output from process
       ;; Compiling: ... locked to thread". A zero-delay timer runs the
       ;; same work from the command loop instead, once the sentinel has
       ;; returned.
       (run-at-time
        0 nil
        (lambda ()
          (let* ((response
                  (expose-commands-view-body-text view))

                 (dot
                  (expose-diagram-extract-dot response)))

            (if (not dot)
                (progn
                  (expose-log
                   "Commands"
                   "%s diagram: no DOT found in response (%d bytes)."
                   type
                   (length (or response "")))

                  (expose-diagram-display-failure
                   response
                   "No Graphviz DOT graph found in the provider's response."
                   title)

                  (message "Expose %s diagram: no DOT in response" (downcase title)))

              (let ((result
                     (expose-diagram-render-svg dot focus direction)))

                (if (car result)
                    (progn
                      (expose-diagram-display (cdr result) dot title origin)
                      (message "Expose %s diagram: done" (downcase title)))

                  (expose-log
                   "Commands"
                   "%s diagram: dot failed: %s"
                   type
                   (cdr result))

                  (expose-diagram-display-failure dot (cdr result) title)
                  (message "Expose %s diagram: dot failed" (downcase title)))))))))
     context)))

;;;###autoload
(defun expose-run-control-flow-diagram ()
  "Render a control-flow graph of the code at point as an image.

The graph counterpart of `expose-run-flow' (which answers the same
question in prose): branches, loops, early returns, and the exception
paths between them, within this one unit of code. For what it calls
outward instead, see `expose-run-call-flow-diagram'.

Advisory, like everything else in Expose -- the graph is the model's
reading of code it can only partly see, and a picture reads as more
authoritative than a paragraph. Press `s' in the diagram buffer to check
it against the DOT source.

When `dot' rejects the generated source -- common enough with generated
DOT to be a normal path, not an exceptional one -- the source and
Graphviz's own complaint are shown together instead, so it can be
corrected by hand."

  (interactive)

  (expose-run-diagram
   'control-flow-diagram
   "Control Flow"
   #'expose-run-control-flow-diagram))

;;;###autoload
(defun expose-run-reverse-call-graph ()
  "Graph what calls the function at point, and what calls those.

The one Expose diagram with no AI in it. The others describe the code
in front of them; this needs the whole project, which no provider can
see -- asked anyway it invents callers, and a fabricated answer to \"is
it safe to change this?\" is worse than none. Edges come from the
language server's call hierarchy, or `xref' when it can't answer, so
they're the same ones navigation uses.

Test files are left out (`expose-callers-exclude-regexps'): tests call
everything, and including them buries the production paths that
actually answer the question. Bounded by
`expose-callers-max-depth' and `expose-callers-max-nodes'; anything
trimmed by those is marked on the graph rather than dropped silently.

Renders through the same pipeline as the other diagrams, so zoom, pan,
export and the source view all work identically."

  (interactive)

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (require 'expose-callers)

  (message "Expose reverse call graph: searching...")

  (let* ((origin (list (current-buffer) (point) #'expose-run-reverse-call-graph))
         (built (expose-callers-build-dot))
         (dot (car built))
         (root (cdr built))
         (result (expose-diagram-render-svg dot root)))

    (if (car result)
        (progn
          (expose-diagram-display (cdr result) dot "Reverse Call Graph" origin)
          (message "Expose reverse call graph: done"))

      (expose-log "Commands" "Reverse call graph: dot failed: %s" (cdr result))
      (expose-diagram-display-failure dot (cdr result) "Reverse Call Graph")
      (message "Expose reverse call graph: dot failed"))))

(defun expose-run-er-diagram-context (model-name)
  "Return an ER-diagram context, folding in real reverse-referencing
models for MODEL-NAME.

Built on top of the ordinary `(expose-context-build)' rather than
replacing it -- `:reverse-relations' is additional fact the model's
own file cannot show (what points AT it from elsewhere in the
project), not a substitute for what's actually in the buffer. Nil
MODEL-NAME or no reverse-referencing models found both leave the base
context untouched. `buffer-file-name' is excluded from the search:
whatever it contains is already part of `:code', which already covers
the common case of several related models sharing one `models.py'."

  (let ((base (expose-context-build)))
    (if-let* ((model-name)
              (models (expose-relations-find-referencing-models model-name buffer-file-name)))
        (plist-put base :reverse-relations models)
      base)))

;;;###autoload
(defun expose-run-er-diagram ()
  "Render an entity-relationship diagram of the models in this buffer.

Unlike the flow diagrams, this is about a whole file rather than the
code at point: a schema is only legible with every model in it. With no
region active, the whole buffer is used -- Expose already prefers an
active region for `:code', so this just widens that to everything.
Select a region first to diagram only part of a large `models.py'.

The most trustworthy of the diagram commands: relationships are
declared in the source rather than inferred, so there is much less room
for invention than in `expose-run-call-flow-diagram'. Models from
outside the file are drawn as external, abstract bases dashed, and each
relationship colored by kind (foreign key, many-to-many, one-to-one) --
except a model that points AT the one at point from a completely
different file, which nothing local can see at all:
`expose-relations-find-referencing-models' greps the whole project for
a relationship field naming the model at point as its target, and
folds each real match's full body into what gets sent, so it's drawn
with its own fields instead of not being drawn at all.

The model point was inside when this ran is emphasized, so a schema of
thirty models still tells you where you came from. That name is
resolved here rather than asked of the provider -- it's a fact about
the buffer, not a judgement call."

  (interactive)

  (require 'expose-relations)

  (let* ((focus
          (or (expose-context-scope-name)
              (expose-context-parent-scope-name)))

         (context
          (if (use-region-p)
              (expose-run-er-diagram-context focus)

            ;; Context is built synchronously here, before anything is
            ;; sent, so a region marked for the duration of this block
            ;; is enough -- and it's undone immediately either way.
            ;;
            ;; `transient-mark-mode' is bound rather than assumed: Expose
            ;; detects a selection with `use-region-p', which returns nil
            ;; when that mode is off no matter what `push-mark' did -- the
            ;; widening would then silently do nothing and the diagram
            ;; would cover only the code at point.
            (save-mark-and-excursion
              (let ((transient-mark-mode t))
                (push-mark (point-min) t t)
                (goto-char (point-max))
                (unwind-protect
                    (expose-run-er-diagram-context focus)
                  (deactivate-mark)))))))

    (expose-run-diagram 'er-diagram "ER" #'expose-run-er-diagram focus nil context)))

;;;###autoload
(defun expose-find-tests ()
  "List the tests that reach the code at point, and jump to one.

The same question as `expose-run-test-graph' -- is this tested, and by
what -- answered as a list you pick from rather than a picture. Which
one you want depends on the question: the graph shows *how* a test gets
here, through which intermediate functions, while this just takes you to
the test.

Computed, not generated: LSP call hierarchy falling back to `xref', plus
non-call references and, for Django, tests that reach a view only by
`reverse()'-ing its URL name. No provider is asked, because \"which
tests cover this\" is worthless answered plausibly.

Only tests are listed. The graph keeps the intermediate functions a test
reaches through, which are worth seeing in a picture and are noise in a
list of somewhere to go.

Shown in a persistent side-panel buffer, placed beside this one --
grouped under its file, the matching line in context, `TAB'/`S-TAB' to
move, `RET' to open a test to the left without losing the list, `g' to
search again."

  (interactive)

  (require 'expose-find-tests)

  (message "Expose: finding tests...")

  (expose-find-tests-open (selected-window)))

;;;###autoload
(defun expose-run-test-graph ()
  "Graph which tests reach the function at point, and how.

Answers \"is this tested, and by what\" -- not a coverage percentage.
The reverse call graph deliberately excludes tests so production paths
stay readable; this is the half it throws away, and only that half:
callers no test goes through are pruned, so what's left is the routes
tests take to get here, intermediate functions included.

Computed, not generated -- LSP call hierarchy, falling back to `xref',
same as `expose-run-reverse-call-graph'. Non-call references count too,
since a function registered rather than called is still exercised.

When nothing reaches it, that's stated plainly instead of drawn as an
empty graph. Worth knowing what that does and doesn't mean: it says no
test reaches this within `expose-callers-max-depth' levels, not that the
code is untested by every possible route."

  (interactive)

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (require 'expose-callers)

  (message "Expose test graph: searching...")

  (let* ((origin (list (current-buffer) (point) #'expose-run-test-graph))
         (built (expose-callers-build-tests-dot))
         (dot (nth 0 built))
         (root (nth 1 built))
         (count (nth 2 built))
         (result (expose-diagram-render-svg dot root)))

    (if (car result)
        (progn
          (expose-diagram-display (cdr result) dot "Tests" origin)
          (message "Expose test graph: %d test%s reach %s"
                   count (if (= count 1) "" "s") root))

      (expose-log "Commands" "Test graph: dot failed: %s" (cdr result))
      (expose-diagram-display-failure dot (cdr result) "Tests")
      (message "Expose test graph: dot failed"))))

;;;###autoload
(defun expose-run-migration-history (&optional complete)
  "Graph how the Django model at point was shaped by its migrations.

With a prefix argument, COMPLETE draws every migration rather than the
most recent `expose-migrations-max-migrations'. Worth knowing what you
are asking for: each table lists every field the model had at that
point, so a few hundred migrations is a picture that has to be scrolled
rather than read.

Every operation that touched it, oldest first: created, fields added,
retyped, renamed, dropped. Colored by what each does to existing data --
additive green, altering amber, renaming violet, destructive red -- so
the edits that lost or reshaped data stand out from the ones that only
added.

Computed by parsing the migration files, not generated. They are
mechanically regular and there are usually dozens of them, which makes
this exactly the tedious exact work a parser does better; and asking
when a field became nullable is a question where a plausible answer is
worth nothing.

Reading any single migration shows one edit. What this adds is the
ordering: a field added in 0004, retyped in 0011 and dropped in 0032
lives in three files named after whatever else they happened to
contain."

  (interactive "P")

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (require 'expose-migrations)

  (message "Expose migration history: reading migrations...")

  (let* ((origin (list (current-buffer) (point) #'expose-run-migration-history))
         ;; nil is "no limit" -- see `expose-migrations-max-migrations'.
         (expose-migrations-max-migrations
          (if complete nil expose-migrations-max-migrations))
         (built (expose-migrations-build-dot))
         (dot (car built))
         (model (cdr built))
         (result (expose-diagram-render-svg dot model "LR")))

    (if (car result)
        (progn
          (expose-diagram-display (cdr result) dot "Migration History" origin)
          (message "Expose migration history: done"))

      (expose-log "Commands" "Migration history: dot failed: %s" (cdr result))
      (expose-diagram-display-failure dot (cdr result) "Migration History")
      (message "Expose migration history: dot failed"))))

;;;###autoload
(defun expose-run-middleware-diagram ()
  "Draw the Django middleware stack for the current project, in real
request order.

`expose-run-request-flow-diagram' draws a single view's own pipeline;
this is the layer above every one of them, that every request passes
through before any view runs at all, and it lives in one project-wide
list in settings.py that no per-view diagram can show. Drawn as the
onion it actually is: the first entry is outermost, first to see the
request and last to see the response, so two edges connect each
adjacent pair -- one each direction -- rather than implying a single
straight pipe.

Computed by parsing `MIDDLEWARE', not generated: it is a literal
Python list in the overwhelming common case, and \"what order do these
run in\" is exactly the kind of question a parser answers exactly where
a provider could only guess at a settings file it may not even have
been shown. Project-local middleware are shown with their own
docstring when they have one; third-party and Django built-in
middleware, not in this project's own tree to read, are named only."

  (interactive)

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (require 'expose-middleware)

  (message "Expose middleware pipeline: reading settings...")

  (let* ((origin (list (current-buffer) (point) #'expose-run-middleware-diagram))
         (dot (expose-middleware-build-dot))
         (result (expose-diagram-render-svg dot nil "TB")))

    (if (car result)
        (progn
          (expose-diagram-display (cdr result) dot "Middleware" origin)
          (message "Expose middleware pipeline: done"))

      (expose-log "Commands" "Middleware pipeline: dot failed: %s" (cdr result))
      (expose-diagram-display-failure dot (cdr result) "Middleware")
      (message "Expose middleware pipeline: dot failed"))))

;;;###autoload
(defun expose-run-urls-diagram ()
  "Draw the Django URL routing tree for the current project.

Starts from `ROOT_URLCONF' and follows every `path()'/`re_path()'/
`url()' entry, recursing through `include(\"app.urls\")' from there --
so the tree is not just the file you happen to be looking at, but
everywhere routing actually leads, the same way a request itself
travels through it.

Computed by parsing, not generated: routing is declarative,
mechanically regular Python spread across as many files as the project
has `include()'d, which is exactly the shape a parser reconstructs
exactly and a provider, shown only one urls.py at a time, cannot. A DRF
router's own registrations are read too, wherever `....register(...)'
appears, alongside plain `path()' entries.

Bounded by `expose-urls-max-depth' and `expose-urls-max-nodes'; a walk
trimmed by either says so in the diagram's own title rather than
drawing a partial tree that looks complete. `include(router.urls)' and
other bare-identifier includes are not followed -- only the common
string-argument form, `include(\"app.urls\")', is -- a real, stated
limit rather than a silent one."

  (interactive)

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (require 'expose-urls)

  (message "Expose URL tree: reading routes...")

  (let* ((origin (list (current-buffer) (point) #'expose-run-urls-diagram))
         (dot (expose-urls-build-dot))
         (result (expose-diagram-render-svg dot nil "LR")))

    (if (car result)
        (progn
          (expose-diagram-display (cdr result) dot "URL Routes" origin)
          (message "Expose URL tree: done"))

      (expose-log "Commands" "URL tree: dot failed: %s" (cdr result))
      (expose-diagram-display-failure dot (cdr result) "URL Routes")
      (message "Expose URL tree: dot failed"))))

;;;###autoload
(defun expose-run-import-graph (&optional show-externals)
  "Graph what this file imports, transitively.

Computed from the source, not generated: imports are trivially
parseable, so asking a provider to describe them would trade an exact
answer for a plausible one. The other diagram this applies to is
`expose-run-reverse-call-graph', for the same reason.

Follows project-local imports and stops at the boundary -- third-party
and standard library packages are leaves, since walking into
site-packages isn't the point. With a prefix argument they're drawn as
external nodes; by default they're omitted, which usually makes the
project's own shape far easier to read.

Import cycles are detected and drawn in red. That's the main reason to
render this at all: a cycle is invisible in any single file, and in
Python it's a real failure rather than a style problem.

Python and TypeScript/JavaScript. Tests, migrations and node_modules are
excluded (`expose-imports-exclude-regexps'); bounded by
`expose-imports-max-depth' and `expose-imports-max-nodes'."

  (interactive "P")

  (unless (executable-find expose-diagram-dot-executable)
    (user-error
     "Graphviz `%s' not found on PATH; needed to render Expose diagrams"
     expose-diagram-dot-executable))

  (require 'expose-imports)

  (message "Expose import graph: scanning...")

  (let* ((origin (list (current-buffer) (point) #'expose-run-import-graph))
         (built (expose-imports-build-dot show-externals))
         (dot (car built))
         (label (cdr built))
         (result (expose-diagram-render-svg dot label)))

    (if (car result)
        (progn
          (expose-diagram-display (cdr result) dot "Import Graph" origin)
          (message "Expose import graph: done"))

      (expose-log "Commands" "Import graph: dot failed: %s" (cdr result))
      (expose-diagram-display-failure dot (cdr result) "Import Graph")
      (message "Expose import graph: dot failed"))))

;;;###autoload
(defun expose-run-side-effects-diagram ()
  "Render what the code at point changes outside itself.

Rows written, mail sent, jobs queued, services called -- including
effects several frames down, where the body is visible. Where call flow
shows what gets invoked and data flow where values go, this is about
consequences that outlive the call.

Effects inside a transaction are grouped in their own box, because the
useful question is usually which of them survive a rollback: mail and
queued tasks do, and a failure after that point leaves a notification
about a row that no longer exists. They keep their own shape inside the
transaction box rather than being redrawn as writes, so that stays
visible.

Provider-generated and inference-heavy, so worth checking: `s' shows the
DOT it was built from."

  (interactive)

  (expose-run-diagram
   'side-effects-diagram
   "Side Effects"
   #'expose-run-side-effects-diagram
   nil
   ;; Vertical: effects fan out from one entry point, and laid out
   ;; left-to-right that fan runs along the X axis into a ribbon.
   "TB"))

;;;###autoload
(defun expose-run-request-flow-diagram ()
  "Render a Django request-flow diagram of the view at point.

Traces one request through the code -- view, permission and validation
gates, domain calls, ORM and cache access, response -- grouped into
labelled pipeline layers. Where `expose-run-call-flow-diagram' draws a
flat call tree, this one is about order and layering, so a missing layer
reads as an absence: a view with no permission gate, or one reaching
straight into the ORM, is visible as a gap rather than something you
have to notice isn't there.

Gates that can reject the request are drawn as conditions and their
failure paths are requested explicitly, since a gate shown with only its
success edge is worse than not drawing it.

Routing is included only when the URL configuration is in the code being
looked at, which from a views module it usually isn't -- rather than
inventing a plausible route. To find what actually routes here, use
`expose-run-reverse-call-graph', which reports the `urls.py' reference
as a module-level usage."

  (interactive)

  (expose-run-diagram
   'request-flow-diagram
   "Request Flow"
   #'expose-run-request-flow-diagram))

;;;###autoload
(defun expose-run-data-flow-diagram ()
  "Render a data-flow graph of the code at point as an image.

The third axis: `expose-run-control-flow-diagram' shows when things
run, `expose-run-call-flow-diagram' shows what gets invoked, and this
shows where values come from, what reshapes them, and where they end
up. Inputs, derived values, third-party transforms, sinks that leave
the process, and returns are colored differently.

Edges carry the operation, so in-place mutation is stated rather than
implied -- rebinding a name and mutating the object behind it look
nearly identical in source and behave nothing alike, which is the thing
this is worth drawing for.

Inference-heavy, so the most worth checking of the provider-generated
diagrams: aliasing and mutation are exactly where a plausible reading
can be wrong. Press `s' to see the DOT it was built from."

  (interactive)

  (expose-run-diagram
   'data-flow-diagram
   "Data Flow"
   #'expose-run-data-flow-diagram))

;;;###autoload
(defun expose-run-call-flow-diagram ()
  "Render a call-flow graph of the code at point as an image.

Maps outward -- what this code calls, and what those call in turn --
where `expose-run-control-flow-diagram' maps the branching inside it.
Callees are colored by kind: local code, third-party library, and I/O
\(database, network, filesystem) each read differently, since the last
two are where the surprises usually are.

Worth more skepticism than the control-flow graph: a model asked what
something \"calls\" will readily describe the insides of a dependency it
was never shown. The request pins it to visible call sites and asks for
anything it can't see to be marked \"(unresolved)\" rather than guessed,
but `s' to check against the DOT source is the real safeguard."

  (interactive)

  (expose-run-diagram
   'call-flow-diagram
   "Call Flow"
   #'expose-run-call-flow-diagram))

;;;###autoload
(defun expose-run-signal-flow-diagram-context (model-name)
  "Return a signal-flow context, folding in real receivers of MODEL-NAME.

Built on top of the ordinary point-based `(expose-context-build)'
rather than replacing it -- `:receivers' is additional fact the model's
own code cannot show, not a substitute for it. Nil MODEL-NAME (nothing
resolved at point) or no receivers found for it both leave the base
context untouched, so this is a pure no-op exactly when there is
nothing more to add -- most visibly when run from inside the receiver
function itself, which already has its own `@receiver' visible in its
own code."

  (let ((base (expose-context-build)))
    (if-let* ((model-name)
              (receivers (expose-signals-find-receivers model-name)))
        (plist-put base :receivers receivers)
      base)))

(defun expose-run-signal-flow-diagram ()
  "Render a Django signal-flow diagram for the model or code at point.

Traces a signal from what fires it (a `.save()'/`.delete()' or an
explicit `Signal().send()') through every receiver that responds, and
what each receiver itself then does. Nothing else in Expose follows
this link: a receiver connects to a signal by decorator or `.connect()'
call that routinely lives in a different app's `signals.py' than the
model it watches, so reading the model or the `save()' call alone shows
none of it -- which is exactly the case this command's own context
building compensates for: `expose-signals-find-receivers' greps the
whole project for `@receiver(...)' functions whose `sender=' names the
model at point, and folds their real bodies into what gets sent,
rather than asking the provider to draw a link it was never shown any
evidence of. Run from inside the receiver itself, its own `@receiver'
is already visible in the ordinary code context and this search
correctly finds nothing more to add.

Provider-generated, so worth checking: a decorator's `sender=' is
declarative and hard to get wrong, but whether a plain `.save()' call
actually fires the signal -- `raw=True' and a fixture loader suppress it
-- takes understanding the model, not just finding the decorator. Press
`s' in the diagram buffer to check the DOT it was built from."

  (interactive)

  (require 'expose-signals)

  (let* ((model-name
          (or (expose-context-scope-name) (expose-context-parent-scope-name)))

         (context
          (expose-run-signal-flow-diagram-context model-name)))

    (expose-run-diagram
     'signal-flow-diagram
     "Signal Flow"
     #'expose-run-signal-flow-diagram
     model-name
     nil
     context)))

(defun expose-run-changelog ()
  "Run the registered Expose changelog action."

  (interactive)

  (expose-popup-run-action ?n))

;;; ---------------------------------------------------------------------------
;;; PR Description
;;; ---------------------------------------------------------------------------

(defun expose-pr-description-diff (project-root base-branch)
  "Return the diff of the current branch in PROJECT-ROOT against BASE-BRANCH.

`BASE-BRANCH...HEAD' rather than `BASE-BRANCH..HEAD' -- the three-dot
form compares against the merge-base, so commits landed on BASE-BRANCH
after this branch forked from it don't show up as \"changes\" here, the
same range `expose-review-open-pr-diff' shows locally as a Magit diff
and GitHub itself uses for a PR's own \"Files changed\" tab."

  (expose-context-truncate
   (expose-review-context-git-string
    project-root "diff" (format "%s...HEAD" base-branch) "--no-ext-diff")
   expose-context-git-diff-max-length))

(defun expose-pr-description-commits (project-root base-branch)
  "Return one-line commit subjects unique to the current branch in
PROJECT-ROOT, relative to BASE-BRANCH.

Two dots, not three: unlike the diff above, the commit log wants
exactly what this branch added -- BASE-BRANCH's own history since the
fork is not part of that story and would only pad it. Worth more than
the diff alone would say on its own: a commit message routinely states
intent (\"why\") that a diff of the end result cannot -- particularly
after a rebase or several `fixup!' commits have flattened the path
actually taken into a diff that only shows where it ended up."

  (expose-review-context-git-string
   project-root "log" (format "%s..HEAD" base-branch) "--pretty=format:%s"))

;;;###autoload
(defun expose-run-pr-description ()
  "Write a GitHub pull request description for the current branch.

Scoped to the whole branch against its detected base (`main'/`master'/
`develop', or `expose-review-base-branch' when set) -- the same
project-root and base-branch detection `expose-review-open-pr-diff'
and Full Review share (`expose-review-context-project-root'/
`expose-review-context-detect-base-branch') -- not to just the working
tree's uncommitted changes the way `expose-run-changelog' is. Refuses
up front, like `expose-run-buffer-review', if no base branch could be
detected (which, since that detection itself falls back to plain
`default-directory' when nothing else resolves a project root, is also
what happens outside a Git repository entirely) or the branch has no
changes relative to it."

  (interactive)

  (let* ((project-root
          (expose-review-context-project-root))

         (base-branch
          (or (expose-review-context-detect-base-branch project-root)
              (user-error "Could not detect a base branch to compare against (tried %s)"
                          (string-join expose-review-context-base-branch-candidates ", ")))))

    (let ((diff (expose-pr-description-diff project-root base-branch)))
      (when (or (null diff) (string-blank-p diff))
        (user-error "No changes on this branch relative to %s" base-branch))))

  (expose-popup-run-action ?P))

;;; ---------------------------------------------------------------------------
;;; Views
;;; ---------------------------------------------------------------------------

(defun expose-action-view (title response &optional type context refinements)
  "Create an Expose popup view with TITLE and RESPONSE.

TYPE and CONTEXT, when both given, are carried on a `:refine' key --
see `expose-action-buffer-refine' for what it holds and who reads it --
so this result can later be rebuilt with an amended instruction rather
than left a dead end. REFINEMENTS is the list of follow-up asks already
applied to reach this result, oldest first; omitted for a fresh,
not-yet-refined one.

Omit TYPE/CONTEXT entirely for a result that should not be refinable at
all -- an error response, say, where there is nothing successful yet to
build on."

  (let ((view
         (expose-popup-view-create title response)))

    (if (and type context)
        (plist-put
         view :refine
         (list :type type :context context :refinements refinements))
      view)))

(defun expose-send-view-action-async (type title callback &optional context)
  "Send TYPE asynchronously and call CALLBACK with a titled popup view.

CONTEXT defaults to a freshly built `(expose-context-build)' -- the
generic, point-based context every ordinary `SPC c h h' action wants.
Pass one in for a type built from something else entirely (a whole
buffer's diff, say, not point/selection); passed through to
`expose-request-build', same as there.

Whichever it is, built once, up front -- not inside
`expose-document-build' itself, though that would be the more obvious
place -- specifically so it can be captured and threaded onto the
resulting view's `:refine' key. A refinement rebuilds this exact
request later with an amended instruction, and needs the context it
was originally about, not whatever building it fresh would return if
it ran again at that later point."

  (expose-log
   "Command"
   "Starting async action %s using provider %s."
   type
   expose-provider-default)

  (let ((context (or context (expose-context-build))))

    (expose-commands-send-document-async
     (symbol-name type)
     expose-provider-default
     (expose-document-build type context)
     nil

     (lambda (response)

       (expose-log
        "Command"
        "Async action %s returned response (%d bytes)."
        type
        (length response))

       (funcall
        callback
        (expose-action-view title response type context))

       (expose-log
        "Command"
        "Async action %s completed."
        type))

     (lambda (error-message)

       (expose-log
        "Command"
        "Async action %s failed: %s"
        type
        error-message)

       ;; No :refine here -- nothing succeeded yet to build a follow-up
       ;; on top of.
       (funcall
        callback
        (expose-action-view title error-message))))))

;;; ---------------------------------------------------------------------------
;;; Action Commands
;;; ---------------------------------------------------------------------------

(defun expose-review ()
  "Run an asynchronous Expose review."

  (interactive)

  (expose-run-review))

(defun expose-review-async (callback)
  "Run an asynchronous Expose review and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'review
   "Review"
   callback))

(defun expose-buffer-review-async (callback)
  "Review the current buffer's uncommitted changes and call CALLBACK with a popup view.

Built from a plist of its own, not `expose-context-build' -- the
generic context builder is about point/selection, and this has neither;
what it has is a file and a diff."

  (let ((context
         (list
          :project (expose-context-project)
          :language (expose-context-language)
          :file (expose-context-relative-file)
          :buffer-diff (expose-context-git-diff-for-buffer))))

    (expose-send-view-action-async
     'buffer-review
     "Buffer Review"
     callback
     context)))

(defun expose-merge-conflict-async (callback)
  "Explain and propose a resolution for the conflict at point and call
CALLBACK with a popup view.

`expose-run-merge-conflict' already refused up front if point is not
inside a conflict, before this ever ran -- so a nil here means point
moved in between, which cannot actually happen (both run synchronously
in the same call), but is still guarded rather than assumed."

  (let ((conflict
         (or (expose-conflict-at-point)
             (user-error "Point is not inside a merge conflict"))))

    (let ((context
           (list
            :project (expose-context-project)
            :language (expose-context-language)
            :file (expose-context-relative-file)
            :ours (plist-get conflict :ours)
            :ours-label (plist-get conflict :ours-label)
            :theirs (plist-get conflict :theirs)
            :theirs-label (plist-get conflict :theirs-label)
            :code (expose-commands-context-around
                   (plist-get conflict :start)
                   expose-conflict-context-lines))))

      (expose-send-view-action-async
       'merge-conflict
       "Merge Conflict"
       callback
       context))))

(defun expose-diagnostics ()
  "Explain diagnostics at point asynchronously."

  (interactive)

  (expose-run-diagnostics))

(defun expose-diagnostics-async (callback)
  "Explain diagnostics asynchronously and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'diagnostics
   "Diagnostics"
   callback))

(defun expose-explain ()
  "Explain the symbol or construct at point asynchronously."

  (interactive)

  (expose-run-explain))

(defun expose-explain-async (callback)
  "Explain the current symbol or construct and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'explain
   "Explain"
   callback))

(defun expose-fix ()
  "Suggest the smallest safe fix for the current code asynchronously."

  (interactive)

  (expose-run-fix))

(defun expose-fix-async (callback)
  "Suggest the smallest safe fix and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'fix
   "Fix"
   callback))

(defun expose-refactor ()
  "Suggest a behavior-preserving refactor asynchronously."

  (interactive)

  (expose-run-refactor))

(defun expose-refactor-async (callback)
  "Suggest a behavior-preserving refactor and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'refactor
   "Refactor"
   callback))

(defun expose-security ()
  "Review the current code for security issues asynchronously."

  (interactive)

  (expose-run-security))

(defun expose-security-async (callback)
  "Review the current code for security issues and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'security
   "Security"
   callback))

(defun expose-performance ()
  "Review the current code for performance issues asynchronously."

  (interactive)

  (expose-run-performance))

(defun expose-performance-async (callback)
  "Review the current code for performance issues and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'performance
   "Performance"
   callback))

(defun expose-tests ()
  "Suggest focused tests for the current code asynchronously."

  (interactive)

  (expose-run-tests))

(defun expose-tests-async (callback)
  "Suggest focused tests and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'tests
   "Tests"
   callback))

(defun expose-edge-cases ()
  "Identify important edge cases asynchronously."

  (interactive)

  (expose-run-edge-cases))

(defun expose-edge-cases-async (callback)
  "Identify important edge cases and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'edge-cases
   "Edge Cases"
   callback))

(defun expose-flow ()
  "Explain code flow asynchronously."

  (interactive)

  (expose-run-flow))

(defun expose-flow-async (callback)
  "Explain code flow and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'flow
   "Flow"
   callback))

(defun expose-usage ()
  "Explain usage asynchronously."

  (interactive)

  (expose-run-usage))

(defun expose-usage-async (callback)
  "Explain usage and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'usage
   "Usage"
   callback))

(defun expose-docstring ()
  "Suggest a docstring/comment asynchronously."

  (interactive)

  (expose-run-docstring))

(defun expose-docstring-async (callback)
  "Suggest a docstring/comment and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'docstring
   "Docstring"
   callback))

(defun expose-summary ()
  "Summarize the current code asynchronously."

  (interactive)

  (expose-run-summary))

(defun expose-summary-async (callback)
  "Summarize the current code and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'summary
   "Summary"
   callback))

(defun expose-types ()
  "Explain types asynchronously."

  (interactive)

  (expose-run-types))

(defun expose-types-async (callback)
  "Explain types and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'types
   "Types"
   callback))

(defun expose-concurrency ()
  "Review concurrency and race-condition risks asynchronously."

  (interactive)

  (expose-run-concurrency))

(defun expose-concurrency-async (callback)
  "Review concurrency and race-condition risks and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'concurrency
   "Concurrency"
   callback))

(defun expose-invariants ()
  "Identify important invariants asynchronously."

  (interactive)

  (expose-run-invariants))

(defun expose-invariants-async (callback)
  "Identify important invariants and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'invariants
   "Invariants"
   callback))

(defun expose-risks ()
  "Identify practical risks asynchronously."

  (interactive)

  (expose-run-risks))

(defun expose-risks-async (callback)
  "Identify practical risks and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'risks
   "Risks"
   callback))

(defun expose-why ()
  "Explain why the current code may be written this way asynchronously."

  (interactive)

  (expose-run-why))

(defun expose-why-async (callback)
  "Explain why the current code may be written this way and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'why
   "Why"
   callback))

(defun expose-mental-model ()
  "Build a mental model for the current code asynchronously."

  (interactive)

  (expose-run-mental-model))

(defun expose-mental-model-async (callback)
  "Build a mental model for the current code and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'mental-model
   "Mental Model"
   callback))

(defun expose-commit-message ()
  "Write a commit message for the current changes asynchronously."

  (interactive)

  (expose-run-commit-message))

(defun expose-commit-message-async (callback)
  "Write a commit message and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'commit-message
   "Commit Message"
   callback))

(defun expose-changelog ()
  "Write a changelog entry for the current changes asynchronously."

  (interactive)

  (expose-run-changelog))

(defun expose-changelog-async (callback)
  "Write a changelog entry and call CALLBACK with a popup view."

  (expose-send-view-action-async
   'changelog
   "Changelog"
   callback))

(defun expose-pr-description-async (callback)
  "Write a PR description for the current branch and call CALLBACK with a
popup view.

Built from a plist of its own, not `expose-context-build' -- same
reason `expose-buffer-review-async' is: the generic context builder is
about point/selection within one file, and a PR description has
neither, only a branch and what it changed relative to its base."

  (let* ((project-root
          (expose-review-context-project-root))

         (base-branch
          (expose-review-context-detect-base-branch project-root))

         (context
          (list
           :project (expose-context-project)
           :language (expose-context-language)
           :branch (expose-review-context-current-branch project-root)
           :base-branch base-branch
           :commits (expose-pr-description-commits project-root base-branch)
           :diff (expose-pr-description-diff project-root base-branch))))

    (expose-send-view-action-async
     'pr-description
     "PR Description"
     callback
     context)))

;;; ---------------------------------------------------------------------------
;;; Actions
;;; ---------------------------------------------------------------------------

(defun expose-register-default-actions ()
  "Register Expose default popup actions."

  (expose-popup-register-action
   ?r
   "Review"
   'view
   #'expose-review-async
   :async t)

  (expose-popup-register-action
   ?b
   "Buffer Review"
   'view
   #'expose-buffer-review-async
   :async t)

  (expose-popup-register-action
   ?k
   "Merge Conflict"
   'view
   #'expose-merge-conflict-async
   :async t)

  (expose-popup-register-action
   ?d
   "Diagnostics"
   'view
   #'expose-diagnostics-async
   :async t)

  (expose-popup-register-action
   ?e
   "Explain"
   'view
   #'expose-explain-async
   :async t)

  (expose-popup-register-action
   ?f
   "Fix"
   'view
   #'expose-fix-async
   :async t)

  (expose-popup-register-action
   ?F
   "Refactor"
   'view
   #'expose-refactor-async
   :async t)

  (expose-popup-register-action
   ?s
   "Security"
   'view
   #'expose-security-async
   :async t)

  (expose-popup-register-action
   ?p
   "Performance"
   'view
   #'expose-performance-async
   :async t)

  (expose-popup-register-action
   ?t
   "Tests"
   'view
   #'expose-tests-async
   :async t)

  (expose-popup-register-action
   ?x
   "Edge Cases"
   'view
   #'expose-edge-cases-async
   :async t)

  (expose-popup-register-action
   ?w
   "Flow"
   'view
   #'expose-flow-async
   :async t)

  (expose-popup-register-action
   ?u
   "Usage"
   'view
   #'expose-usage-async
   :async t)

  (expose-popup-register-action
   ?D
   "Docstring"
   'view
   #'expose-docstring-async
   :async t)

  (expose-popup-register-action
   ?m
   "Summary"
   'view
   #'expose-summary-async
   :async t)

  (expose-popup-register-action
   ?T
   "Types"
   'view
   #'expose-types-async
   :async t)

  (expose-popup-register-action
   ?C
   "Concurrency"
   'view
   #'expose-concurrency-async
   :async t)

  (expose-popup-register-action
   ?i
   "Invariants"
   'view
   #'expose-invariants-async
   :async t)

  (expose-popup-register-action
   ?!
   "Risks"
   'view
   #'expose-risks-async
   :async t)

  (expose-popup-register-action
   ?Y
   "Why"
   'view
   #'expose-why-async
   :async t)

  (expose-popup-register-action
   ?M
   "Mental Model"
   'view
   #'expose-mental-model-async
   :async t)

  (expose-popup-register-action
   ?g
   "Commit Message"
   'view
   #'expose-commit-message-async
   :async t)

  (expose-popup-register-action
   ?n
   "Changelog"
   'view
   #'expose-changelog-async
   :async t)

  (expose-popup-register-action
   ?P
   "PR Description"
   'view
   #'expose-pr-description-async
   :async t))

;;; ---------------------------------------------------------------------------
;;; Where `SPC c h h' results are shown
;;; ---------------------------------------------------------------------------
;;
;; A result from this group -- explain, fix, refactor, and the rest --
;; routinely overflowed the small hover it used to show in. Redirected to
;; the persistent, colorized side window `expose-action-buffer' provides
;; instead, via the indirection `expose-popup-run-view-action' calls
;; through rather than `expose-popup-show-view' directly.
;; `expose-action-buffer-show' has the same (VIEW SOURCE-WINDOW) shape
;; `expose-popup-view-display-function' calls, so it can be set directly
;; here with no wrapper -- and it adds to popup history itself, so
;; `SPC c h H' keeps seeing these results even though they no longer
;; pass through the function history used to piggyback on. Watch, Region
;; Review, and Full Review's source hover are untouched by any of this:
;; none of them are registered actions, and none of them go through
;; `expose-popup-view-display-function' -- each calls
;; `expose-popup-show-view' itself, hover and history both exactly as
;; before.

(setq expose-popup-view-display-function #'expose-action-buffer-show)

;;; ---------------------------------------------------------------------------
;;; Refining an action buffer result
;;; ---------------------------------------------------------------------------
;;
;; Experimental. Every `SPC c h h' action funnels through
;; `expose-send-view-action-async', so every one of them -- Explain,
;; Tests, Fix, all the rest -- ends up refinable; the one thing that
;; is not is a result that errored (see `expose-action-buffer-refine'),
;; since there is nothing successful yet to build a follow-up on.

(defun expose-commands-refine-instructions-text (refinements)
  "Format REFINEMENTS as text for `expose-request-extra-instructions'.

Explicitly numbered and framed as an ordered sequence, not left as a
flat blob of concatenated asks: a follow-up like \"undo that\" is only
reliably resolved by the model when it can see exactly which numbered
item \"that\" refers to."

  (concat
   "The user has asked for these follow-up refinements to your previous "
   "answer, in the order given. A later one may reference or countermand "
   "an earlier one by position (e.g. \"undo that\" or \"nvm\" refers to "
   "the item immediately before it) -- apply your best judgment for what "
   "the combined, final intent is, then answer accordingly:\n\n"
   (string-join
    (cl-loop for instruction in refinements
             for n from 1
             collect (format "%d. %s" n instruction))
    "\n")))

(defun expose-commands-refine-action-buffer ()
  "Refine the action buffer's current result with a follow-up instruction.

Prompts for one line of free text, folds it into the growing list of
refinements applied so far, and rebuilds the *same* request -- same
type, same context captured when the action first ran -- with that
list appended as extra instruction text, asking the provider to read
back through it and act on the combined intent.

Nothing is ever removed from the list, including after \"undo that\" --
undo is just one more entry for the model to reconcile against what
came before, not a real rewind (seemed easier to actually get right
than tracking real undo state, and cheap to try first). A failed
refinement drops back to the state before it was asked, so the buffer
stays refinable for another attempt rather than dead-ending."

  (interactive)

  (unless expose-action-buffer-refine
    (user-error "This result cannot be refined"))

  (let* ((refine expose-action-buffer-refine)
         (type (plist-get refine :type))
         (context (plist-get refine :context))
         (title (plist-get refine :title))
         (previous-refinements (plist-get refine :refinements))

         (instruction
          (string-trim
           (read-string
            (format
             "Refine %s (e.g. \"also add a test for the empty-list case\", \"undo that\"): "
             title)))))

    (if (string-empty-p instruction)

        (message "Refine cancelled (empty input)")

      (let* ((refinements
              (append previous-refinements (list instruction)))

             (placement-window
              (expose-action-buffer-source-window)))

        (expose-log
         "Command"
         "Refining %s action with %d refinement(s): %s"
         type
         (length refinements)
         instruction)

        ;; Shown immediately, not just on completion: carries the new
        ;; instruction in its own `:refine' data too, so the
        ;; refinements list visibly grows right away rather than
        ;; flashing blank during the request.
        (expose-action-buffer-show
         (list
          :title title
          :body "Loading..."
          :format 'plain
          :history nil
          :refine (list :type type :context context :title title
                        :refinements refinements))
         placement-window)

        (let ((expose-request-extra-instructions
               (expose-commands-refine-instructions-text refinements)))

          (expose-commands-send-document-async
           (format "%s (refine)" (symbol-name type))
           expose-provider-default
           (expose-document-build type context)
           nil

           (lambda (response)

             (expose-log
              "Command"
              "Refinement of %s returned response (%d bytes)."
              type
              (length response))

             (expose-action-buffer-show
              (expose-action-view title response type context refinements)
              placement-window))

           (lambda (error-message)

             (expose-log
              "Command"
              "Refinement of %s failed: %s"
              type
              error-message)

             ;; Rolled back to PREVIOUS-REFINEMENTS, not REFINEMENTS --
             ;; the failed ask never actually got answered, so keeping
             ;; it in the list next time would misrepresent it as
             ;; already having been acted on.
             (expose-action-buffer-show
              (list
               :title title
               :body (format "Refinement failed: %s" error-message)
               :format 'plain
               :history nil
               :refine (list :type type :context context :title title
                             :refinements previous-refinements))
              placement-window))))))))

(with-eval-after-load 'evil
  (evil-define-key* 'normal expose-action-buffer-mode-map
    (kbd "r") #'expose-commands-refine-action-buffer)

  (evil-define-key* 'motion expose-action-buffer-mode-map
    (kbd "r") #'expose-commands-refine-action-buffer))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-review-self-test ()
  "Exercise the Expose review pipeline."

  (interactive)

  (expose-review)

  (message "Expose review pipeline started"))

(provide 'expose-commands)
