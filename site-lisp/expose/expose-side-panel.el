;;; expose-side-panel.el -*- lexical-binding: t; -*-

;;; Placing a persistent result buffer next to the buffer that produced
;;; it, instead of taking over the window it was invoked from -- the
;;; window-arrangement half of `expose-action-buffer', extracted so
;;; other persistent, non-hover displays (Full Review's dashboard) can
;;; get the same treatment without duplicating it.
;;;
;;; The placement rule: the buffer something was invoked from always
;;; ends up on the left, wherever it started, and the result always
;;; ends up in whatever window is immediately to its right -- created
;;; by splitting if none exists. Re-derived fresh every time rather
;;; than tracked as state, which makes it self-correcting: close the
;;; result window, rearrange your frame, invoke this from a different
;;; buffer entirely, and the next call still lands in the right place
;;; without needing to know what happened since the last one.

(defun expose-side-panel-live-window (window)
  "Return WINDOW if it is still live, otherwise the selected window.

A captured SOURCE-WINDOW can go stale between when an asynchronous
request starts and when its response arrives, or simply between one
call and the next -- callers should not each carry their own copy of
this fallback to drift out of sync with each other."

  (if (window-live-p window) window (selected-window)))

(defun expose-side-panel-place (source-window target-buffer)
  "Arrange SOURCE-WINDOW and TARGET-BUFFER as left/right panes.

Returns the window now showing TARGET-BUFFER.

SOURCE-WINDOW -- the window whose buffer this result is about -- always
ends up on the left, wherever it started. TARGET-BUFFER always ends up
immediately to its right.

Three shapes this actually has to handle, matching how this gets used
in practice: one buffer open (split, the source buffer keeps the
original window), two buffers with the source one on the left (the
right pane becomes the result, whatever it held before), and two
buffers with the source one on the right (it moves left, displacing
whatever was there, and its own former window becomes the result
pane). Beyond two side-by-side windows this still does something
reasonable -- act on whatever window is already to the right, or split
if none -- but is not trying to solve arbitrary N-window layouts;
nothing that uses this asked for that.

Falls back to the selected window if SOURCE-WINDOW is no longer live --
the caller may have captured it well before this runs, at the start of
an asynchronous request, and the window can be closed by the time the
response comes back. Checked here rather than left only to the caller:
this function's own use of `window-in-direction' signals on a dead
window, so skipping the check here is a trap the next caller could fall
into just as easily as the first one already did once."

  (let* ((source-window (expose-side-panel-live-window source-window))
         (source-buffer (window-buffer source-window))
         (right (window-in-direction 'right source-window))
         (left (window-in-direction 'left source-window)))

    (cond
     (right
      (set-window-buffer right target-buffer)
      right)

     (left
      (set-window-buffer left source-buffer)
      (set-window-buffer source-window target-buffer)
      source-window)

     (t
      (let ((new-window (split-window source-window nil 'right)))
        (set-window-buffer new-window target-buffer)
        new-window)))))

(provide 'expose-side-panel)
