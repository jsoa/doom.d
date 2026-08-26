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
;;;
;;; This file also resolves the OTHER direction a model's own file
;;; doesn't show in full: its base classes. A mixin (`TimestampedModel',
;;; `SoftDeleteModel') is named right there in the `class Event(...):'
;;; header, but routinely defined in a different, shared file -- the
;;; whole point of a mixin -- so its own fields are invisible here too
;;; without the same real-project resolution.

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

(defcustom expose-relations-max-base-classes 4
  "Maximum base classes of the focused model to resolve for an ER diagram."
  :type 'integer
  :group 'expose-relations)

(defcustom expose-relations-ignored-base-names '("Model" "object")
  "Base-class names never worth resolving for an ER diagram.

Django's own `Model' and Python's own `object' are the bases of every
model there is; even when a class named one of these genuinely exists
somewhere in the project (an unrelated `object' subclass with a
generic name, say), it carries nothing worth drawing. Skipped before
searching, rather than filtered out after, so a name this common never
costs a whole-project grep for a result that would be thrown away."
  :type '(repeat string)
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

;;; ---------------------------------------------------------------------------
;;; Base classes
;;; ---------------------------------------------------------------------------

(defun expose-relations-class-declaration (model-name)
  "Return the parenthesized base-class list from MODEL-NAME's own
`class MODEL-NAME(...):' header in the current buffer, or nil.

Operates on the current buffer rather than searching the project --
called at the point the diagram command was invoked from, the same
place `expose-context-scope-name' resolves MODEL-NAME itself, so the
declaration is right there to read rather than needing to be found.
`[^)]' rather than `.' spans a base list wrapped onto several lines,
same as a multi-line `ForeignKey(' call elsewhere in this file."

  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (concat "^class[ \t]+" (regexp-quote model-name)
                   "[ \t]*(\\([^)]*\\))[ \t]*:")
           nil t)
      (match-string 1))))

(defun expose-relations-parse-base-names (bases-text)
  "Return the base-class names declared in BASES-TEXT, the parenthesized
argument list of a `class NAME(...):' header.

A keyword argument (`metaclass=ABCMeta') names a class-construction
option, not a base class, and is dropped. A dotted name
(`models.Model') is reduced to its final component -- the name the
class is actually declared under; the module qualifier in front of it
says nothing about where to look."

  (let (names)
    (dolist (part (split-string bases-text "," t "[ \t\n]+"))
      (unless (string-match-p "=" part)
        (push (car (last (split-string part "\\."))) names)))
    (nreverse names)))

(defun expose-relations-grep-class-definition (class-name project-root)
  "Return (FILE . LINE) for CLASS-NAME's own `class CLASS-NAME(' or
`class CLASS-NAME:' definition somewhere under PROJECT-ROOT.

Nil when there is no such definition, or more than one -- a name
shared by two classes is ambiguous, and skipping it is better than
guessing which definition is the real base."

  (when project-root
    (with-temp-buffer
      (let ((status
             (ignore-errors
               (call-process
                "grep" nil t nil
                "-rnE" "--include=*.py" "--"
                (format "^class[ \t]+%s[ \t]*[(:]" (regexp-quote class-name))
                project-root))))

        (when (memq status '(0 1))
          (goto-char (point-min))
          (let (matches)
            (while (re-search-forward "^\\(.+?\\):\\([0-9]+\\):" nil t)
              (push (cons (match-string 1) (string-to-number (match-string 2))) matches))
            (when (= (length matches) 1)
              (car matches))))))))

(defun expose-relations-find-base-classes (model-name)
  "Return plists for the real, project-defined base classes of MODEL-NAME.

MODEL-NAME's own base-class list is read from its `class ...:' header
in the CURRENT buffer; each name found there -- other than one listed
in `expose-relations-ignored-base-names' -- is searched for under
`expose-relations-project-root' and, when its definition is found
exactly once, its full body is read off disk. A name that resolves to
no definition (Django's own `Model' reached under a different alias,
some other framework or third-party class) or to more than one simply
drops out; nothing here is invented.

Each result is `(:name :file :line :code)'. A base defined in the same
file as MODEL-NAME is included like any other -- its body is already
part of the ordinary `:code' context, but repeating one small class a
second time costs nothing next to the alternative of leaving the
diagram's provider to guess whether it was actually resolved.

Capped to `expose-relations-max-base-classes'."

  (when-let* ((bases-text (expose-relations-class-declaration model-name))
              (names (expose-relations-parse-base-names bases-text))
              (project-root (expose-relations-project-root)))

    (let (result)
      (catch 'done
        (dolist (name names)
          (when (>= (length result) expose-relations-max-base-classes)
            (throw 'done nil))

          (unless (member name expose-relations-ignored-base-names)
            (when-let* ((found (expose-relations-grep-class-definition name project-root))
                        (file (car found))
                        (line (cdr found))
                        (code (expose-relations-class-body file line)))
              (push (list :name name :file file :line line :code code) result)))))

      (nreverse result))))

(provide 'expose-relations)

;;; expose-relations.el ends here
