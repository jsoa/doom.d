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

(defun expose-migrations-to-dot (model history)
  "Render MODEL's HISTORY as Graphviz DOT."

  (let ((lines nil)
        (index 0)
        (previous nil))

    (push "digraph migrations {" lines)
    (push "  rankdir=TB;" lines)
    (push (format "  label=\"%s: %d migration operation%s\";"
                  (expose-migrations-escape model)
                  (length history)
                  (if (= (length history) 1) "" "s"))
          lines)

    (dolist (entry history)
      (let* ((id (format "m%d" index))
             (operation (plist-get entry :operation))
             (colors (or (cdr (assoc operation expose-migrations-operation-colors))
                         (list "#f4f6f8" "#c2cad4" "#1f2933")))

             (detail
              (cond
               ((and (plist-get entry :field) (plist-get entry :type))
                (format "%s: %s" (plist-get entry :field) (plist-get entry :type)))
               ((plist-get entry :field) (plist-get entry :field))
               (t "")))

             (label
              (format "%s%s\\n%s"
                      (expose-migrations-escape operation)
                      (if (string-empty-p detail)
                          ""
                        (concat "  " (expose-migrations-escape detail)))
                      (expose-migrations-escape (plist-get entry :migration)))))

        (push (format "  %s [shape=%s,label=\"%s\",style=\"filled,rounded\",fillcolor=\"%s\",color=\"%s\",fontcolor=\"%s\"];"
                      id
                      (if (equal operation "CreateModel") "ellipse" "box")
                      label
                      (nth 0 colors) (nth 1 colors) (nth 2 colors))
              lines)

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
