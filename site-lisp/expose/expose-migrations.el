;;; expose-migrations.el -*- lexical-binding: t; -*-

;;; How a Django model got its current shape, read from its migrations.
;;;
;;; Computed, not generated. Migrations are mechanically regular Python,
;;; and a project accumulates dozens of them -- 48 in the one this was
;;; written against -- so reading them is exactly the kind of tedious,
;;; exact work a parser does better than a provider. It's also the kind
;;; of question where a plausible answer is worthless: "when did this
;;; field become nullable" is only useful if it's right.
;;;
;;; What it buys over reading the files yourself is the ordering. Any one
;;; migration shows a single edit; the history of a field -- added here,
;;; retyped there, dropped and reintroduced later -- is spread across
;;; files that are named for whatever else they happened to contain.

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'expose-log)

(defgroup expose-migrations nil
  "Django migration history for Expose."
  :group 'expose)

(defcustom expose-migrations-max-operations 60
  "Maximum operations to include in a model's history."
  :type 'integer
  :group 'expose-migrations)

(defcustom expose-migrations-max-definition-width 44
  "Maximum characters of a field's arguments to show in a table cell.

Django definitions run long -- a `choices=' list can be hundreds of
characters -- and a single one of those stretches its table wide enough
to squash every other node in the diagram."
  :type 'integer
  :group 'expose-migrations)

(defconst expose-migrations-operation-colors
  '(("CreateModel"  "#e8f0fe" "#4a7fd4" "#1b3c66")
    ("AddField"     "#e9f6ec" "#4f9d69" "#1d4a2d")
    ("AlterField"   "#fff5e2" "#cf9a3c" "#5c4310")
    ("RenameField"  "#f4eefb" "#8b6fc4" "#3d2a63")
    ("RenameModel"  "#f4eefb" "#8b6fc4" "#3d2a63")
    ("AlterModelOptions" "#f4f6f8" "#c2cad4" "#1f2933")
    ("AlterUniqueTogether" "#f4f6f8" "#c2cad4" "#1f2933")
    ("AddIndex"     "#e6f4f6" "#4a99a4" "#11434a")
    ("RemoveIndex"  "#e6f4f6" "#4a99a4" "#11434a")
    ("RemoveField"  "#fdeceb" "#c0544b" "#75211b")
    ("DeleteModel"  "#fdeceb" "#c0544b" "#75211b"))
  "Fill, border and text color per migration operation.

Grouped by what the operation does to existing data rather than by name:
additive green, altering amber, renaming violet, destructive red. The
destructive ones are what you are usually looking for.")

;;; ---------------------------------------------------------------------------
;;; Parsing
;;; ---------------------------------------------------------------------------

(defun expose-migrations-arguments (text open)
  "Return the argument text of the call whose opening paren is at OPEN in TEXT.

Scans for the matching close paren while tracking nesting and string
literals, so a definition carrying its own brackets -- Django's
`choices=[(\"a\", \"A\")]' being the usual one -- is not cut short at the
first `)'. Returns nil if the call is never closed within TEXT."

  (let ((depth 0) (index open) (limit (length text)) (in-string nil) (closed nil))
    (while (and (< index limit) (not closed))
      (let ((char (aref text index)))
        (cond
         (in-string
          (cond ((eq char ?\\) (setq index (1+ index)))
                ((eq char in-string) (setq in-string nil))))
         ((memq char (list ?\" ?\')) (setq in-string char))
         ((memq char (list ?\( ?\[)) (setq depth (1+ depth)))
         ((memq char (list ?\) ?\]))
          (setq depth (1- depth))
          (when (<= depth 0) (setq closed t)))))
      (setq index (1+ index)))

    (when closed
      (substring text (1+ open) (1- index)))))

(defun expose-migrations-signature (type text open)
  "Return TYPE with its argument list from TEXT at OPEN, whitespace collapsed.

Without the arguments an `AlterField' is invisible: most Django
alterations change a keyword -- `null=True', a wider `max_length' --
and never the field class, so both sides would read `CharField' and the
row would be tinted amber with nothing to show for it.

Kept whole rather than shortened here. Shortening is a display concern
\(see `expose-migrations-truncate'), and `expose-migrations-delta' needs
the untruncated text to tell which argument actually changed."

  (let* ((raw (expose-migrations-arguments text open))
         (flat (and raw (string-trim (replace-regexp-in-string "[ \t\n]+" " " raw)))))
    (if (or (null flat) (string-empty-p flat))
        type
      (format "%s(%s)" type flat))))

(defun expose-migrations-truncate (text)
  "Shorten TEXT to `expose-migrations-max-definition-width' arguments."

  (let ((body (or text "")))
    (if (<= (length body) expose-migrations-max-definition-width)
        body
      (concat (substring body 0 expose-migrations-max-definition-width) "..."))))

(defcustom expose-migrations-max-expanded-fields 4
  "Most changed fields in one migration that may be shown in full.

Spelling out a definition earns its space by singling a field out from
the ones around it. A migration that changes nearly everything -- above
all `CreateModel', where every field counts as added -- has nothing to
single out, and expanding all of them turns the table into a wall taller
than the rest of the diagram."
  :type 'integer
  :group 'expose-migrations)

(defcustom expose-migrations-max-detail-lines 6
  "Most continuation rows a single changed field may occupy.

A `choices=' list can run to hundreds of characters, and letting one
field claim thirty rows would push every other field in the table out of
view. Past this the definition is cut, since by then it has said what it
had to say."
  :type 'integer
  :group 'expose-migrations)

(defun expose-migrations-detail-lines (definition)
  "Return DEFINITION as its type, then one line per keyword argument.

One property per row rather than the definition reflowed across rows:
the properties are what changed, and a line break falling wherever the
width ran out puts half of `related_name' on one row and half on the
next. Each value is still truncated -- a `choices=' list is not made
readable by giving it six rows, and what you need from it is that it was
`choices' that moved.

Capped by `expose-migrations-max-detail-lines'."

  (let* ((parsed (expose-migrations-parse-definition (or definition "")))
         (type (car parsed))
         (arguments (cdr parsed))
         (lines
          (if (null arguments)
              (list (expose-migrations-truncate type))
            (cons type
                  (mapcar
                   (lambda (argument)
                     (expose-migrations-truncate
                      (if (car argument)
                          (format "%s=%s" (car argument) (cdr argument))
                        (cdr argument))))
                   arguments)))))

    (if (> (length lines) expose-migrations-max-detail-lines)
        (append (seq-take lines (1- expose-migrations-max-detail-lines))
                (list (format "... %d more"
                              (- (length lines)
                                 (1- expose-migrations-max-detail-lines)))))
      lines)))

(defun expose-migrations-split-arguments (text)
  "Split TEXT on its top-level commas.

Nested calls, lists and string literals are stepped over, so a
`choices=[(1, \"a\"), (2, \"b\")]' stays one argument instead of four."

  (let ((parts nil) (start 0) (depth 0) (in-string nil)
        (index 0) (limit (length text)))

    (while (< index limit)
      (let ((char (aref text index)))
        (cond
         (in-string
          (cond ((eq char ?\\) (setq index (1+ index)))
                ((eq char in-string) (setq in-string nil))))
         ((memq char (list ?\" ?\')) (setq in-string char))
         ((memq char (list ?\( ?\[ ?{)) (setq depth (1+ depth)))
         ((memq char (list ?\) ?\] ?})) (setq depth (1- depth)))
         ((and (eq char ?,) (zerop depth))
          (push (string-trim (substring text start index)) parts)
          (setq start (1+ index)))))
      (setq index (1+ index)))

    (push (string-trim (substring text start)) parts)
    (seq-remove #'string-empty-p (nreverse parts))))

(defun expose-migrations-parse-argument (argument)
  "Return ARGUMENT as (KEYWORD . VALUE), with KEYWORD nil if positional."

  (if (string-match "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*=[ \t]*" argument)
      (cons (match-string 1 argument) (substring argument (match-end 0)))
    (cons nil argument)))

(defun expose-migrations-parse-definition (definition)
  "Return DEFINITION as (TYPE . ARGUMENTS), ARGUMENTS being parsed pairs."

  (if (string-match "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)(" definition)
      (let* ((type (match-string 1 definition))
             (open (1- (match-end 0)))
             (arguments (expose-migrations-arguments definition open)))
        (cons type
              (mapcar #'expose-migrations-parse-argument
                      (expose-migrations-split-arguments (or arguments "")))))
    (cons definition nil)))

(defun expose-migrations-delta (old new)
  "Return what changed between field definitions OLD and NEW, or nil.

Only the arguments that actually differ are described. A Django field
carries most of its definition unchanged through an alteration -- the
`help_text' paragraph that was already there stays -- and showing the
whole thing pushed the one argument that moved past the width limit,
which is precisely the argument you opened the diagram to find. Dropped
keywords are shown as `-name', since their absence is otherwise
invisible."

  (let* ((before (expose-migrations-parse-definition (or old "")))
         (after (expose-migrations-parse-definition (or new "")))
         (old-arguments (cdr before))
         (new-arguments (cdr after))
         (differences nil))

    (dolist (argument new-arguments)
      (let ((keyword (car argument))
            (value (cdr argument)))
        (cond
         ;; Positional arguments have no name to compare by, so they
         ;; count as changed only if the exact text is gone.
         ((null keyword)
          (unless (member argument old-arguments)
            (push value differences)))
         ((not (equal value (cdr (assoc keyword old-arguments))))
          (push (format "%s=%s" keyword value) differences)))))

    (dolist (argument old-arguments)
      (when (and (car argument) (not (assoc (car argument) new-arguments)))
        (push (format "-%s" (car argument)) differences)))

    ;; Shortest first, rather than in source order. Several arguments can
    ;; change at once and one of them is typically a paragraph of
    ;; `help_text', which under the width limit would push a terse
    ;; `related_name=' or `null=True' off the end -- the terse ones being
    ;; the changes that alter behaviour rather than wording.
    (setq differences (sort (nreverse differences)
                            (lambda (a b) (< (length a) (length b)))))

    ;; Identical definitions produce nothing; the caller falls back to
    ;; showing the field as it stands.
    (unless (and (equal (car before) (car after)) (null differences))
      (format "%s(%s)" (car after) (string-join differences ", ")))))

(defun expose-migrations-files (root)
  "Return every migration file under ROOT, sorted by app then number.

Django numbers migrations per app, so within one app the zero-padded
names are chronological and this ordering is exact. Across apps they are
not comparable: `orders/0003' and `events/0032' carry no relative order
in their names, and only the dependency graph knows the truth. Grouping
by app is therefore the honest presentation -- a model touched by two
apps reads as two ordered runs, not one false timeline."

  (sort
   (seq-remove
    (lambda (file) (string-suffix-p "__init__.py" file))
    (ignore-errors
      (seq-filter
       (lambda (file) (string-match-p "/migrations/" file))
       (directory-files-recursively root "\\.py\\'"))))
   #'string<))

(defun expose-migrations-app (file)
  "Return the Django app name a migration FILE belongs to."

  (let* ((migrations-dir (directory-file-name (file-name-directory file)))
         (app-dir (directory-file-name (file-name-directory migrations-dir))))
    (file-name-nondirectory app-dir)))

(defun expose-migrations-operations-in (file model)
  "Return the operations in FILE that act on MODEL.

MODEL is matched case-insensitively: `CreateModel' names it as written
\(`EventRegistration') while every other operation lower-cases it
\(`model_name=\"eventregistration\"'), and treating those as different
models would split a history in half at its first edit."

  (let ((results nil)
        (target (downcase model)))

    (with-temp-buffer
      (insert-file-contents file)

      (goto-char (point-min))
      (while (re-search-forward "migrations\\.\\([A-Za-z]+\\)(" nil t)

        (let* ((operation (match-string 1))
               (start (point))
               (end (save-excursion
                      (if (re-search-forward "^\\s-*migrations\\.[A-Za-z]+(" nil t)
                          (match-beginning 0)
                        (point-max))))
               (body (buffer-substring-no-properties start end)))

          ;; Anchored to the start of a line, which is how migrations are
          ;; written -- one keyword argument per line. Matching `name='
          ;; anywhere instead picks up the tail of `model_name=', because
          ;; `_' is not a word constituent here, so every field was
          ;; labelled with its model's name.
          (let* ((model-name
                  (when (string-match "^[ \t]*model_name[ \t]*=[ \t]*[\"']\\([^\"']+\\)[\"']" body)
                    (match-string 1 body)))

                 (name
                  (when (string-match "^[ \t]*name[ \t]*=[ \t]*[\"']\\([^\"']+\\)[\"']" body)
                    (match-string 1 body)))

                 (field-type
                  (when (string-match "field[ \t]*=[ \t]*\\(?:[A-Za-z_][A-Za-z0-9_.]*\\.\\)?\\([A-Za-z]+\\)(" body)
                    (match-string 1 body)))

                 ;; The type plus its arguments, which is what a reader
                 ;; needs to see an alteration at all -- see
                 ;; `expose-migrations-signature'.
                 (field-definition
                  (when (string-match "field[ \t]*=[ \t]*\\(?:[A-Za-z_][A-Za-z0-9_.]*\\.\\)?\\([A-Za-z]+\\)(" body)
                    (expose-migrations-signature
                     (match-string 1 body) body (1- (match-end 0)))))

                 ;; CreateModel carries the model's whole starting shape
                 ;; in a `fields=[("name", models.Type(...)), ...]' list.
                 ;; Without it the history would begin from nothing and
                 ;; every original field would look like a later addition.
                 (initial-fields
                  (when (equal operation "CreateModel")
                    (let ((fields nil)
                          (offset 0))
                      (while (string-match
                              (concat "([ \t\n]*[\"']\\([A-Za-z_][A-Za-z0-9_]*\\)[\"'][ \t\n]*,[ \t\n]*"
                                      "\\(?:[A-Za-z_][A-Za-z0-9_.]*\\.\\)?\\([A-Za-z]+\\)(")
                              body offset)
                        ;; Every piece of this match is read out before
                        ;; `expose-migrations-signature' runs, because it
                        ;; calls `replace-regexp-in-string' internally and
                        ;; that clobbers the match data -- reading
                        ;; `match-end' afterwards left OFFSET unchanged and
                        ;; hung the loop.
                        (let ((field-name (match-string 1 body))
                              (type (match-string 2 body))
                              (open (1- (match-end 0)))
                              (next (match-end 1)))
                          (push (cons field-name
                                      (expose-migrations-signature type body open))
                                fields)
                          (setq offset next)))
                      (nreverse fields))))

                 (new-name
                  (when (string-match "^[ \t]*new_name[ \t]*=[ \t]*[\"']\\([^\"']+\\)[\"']" body)
                    (match-string 1 body)))

                 (old-name
                  (when (string-match "^[ \t]*old_name[ \t]*=[ \t]*[\"']\\([^\"']+\\)[\"']" body)
                    (match-string 1 body)))

                 ;; CreateModel/DeleteModel/RenameModel name the model in
                 ;; `name'; everything else names it in `model_name' and
                 ;; uses `name' for the field.
                 (model-operation
                  (member operation '("CreateModel" "DeleteModel" "RenameModel")))

                 (subject (if model-operation name model-name))
                 (field (unless model-operation name)))

            (when (and subject (equal (downcase subject) target))
              (push (list :operation operation
                          :field field
                          :type field-type
                          :definition field-definition
                          :initial-fields initial-fields
                          :old-name old-name
                          :new-name new-name
                          :file file)
                    results))))))

    (nreverse results)))

(defun expose-migrations-history (model root)
  "Return MODEL's migration history under ROOT, oldest first."

  (let ((history nil))
    (dolist (file (expose-migrations-files root))
      (dolist (operation (expose-migrations-operations-in file model))
        (push (append operation
                      (list :app (expose-migrations-app file)
                            :migration (file-name-base file)))
              history)))

    (let ((ordered (nreverse history)))
      (if (> (length ordered) expose-migrations-max-operations)
          (last ordered expose-migrations-max-operations)
        ordered))))

;;; ---------------------------------------------------------------------------
;;; DOT
;;; ---------------------------------------------------------------------------

(defun expose-migrations-escape (text)
  "Escape TEXT for a quoted DOT label."
  (replace-regexp-in-string "\"" "\\\\\"" (or text "")))

(defun expose-migrations-escape-html (text)
  "Escape TEXT for use inside a Graphviz HTML-like label."

  (let ((escaped (or text "")))
    (setq escaped (replace-regexp-in-string "&" "&amp;" escaped t t))
    (setq escaped (replace-regexp-in-string "<" "&lt;" escaped t t))
    (setq escaped (replace-regexp-in-string ">" "&gt;" escaped t t))
    escaped))

(defun expose-migrations-replay (history)
  "Replay HISTORY into one snapshot of the model per migration.

Each snapshot is a plist: `:migration', `:app', `:fields' (an ordered
list of (NAME . TYPE) as the model stood *after* that migration), and
`:added', `:altered', `:removed' naming what that migration changed.

Rebuilding the state is the point of doing this at all. A list of
operations tells you what each migration did; only the accumulated state
answers what the model actually looked like at a given moment, which is
the question you have when reading an old migration or a stack trace
from a past deploy."

  (let ((fields nil)
        (snapshots nil)
        (current-key nil)
        (added nil) (altered nil) (removed nil) (changes nil))

    (cl-flet
        ((flush ()
           (when current-key
             (push (list :migration (car current-key)
                         :app (cdr current-key)
                         ;; Each cons is copied, not just the spine.
                         ;; `AlterField' below edits fields in place with
                         ;; `setcdr', and a shallow copy shares those
                         ;; cells -- so a later type change rewrote every
                         ;; earlier snapshot, showing each field's final
                         ;; type throughout and hiding the very evolution
                         ;; this diagram exists to show.
                         :fields (mapcar (lambda (field)
                                           (cons (car field) (cdr field)))
                                         fields)
                         :added (nreverse added)
                         :altered (nreverse altered)
                         :removed (nreverse removed)
                         :changes (nreverse changes))
                   snapshots))))

      (dolist (entry history)
        (let ((key (cons (plist-get entry :migration) (plist-get entry :app))))

          ;; A migration can hold several operations on the same model;
          ;; they collapse into one snapshot rather than one per edit.
          (unless (equal key current-key)
            (flush)
            (setq current-key key added nil altered nil removed nil changes nil))

          (pcase (plist-get entry :operation)
            ("CreateModel"
             ;; Deep copy for the same reason as the snapshot above: the
             ;; in-place edits below must not reach back into the parsed
             ;; entry, which callers may replay more than once.
             (setq fields (mapcar (lambda (field) (cons (car field) (cdr field)))
                                  (plist-get entry :initial-fields)))
             (dolist (field fields) (push (car field) added)))

            ("AddField"
             (when-let ((name (plist-get entry :field)))
               (setq fields (append fields (list (cons name (or (plist-get entry :definition) (plist-get entry :type))))))
               (push name added)))

            ("AlterField"
             (when-let ((name (plist-get entry :field)))
               (let ((new (or (plist-get entry :definition) (plist-get entry :type))))
                 (if-let ((existing (assoc name fields)))
                     (progn
                       ;; Recorded here because this is the only place
                       ;; both sides of the change exist at once.
                       (when-let ((delta (expose-migrations-delta (cdr existing) new)))
                         (push (cons name delta) changes))
                       (setcdr existing new))
                   ;; Altering something never seen added: the model
                   ;; predates the migrations that are checked in.
                   (setq fields (append fields (list (cons name new))))))
               (push name altered)))

            ("RemoveField"
             (when-let ((name (plist-get entry :field)))
               (setq fields (assoc-delete-all name fields))
               (push name removed)))

            ("RenameField"
             (let ((old (plist-get entry :old-name))
                   (new (plist-get entry :new-name)))
               (when (and old new)
                 (if-let ((existing (assoc old fields)))
                     (setcar existing new)
                   (setq fields (append fields (list (cons new nil)))))
                 (push (format "%s -> %s" old new) altered))))

            (_ nil))))

      (flush))

    (nreverse snapshots)))

(defun expose-migrations-row (name type highlight &optional expand)
  "Return the HTML table row or rows for field NAME of TYPE.

HIGHLIGHT is `added', `altered', `removed' or nil, and picks the row's
background. Colouring the row rather than the whole table is the reason
these use HTML-like labels at all: a Graphviz record can't tint an
individual cell, so the change would be invisible in exactly the place
you're looking.

A highlighted row is allowed to run onto continuation rows rather than
being cut off at the width, because on those rows the definition is the
thing you came to read. The continuations leave the name column empty,
so the field still reads as one entry. Unhighlighted rows are carried
forward unchanged from the migration before and are context rather than
news, so they still truncate -- letting every one of them wrap would
make each table taller than the diagram.

EXPAND is decided per migration by `expose-migrations-snapshot-node',
which withholds it when almost every field changed."

  (let* ((background
          (pcase highlight
            ('added "#e9f6ec")
            ('altered "#fff5e2")
            ('removed "#fdeceb")
            (_ nil)))
         (cell (if background (format " BGCOLOR=\"%s\"" background) ""))
         (lines
          (if (and highlight expand)
              ;; Always split, even when the whole definition would have
              ;; fitted. Splitting only the long ones made a one-property
              ;; change read differently from a four-property change, so
              ;; the same edit looked like two different kinds of thing
              ;; depending on how much text it happened to carry.
              (expose-migrations-detail-lines type)
            ;; Context, not news: carried forward from the migration before.
            (list (expose-migrations-truncate type)))))

    (mapconcat
     (lambda (line)
       (prog1
           (format
            "        <TR><TD ALIGN=\"LEFT\"%s>%s</TD><TD ALIGN=\"LEFT\"%s><FONT POINT-SIZE=\"9\">%s</FONT></TD></TR>"
            cell
            (expose-migrations-escape-html (or name ""))
            cell
            (expose-migrations-escape-html line))
         ;; Only the first row is labelled; the rest continue it.
         (setq name "")))
     lines
     "\n")))

(defun expose-migrations-snapshot-node (id model snapshot)
  "Return the DOT node for one SNAPSHOT of MODEL, as an HTML table."

  (let* ((added (plist-get snapshot :added))
         (altered (plist-get snapshot :altered))
         (removed (plist-get snapshot :removed))
         (changes (plist-get snapshot :changes))

         ;; Withheld when the migration changed nearly everything: there
         ;; is then nothing to single out, and `CreateModel' -- where
         ;; every field counts as added -- would expand the whole model.
         (expand (<= (+ (length added) (length altered))
                     expose-migrations-max-expanded-fields))

         (rows
          (mapconcat
           (lambda (field)
             (expose-migrations-row
              (car field)
              ;; An altered field shows only what the migration changed.
              ;; Its full definition is mostly the text it already had,
              ;; which crowds out the one argument that moved.
              (or (cdr (assoc (car field) changes)) (cdr field))
              (cond ((member (car field) added) 'added)
                    ((member (car field) altered) 'altered)
                    ;; A rename is recorded as "old -> new", so the
                    ;; renamed field is matched by its new name too.
                    ((cl-find-if (lambda (a) (string-suffix-p (concat "> " (car field)) a))
                                 altered)
                     'altered)
                    (t nil))
              expand))
           (plist-get snapshot :fields)
           "\n"))

         ;; Dropped fields are shown for the step that dropped them and
         ;; then disappear -- otherwise the removal is the one change the
         ;; diagram silently omits.
         (removed-rows
          (mapconcat
           (lambda (name) (expose-migrations-row name "removed" 'removed))
           removed
           "\n")))

    (format
     "  %s [shape=plaintext,label=<
      <TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\" CELLPADDING=\"4\">
        <TR><TD COLSPAN=\"2\" BGCOLOR=\"#e8f0fe\"><B>%s</B><BR/><FONT POINT-SIZE=\"9\">%s</FONT></TD></TR>
%s%s%s
      </TABLE>>];"
     id
     (expose-migrations-escape-html model)
     (expose-migrations-escape-html (plist-get snapshot :migration))
     rows
     (if (and (not (string-empty-p rows)) (not (string-empty-p removed-rows))) "\n" "")
     removed-rows)))

(defun expose-migrations-to-dot (model history)
  "Render MODEL's HISTORY as a left-to-right series of field tables.

One table per migration, each showing the model as it stood after that
migration, with the fields that migration touched picked out: added
green, altered amber, dropped red. A dropped field appears once, in the
step that dropped it, then disappears -- the same way it did in reality."

  (let* ((snapshots (expose-migrations-replay history))
         (lines nil)
         (index 0)
         (previous nil))

    (push "digraph migrations {" lines)
    (push "  rankdir=LR;" lines)
    (push (format "  label=\"%s: %d migration%s\";"
                  (expose-migrations-escape model)
                  (length snapshots)
                  (if (= (length snapshots) 1) "" "s"))
          lines)

    (dolist (snapshot snapshots)
      (let ((id (format "m%d" index)))

        (push (expose-migrations-snapshot-node id model snapshot) lines)

        (when previous
          (push (format "  %s -> %s;" previous id) lines))

        (setq previous id)
        (setq index (1+ index))))

    (push "}" lines)

    (mapconcat #'identity (nreverse lines) "\n")))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun expose-migrations-build-dot ()
  "Return (DOT . MODEL) for the migration history of the model at point."

  (let* ((model (or (thing-at-point 'symbol t)
                    (user-error "No symbol at point")))

         (root (when-let ((project (project-current nil)))
                 (expand-file-name (project-root project)))))

    (unless root
      (user-error "Not inside a project"))

    (expose-log "Migrations" "Reading migration history for %s under %s." model root)

    (let ((history (expose-migrations-history model root)))

      (unless history
        (user-error
         "No migration operations found for %s (is it a model, and are its migrations checked in?)"
         model))

      (expose-log "Migrations" "Found %d operation(s) for %s." (length history) model)

      (cons (expose-migrations-to-dot model history) model))))

(provide 'expose-migrations)
