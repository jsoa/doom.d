;;; expose-relations.el -*- lexical-binding: t; -*-

;;; Finding the models elsewhere in the project that declare a
;;; relationship field pointing AT the model at point -- the reverse
;;; direction `expose-run-er-diagram' cannot see on its own.
;;;
;;; A model's own file only ever shows what it points OUTWARD to: its
;;; own `ForeignKey'/`OneToOneField'/`ManyToManyField' declarations are
;;; right there in its class body. What points INWARD -- another app's
;;; model with a `ForeignKey(ThisModel, ...)' of its own -- is
;;; invisible from here, and routinely lives in a completely different
;;; file. The same gap `expose-signals.el' closes for signal receivers,
;;; closed the same way: grep the real project, confirm each match is
;;; genuinely a relationship field declaration and not a coincidental
;;; mention, and hand the provider the real declaring model's full
;;; body rather than asking it to draw a connection it was never shown.

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'expose-context)

(defgroup expose-relations nil
  "Django reverse-relationship discovery for Expose."
  :group 'expose)

(defcustom expose-relations-lookback-lines 6
  "Lines to look back from a matched model name for its owning
`ForeignKey('/`OneToOneField('/`ManyToManyField(' call.

A relationship field's target is normally the call's first argument,
on the same line as the call or the line just after it wraps onto --
this bounds how far back to look for the call that owns it."
  :type 'integer
  :group 'expose-relations)

(defcustom expose-relations-max-models 8
  "Maximum reverse-referencing models to include in an ER diagram's context.

A heavily-referenced model (a base `User', a lookup table) could
otherwise mean sending a large multiple of the model's own code for
one diagram; trimmed to the first this many found, in file order."
  :type 'integer
  :group 'expose-relations)

(defcustom expose-relations-max-model-length 4000
  "Maximum characters of one reverse-referencing model's body to include."
  :type 'integer
  :group 'expose-relations)

;;; ---------------------------------------------------------------------------
;;; Search
;;; ---------------------------------------------------------------------------

(defun expose-relations-project-root ()
  "Return the current project root, or nil."

  (when-let ((project (project-current nil)))
    (expand-file-name (project-root project))))

(defun expose-relations-grep-matches (model-name project-root)
  "Return (FILE . LINE) pairs where MODEL-NAME appears in a shape a
relationship field's target could take, somewhere under PROJECT-ROOT.

Matches the bare-class form (`ForeignKey(Event, ...)'), the quoted
same-app form (`ForeignKey(\"Event\", ...)') Django itself supports
specifically to avoid circular imports, and the quoted fully-qualified
form (`ForeignKey(\"events.Event\", ...)'). Deliberately a superset --
`expose-relations-field-line-at' confirms each candidate is genuinely
inside one of the three relationship field calls before it is
trusted, the same two-step shape `expose-signals-grep-sender-matches'/
`expose-signals-decorator-line-at' already use."

  (when project-root
    (with-temp-buffer
      (let ((status
             (ignore-errors
               (call-process
                "grep" nil t nil
                "-rnE" "--include=*.py" "--"
                (format "[\"'(.]%s[\"'),]" (regexp-quote model-name))
                project-root))))

        (when (memq status '(0 1))
          (goto-char (point-min))
          (let (matches)
            (while (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t)
              (push (cons (match-string 1) (string-to-number (match-string 2))) matches))
            (nreverse matches)))))))

(defun expose-relations-field-line-at (file line)
  "Return non-nil if the model-name match at FILE:LINE is genuinely the
target of a `ForeignKey('/`OneToOneField('/`ManyToManyField(' call.

Searched backward within `expose-relations-lookback-lines' of LINE in
FILE, the same reason `expose-signals-decorator-line-at' does: the
field call and its target are not always on the same line."

  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (forward-line (1- line))
    (end-of-line)

    (let ((limit
           (save-excursion
             (forward-line (- expose-relations-lookback-lines))
             (point))))

      (re-search-backward
       "\\(?:ForeignKey\\|OneToOneField\\|ManyToManyField\\)("
       limit t))))

(defun expose-relations-enclosing-class (bound-position)
  "Return (NAME . LINE) for the nearest enclosing `class ...:' at or
before BOUND-POSITION in the current buffer, or nil."

  (save-excursion
    (goto-char bound-position)
    (when (re-search-backward "^class[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" nil t)
      (cons (match-string 1) (line-number-at-pos)))))

(defun expose-relations-class-body (file line)
  "Return the full source of the class at LINE in FILE -- the `class'
line through the end of its body -- or nil.

Bounded the same way `expose-signals-receiver-body' bounds a function
without a full parser: everything from the `class' line up to the
next line that starts at column 0."

  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (forward-line (1- line))

      (let ((start (line-beginning-position)))
        (forward-line 1)

        (let ((bound
               (if (re-search-forward "^\\S-" nil t)
                   (line-beginning-position)
                 (point-max))))

          (expose-context-truncate
           (string-trim-right (buffer-substring-no-properties start bound))
           expose-relations-max-model-length))))))

(defun expose-relations-find-referencing-models (model-name &optional exclude-file)
  "Return plists for models elsewhere in the project that declare a
relationship field pointing at MODEL-NAME.

Each is `(:file :line :code)' -- FILE/LINE naming the referencing
model's own `class' line, CODE its full body, real source read off
disk rather than reconstructed. EXCLUDE-FILE, when given, skips matches
in that one file -- the file MODEL-NAME itself was viewed from, whose
own content is already part of the ordinary `:code' context and would
otherwise be sent a second time for no reason.

Excludes a self-referential field (a `parent' field on MODEL-NAME
itself, `ForeignKey(\"Event\", ...)' written inside `Event' rather than
`ForeignKey(\"self\", ...)') -- that names MODEL-NAME's own class as
its \"referencing model\", which would draw the model being
diagrammed as if it were also something pointing at itself from
outside.

Deduplicated by (file . class-line), since a model can point at the
same target through more than one field without needing to be drawn
twice. Capped to `expose-relations-max-models'."

  (when-let* ((project-root (expose-relations-project-root))
              (matches (expose-relations-grep-matches model-name project-root)))

    (let (seen models)
      (catch 'done
        (dolist (match matches)
          (when (>= (length models) expose-relations-max-models)
            (throw 'done nil))

          (let ((file (car match))
                (match-line (cdr match)))

            (unless (and exclude-file (file-equal-p file exclude-file))
              (when (expose-relations-field-line-at file match-line)
                (let* ((enclosing
                        (with-temp-buffer
                          (insert-file-contents file)
                          (goto-char (point-min))
                          (forward-line (1- match-line))
                          (expose-relations-enclosing-class (point))))

                       (class-name (car enclosing))
                       (class-line (cdr enclosing))
                       (key (and class-line (cons file class-line))))

                  (when (and class-line
                             (not (equal class-name model-name))
                             (not (member key seen)))
                    (push key seen)

                    (when-let ((code (expose-relations-class-body file class-line)))
                      (push (list :file file :line class-line :code code) models)))))))))

      (nreverse models))))

(provide 'expose-relations)

;;; expose-relations.el ends here
