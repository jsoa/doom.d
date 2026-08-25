;;; expose-usages.el -*- lexical-binding: t; -*-

;;; The direct callers/references of the symbol at point, as a flat
;;; list rather than a picture -- two different questions asked of the
;;; same one-level walk `expose-callers-collect' already does for the
;;; reverse call graph:
;;;
;;; - Dead code check: is anything here at all? Nothing found is the
;;;   useful answer, not a failure -- but "nothing found" and "the
;;;   search did not finish" are opposite answers, and the second must
;;;   never be reported as the first (see `expose-callers-signal-nothing').
;;;
;;; - Rename impact: before renaming, which call sites would silently
;;;   break? Ones inside this symbol's own top-level directory are
;;;   exactly what an editor-wide rename already catches; the ones
;;;   worth a human's attention are the callers *outside* it, and those
;;;   are marked OUTSIDE rather than left to blend in with the rest.
;;;
;;; No AI in either, for the same reason the reverse call graph has
;;; none: this needs the whole project, which no provider can see.
;;;
;;; Presented the same way `expose-find-tests' presents its results --
;;; a persistent side-panel buffer placed beside the source, `RET' to
;;; visit a call site to the left without losing the list -- rather
;;; than through a picture, since a flat list of call sites is what
;;; both these questions actually want as an answer.

(require 'subr-x)
(require 'project)
(require 'expose-log)
(require 'expose-side-panel)

;; Loaded on demand inside `expose-usages-collect', not required at the
;; top of this file -- see `expose-find-tests.el', which the comment
;; there explains: it pulls in `xref' and only matters once one of
;; these commands actually runs.
(declare-function expose-callers-lsp-available-p "expose-callers" ())
(declare-function expose-callers-lsp-prepare "expose-callers" ())
(declare-function expose-callers-lsp-references "expose-callers" ())
(declare-function expose-callers-xref-nodes "expose-callers" (identifier kind))
(declare-function expose-callers-collect "expose-callers" (root use-lsp &optional root-references))
(declare-function expose-callers-node-key "expose-callers" (node))
(declare-function expose-callers-signal-nothing "expose-callers" (format-string &rest args))
(declare-function expose-callers-line-text "expose-callers" (file line))
(defvar expose-callers-lsp-failures)
(defvar expose-callers-include-references)
(defvar expose-callers-max-depth)

(defconst expose-usages-buffer-name "*EXPOSE Usages*"
  "Name of the Expose dead-code-check/rename-impact results buffer.")

(defface expose-usages-title-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the Expose usages buffer's title and file headings.")

(defface expose-usages-meta-face
  '((t :inherit shadow))
  "Face for secondary text in the Expose usages buffer.")

(defvar-local expose-usages-purpose nil
  "`dead-code' or `rename' -- which question this buffer's results answer.

The underlying search is identical either way (see
`expose-usages-collect'); only the framing and the OUTSIDE marker in
`expose-usages-insert-item' depend on which one this is.")

(defvar-local expose-usages-origin-buffer nil
  "The buffer the current search was run from, for `g' to search again from.")

(defvar-local expose-usages-origin-position nil
  "The position in `expose-usages-origin-buffer' to search again from.

Captured once, at the first search, rather than read from this buffer's
own point on refresh -- point here is wherever you're reading results,
which has nothing to do with what symbol the search was about.")

(define-derived-mode expose-usages-mode special-mode "Expose-Usages"
  "Major mode for the Expose dead-code-check/rename-impact results buffer."

  (setq-local truncate-lines t)

  (when (bound-and-true-p evil-local-mode)
    (evil-normal-state)))

;;; ---------------------------------------------------------------------------
;;; Collection
;;; ---------------------------------------------------------------------------

(defun expose-usages-collect ()
  "Return a plist of the direct callers/references of the symbol at point.

Keys: `:root', `:nodes', `:edges', `:failures', `:use-lsp'. Shares its
root-finding and reference-gathering with `expose-callers-build-dot' --
duplicated rather than factored out, the same call `expose-callers-
collect-tests' already makes for the same reason: each caller wants a
different final step (a directed graph there, a flat list here), and
root-finding is cheap enough that sharing it would only rename the
duplication rather than remove it.

Capped to depth 1 via a narrow `let' around `expose-callers-max-depth':
this answers who calls the symbol at point, not who calls those in
turn -- climbing further is what `expose-run-reverse-call-graph' already
draws as a picture."

  (let* ((expose-callers-lsp-failures nil)
         (use-lsp (expose-callers-lsp-available-p))

         (root
          (if use-lsp
              (car (expose-callers-lsp-prepare))

            (let ((name (or (thing-at-point 'symbol t)
                            (user-error "No symbol at point"))))
              (list :name name
                    :file (buffer-file-name)
                    :line (line-number-at-pos))))))

    (unless root
      (expose-callers-signal-nothing "Nothing callable at point"))

    (let* ((root-references
            (when expose-callers-include-references
              (condition-case err
                  (if use-lsp
                      (expose-callers-lsp-references)
                    (expose-callers-xref-nodes (plist-get root :name) 'reference))
                (error
                 (expose-log "Usages" "Reference lookup failed: %s"
                             (error-message-string err))
                 nil))))

           (graph
            (let ((expose-callers-max-depth 1))
              (expose-callers-collect root use-lsp root-references)))

           (nodes (car graph))
           (edges (cdr graph)))

      (list :root root :nodes nodes :edges edges
            :failures expose-callers-lsp-failures :use-lsp use-lsp))))

(defun expose-usages-callers (found)
  "Return FOUND's direct callers/references, sorted by file then line."

  (let* ((nodes (plist-get found :nodes))
         (root-key (expose-callers-node-key (plist-get found :root)))
         (callers nil))

    (maphash
     (lambda (key node)
       (unless (equal key root-key)
         (push node callers)))
     nodes)

    (sort callers
          (lambda (a b)
            (let ((file-a (or (plist-get a :file) ""))
                  (file-b (or (plist-get b :file) "")))
              (if (string= file-a file-b)
                  (< (or (plist-get a :line) 0) (or (plist-get b :line) 0))
                (string< file-a file-b)))))))

(defun expose-usages-area (file)
  "Return FILE's top-level directory relative to its project root, or nil.

Nil both when FILE has no project (outside any `project-current' root)
and when FILE sits directly at the project root with no subdirectory of
its own -- both cases where there's no meaningful \"area\" to compare
against, and `expose-usages-insert-item' treats a nil root area as
\"don't mark anything OUTSIDE\" rather than a group of its own."

  (when-let* ((file file)
              (project (project-current nil (file-name-directory file)))
              (root (expand-file-name (project-root project))))

    (let* ((relative (file-relative-name file root))
           (first (car (split-string relative "/"))))
      (unless (equal first relative) first))))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun expose-usages-insert-item (node purpose root-area)
  "Insert one caller/reference NODE, tagged for navigation and visiting.

Prefixed with OUTSIDE when PURPOSE is `rename' and NODE's own area
(see `expose-usages-area') differs from ROOT-AREA -- the call sites an
editor-wide rename would not already catch for you."

  (let* ((block-start (point))
         (file (plist-get node :file))
         (line (or (plist-get node :line) 1))
         (text (expose-callers-line-text file line))
         (summary
          (if (and text (not (string-blank-p text)))
              (string-trim-right text)
            (or (plist-get node :name) "?")))

         (outside
          (and (eq purpose 'rename)
               root-area
               (not (equal (expose-usages-area file) root-area)))))

    (when outside
      (insert (propertize "OUTSIDE  " 'face 'warning)))

    (insert (format "  %5d  " line))
    (insert summary)
    (insert "\n")

    (add-text-properties
     block-start
     (point)
     (list 'expose-usages-item node))))

(defun expose-usages-insert (purpose found)
  "Render FOUND into the current buffer, framed for PURPOSE."

  (let* ((root (plist-get found :root))
         (name (or (plist-get root :name) "?"))
         (callers (expose-usages-callers found))
         (failures (plist-get found :failures))
         (root-area (expose-usages-area (plist-get root :file)))
         (inhibit-read-only t))

    (erase-buffer)

    (insert
     (propertize
      (pcase purpose
        ('dead-code (format "Dead code check: %s" name))
        ('rename (format "Rename impact: %s" name)))
      'face 'expose-usages-title-face))

    (insert "\n\n")

    (if (null callers)

        (progn
          (insert
           (propertize
            (pcase purpose
              ('dead-code
               (format "Nothing calls or references %s within this project." name))
              ('rename
               (format "No call sites found for %s in this project -- renaming should be safe here."
                       name)))
            'face 'expose-usages-meta-face))

          (insert "\n\n")

          (insert
           (propertize
            "This only sees this project: a public API used elsewhere -- another package, a different repo -- would not show up here either way."
            'face 'expose-usages-meta-face))

          (insert "\n"))

      (progn
        (insert
         (propertize
          (format "%d caller%s/reference%s found%s"
                  (length callers)
                  (if (= 1 (length callers)) "" "s")
                  (if (= 1 (length callers)) "" "s")
                  (if (eq purpose 'dead-code) " -- likely not dead code." "."))
          'face 'expose-usages-meta-face))

        (when failures
          (insert
           (propertize
            (format " (incomplete: %d lookup%s failed -- see the log)"
                    (length failures) (if (= 1 (length failures)) "" "s"))
            'face 'warning)))

        (insert "\n")

        (insert
         (propertize
          (if (eq purpose 'rename)
              "TAB/S-TAB moves between call sites. RET opens one to the left. OUTSIDE rows sit outside this symbol's own area -- check those by hand. g refreshes. q quits.\n\n"
            "TAB/S-TAB moves between call sites. RET opens one to the left. g refreshes. q quits.\n\n")
          'face 'expose-usages-meta-face))

        (let (current-file)
          (dolist (node callers)
            (let ((file (plist-get node :file)))

              (unless (equal file current-file)
                (setq current-file file)
                (insert "\n")
                (insert
                 (propertize
                  (if file (abbreviate-file-name file) "(unknown file)")
                  'face 'expose-usages-title-face))
                (insert "\n")))

            (expose-usages-insert-item node purpose root-area)))))

    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun expose-usages-current-item ()
  "Return the caller node at point, or nil."

  (or
   (get-text-property (point) 'expose-usages-item)
   (get-text-property (line-beginning-position) 'expose-usages-item)
   (get-text-property (max (point-min) (1- (line-end-position))) 'expose-usages-item)))

(defun expose-usages-next-item-position ()
  "Return the position of the next caller item after point."

  (let ((current (expose-usages-current-item))
        (position (point))
        found)

    (while (and (not found) (< position (point-max)))
      (setq position
            (next-single-property-change position 'expose-usages-item nil (point-max)))

      (let ((item (get-text-property position 'expose-usages-item)))
        (when (and item (not (eq item current)))
          (setq found position))))

    found))

(defun expose-usages-previous-item-position ()
  "Return the position of the previous caller item before point."

  (let ((current (expose-usages-current-item))
        (position (point))
        found)

    (while (and (not found) (> position (point-min)))
      (setq position
            (previous-single-property-change position 'expose-usages-item nil (point-min)))

      (let* ((probe (max (point-min) (1- position)))
             (item (get-text-property probe 'expose-usages-item)))
        (when (and item (not (eq item current)))
          (setq found probe))))

    found))

(defun expose-usages-next-item ()
  "Move to the next caller in the Expose usages buffer."

  (interactive)

  (if-let ((position (expose-usages-next-item-position)))
      (progn (goto-char position) (beginning-of-line))
    (message "No next call site")))

(defun expose-usages-previous-item ()
  "Move to the previous caller in the Expose usages buffer."

  (interactive)

  (if-let ((position (expose-usages-previous-item-position)))
      (progn (goto-char position) (beginning-of-line))
    (message "No previous call site")))

(defun expose-usages-visit ()
  "Open the call site at point, to the left of this list."

  (interactive)

  (let ((item (expose-usages-current-item)))
    (unless item
      (user-error "No call site on this line"))

    (let ((file (plist-get item :file))
          (line (or (plist-get item :line) 1)))

      (unless (and file (file-exists-p file))
        (user-error "File does not exist: %s" file))

      (let* ((list-window (selected-window))
             (target-window
              (or (window-in-direction 'left list-window)
                  (split-window list-window nil 'left))))

        (select-window target-window)
        (find-file file)
        (goto-char (point-min))
        (forward-line (1- line))))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun expose-usages-search-and-render (purpose origin-buffer origin-position)
  "Search PURPOSE from ORIGIN-BUFFER at ORIGIN-POSITION, render results."

  (require 'expose-callers)

  (let* ((found
          (with-current-buffer origin-buffer
            (save-excursion
              (goto-char origin-position)
              (expose-usages-collect))))

         (name (plist-get (plist-get found :root) :name))
         (callers (expose-usages-callers found))
         (failures (plist-get found :failures)))

    (setq expose-usages-purpose purpose)
    (setq expose-usages-origin-buffer origin-buffer)
    (setq expose-usages-origin-position origin-position)

    (expose-usages-insert purpose found)

    (message "Expose: %s %s%s%s"
             (if (eq purpose 'dead-code) "checked" "found")
             name
             (if (eq purpose 'dead-code)
                 (format (if (null callers) " -- no callers found" " -- %d caller(s)/reference(s) found")
                         (length callers))
               (format " -- %d call site(s)" (length callers)))
             (if failures
                 (format " (incomplete: %d lookup%s failed -- see the log)"
                         (length failures) (if (= 1 (length failures)) "" "s"))
               ""))))

(defun expose-usages-reload ()
  "Search again from where this search was originally started."

  (interactive)

  (unless (buffer-live-p expose-usages-origin-buffer)
    (user-error "The buffer this search started from is gone"))

  (let ((point-line (line-number-at-pos))
        (point-column (current-column))
        (purpose expose-usages-purpose))

    (expose-usages-search-and-render
     purpose
     expose-usages-origin-buffer
     expose-usages-origin-position)

    (goto-char (point-min))
    (forward-line (1- point-line))
    (move-to-column point-column)))

(defun expose-usages-open (purpose source-window)
  "Run a PURPOSE usages search from SOURCE-WINDOW and show results beside it."

  (let* ((origin-buffer (window-buffer source-window))
         (origin-position (window-point source-window))
         (buffer (get-buffer-create expose-usages-buffer-name)))

    (with-current-buffer buffer
      (unless (derived-mode-p 'expose-usages-mode)
        (expose-usages-mode))
      (expose-usages-search-and-render purpose origin-buffer origin-position))

    (select-window (expose-side-panel-place source-window buffer))))

;;;###autoload
(defun expose-run-dead-code-check ()
  "Check whether anything calls or references the symbol at point.

Nothing found is the useful answer here, not a failure -- but it means
only \"nothing in this project\": a public API used from another
package or repo is invisible to this the same way it is to
`expose-run-reverse-call-graph', which this shares its search with,
capped to direct callers/references only (see `expose-usages-collect').

No AI: this needs the whole project, which no provider can see, and a
confident, invented answer to \"is this dead\" is the worst possible
kind of wrong here."

  (interactive)

  (message "Expose: checking for callers...")
  (expose-usages-open 'dead-code (selected-window)))

;;;###autoload
(defun expose-run-rename-impact ()
  "List what would break if the symbol at point were renamed.

Every direct caller/reference, same search as
`expose-run-dead-code-check'. Callers inside this symbol's own
top-level directory are what an editor-wide rename already catches for
you; the ones marked OUTSIDE are not, and are worth a look before you
commit to the rename.

No AI, for the same reason as `expose-run-dead-code-check': a guessed
answer to \"what would this rename break\" is worse than none."

  (interactive)

  (message "Expose: checking call sites...")
  (expose-usages-open 'rename (selected-window)))

(with-eval-after-load 'evil
  (evil-define-key* 'normal expose-usages-mode-map
    (kbd "TAB") #'expose-usages-next-item
    (kbd "<backtab>") #'expose-usages-previous-item
    (kbd "RET") #'expose-usages-visit
    (kbd "g") #'expose-usages-reload
    (kbd "q") #'quit-window)

  (evil-define-key* 'motion expose-usages-mode-map
    (kbd "TAB") #'expose-usages-next-item
    (kbd "<backtab>") #'expose-usages-previous-item
    (kbd "RET") #'expose-usages-visit
    (kbd "g") #'expose-usages-reload
    (kbd "q") #'quit-window)

  (evil-set-initial-state 'expose-usages-mode 'normal))

(provide 'expose-usages)

;;; expose-usages.el ends here
