;;; expose-commands.el -*- lexical-binding: t; -*-

(require 'project)
(require 'subr-x)
(require 'newcomment)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-hover)
(require 'expose-transport)
(require 'expose-provider)

(defcustom expose-provider-default
  'codex
  "Default provider used by Expose."
  :type '(choice
          (const clipboard)
          (const codex)
          (const copilot))
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

;;; ---------------------------------------------------------------------------
;;; Code Comment
;;; ---------------------------------------------------------------------------

(defcustom expose-code-comment-context-lines 12
  "Number of lines of context to send for generated code comments."
  :type 'integer
  :group 'expose)

(defun expose-code-comment-project-root ()
  "Return current project root or `default-directory'."

  (or
   (when-let ((project
               (project-current nil)))

     (file-name-as-directory
      (project-root project)))

   default-directory))


(defun expose-code-comment-relative-file ()
  "Return current buffer file relative to project root."

  (if buffer-file-name

      (file-relative-name
       buffer-file-name
       (expose-code-comment-project-root))

    (buffer-name)))


(defun expose-code-comment-line-blank-p ()
  "Return non-nil when current line is blank."

  (string-empty-p
   (string-trim
    (buffer-substring-no-properties
     (line-beginning-position)
     (line-end-position)))))


(defun expose-code-comment-target-position ()
  "Return position of code to comment.

If point is on a blank line, use the next nonblank line. Otherwise use
the current line."

  (save-excursion
    (beginning-of-line)

    (when (expose-code-comment-line-blank-p)

      (while (and
              (not
               (eobp))
              (expose-code-comment-line-blank-p))

        (forward-line 1)))

    (point)))


(defun expose-code-comment-context (target-position)
  "Return source context around TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (let* ((target-line
            (line-number-at-pos target-position))

           (start-line
            (max
             1
             (- target-line
                expose-code-comment-context-lines)))

           (end-line
            (min
             (line-number-at-pos
              (point-max))
             (+ target-line
                expose-code-comment-context-lines)))

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


(defun expose-code-comment-target-line-text (target-position)
  "Return source line text at TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (string-trim
     (buffer-substring-no-properties
      (line-beginning-position)
      (line-end-position)))))


(defun expose-code-comment-target-line-number (target-position)
  "Return line number for TARGET-POSITION."

  (line-number-at-pos target-position))


(defun expose-code-comment-request (target-position)
  "Build AI request for a code comment at TARGET-POSITION."

  (let* ((file
          (expose-code-comment-relative-file))

         (line-number
          (expose-code-comment-target-line-number target-position))

         (target-line
          (expose-code-comment-target-line-text target-position))

         (context
          (expose-code-comment-context target-position)))

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

(defun expose-docstring-project-root ()
  "Return current project root or `default-directory'."

  (or
   (when-let ((project
               (project-current nil)))

     (file-name-as-directory
      (project-root project)))

   default-directory))


(defun expose-docstring-relative-file ()
  "Return current buffer file relative to project root."

  (if buffer-file-name

      (file-relative-name
       buffer-file-name
       (expose-docstring-project-root))

    (buffer-name)))

(defun expose-docstring-context (target-position)
  "Return source context around TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (let* ((target-line
            (line-number-at-pos target-position))

           (start-line
            (max
             1
             (- target-line
                expose-docstring-context-lines)))

           (end-line
            (min
             (line-number-at-pos
              (point-max))
             (+ target-line
                expose-docstring-context-lines)))

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


(defun expose-docstring-target-line-text (target-position)
  "Return source line text at TARGET-POSITION."

  (save-excursion
    (goto-char target-position)

    (string-trim
     (buffer-substring-no-properties
      (line-beginning-position)
      (line-end-position)))))


(defun expose-docstring-target-line-number (target-position)
  "Return line number for TARGET-POSITION."

  (line-number-at-pos target-position))

(defun expose-docstring-line-blank-p ()
  "Return non-nil when current line is blank."

  (string-empty-p
   (string-trim
    (buffer-substring-no-properties
     (line-beginning-position)
     (line-end-position)))))


(defun expose-docstring-target-position ()
  "Return position whose surrounding code should be documented.

If point is on a blank line, use the next nonblank line as the target.
Otherwise use the current line."

  (save-excursion
    (beginning-of-line)

    (when (expose-docstring-line-blank-p)

      (while (and
              (not
               (eobp))
              (expose-docstring-line-blank-p))

        (forward-line 1)))

    (back-to-indentation)
    (point)))


(defun expose-docstring-insert-position (target-position)
  "Return position where the generated docstring should be inserted.

If point is on a blank line, insert at point's line. If point is on code,
insert under TARGET-POSITION."

  (if (expose-docstring-line-blank-p)

      (line-beginning-position)

    (save-excursion
      (goto-char target-position)
      (forward-line 1)
      (line-beginning-position))))

(defun expose-docstring-request (target-position)
  "Build AI request for a docstring at TARGET-POSITION."

  (let* ((file
          (expose-docstring-relative-file))

         (line-number
          (expose-docstring-target-line-number target-position))

         (target-line
          (expose-docstring-target-line-text target-position))

         (context
          (expose-docstring-context target-position)))

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


(defun expose-docstring-current-line-blank-p ()
  "Return non-nil when the current line is blank."

  (string-empty-p
   (string-trim
    (buffer-substring-no-properties
     (line-beginning-position)
     (line-end-position)))))


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

    (if (expose-docstring-current-line-blank-p)

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

                 start
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

              (setq start
                    (point))

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
          (expose-code-comment-project-root))

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
          (expose-code-comment-request target-position)))

    (message "Expose code comment: generating...")

    (expose-log
     "Commands"
     "Generating code comment for %s using %s."
     (expose-code-comment-relative-file)
     provider)

    (expose-transport-send-document-async
     provider
     document

     (lambda (response-text)

       (expose-code-comment-insert-at-marker
        source-buffer
        insert-marker
        target-position
        response-text))

     project-root

     (lambda (error-data)
       (set-marker insert-marker nil)
       (set-marker target-position nil)

       (message
        "Expose code comment failed: %s"
        (error-message-string error-data))))))

;;;###autoload
(defun expose-run-docstring ()
  "Generate and insert a useful docstring at point."

  (interactive)

  (unless buffer-file-name
    (user-error "Expose docstring requires a file buffer"))

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-docstring-project-root))

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
          (expose-docstring-request target-position)))

    (message "Expose docstring: generating...")

    (expose-log
     "Commands"
     "Generating docstring for %s using %s."
     (expose-docstring-relative-file)
     provider)

    (expose-transport-send-document-async
     provider
     document

     (lambda (response-text)

       (expose-docstring-insert-at-marker
        source-buffer
        insert-marker
        target-position
        response-text))

     project-root

     (lambda (error-data)
       (set-marker insert-marker nil)
       (set-marker target-position nil)

       (message
        "Expose docstring failed: %s"
        (error-message-string error-data))))))

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
  "Generate a commit message and insert it at point."

  (interactive)

  (let* ((source-buffer
          (current-buffer))

         ;; Insert at the point where the command was invoked, like
         ;; `expose-continue-at-point'.
         (anchor
          (copy-marker
           (point)))

         (project-root
          (expose-commands-project-root-or-default)))

    (expose-log
     "Commands"
     "Generating commit message for insertion from %s."
     project-root)

    (message "Expose commit message: generating...")

    (condition-case error-data

        (let ((default-directory
               project-root))

          (expose-send-view-action-async
           'commit-message
           "Commit Message"

           (lambda (view)
             (expose-commands-insert-text-at-marker
              source-buffer
              anchor
              (expose-commands-view-body-text view)
              "commit message"))))

      (error
       (set-marker anchor nil)

       (message
        "Expose commit message failed: %s"
        (error-message-string error-data))))))

(defun expose-run-changelog ()
  "Run the registered Expose changelog action."

  (interactive)

  (expose-popup-run-action ?n))

;;; ---------------------------------------------------------------------------
;;; Views
;;; ---------------------------------------------------------------------------

(defun expose-action-view (title response)
  "Create an Expose popup view with TITLE and RESPONSE."

  (expose-popup-view-create
   title
   response))

(defun expose-send-view-action-async (type title callback)
  "Send TYPE asynchronously and call CALLBACK with a titled popup view."

  (expose-log
   "Command"
   "Starting async action %s using provider %s."
   type
   expose-provider-default)

  (expose-transport-send-async
   type
   expose-provider-default
   (lambda (response)

     (expose-log
      "Command"
      "Async action %s returned response (%d bytes)."
      type
      (length response))

     (funcall
      callback
      (expose-action-view title response))

     (expose-log
      "Command"
      "Async action %s completed."
      type))))

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
   :async t))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-review-self-test ()
  "Exercise the Expose review pipeline."

  (interactive)

  (expose-review)

  (message "Expose review pipeline started"))

(provide 'expose-commands)
