;;; expose-action-buffer.el -*- lexical-binding: t; -*-

;;; A colorized, persistent pane for the result of a `SPC c h h' action --
;;; explain, fix, refactor, and the rest of that group -- replacing the
;;; small posframe those used to show in.
;;;
;;; The posframe's problem was never the rendering, it was the size: a
;;; result capped at a handful of lines when the answer runs to forty. A
;;; real window has no such ceiling. What it needs instead is somewhere
;;; consistent to live, since unlike a posframe it does not vanish on its
;;; own when you move point -- so this module is entirely about *where*
;;; that window goes, not about rendering, which it borrows from
;;; `expose-popup' unchanged.
;;;
;;; The placement rule: the buffer you actioned always ends up on the
;;; left, wherever it started, and the result always ends up in whatever
;;; window is immediately to its right -- created by splitting if none
;;; exists. Re-derived fresh on every action rather than tracked as
;;; state, which makes it self-correcting: close the result window,
;;; rearrange your frame, action a different buffer entirely, and the
;;; next action still lands in the right place without needing to know
;;; what happened since the last one.

(require 'cl-lib)
(require 'subr-x)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-history)

(defconst expose-action-buffer-name "*EXPOSE Action*"
  "Name of the persistent action-result buffer.

Not hidden with a leading space, unlike the posframe's own buffer: this
one is meant to be looked at, scrolled, and selected into directly, the
way `expose-history-buffer-name' is.")

(defvar-local expose-action-buffer-source nil
  "The buffer this action buffer's current content was produced from.

Cosmetic only -- shown in the header -- but also the reason this is
buffer-local rather than a plain defvar: a stale value from the last
action must not leak into a fresh one.")

(defvar-local expose-action-buffer-refine nil
  "Opaque refinement data for this buffer's current content, or nil.

Carried on a view's `:refine' key by whichever caller built it (see
`expose-action-buffer-insert'), and otherwise meaningless here: this
module does not know or care what a \"type\" or \"context\" is, only
that their presence means a follow-up ask is possible, and their
absence means it is not -- `expose-commands-refine-action-buffer' is
what actually understands and acts on this plist. A plist with at
least `:type', `:context', and `:refinements' (the list of follow-up
asks applied so far, oldest first) when refinement is possible; nil
when it is not -- currently only a result that errored.")

(define-derived-mode expose-action-buffer-mode special-mode "Expose-Action"
  "Major mode for the Expose action-result buffer.

`special-mode' rather than something built from scratch: read-only by
default, and `q' already runs `quit-window' -- the \"close it\" half of
\"remains open until I close it or action something else\" needs nothing
more than that."
  (setq-local truncate-lines nil)

  ;; `expose-popup-render-body' marks a rendered `**bold**''s asterisks
  ;; `invisible markdown-markup' -- a real text property, but one that
  ;; only `markdown-mode' itself knows to act on by default. Neither
  ;; this mode nor the popup's own `expose-popup-mode' otherwise honors
  ;; it, so without this the markup characters render literally, right
  ;; next to the bold/code face already correctly applied around them.
  (add-to-invisibility-spec 'markdown-markup)

  ;; This buffer should still feel like a normal Evil-readable buffer --
  ;; navigation and search work the same as anywhere else. Only matters
  ;; on a stale re-entry (the mode function itself only runs once per
  ;; buffer, on the first `expose-action-buffer-show'; see there), since
  ;; `evil-set-initial-state' below already covers the first entry.
  (when (bound-and-true-p evil-local-mode)
    (evil-normal-state)))

;;; ---------------------------------------------------------------------------
;;; Placement
;;; ---------------------------------------------------------------------------

(defun expose-action-buffer-live-window (window)
  "Return WINDOW if it is still live, otherwise the selected window.

Shared by `expose-action-buffer-place' and `expose-action-buffer-show',
which both need the same fallback for the same reason -- a captured
SOURCE-WINDOW can go stale between when an asynchronous request starts
and when its response arrives -- and should not each carry their own
copy of it to drift out of sync with each other."

  (if (window-live-p window) window (selected-window)))

(defun expose-action-buffer-source-window ()
  "Return the best window to place a follow-up result relative to.

For an action started from a source buffer, that is simply the window
the request was invoked from -- but a refinement is asked for from
*inside* the action buffer itself, where `(selected-window)' is this
buffer's own window, not the source's. Passing that straight to
`expose-action-buffer-show' would misfire: seeing a window to its own
left, it would treat this buffer as if IT were what got actioned, and
overwrite the real source pane with a copy of itself.

Tries, in order: the window currently showing
`expose-action-buffer-source' (correct whenever the usual two-pane
layout is still intact), the window to the left of the selected one
(correct even if that buffer was replaced by something else since),
then the selected window itself as a last resort -- not usually
correct, but a working command beats a hard error when nothing better
can be found."

  (or
   (and expose-action-buffer-source
        (get-buffer-window expose-action-buffer-source))
   (window-in-direction 'left (selected-window))
   (selected-window)))

(defun expose-action-buffer-place (source-window)
  "Arrange SOURCE-WINDOW and the action buffer as left/right panes.

Returns the window now showing the action buffer.

SOURCE-WINDOW -- the window whose buffer was just actioned -- always
ends up on the left, wherever it started. The action buffer always ends
up immediately to its right.

Three shapes this actually has to handle, matching how this gets used
in practice: one buffer open (split, actioned buffer keeps the original
window), two buffers with the actioned one on the left (the right pane
becomes the result, whatever it held before), and two buffers with the
actioned one on the right (it moves left, displacing whatever was
there, and its own former window becomes the result pane). Beyond two
side-by-side windows this still does something reasonable -- act on
whatever window is already to the right, or split if none -- but is not
trying to solve arbitrary N-window layouts; nothing about this feature
asked for that.

Falls back to the selected window if SOURCE-WINDOW is no longer live --
the caller may have captured it well before this runs, at the start of
an asynchronous request, and the window can be closed by the time the
response comes back. Checked here rather than left only to the caller:
this function's own use of `window-in-direction' signals on a dead
window, so skipping the check here is a trap the next caller could fall
into just as easily as this one already did once."

  (let* ((source-window (expose-action-buffer-live-window source-window))

         ;; `get-buffer-create' rather than relying on the caller having
         ;; made this buffer already: `set-window-buffer' takes a buffer
         ;; name only when a buffer by that name exists, and there is no
         ;; reason for this function's correctness to depend on being
         ;; called in a particular order relative to whatever creates it.
         (action-buffer (get-buffer-create expose-action-buffer-name))
         (source-buffer (window-buffer source-window))
         (right (window-in-direction 'right source-window))
         (left (window-in-direction 'left source-window)))

    (cond
     (right
      (set-window-buffer right action-buffer)
      right)

     (left
      (set-window-buffer left source-buffer)
      (set-window-buffer source-window action-buffer)
      source-window)

     (t
      (let ((new-window (split-window source-window nil 'right)))
        (set-window-buffer new-window action-buffer)
        new-window)))))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun expose-action-buffer-insert (view source-buffer)
  "Render VIEW into the current buffer, noting SOURCE-BUFFER in the header.

VIEW is rendered the same way the posframe popup rendered it --
`expose-popup-render-body', unchanged -- so the colorizing this is
explicitly meant to keep is not a second implementation of it.

Also stashes VIEW's `:refine' key into `expose-action-buffer-refine',
and, when it is set, renders the refinements applied so far (if any)
under the header and a one-line hint above the body -- see
`expose-action-buffer-refine' for what that key means and who sets it."

  (let ((inhibit-read-only t)
        (refine (plist-get view :refine)))

    (erase-buffer)

    (insert
     (propertize (or (plist-get view :title) "Expose") 'face 'bold))

    (when source-buffer
      (insert (propertize (format "  (%s)" source-buffer) 'face 'shadow)))

    (insert "\n")
    (insert (propertize (make-string 60 ?─) 'face 'shadow))
    (insert "\n")

    (when-let ((refinements (plist-get refine :refinements)))
      (insert
       (propertize
        (concat
         "Refinements: "
         (string-join
          (cl-loop for instruction in refinements
                   for n from 1
                   collect (format "%d) %s" n instruction))
          "  "))
        'face 'shadow))
      (insert "\n"))

    (insert "\n")
    (insert (expose-popup-render-body view))

    (when refine
      (insert "\n\n")
      (insert (propertize (make-string 60 ?─) 'face 'shadow))
      (insert
       (propertize
        "\nr: refine this result, e.g. \"also add a test for the empty-list case\" or \"undo the last one\""
        'face 'shadow)))

    (setq expose-action-buffer-refine refine)

    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun expose-action-buffer-show (view source-window)
  "Show VIEW in the action buffer, placed relative to SOURCE-WINDOW.

SOURCE-WINDOW is the window the action was invoked from, captured by
the caller before the (usually asynchronous) request was sent -- by the
time a response arrives, point may have moved anywhere, so this cannot
be discovered here. Falls back to the currently selected window if
SOURCE-WINDOW is no longer live, which is a reasonable place to put a
result even though it is not the one the request was actually about.

Also adds VIEW to popup history, unless it carries `:history nil' --
`expose-popup-view-history-p', reused as-is rather than reimplemented,
is what `expose-popup-show-view' itself has always checked before
adding a view, and every kind of result this buffer shows (a `SPC c h
h' action, a Region Review result) is meant to keep landing in history
exactly as it did before it had a persistent window of its own to show
in. The one thing that should not: the transient \"Loading...\"
placeholder a caller shows while a request is in flight, which is why
this check exists at all rather than adding unconditionally."

  (let* ((placement-window (expose-action-buffer-live-window source-window))

         (source-buffer
          (window-buffer placement-window))

         (buffer
          (get-buffer-create expose-action-buffer-name)))

    (expose-log
     "ActionBuffer"
     "Showing %s (%d bytes) from %s."
     (or (plist-get view :title) "Expose")
     (length (or (plist-get view :body) ""))
     source-buffer)

    (with-current-buffer buffer
      (unless (derived-mode-p 'expose-action-buffer-mode)
        (expose-action-buffer-mode))

      (expose-action-buffer-insert view source-buffer)
      (setq expose-action-buffer-source source-buffer))

    (when (expose-popup-view-history-p view)
      (expose-history-add view))

    (let ((result-window (expose-action-buffer-place placement-window)))
      (set-window-point result-window (point-min))
      buffer)))

;;; ---------------------------------------------------------------------------
;;; Interactive commands
;;; ---------------------------------------------------------------------------

(defun expose-action-buffer-code-blocks ()
  "Return the fenced code blocks in the current buffer.

Each element is a (START . END) cons delimiting one block's *content*,
excluding the ``` fence lines themselves. Found with a plain regexp
search over the buffer's own text rather than via `markdown-mode'
machinery: the fence lines are always literally present here regardless
of whether real fontification hid them (see `expose-action-buffer-mode'
above, and its `markdown-markup' invisibility spec) -- a raw
`invisible' property never actually deletes text -- so this works the
same whether or not `markdown-mode' was available to render with, and
does not need it either."

  (save-excursion
    (goto-char (point-min))
    (let (blocks)
      (while (re-search-forward "^```[[:alnum:]_+-]*[ \t]*$" nil t)
        (let ((content-start (progn (forward-line 1) (point))))
          (if (re-search-forward "^```[ \t]*$" nil t)
              (progn
                (push (cons content-start (match-beginning 0)) blocks)
                (goto-char (match-end 0)))
            ;; An unterminated fence: stop, rather than treat the rest
            ;; of the buffer as if it were still inside a block.
            (goto-char (point-max)))))
      (nreverse blocks))))

(defun expose-action-buffer-code-block-bounds-at (blocks pos)
  "Return the element of BLOCKS containing POS, or nil."

  (cl-loop for bounds in blocks
           when (and (>= pos (car bounds)) (<= pos (cdr bounds)))
           return bounds))

(defun expose-action-buffer-copy ()
  "Copy the whole action buffer to the kill ring."

  (interactive)

  (kill-new (buffer-substring-no-properties (point-min) (point-max)))
  (message "Expose action buffer copied"))

(defun expose-action-buffer-copy-code-at-point ()
  "Copy the fenced code block at point to the kill ring.

If point is not inside a code block but the buffer contains exactly
one, copies that one instead: most single-action results (Fix,
Refactor, a Region Review item) carry exactly one snippet, and
requiring point to sit inside it first would be friction for no real
benefit. With more than one and point outside all of them, this says so
rather than guessing which one you meant."

  (interactive)

  (let* ((blocks (expose-action-buffer-code-blocks))
         (bounds
          (or (expose-action-buffer-code-block-bounds-at blocks (point))
              (and (= 1 (length blocks)) (car blocks)))))

    (cond
     (bounds
      (kill-new (buffer-substring-no-properties (car bounds) (cdr bounds)))
      (message "Code block copied"))

     (blocks
      (message
       "Point is not in a code block (%d in this buffer) -- move point into one first"
       (length blocks)))

     (t
      (message "No code block in this buffer")))))

;;; ---------------------------------------------------------------------------
;;; Keymap
;;; ---------------------------------------------------------------------------
;;
;; This buffer should still feel like a normal Evil-readable buffer:
;; motion, search, and visual-selection yank all work exactly as they
;; do anywhere else. Only two keys are added, and only in Normal state
;; (Visual state's own `y' -- yanking a selection you made yourself --
;; is untouched): `y' and `c' as pending operators have nothing to act
;; on in a read-only buffer without a following edit, so repurposing
;; them here costs nothing real. `y' for the common case (copy
;; everything), `c' for the one this feature was actually asked for
;; (copy just the code).

(with-eval-after-load 'evil
  (evil-define-key* 'normal expose-action-buffer-mode-map
    (kbd "y") #'expose-action-buffer-copy
    (kbd "c") #'expose-action-buffer-copy-code-at-point
    (kbd "q") #'quit-window)

  (evil-define-key* 'motion expose-action-buffer-mode-map
    (kbd "y") #'expose-action-buffer-copy
    (kbd "c") #'expose-action-buffer-copy-code-at-point
    (kbd "q") #'quit-window)

  (evil-set-initial-state 'expose-action-buffer-mode 'normal))

(provide 'expose-action-buffer)
