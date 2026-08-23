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
  (add-to-invisibility-spec 'markdown-markup))

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
explicitly meant to keep is not a second implementation of it."

  (let ((inhibit-read-only t))
    (erase-buffer)

    (insert
     (propertize (or (plist-get view :title) "Expose") 'face 'bold))

    (when source-buffer
      (insert (propertize (format "  (%s)" source-buffer) 'face 'shadow)))

    (insert "\n")
    (insert (propertize (make-string 60 ?─) 'face 'shadow))
    (insert "\n\n")

    (insert (expose-popup-render-body view))

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

(provide 'expose-action-buffer)
