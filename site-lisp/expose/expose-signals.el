;;; expose-signals.el -*- lexical-binding: t; -*-

;;; Finding the `@receiver(...)'-decorated functions connected to a
;;; Django model, across the whole project.
;;;
;;; This is the one piece of information nothing else in Expose, or
;;; the model's own source, can show: a receiver is wired to its
;;; signal by decorator, not by anything the model declares, and
;;; routinely lives in a different app's `signals.py' entirely.
;;; `expose-run-signal-flow-diagram' asked from inside the model's own
;;; class body has nothing local to show a provider at all -- and a
;;; provider shown nothing correctly reports nothing connected, which
;;; is not the same as nothing being connected.
;;;
;;; Computed by grepping, not generated: like `expose-callers.el''s
;;; test-mention search, this searches real project text and hands the
;;; provider the actual receiver bodies actually found, rather than
;;; asking a model to imagine signal wiring it cannot see from one
;;; class body alone.

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'expose-context)

(defgroup expose-signals nil
  "Django signal receiver discovery for Expose."
  :group 'expose)

(defcustom expose-signals-lookback-lines 12
  "Lines to look back from a `sender=' match for its owning `@receiver('.

A decorator's arguments routinely wrap onto their own lines
\(`@receiver(\\n    post_save,\\n    sender=Event,\\n)'), so the
`sender=' keyword and the `@receiver(' that owns it are not usually on
the same line -- this bounds how far back to look for it."
  :type 'integer
  :group 'expose-signals)

(defcustom expose-signals-max-receivers 8
  "Maximum receivers to include in a signal-flow diagram's context.

A model watched by many receivers (an audit log, a search index, a
cache invalidator, and half a dozen app-specific ones) could otherwise
mean sending a large multiple of the model's own code for one
diagram; trimmed to the first this many found, in file order."
  :type 'integer
  :group 'expose-signals)

(defcustom expose-signals-max-receiver-length 4000
  "Maximum characters of one receiver's body to include."
  :type 'integer
  :group 'expose-signals)

;;; ---------------------------------------------------------------------------
;;; Search
;;; ---------------------------------------------------------------------------

(defun expose-signals-project-root ()
  "Return the current project root, or nil."

  (when-let ((project (project-current nil)))
    (expand-file-name (project-root project))))

(defun expose-signals-grep-sender-matches (model-name project-root)
  "Return (FILE . LINE) pairs where MODEL-NAME appears as a `sender='
argument somewhere under PROJECT-ROOT.

Textual, not a real parse: a sender expressed any other way -- a
variable holding the model class, a lazy string reference like
`sender=\"app.Event\"' -- is not found this way, and neither is a
receiver with no `sender=' at all (one that watches every model, an
audit log say). Both are real, stated limits, not silent ones."

  (when project-root
    (with-temp-buffer
      (let ((status
             (ignore-errors
               (call-process
                "grep" nil t nil
                "-rnE" "--include=*.py" "--"
                (format "sender[ \t]*=[ \t]*%s\\b" (regexp-quote model-name))
                project-root))))

        ;; grep exits 1 for "no matches", which is not an error here --
        ;; same convention `expose-callers-test-mentions' uses.
        (when (memq status '(0 1))
          (goto-char (point-min))
          (let (matches)
            (while (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t)
              (push (cons (match-string 1) (string-to-number (match-string 2))) matches))
            (nreverse matches)))))))

(defun expose-signals-decorator-line-at (file line)
  "Return the line number of the `@receiver(' owning the `sender='
match at FILE:LINE, or nil.

Searched backward within `expose-signals-lookback-lines' of LINE in
FILE, rather than assuming the decorator sits on the immediately
preceding line -- see `expose-signals-lookback-lines'."

  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (forward-line (1- line))

    ;; `end-of-line', not left at the line's beginning: the common case
    ;; is a single-line `@receiver(post_save, sender=Event)', where the
    ;; decorator and the `sender=' match are on the very same line --
    ;; `re-search-backward' only finds a match that ends at or before
    ;; point, and a match starting exactly at point extends forward past
    ;; it, so searching from the line's start would miss that match
    ;; entirely.
    (end-of-line)

    (let ((limit
           (save-excursion
             (forward-line (- expose-signals-lookback-lines))
             (point))))

      (when (re-search-backward "^[ \t]*@receiver(" limit t)
        (line-number-at-pos)))))

(defun expose-signals-receiver-body (file decorator-line)
  "Return the full source of the receiver at DECORATOR-LINE in FILE --
its decorator(s) through the end of its body -- or nil.

Bounded the same way `expose-callers-drf-default-basename' bounds a
class body without a full parser: skip this receiver's own decorator
line(s) and `def' line, then take everything up to the next line that
starts at column 0 -- the next top-level `def', `class', decorator, or
plain module-level statement, whichever comes first, all of which
correctly mark the end of an indented function body in well-formatted
Python."

  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (forward-line (1- decorator-line))

      (let ((start (line-beginning-position)))

        (while (looking-at "^[ \t]*@")
          (forward-line 1))

        (when (looking-at "^[ \t]*\\(async[ \t]+\\)?def\\b")
          (forward-line 1))

        (let ((bound
               (if (re-search-forward "^\\S-" nil t)
                   (line-beginning-position)
                 (point-max))))

          (expose-context-truncate
           (string-trim-right (buffer-substring-no-properties start bound))
           expose-signals-max-receiver-length))))))

(defun expose-signals-find-receivers (model-name)
  "Return receiver plists for MODEL-NAME, found across the project.

Each is `(:file :line :code)' -- FILE/LINE naming the `@receiver(' and
CODE its full body, real source read off disk rather than reconstructed.
Deduplicated by (file . decorator-line), since more than one `sender='
match can belong to the same decorator call, and capped to
`expose-signals-max-receivers'."

  (when-let* ((project-root (expose-signals-project-root))
              (matches (expose-signals-grep-sender-matches model-name project-root)))

    (let (seen receivers)

      (catch 'done
        (dolist (match matches)
          (when (>= (length receivers) expose-signals-max-receivers)
            (throw 'done nil))

          (let* ((file (car match))
                 (sender-line (cdr match))
                 (decorator-line (expose-signals-decorator-line-at file sender-line))
                 (key (and decorator-line (cons file decorator-line))))

            (when (and decorator-line (not (member key seen)))
              (push key seen)

              (when-let ((code (expose-signals-receiver-body file decorator-line)))
                (push (list :file file :line decorator-line :code code) receivers))))))

      (nreverse receivers))))

(provide 'expose-signals)

;;; expose-signals.el ends here
