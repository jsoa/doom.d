;;; expose-trace.el -*- lexical-binding: t; -*-

;;; ---------------------------------------------------------------------------
;;; Text-based call trace
;;;
;;; Not a diagram, and no AI: you navigate the call path yourself (the
;;; same `+lookup/definition' hop you'd already use), marking each stop
;;; worth keeping. `expose-trace-show' renders the marked stops as
;;; permalink-free, project-relative snippets suitable for pasting
;;; straight into a code review comment -- a text alternative to
;;; `expose-run-call-flow-diagram' for exactly the case that command's
;;; own docstring warns about: something meant to read as a citation
;;; has no business being AI-invented. `expose-trace-show-markdown'
;;; renders the same marked stops instead as GitHub-flavored Markdown,
;;; each stop's code fenced with its language tag, for pasting into a
;;; PR/issue comment where GitHub does its own syntax highlighting.
;;; ---------------------------------------------------------------------------

(require 'subr-x)
(require 'expose-context)
(require 'expose-side-panel)

(defcustom expose-trace-context-lines 5
  "How many lines immediately before a marked stop to include as context."
  :type 'integer
  :group 'expose)

(defcustom expose-trace-context-lines-after 2
  "How many lines immediately after a marked stop to include as context."
  :type 'integer
  :group 'expose)

(defcustom expose-trace-arrow "----->"
  "Marker prefixed to a trace stop's own line in place of its indentation."
  :type 'string
  :group 'expose)

(defcustom expose-trace-fence-languages
  '((python-mode . "python")
    (python-ts-mode . "python")
    (js-mode . "javascript")
    (js2-mode . "javascript")
    (js-ts-mode . "javascript")
    (rjsx-mode . "javascript")
    (typescript-mode . "typescript")
    (typescript-ts-mode . "typescript")
    (tsx-ts-mode . "tsx")
    (web-mode . "html")
    (html-mode . "html")
    (mhtml-mode . "html")
    (css-mode . "css")
    (css-ts-mode . "css")
    (emacs-lisp-mode . "elisp")
    (lisp-interaction-mode . "elisp")
    (sh-mode . "bash")
    (ruby-mode . "ruby")
    (go-mode . "go")
    (go-ts-mode . "go")
    (java-mode . "java")
    (sql-mode . "sql")
    (yaml-mode . "yaml")
    (yaml-ts-mode . "yaml"))
  "Alist of MAJOR-MODE to the language tag GitHub expects on a fenced
code block (the part after the opening ```` ``` ````)."
  :type '(alist :key-type symbol :value-type string)
  :group 'expose)

(defvar expose-trace-buffer "*EXPOSE TRACE*")
(defvar expose-trace-markdown-buffer "*EXPOSE TRACE MARKDOWN*")

(defvar expose-trace-stops nil
  "Ordered list of plists describing marked call-trace stops, oldest
first -- see `expose-trace--gather-stop' for the shape.")

(defun expose-trace--relative-file ()
  "Return the current buffer's file path relative to the project root."

  (if-let* ((root (expose-context-project-root))
            (file buffer-file-name))
      (file-relative-name file root)
    (or buffer-file-name (buffer-name))))

(defun expose-trace--fence-language ()
  "Return a GitHub fenced-code-block language tag for the current buffer.

Looked up from `expose-trace-fence-languages' by `major-mode' first,
then by the derived mode it's based on, if any (so `python-ts-mode'
still matches a `python-mode' entry if the alist were ever missing the
more specific one). Falls back to `major-mode' itself with a trailing
`-ts-mode'/`-mode' stripped -- an imperfect guess for anything not
listed, but a plausible one, and GitHub simply shows a plain block
rather than erroring on a tag it doesn't recognize."

  (or (alist-get major-mode expose-trace-fence-languages)
      (seq-some
       (lambda (entry) (and (derived-mode-p (car entry)) (cdr entry)))
       expose-trace-fence-languages)
      (replace-regexp-in-string
       "-ts-mode\\'\\|-mode\\'" "" (symbol-name major-mode))))

(defun expose-trace--fontified-line (line-number)
  "Return LINE-NUMBER's own text, real font-lock/LSP faces and all.

Reads it straight out of the buffer being traced -- the same
`font-lock-ensure' + take-the-propertized-text-back-out trick
`expose-orm-render-sql' uses for SQL, except the text is already
sitting in a live buffer here, so there is no temp buffer or mode
lookup to do: whatever highlighting the buffer itself would show is
exactly what a stop's snippet should show too. `font-lock-ensure' is
still required explicitly -- jit-lock only fontifies what has actually
been displayed, and an unmarked stop far from where you've scrolled
would otherwise come back as plain text.

The properties this leaves in place are for `expose-trace-show''s
colorized, in-Emacs view; `expose-trace-show-markdown' strips them back
out with `substring-no-properties' -- GitHub does its own highlighting
from the fence's language tag, and Emacs faces mean nothing to it."

  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line-number))
    (font-lock-ensure (line-beginning-position) (line-end-position))
    (buffer-substring (line-beginning-position) (line-end-position))))

(defun expose-trace--scope-header-line (node)
  "Return NODE's own first source line, fontified, or nil when NODE is nil."

  (when node
    (expose-trace--fontified-line
     (line-number-at-pos (treesit-node-start node)))))

(defun expose-trace--line-indentation (line)
  "Return LINE's leading whitespace."

  (if (string-match "\\`[ \t]*" line)
      (match-string 0 line)
    ""))

(defun expose-trace--arrow-prefix (indentation)
  "Return `expose-trace-arrow' padded out to INDENTATION's own width, so
code after it still starts at the column plain indentation would put
it -- a deeply-nested stop shouldn't collapse to the same column as a
shallow one just because the arrow replaced its indentation outright.

When INDENTATION is narrower than the arrow itself, there is no room
to preserve that column inside it; the arrow's own width (plus one
trailing space) sets the column instead, pushing the code right a
little rather than truncating the arrow."

  (concat
   (propertize expose-trace-arrow 'face 'bold)
   (make-string
    (max 1 (- (length indentation) (length expose-trace-arrow)))
    ?\s)))

(defun expose-trace--trim-left (line)
  "Return LINE without its leading whitespace, preserving text properties
on what remains -- `string-trim-left' would too, but going through
`substring' directly keeps this independent of that implementation
detail."

  (substring line (length (expose-trace--line-indentation line))))

(defun expose-trace--gather-stop ()
  "Return a plist describing the call-trace stop at point.

:file and :line locate it (project-relative path, 1-indexed line
number). :language is a GitHub fence tag (see
`expose-trace--fence-language'). :code-lines is the full snippet as a
list of already-fontified lines, in display order: the enclosing
scope's own header line(s) (and its parent's, for a method inside a
class -- `class Foo:' above `def bar(self):'), an elided `...' line if
`expose-trace-context-lines' doesn't reach back to the header, up to
that many lines immediately before point, point's own line with its
indentation replaced by `expose-trace-arrow' (see
`expose-trace--arrow-prefix'), up to `expose-trace-context-lines-after'
lines immediately after, and a trailing `...' if that didn't reach the
end of the enclosing scope either.

Two renderers consume this: `expose-trace--render-colorized' keeps the
faces `expose-trace--fontified-line' left in place, and
`expose-trace--render-markdown' strips them back out."

  (let* ((file (expose-trace--relative-file))
         (current-line (line-number-at-pos))
         (language (expose-trace--fence-language))
         (scope (expose-context-scope-node))
         (parent-scope (expose-context-parent-scope-node))
         (parent-header (expose-trace--scope-header-line parent-scope))
         (scope-header (expose-trace--scope-header-line scope))
         (headers (delq nil (list parent-header scope-header)))
         (scope-body-start-line
          (if scope
              (1+ (line-number-at-pos (treesit-node-start scope)))
            1))
         (scope-body-end-line
          (if scope
              (line-number-at-pos (treesit-node-end scope))
            (line-number-at-pos (point-max))))
         (window-start-line
          (max scope-body-start-line
               (- current-line expose-trace-context-lines -1)))
         (window-end-line
          (min scope-body-end-line
               (+ current-line expose-trace-context-lines-after)))
         (gap-before (> window-start-line scope-body-start-line))
         (gap-after (< window-end-line scope-body-end-line))
         (context-before
          (mapcar #'expose-trace--fontified-line
                  (number-sequence window-start-line (1- current-line))))
         (marked-line (expose-trace--fontified-line current-line))
         (context-after
          (mapcar #'expose-trace--fontified-line
                  (number-sequence (1+ current-line) window-end-line)))
         (ellipsis-indent
          (if context-before
              (expose-trace--line-indentation (car context-before))
            (expose-trace--line-indentation marked-line))))

    (list
     :file file
     :line current-line
     :language language
     :code-lines
     (append
      headers
      (when gap-before (list (concat ellipsis-indent "...")))
      context-before
      (list (concat
             (expose-trace--arrow-prefix
              (expose-trace--line-indentation marked-line))
             (expose-trace--trim-left marked-line)))
      context-after
      (when gap-after (list (concat ellipsis-indent "...")))))))

(defun expose-trace--render-colorized (stop)
  "Render STOP (see `expose-trace--gather-stop') for in-Emacs viewing,
keeping the real faces its code lines carry."

  (mapconcat
   #'identity
   (append
    (list
     (concat
      (propertize (plist-get stop :file) 'face 'bold)
      (propertize (format " #L%d" (plist-get stop :line)) 'face 'shadow))
     "")
    (plist-get stop :code-lines))
   "\n"))

(defun expose-trace--render-markdown (stop)
  "Render STOP (see `expose-trace--gather-stop') as GitHub-flavored
Markdown: the file/line as a plain heading line, then its code lines
fenced with the language tag GitHub needs to highlight them -- stripped
of Emacs's own faces first, which mean nothing to GitHub and have no
business inside a fence it renders verbatim."

  (format "%s #L%d\n\n```%s\n%s\n```"
          (plist-get stop :file)
          (plist-get stop :line)
          (plist-get stop :language)
          (mapconcat #'substring-no-properties
                     (plist-get stop :code-lines)
                     "\n")))

;;;###autoload
(defun expose-trace-mark ()
  "Mark the line at point as the next stop in the call trace."

  (interactive)

  (setq expose-trace-stops
        (append expose-trace-stops (list (expose-trace--gather-stop))))

  (message "Expose trace: marked stop %d (%s:%d)"
           (length expose-trace-stops)
           (expose-trace--relative-file)
           (line-number-at-pos)))

;;;###autoload
(defun expose-trace-clear ()
  "Discard all marked call-trace stops."

  (interactive)

  (setq expose-trace-stops nil)
  (message "Expose trace: cleared"))

(defun expose-trace--show (buffer render-stop success-suffix)
  "Shared body for `expose-trace-show' and `expose-trace-show-markdown'.

Joins every marked stop through RENDER-STOP, displays the result in
BUFFER via the usual side panel, and copies it to the kill ring.
SUCCESS-SUFFIX is appended to the confirmation message, so each caller
can name what it produced."

  (unless expose-trace-stops
    (user-error "No trace stops marked yet -- `expose-trace-mark' one first"))

  (let* ((source-window (selected-window))
         (rendered
          (mapconcat render-stop expose-trace-stops "\n\n")))

    (kill-new rendered)

    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert rendered)
        (goto-char (point-min))))

    (select-window (expose-side-panel-place source-window buffer))
    (message "Expose trace: %d stop(s) %s"
             (length expose-trace-stops)
             success-suffix)))

;;;###autoload
(defun expose-trace-show ()
  "Render the marked call trace, display it, and copy it to the kill ring."

  (interactive)

  (expose-trace--show
   (get-buffer-create expose-trace-buffer)
   #'expose-trace--render-colorized
   "shown and copied to the kill ring"))

;;;###autoload
(defun expose-trace-show-markdown ()
  "Render the marked call trace as GitHub-flavored Markdown, display it,
and copy it to the kill ring -- ready to paste into a PR or issue
comment, each stop's code fenced with its own language tag."

  (interactive)

  (expose-trace--show
   (get-buffer-create expose-trace-markdown-buffer)
   #'expose-trace--render-markdown
   "shown as Markdown and copied to the kill ring"))

(provide 'expose-trace)
