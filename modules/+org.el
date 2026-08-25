;;; modules/+org.el -*- lexical-binding: t; -*-

;; For `expose-side-panel-place' only -- the exact window-arrangement
;; logic `expose' already uses for its own persistent results,
;; reused here rather than reimplemented. Added to `load-path'
;; independently of `+expose.el', which also does this: this file
;; must not depend on `+expose.el' having loaded first.
(add-to-list 'load-path (expand-file-name "site-lisp/expose" doom-user-dir))

;;; ---------------------------------------------------------------------
;;; Org cheat-sheet side panel
;;;
;;; Every verified-real binding below was checked directly against
;;; Org's own `org-keys.el' (or this config's actual `+evil-bindings.el'
;;; for the "Doom leader" section), not recalled from memory -- the
;;; same standard the rest of this session has held to throughout,
;;; because a cheat sheet that's subtly wrong is worse than none.
;;; ---------------------------------------------------------------------

(defconst jsoa/org-cheatsheet-buffer-name "*Org Cheatsheet*")

(defcustom jsoa/org-cheatsheet-auto-show t
  "Whether opening a real org file automatically shows the cheat-sheet
side panel. Toggle with `jsoa/org-cheatsheet-toggle-auto-show'."
  :type 'boolean
  :group 'org)

(define-derived-mode jsoa/org-cheatsheet-mode special-mode "Org-Cheatsheet"
  "Major mode for the Org cheat-sheet side panel.")

(defun jsoa/org-cheatsheet--section (title rows)
  "Insert one cheat-sheet section: TITLE, then ROWS of (KEY . DESCRIPTION)."

  (insert (propertize title 'face 'bold))
  (insert "\n")
  (dolist (row rows)
    (insert (propertize (format "  %-16s" (car row)) 'face 'font-lock-keyword-face))
    (insert (cdr row))
    (insert "\n"))
  (insert "\n"))

(defun jsoa/org-cheatsheet-insert ()
  "Render the cheat sheet into the current buffer."

  (let ((inhibit-read-only t))
    (erase-buffer)

    (insert (propertize "Org Mode Cheatsheet" 'face 'bold))
    (insert "\n")
    (insert (propertize (make-string 38 ?─) 'face 'shadow))
    (insert "\n\n")

    (jsoa/org-cheatsheet--section
     "TODO & Priority"
     '(("C-c C-t" . "Cycle TODO state")
       ("S-left/right" . "Shift-cycle TODO/priority/timestamp at point")
       ("C-c ," . "Set priority")))

    (jsoa/org-cheatsheet--section
     "Timestamps & Scheduling"
     '(("C-c ." . "Insert active timestamp")
       ("C-c !" . "Insert inactive timestamp")
       ("C-c C-s" . "Schedule")
       ("C-c C-d" . "Set deadline")))

    (jsoa/org-cheatsheet--section
     "Structure"
     '(("M-RET" . "New heading/item, same level")
       ("M-S-RET" . "New TODO heading")
       ("TAB" . "Cycle visibility (or move table column)")
       ("S-TAB" . "Cycle visibility, whole buffer")
       ("M-left/right" . "Promote/demote (or move table column)")
       ("M-up/down" . "Move heading up/down (or move table row)")
       ("C-c C-w" . "Refile to another heading")
       ("C-c $" . "Archive subtree")))

    (jsoa/org-cheatsheet--section
     "Tags"
     '(("C-c C-q" . "Set tags on heading")))

    (jsoa/org-cheatsheet--section
     "Links"
     '(("C-c C-l" . "Insert/edit link")
       ("C-c C-o" . "Open link at point")))

    (jsoa/org-cheatsheet--section
     "Lists & Checkboxes"
     '(("C-c -" . "Cycle bullet / insert list item")
       ("C-c C-x C-b" . "Toggle checkbox")))

    (jsoa/org-cheatsheet--section
     "Tables"
     '(("|" . "Start a table")
       ("TAB" . "Next cell")
       ("C-c C-c" . "Recalculate formulas")))

    (jsoa/org-cheatsheet--section
     "Source Blocks"
     '(("C-c C-," . "Insert structure template (#+begin_src etc.)")
       ("C-c C-c" . "Execute block at point")))

    (jsoa/org-cheatsheet--section
     "Clocking"
     '(("C-c C-x C-i" . "Clock in")
       ("C-c C-x C-o" . "Clock out")
       ("C-c C-x C-q" . "Cancel active clock")
       ("C-c C-x C-x" . "Clock in on the last task")))

    (jsoa/org-cheatsheet--section
     "Navigation & Search"
     '(("C-c C-j" . "Jump to heading (fuzzy)")
       ("C-c /" . "Sparse tree search")))

    (insert
     (propertize
      (concat "C-c C-c is context-sensitive throughout: toggles a checkbox, "
              "recalculates a table, runs a source block, and more -- the "
              "closest thing Org has to one \"do the right thing\" key.")
      'face 'shadow))
    (insert "\n\n")

    (jsoa/org-cheatsheet--section
     "Doom leader (this config)"
     '(("SPC n a" . "Org agenda")
       ("SPC n l" . "Store link")
       ("SPC n t" . "Global TODO list")
       ("SPC n n g" . "Quick note (general)")
       ("SPC n n p" . "Quick note (this project)")
       ("SPC n n F" . "New named org file")
       ("SPC n n ?" . "Show this panel")
       ("SPC n n A" . "Toggle auto-show on open")))

    (insert (propertize "q" 'face 'font-lock-keyword-face))
    (insert "  Close this panel (reopen any time with SPC n n ?)\n")

    (goto-char (point-min))))

(defun jsoa/org-cheatsheet-show (&optional source-window)
  "Show the Org cheat-sheet panel beside SOURCE-WINDOW (default: selected)."

  (interactive)

  (require 'expose-side-panel)

  (let ((buffer (get-buffer-create jsoa/org-cheatsheet-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'jsoa/org-cheatsheet-mode)
        (jsoa/org-cheatsheet-mode))
      (jsoa/org-cheatsheet-insert))
    (expose-side-panel-place (or source-window (selected-window)) buffer)))

(defun jsoa/org-cheatsheet-toggle-auto-show ()
  "Toggle whether opening an org file auto-shows the cheat-sheet panel."

  (interactive)

  (setq jsoa/org-cheatsheet-auto-show (not jsoa/org-cheatsheet-auto-show))
  (message "Org cheat-sheet auto-show: %s" (if jsoa/org-cheatsheet-auto-show "on" "off")))

(defun jsoa/org-cheatsheet-maybe-show ()
  "Show the Org cheat-sheet panel on genuinely opening a real org file.

Guarded three ways, each a real case this hook otherwise misfires on:
`buffer-file-name' excludes org-mode buffers with no file of their own
\(the agenda's own temp buffers, `org-edit-special' popups); the
`org-capture-mode' check excludes capture buffers, where a whole side
panel would fight the point of a *quick* capture; and the
`window-buffer' check excludes org-mode being turned on for a buffer
that isn't actually the one on screen -- which happens whenever
anything scans `org-agenda-files' in the background (`SPC n a' itself
visits every file in it this same way), not just on a real,
interactive `find-file'."

  (when (and jsoa/org-cheatsheet-auto-show
             buffer-file-name
             (not (bound-and-true-p org-capture-mode))
             (eq (current-buffer) (window-buffer (selected-window))))
    (jsoa/org-cheatsheet-show (selected-window))))

(add-hook 'org-mode-hook #'jsoa/org-cheatsheet-maybe-show)

(after! org
  (setq org-columns-default-format "%50ITEM(Task) %10CLOCKSUM %16LASTWORKED %16CLOSED")

  ;; Guarded on the directory existing: `directory-files-recursively'
  ;; signals `file-missing' rather than returning nil for a missing
  ;; directory, which would take the whole `after! org' body -- and so
  ;; org itself -- down on any machine without an ~/org yet.
  (setq org-agenda-files
        (when (file-directory-p org-directory)
          (directory-files-recursively org-directory "\\.org\\'")))

  ;; ---------------------------------------------------------------------
  ;; Quick capture: one general note file, one per-project note file.
  ;;
  ;; Both templates are pure "* %U %?\n  %a\n": an inactive timestamp
  ;; (so a quick note never clutters the agenda the way an active one
  ;; would), point left at %? for the note body, and %a -- a real link
  ;; back to wherever capture was invoked from, file and line included
  ;; for a source buffer -- on its own line underneath. No heading
  ;; picked, no file chosen by hand: the whole point of a "quick" note
  ;; is that capturing it costs zero decisions.
  ;; ---------------------------------------------------------------------

  (defun jsoa/org-notes-project-root ()
    "Return the current project's root, or nil outside one."
    (when-let ((project (project-current nil)))
      (expand-file-name (project-root project))))

  (defun jsoa/org-notes-project-file ()
    "Return the note file for the current project, under `org-directory'.

Keyed on the project's own directory basename (`tristate-api.org'),
not its full path -- simpler, and matches what was actually asked for.
The tradeoff, taken deliberately: two differently-located projects
that happen to share a directory name would collide into the same
note file. `jsoa/project-root' in `+vterm.el' keys on the full path
instead for exactly this reason, but that's for a buffer name, not a
filename on disk, where a real path can't be used verbatim anyway --
worth revisiting here only if the collision ever actually happens."

    (if-let ((root (jsoa/org-notes-project-root)))
        (expand-file-name
         (concat (file-name-nondirectory (directory-file-name root)) ".org")
         org-directory)
      (user-error "Not inside a project")))

  (defun jsoa/org-notes-new-file ()
    "Create (or revisit) a new, named org file under `org-directory',
and open it for editing.

For a one-off note that doesn't belong in the general or per-project
file -- meeting notes, most often -- typed instead of picked. A name
containing `/' creates the file in a subdirectory of `org-directory',
created if it doesn't exist yet, rather than being rejected -- typing
`clients/acme-sync' to keep one client's meeting notes together in
their own subdirectory is a reasonable thing to want, not a mistake to
guard against.

Nothing is written into an already-existing file with this name --
only a genuinely new one gets a `#+TITLE:' line -- so reusing a name
(the same recurring meeting, say) reopens what's already there rather
than clobbering it."

    (interactive)

    (let ((typed (string-trim (read-string "New org file: "))))
      (when (string-empty-p typed)
        (user-error "No name given"))

      (let* ((filename (if (string-suffix-p ".org" typed) typed (concat typed ".org")))
             (path (expand-file-name filename org-directory))
             (new (not (file-exists-p path))))

        (make-directory (file-name-directory path) t)
        (find-file path)

        (when new
          (insert (format "#+TITLE: %s\n\n" (file-name-base filename)))
          (goto-char (point-max))))))

  (setq org-capture-templates
        (append
         org-capture-templates
         `(("n" "Note" entry (file ,(expand-file-name "notes.org" org-directory))
            "* %U %?\n  %a\n")
           ("p" "Project note" entry (file jsoa/org-notes-project-file)
            "* %U %?\n  %a\n")))))

;; Confirmed live: with this disabled, `SPC n' shows exactly stock
;; Doom's own list (`*' `a' `c' `C' `f' `F' `l' `m' `n' `N' `o' `s' `S'
;; `t' `v' `y' `Y') and nothing else -- so this file is genuinely the
;; one in effect.
;;
;; Wrapping the new binding in an outer `(:prefix ("n" . "notes")
;; ...)' -- redeclaring a prefix stock Doom already owns and has
;; populated, just to nest one more thing inside it -- reset that
;; whole prefix down to only what was declared here, discarding every
;; other entry (`a' `c' `f' ... ) rather than adding alongside them.
;; Given directly, as a single two-key path with no outer prefix
;; redeclared at all, this only ever adds the one nested keymap at
;; `n n' and should leave everything else under `SPC n' untouched.
(map! :leader
      (:prefix-map ("n n" . "quick note")
       :desc "General note"    "g" (cmd! (org-capture nil "n"))
       :desc "Project note"    "p" (cmd! (org-capture nil "p"))
       :desc "New file"        "F" #'jsoa/org-notes-new-file
       :desc "Show cheatsheet" "?" #'jsoa/org-cheatsheet-show
       :desc "Toggle auto-show" "A" #'jsoa/org-cheatsheet-toggle-auto-show))

(after! org-re-reveal
  (setq org-re-reveal-root (concat (getenv "HOME") "/.doom.d/private/reveal.js"))
  )
