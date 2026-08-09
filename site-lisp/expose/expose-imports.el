;;; expose-imports.el -*- lexical-binding: t; -*-

;;; Module dependency graph: what this file imports, transitively.
;;;
;;; Computed, not generated. Imports are the one thing in a codebase that
;;; is trivially parseable, so asking a provider to describe them trades
;;; an exact answer for a plausible one -- and this graph is used to
;;; decide what depends on what, where being subtly wrong is worse than
;;; being absent. Same reasoning as the reverse call graph.
;;;
;;; What it buys over reading the imports yourself is transitivity and
;;; cycle detection: an import cycle is invisible in any single file and
;;; is a real failure mode in Python, so cycles are found and drawn in
;;; red rather than left for you to trace by eye.

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'expose-log)

(defgroup expose-imports nil
  "Module dependency graph for Expose."
  :group 'expose)

(defcustom expose-imports-max-depth 3
  "How many levels of imports to follow."
  :type 'integer
  :group 'expose-imports)

(defcustom expose-imports-max-nodes 60
  "Maximum modules to include before the walk stops."
  :type 'integer
  :group 'expose-imports)

(defcustom expose-imports-exclude-regexps
  '("/tests?/"
    "/migrations/"
    "_test\\.[a-z]+\\'"
    "\\.test\\.[a-z]+\\'"
    "\\.spec\\.[a-z]+\\'"
    "/__tests__/"
    "/node_modules/")
  "Paths left out of the dependency graph.

Django migrations especially: there are hundreds, they import models
wholesale, and they say nothing about how the code is actually
structured."
  :type '(repeat regexp)
  :group 'expose-imports)

(defcustom expose-imports-source-roots '("" "src" "lib" "app")
  "Directories under the project root to resolve absolute imports against.

Tried in order. The empty string means the project root itself, which is
what a `src.apps.events.models'-style import needs; `src' covers layouts
whose imports omit it."
  :type '(repeat string)
  :group 'expose-imports)

;;; ---------------------------------------------------------------------------
;;; Parsing
;;; ---------------------------------------------------------------------------

(defun expose-imports-python (file)
  "Return the modules FILE imports, as (MODULE . RELATIVE-LEVEL) pairs.

Only the module path is needed for a dependency graph, and that always
sits on the statement's first line -- so parenthesized multi-line imports
need no special handling.

RELATIVE-LEVEL is the number of leading dots: 0 absolute, 1 for `.x', 2
for `..x'."

  (let (results)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))

      ;; from [.]*MODULE import ...
      (while (re-search-forward
              "^[ \t]*from[ \t]+\\(\\.*\\)\\([A-Za-z_][A-Za-z0-9_.]*\\)?[ \t]+import\\b"
              nil t)
        (push (cons (or (match-string 2) "")
                    (length (match-string 1)))
              results))

      (goto-char (point-min))

      ;; import A.B, C.D
      (while (re-search-forward "^[ \t]*import[ \t]+\\([^\n#]+\\)" nil t)
        (dolist (spec (split-string (match-string 1) "[ \t]*,[ \t]*" t))
          (let ((module (car (split-string (string-trim spec) "[ \t]+as[ \t]+"))))
            (when (string-match-p "\\`[A-Za-z_][A-Za-z0-9_.]*\\'" module)
              (push (cons module 0) results))))))

    (nreverse results)))

(defun expose-imports-javascript (file)
  "Return the module specifiers FILE imports, as (SPECIFIER . 0) pairs."

  (let (results)
    (with-temp-buffer
      (insert-file-contents file)

      (dolist (pattern '("\\(?:import\\|export\\)[^;\n]*?from[ \t]*['\"]\\([^'\"]+\\)['\"]"
                         "\\bimport[ \t]*(['\"]\\([^'\"]+\\)['\"])"
                         "\\brequire[ \t]*(['\"]\\([^'\"]+\\)['\"])"))
        (goto-char (point-min))
        (while (re-search-forward pattern nil t)
          (push (cons (match-string 1) 0) results))))

    (nreverse (delete-dups results))))

(defun expose-imports-parse (file)
  "Return the imports of FILE, dispatching on its extension."

  (let ((extension (downcase (or (file-name-extension file) ""))))
    (cond
     ((member extension '("py" "pyi"))
      (expose-imports-python file))

     ((member extension '("ts" "tsx" "js" "jsx" "mjs" "cjs"))
      (expose-imports-javascript file))

     (t nil))))

;;; ---------------------------------------------------------------------------
;;; Resolution
;;; ---------------------------------------------------------------------------

(defun expose-imports-first-existing (candidates)
  "Return the first readable regular file among CANDIDATES."

  (seq-find (lambda (path)
              (and path (file-regular-p path) (file-readable-p path)))
            candidates))

(defun expose-imports-python-candidates (directory parts)
  "Return the files a Python module PARTS under DIRECTORY could be."

  (let ((base (expand-file-name (mapconcat #'identity parts "/") directory)))
    (list (concat base ".py")
          (expand-file-name "__init__.py" base))))

(defun expose-imports-resolve-python (module level file root)
  "Resolve a Python MODULE imported at relative LEVEL from FILE.

Returns an absolute path inside the project, or nil when the import
resolves outside it -- third-party or stdlib, which the caller renders as
an external leaf rather than following."

  (let ((parts (if (string-empty-p module)
                   nil
                 (split-string module "\\." t))))

    (if (> level 0)
        ;; Relative: level 1 is this file's own directory, each extra dot
        ;; climbs one more.
        (let ((directory (file-name-directory file)))
          (dotimes (_ (1- level))
            (setq directory (file-name-directory (directory-file-name directory))))
          (expose-imports-first-existing
           (expose-imports-python-candidates directory parts)))

      (when (and parts root)
        (expose-imports-first-existing
         (apply
          #'append
          (mapcar
           (lambda (source-root)
             (expose-imports-python-candidates
              (expand-file-name source-root root)
              parts))
           expose-imports-source-roots)))))))

(defun expose-imports-resolve-javascript (specifier file)
  "Resolve a JS/TS SPECIFIER imported from FILE.

Only relative specifiers are resolved; bare ones are packages, and
tsconfig path aliases are not read, so both fall through as external."

  (when (string-prefix-p "." specifier)
    (let ((base (expand-file-name specifier (file-name-directory file))))
      (expose-imports-first-existing
       (append
        (mapcar (lambda (extension) (concat base extension))
                '(".ts" ".tsx" ".js" ".jsx" ".mjs" ".cjs" ""))
        (mapcar (lambda (index) (expand-file-name index base))
                '("index.ts" "index.tsx" "index.js" "index.jsx")))))))

(defun expose-imports-resolve (import file root)
  "Resolve IMPORT -- a (MODULE . LEVEL) pair -- from FILE, or return nil."

  (let ((module (car import))
        (level (cdr import))
        (extension (downcase (or (file-name-extension file) ""))))

    (cond
     ((member extension '("py" "pyi"))
      (expose-imports-resolve-python module level file root))

     ((member extension '("ts" "tsx" "js" "jsx" "mjs" "cjs"))
      (expose-imports-resolve-javascript module file)))))

(defun expose-imports-excluded-p (path)
  "Return non-nil if PATH is excluded by `expose-imports-exclude-regexps'."

  (when path
    (let ((full (expand-file-name path)))
      (seq-some (lambda (regexp) (string-match-p regexp full))
                expose-imports-exclude-regexps))))

;;; ---------------------------------------------------------------------------
;;; Walk
;;; ---------------------------------------------------------------------------

(defun expose-imports-label (path root)
  "Return a display label for PATH relative to ROOT."

  (let ((relative (if (and root (string-prefix-p root (expand-file-name path)))
                      (file-relative-name path root)
                    (file-name-nondirectory path))))
    ;; A package is its directory, not "__init__.py" repeated everywhere.
    (if (equal (file-name-nondirectory relative) "__init__.py")
        (concat (directory-file-name (file-name-directory relative)) "/")
      relative)))

(defun expose-imports-collect (start root)
  "Walk imports outward from START, returning (NODES EDGES EXTERNALS).

NODES maps absolute path to label. EDGES is a list of (FROM . TO) paths.
EXTERNALS maps an importing path to the outside packages it names, kept
separately because they are leaves -- following them would walk into
site-packages, which is not what this is for."

  (let ((nodes (make-hash-table :test 'equal))
        (externals (make-hash-table :test 'equal))
        (edges nil)
        (visited (make-hash-table :test 'equal))
        (queue (list (cons start 0))))

    (puthash start (expose-imports-label start root) nodes)

    (while queue
      (let* ((entry (pop queue))
             (file (car entry))
             (depth (cdr entry)))

        (unless (or (gethash file visited)
                    (>= depth expose-imports-max-depth))

          (puthash file t visited)

          (dolist (import (ignore-errors (expose-imports-parse file)))
            (let ((target (expose-imports-resolve import file root)))

              (cond
               ;; Outside the project: record the package name as a leaf.
               ((null target)
                (let ((name (car (split-string (car import) "\\." t))))
                  (when (and name (not (string-empty-p name))
                             (not (string-prefix-p "." (car import))))
                    (cl-pushnew name (gethash file externals) :test #'equal))))

               ((expose-imports-excluded-p target) nil)

               ((equal target file) nil)

               ((>= (hash-table-count nodes) expose-imports-max-nodes) nil)

               (t
                (unless (gethash target nodes)
                  (puthash target (expose-imports-label target root) nodes)
                  (push (cons target (1+ depth)) queue))

                (cl-pushnew (cons file target) edges :test #'equal))))))))

    (list nodes (nreverse edges) externals)))

(defun expose-imports-cycle-edges (edges)
  "Return the subset of EDGES that take part in an import cycle.

An edge A->B is in a cycle when B can reach A. Cycles are the reason to
draw this graph at all -- they are invisible in any one file and are a
real failure mode in Python -- so they are found here rather than left to
be traced by eye."

  (let ((outgoing (make-hash-table :test 'equal)))

    (dolist (edge edges)
      (push (cdr edge) (gethash (car edge) outgoing)))

    (seq-filter
     (lambda (edge)
       (let ((target (car edge))
             (queue (list (cdr edge)))
             (seen (make-hash-table :test 'equal))
             (found nil))

         (while (and queue (not found))
           (let ((current (pop queue)))
             (cond
              ((equal current target) (setq found t))
              ((gethash current seen) nil)
              (t
               (puthash current t seen)
               (setq queue (append queue (gethash current outgoing)))))))

         found))
     edges)))

;;; ---------------------------------------------------------------------------
;;; DOT
;;; ---------------------------------------------------------------------------

(defun expose-imports-escape (text)
  "Escape TEXT for a quoted DOT label."
  (replace-regexp-in-string "\"" "\\\\\"" (or text "")))

(defun expose-imports-node-id (key)
  "Return a DOT-safe identifier for KEY."
  (concat "n" (substring (secure-hash 'sha1 key) 0 12)))

(defun expose-imports-to-dot (graph start root show-externals)
  "Render GRAPH from `expose-imports-collect' as Graphviz DOT."

  (let* ((nodes (nth 0 graph))
         (edges (nth 1 graph))
         (externals (nth 2 graph))
         (cycles (expose-imports-cycle-edges edges))
         (lines nil))

    (push "digraph imports {" lines)
    (push "  rankdir=LR;" lines)
    (push (format "  label=\"imports of %s%s\";"
                  (expose-imports-escape (expose-imports-label start root))
                  (if cycles "  (red edges form a cycle)" ""))
          lines)

    (maphash
     (lambda (path label)
       (push (format "  %s [shape=%s,label=\"%s\"];"
                     (expose-imports-node-id path)
                     (cond ((equal path start) "ellipse")
                           ((string-suffix-p "/" label) "folder")
                           (t "box"))
                     (expose-imports-escape label))
             lines))
     nodes)

    (when show-externals
      (let ((seen (make-hash-table :test 'equal)))
        (maphash
         (lambda (file names)
           (dolist (name names)
             (let ((id (expose-imports-node-id (concat "ext:" name))))
               (unless (gethash name seen)
                 (puthash name t seen)
                 (push (format "  %s [shape=component,label=\"%s\"];"
                               id (expose-imports-escape name))
                       lines))
               (push (format "  %s -> %s;"
                             (expose-imports-node-id file) id)
                     lines))))
         externals)))

    (dolist (edge edges)
      (push (format "  %s -> %s%s;"
                    (expose-imports-node-id (car edge))
                    (expose-imports-node-id (cdr edge))
                    (if (member edge cycles)
                        (format " [color=\"%s\",penwidth=1.8,label=\"cycle\",fontcolor=\"%s\"]"
                                "#c0544b" "#c0544b")
                      ""))
            lines))

    (push "}" lines)

    (mapconcat #'identity (nreverse lines) "\n")))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun expose-imports-build-dot (&optional show-externals)
  "Return (DOT . LABEL) for the dependency graph of the current buffer."

  (let* ((file (or (buffer-file-name)
                   (user-error "This buffer is not visiting a file")))

         (root (when-let ((project (project-current nil)))
                 (expand-file-name (project-root project)))))

    (unless (expose-imports-parse file)
      (user-error "No imports found in %s" (file-name-nondirectory file)))

    (expose-log
     "Imports"
     "Building dependency graph for %s (depth %d, max %d nodes)."
     file expose-imports-max-depth expose-imports-max-nodes)

    (let* ((graph (expose-imports-collect file root))
           (count (hash-table-count (nth 0 graph)))
           (cycles (expose-imports-cycle-edges (nth 1 graph))))

      (expose-log "Imports" "Found %d module(s), %d edge(s), %d cycle edge(s)."
                  count (length (nth 1 graph)) (length cycles))

      (cons (expose-imports-to-dot graph file root show-externals)
            (expose-imports-label file root)))))

(provide 'expose-imports)
