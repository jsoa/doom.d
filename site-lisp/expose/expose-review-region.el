;;; expose-review-region.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'project)
(require 'markdown-mode nil t)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-provider)
(require 'expose-hover)

(defgroup expose-review-region nil
  "Review region for selected regions."
  :group 'expose-review)

(defcustom expose-review-region-context-lines 20
  "Number of surrounding context lines included with region review."
  :type 'integer
  :group 'expose-review-region)

(defvar expose-provider-default)

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

  (save-excursion
    (let* ((context-start-line
            (max
             1
             (-
              (expose-review-region-line-number-at start)
              expose-review-region-context-lines)))

           (context-end-line
            (+
             (expose-review-region-line-number-at end)
             expose-review-region-context-lines))

           context-start
           context-end)

      (goto-char (point-min))
      (forward-line
       (1- context-start-line))
      (setq context-start
            (point))

      (goto-char (point-min))
      (forward-line
       (1- context-end-line))
      (setq context-end
            (line-end-position))

      (buffer-substring-no-properties
       context-start
       context-end))))

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
  "Build mini review request for region START to END."

  (let* ((file
          (expose-review-region-buffer-file))

         (line-start
          (expose-review-region-line-number-at start))

         (line-end
          (expose-review-region-line-number-at
           (expose-review-region-inclusive-end start end)))

         (code
          (expose-review-region-text start end))

         (context
          (expose-review-region-context start end))

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
    edge cases, typing, performance, and testability.

    Use the symbol/type context only as supporting context.
    Return concise Markdown only.
    Do not return JSON.
    Do not rewrite the whole file.
    Focus on actionable findings.
    If the selected code looks fine, say so briefly.
    Prefer this shape:

    ## Review

    - **Severity:** high|medium|low|info
      **Issue:** ...
      **Why it matters:** ...
      **Suggested change:** ...

    Keep the answer compact enough for a hover popup.
  </instruction>

  <location file=\"%s\" line_start=\"%s\" line_end=\"%s\" major_mode=\"%s\" />

  <selected-code>
%s
  </selected-code>

  <surrounding-context>
%s
  </surrounding-context>

  <symbol-context>
%s
  </symbol-context>

  <diagnostics>
%s
  </diagnostics>
</expose-region-review-request>"
     (expose-review-region-escape file)
     line-start
     line-end
     major-mode
     (expose-review-region-escape code)
     (expose-review-region-escape context)
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

(defun expose-review-region-show-result (response)
  "Show region review RESPONSE in popup."

  (expose-popup-show-view
   (list
    :title "Review Region"
    :body
    (expose-review-region-render-markdown response)
    :history t)))

(defun expose-review-region-show-error (message)
  "Show region review error MESSAGE in popup."

  (expose-popup-show-view
   (list
    :title "Review Region"
    :body message
    :history nil)))

;;;###autoload
(defun expose-review-region (start end)
  "Run a region review for selected region START to END."

  (interactive "r")

  (unless (use-region-p)
    (user-error "Select a region first"))

  (let* ((provider
          (expose-review-region-provider))

         (document
          (expose-review-region-request start end)))

    (expose-popup-show-view
     (list
      :title "Review Region"
      :body "Reviewing selected region..."
      :history nil))

    (expose-log
     "ReviewRegion"
     "Sending region review for %s using %s. Request size: %d bytes."
     (expose-review-region-buffer-file)
     provider
     (length document))

    (condition-case error
        (expose-provider-send-async
         provider
         document
         (lambda (response)
           (expose-review-region-show-result response)))

      (error
       (expose-review-region-show-error
        (error-message-string error))))))

(provide 'expose-review-region)
