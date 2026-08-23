;;; modules/+merge.el -*- lexical-binding: t; -*-

;;
;; Merge conflicts
;;
;; Two halves, and Emacs ships both but arms neither:
;;
;; - `smerge-mode' edits the `<<<<<<<' markers Git leaves in a file. Its
;;   own bindings under `C-c ^' are good; the problem is that the mode is
;;   never on, so a conflicted file opens as plain text and the markers
;;   get edited by hand.
;; - `ediff' resolves a conflict side by side, and is reached from Magit
;;   with `e' on a conflicted file. See `+ediff.el' for the `B' key that
;;   takes *both* sides, which ediff itself has no command for.

(require 'nerd-icons nil t)

(defvar jsoa/merge-conflict-regexp "^<<<<<<< "
  "Regexp matching the start of a Git conflict marker.")

(defun jsoa/merge-conflict-p ()
  "Return non-nil if the current buffer contains a conflict marker.

Skipped for very large files: this runs on every file opened, and the
worst case is a full scan of a buffer with no conflict in it. A file
past `jsoa/large-file-size' is already opened in a stripped-down state
by `+large-file.el', and is not one anybody resolves a merge in."

  (and (not (and (fboundp 'jsoa/large-file-p) (jsoa/large-file-p)))
       (save-excursion
         (save-restriction
           (widen)
           (goto-char (point-min))
           (re-search-forward jsoa/merge-conflict-regexp nil t)))))

(defun jsoa/smerge-maybe-enable ()
  "Turn on `smerge-mode' when the buffer has conflict markers.

Also turns it *off* again once they are gone, so finishing a resolution
leaves the buffer in its normal state rather than in a mode whose
commands have nothing to act on."

  (when (and buffer-file-name (not (bound-and-true-p buffer-read-only)))
    (require 'smerge-mode)
    (if (jsoa/merge-conflict-p)
        (unless (bound-and-true-p smerge-mode)
          ;; Silently. The mode line already says SMerge, the markers are
          ;; unmissable, and a message here competes with flycheck and
          ;; everything else shouting in the echo area at exactly the
          ;; moment a conflicted file is opened.
          (smerge-mode 1)
          (jsoa/merge-suspend-diff-hl))
      (when (bound-and-true-p smerge-mode)
        (smerge-mode -1)
        (jsoa/merge-restore-diff-hl)))))

(defvar-local jsoa/merge-diff-hl-suspended nil
  "Whether `diff-hl-mode' was turned off here because of a conflict.")

(defun jsoa/merge-suspend-diff-hl ()
  "Turn off `diff-hl-mode' while this buffer has conflict markers.

Git cannot produce a normal unified diff for an unmerged path, and
`diff-hl-changes-from-buffer' walks that output with
`diff-beginning-of-hunk' expecting one -- so opening a conflicted file
raises \"Can't find the beginning of the hunk\", repeatedly, from the
gutter rather than from anything you did.

The gutter has nothing useful to say about an unmerged file in any case:
there is no single index version to compare against."

  (when (bound-and-true-p diff-hl-mode)
    (setq jsoa/merge-diff-hl-suspended t)
    (diff-hl-mode -1)))

(defun jsoa/merge-restore-diff-hl ()
  "Turn `diff-hl-mode' back on if this buffer's conflict is resolved."

  (when (and jsoa/merge-diff-hl-suspended (fboundp 'diff-hl-mode))
    (setq jsoa/merge-diff-hl-suspended nil)
    (diff-hl-mode 1)))

;; On open, and again after a revert: Magit reverts buffers after a merge,
;; a rebase and a stash pop, which is exactly when a file that was clean a
;; moment ago starts carrying markers.
(add-hook 'find-file-hook #'jsoa/smerge-maybe-enable)
(add-hook 'after-revert-hook #'jsoa/smerge-maybe-enable)

(defun jsoa/smerge-after-save ()
  "Drop `smerge-mode' once a save leaves no conflict markers behind.

Guarded on the mode already being on, so this does not scan every buffer
on every save. Only turning the mode *off* is in question here: a save
cannot introduce markers, and a file that gains them by other means goes
through `find-file-hook' or `after-revert-hook' instead."

  (when (bound-and-true-p smerge-mode)
    (jsoa/smerge-maybe-enable)))

(add-hook 'after-save-hook #'jsoa/smerge-after-save)

;;; ---------------------------------------------------------------------------
;;; Mode line
;;; ---------------------------------------------------------------------------
;;
;; The first version of `jsoa/smerge-maybe-enable' announced arming with a
;; `message', removed a few commits later because it collided with
;; flycheck's own noise in the echo area at exactly the moment a
;; conflicted file opens -- the one moment it mattered most. That traded
;; a working reminder for no reminder at all. A mode-line segment is the
;; middle ground: on screen for as long as the buffer is conflicted,
;; costs nothing to have there or to ignore, and clickable straight into
;; the resolver rather than only informative.

(defcustom jsoa/merge-mode-line-icon "nf-fa-exclamation_triangle"
  "Nerd Font icon name for the merge-conflict mode-line indicator.

Only used when `nerd-icons' is installed; a plain `⚠' is shown
otherwise, matching how `expose-watch-mode-line-icon' falls back."
  :type 'string
  :group 'jsoa)

(defface jsoa/merge-mode-line-face
  '((t :inherit warning :weight bold))
  "Face for the merge-conflict mode-line indicator.")

(defun jsoa/merge-mode-line-icon-glyph ()
  "Return the icon glyph for the merge-conflict mode-line indicator."

  (if (fboundp 'nerd-icons-faicon)

      (nerd-icons-faicon
       jsoa/merge-mode-line-icon
       :face 'jsoa/merge-mode-line-face
       :height 0.9
       :v-adjust -0.02)

    "⚠"))

(defvar jsoa/merge-mode-line-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'jsoa/smerge-resolve)
    map)
  "Keymap active on a click of the merge-conflict mode-line indicator.

Emacs delivers a click on mode-line text as a `[mode-line mouse-1]'
event to whatever `local-map' that text is propertized with, and always
against the buffer whose mode line was clicked -- correct even when
that window is not the selected one.")

(defun jsoa/merge-mode-line ()
  "Return the mode-line construct for a conflicted buffer, or \"\"."

  (if (bound-and-true-p smerge-mode)

      (propertize
       (format " %s conflict" (jsoa/merge-mode-line-icon-glyph))
       'face 'jsoa/merge-mode-line-face
       'mouse-face 'mode-line-highlight
       'local-map jsoa/merge-mode-line-keymap
       'help-echo "mouse-1: resolve conflicts (jsoa/smerge-resolve)")

    ""))

(defvar jsoa/merge-mode-line-indicator
  '(:eval (jsoa/merge-mode-line))
  "Mode-line construct for merge conflicts.")

(defun jsoa/merge-install-mode-line ()
  "Install the merge-conflict mode-line indicator.

Into `mode-line-misc-info', the same extension point
`expose-watch-install-mode-line' uses, so ordinary Emacs and Doom
modeline's `misc-info' segment both display it without any modeline
config of your own."

  (unless (member jsoa/merge-mode-line-indicator mode-line-misc-info)
    (setq mode-line-misc-info
          (append mode-line-misc-info (list jsoa/merge-mode-line-indicator)))))

(jsoa/merge-install-mode-line)

(defun jsoa/merge-goto-conflict ()
  "Move point to the start of the next conflict, wrapping. Return non-nil if found.

Neither `smerge-next' nor `smerge-find-conflict' does this. Both leave
point *past* the conflict they found, and `smerge-next' called while
point already sits on a marker skips to the following one -- so invoking
a resolve command on a buffer with a single conflict jumped over it and
landed at end of buffer, with the first keystroke then acting on
nothing."

  (let ((start (line-beginning-position)))
    (goto-char start)
    (if (re-search-forward jsoa/merge-conflict-regexp nil t)
        (goto-char (match-beginning 0))
      ;; Nothing below: wrap, so invoking this near the end of a file
      ;; still finds the conflicts above.
      (goto-char (point-min))
      (when (re-search-forward jsoa/merge-conflict-regexp nil t)
        (goto-char (match-beginning 0))))))

(defvar jsoa/smerge-resolve-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'smerge-next)
    (define-key map "p" #'smerge-prev)
    (define-key map "u" #'smerge-keep-upper)
    (define-key map "l" #'smerge-keep-lower)
    (define-key map "b" #'smerge-keep-all)
    (define-key map "a" #'smerge-keep-all)
    (define-key map "c" #'smerge-keep-current)
    (define-key map "r" #'smerge-resolve)
    (define-key map "e" #'smerge-ediff)
    (define-key map "d" #'smerge-refine)
    (define-key map "U" #'smerge-diff-base-upper)
    (define-key map "L" #'smerge-diff-base-lower)
    map)
  "Single-key commands available while `jsoa/smerge-resolve' is active.

`u'/`l' rather than smerge's own `m'/`o' (mine/other): after a rebase
those words swap meaning -- your commits are replayed onto theirs, so
\"mine\" is the branch you rebased *onto* -- and upper/lower always
describe what is actually on screen.")

(defun jsoa/smerge-resolve ()
  "Walk the conflicts in this buffer with single-key commands.

Repeats until you leave it, so resolving ten conflicts is `n u n u ...'
rather than ten invocations of a prefixed binding. Anything not in
`jsoa/smerge-resolve-map' exits and runs normally, so there is nothing
to quit out of.

  n / p  next / previous conflict     u  keep upper (before =======)
  c      keep the one point is in     l  keep lower (after  =======)
  r      resolve if smerge can        b  keep both
  e      hand this one to ediff       d  refine, word by word
  U / L  diff a side against the base"

  (interactive)

  (require 'smerge-mode)

  (unless (jsoa/merge-conflict-p)
    (user-error "No conflict markers in %s" (buffer-name)))

  (unless (bound-and-true-p smerge-mode)
    (smerge-mode 1))

  (jsoa/merge-goto-conflict)

  (message "Resolve: n/p move  u/l/b keep upper/lower/both  c current  r auto  e ediff  d refine")
  (set-transient-map jsoa/smerge-resolve-map t))

(defun jsoa/merge-conflicted-files ()
  "Return the repository's unresolved paths, as absolute file names.

Asked of Git rather than found by scanning: `--diff-filter=U' is the
index's own record of what is unmerged, which is the same thing Git
would refuse to let you commit."

  (let ((root (or (and (fboundp 'magit-toplevel) (magit-toplevel))
                  (locate-dominating-file default-directory ".git"))))
    (when root
      (let ((default-directory root))
        (mapcar
         (lambda (path) (expand-file-name path root))
         (split-string
          (shell-command-to-string
           "git diff --name-only --diff-filter=U --relative")
          "\n" t))))))

(defun jsoa/find-conflicted-file ()
  "Jump to a file with unresolved merge conflicts.

The list Git itself would give you, so it stays right through a rebase
that resolves some and creates others -- unlike a list of buffers you
happen to have open."

  (interactive)

  (let ((files (jsoa/merge-conflicted-files)))
    (unless files
      (user-error "No unresolved conflicts in this repository"))

    (let* ((root (or (and (fboundp 'magit-toplevel) (magit-toplevel))
                     default-directory))
           (choices (mapcar (lambda (file)
                              (cons (file-relative-name file root) file))
                            files))
           (choice (if (= 1 (length choices))
                       (car (car choices))
                     (completing-read
                      (format "Conflicted (%d): " (length choices))
                      choices nil t))))

      (find-file (cdr (assoc choice choices)))
      (jsoa/smerge-resolve))))

;; Added to Doom's existing git prefix rather than relabelling it. Check
;; `SPC g' in which-key after loading this: if Doom or a module already
;; owns `m' or `M' there, these silently win, and the fix is to change
;; the letter here.
(map! :leader
      (:prefix "g"
       :desc "Resolve conflicts here" "m" #'jsoa/smerge-resolve
       :desc "Find conflicted file"   "M" #'jsoa/find-conflicted-file))
