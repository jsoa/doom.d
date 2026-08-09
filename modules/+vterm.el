;;; +vterm.el -*- lexical-binding: t; -*-

(require 'project)
(require 'subr-x)

(after! vterm
  (setq vterm-kill-buffer-on-exit nil))

(defun jsoa/project-root ()
  "Return the current project root, or `default-directory'."

  (if-let ((project
            (project-current nil)))

      (project-root project)

    default-directory))

(defun jsoa/vterm-buffer-live-p (buffer)
  "Return non-nil if BUFFER has a live process."

  (when-let ((process
              (get-buffer-process buffer)))

    (process-live-p process)))

(defun jsoa/project-terminal-buffer-name (tool)
  "Return the project vterm buffer name for TOOL.

Keyed on the full project root rather than just its basename, so that
two different projects sharing a directory basename (e.g. ~/work/api
and ~/side/api) don't collide onto the same terminal buffer -- which
would otherwise hand you the *other* project's shell, already `cd'd
somewhere else, and `jsoa/kill-project-terminal' would kill the wrong
one."

  (format
   "*%s:%s*"
   tool
   (abbreviate-file-name
    (directory-file-name
     (jsoa/project-root)))))

(defun jsoa/window-left-right-pair ()
  "Return (LEFT . RIGHT) if the selected frame has exactly two windows
arranged side by side, or nil otherwise (a different count, or two
windows stacked vertically instead)."

  (let ((windows
         (window-list)))

    (when (= (length windows) 2)
      (let ((a (car windows))
            (b (cadr windows)))

        (cond
         ((eq (window-in-direction 'right a) b)
          (cons a b))

         ((eq (window-in-direction 'right b) a)
          (cons b a))

         (t nil))))))

(defun jsoa/display-project-terminal (buffer)
  "Show and select BUFFER in a window to the right of the current one.

With exactly two windows already open side by side, the terminal
always ends up in the right one and whatever you were looking at
always ends up in the left one, regardless of which of the two you
were actually in when this was called -- so switching to the terminal
from the right-hand window swaps the two instead of splitting a third
window off to the right of it (there being nothing further right of
the rightmost window otherwise). With any other window layout, this
reuses or creates a window to the right of the current one instead --
splitting when there's only a single window, matching the two-window
case for any layout more complex than that. Failing that (a frame too
narrow to split at all), BUFFER takes over the current window rather
than erroring.

Reusing an existing window replaces whatever buffer it was showing,
same as the two-window case above; `display-buffer-in-direction' looks
like the built-in tool for that, but its own notion of \"reuse\" only
kicks in when that window already shows this exact BUFFER, splitting
instead of replacing for any other buffer.

Also closes any OTHER window on this frame already showing BUFFER:
creating a vterm buffer runs it through `display-buffer', and Doom's
popup rules (e.g. for terminal-like buffers) can already have placed
it somewhere -- a bottom popup, typically -- before this function gets
a chance to position it, leaving it visible in two places at once
otherwise. Windows on OTHER frames are left alone."

  (let* ((source-window
          (selected-window))

         (source-buffer
          (window-buffer source-window))

         (pair
          (jsoa/window-left-right-pair))

         (window
          (if pair

              (let ((left
                     (car pair))

                    (right
                     (cdr pair)))

                (when (and (eq source-window right)
                           (not (eq source-buffer buffer)))
                  ;; Active on the right window, showing something
                  ;; other than this terminal already -- move it to
                  ;; the left so the terminal can take the right,
                  ;; instead of losing track of it.
                  (set-window-buffer left source-buffer))

                right)

            (or (window-in-direction 'right)

                ;; The frame can be too narrow to split (or already
                ;; split past `window-min-width'), which signals rather
                ;; than returning nil. `jsoa/project-terminal' has
                ;; already created the vterm process by the time it
                ;; calls this, so letting that error propagate would
                ;; leave the terminal orphaned: never displayed, never
                ;; sent its start command, and -- being live -- reused
                ;; by the next invocation, which retries the same
                ;; failing split instead of recreating it. Fall back to
                ;; taking over the current window instead.
                (ignore-errors
                  (split-window-right))

                source-window))))

    (set-window-buffer window buffer)

    ;; Selected frame only (ALL-FRAMES nil, not t): this function
    ;; positions BUFFER relative to the *current* frame's layout, so a
    ;; window showing it on another frame -- e.g. deliberately parked on
    ;; a second monitor -- isn't a stray duplicate to clean up here.
    (dolist (other (get-buffer-window-list buffer nil nil))
      (unless (eq other window)
        (ignore-errors
          (delete-window other))))

    (select-window window)))

(defun jsoa/project-terminal (tool start-command)
  "Open a dedicated vterm terminal running TOOL for the current project.

START-COMMAND is sent once the terminal is ready. An existing live
terminal for TOOL is reused; a dead one is killed and recreated.
Always shown via `jsoa/display-project-terminal'.

Return the terminal buffer."

  (let* ((project-root
          (jsoa/project-root))

         (buffer-name
          (jsoa/project-terminal-buffer-name tool))

         (existing-buffer
          (get-buffer buffer-name)))

    (cond
     ((and existing-buffer
           (jsoa/vterm-buffer-live-p existing-buffer))
      (jsoa/display-project-terminal existing-buffer)
      existing-buffer)

     (existing-buffer
      (kill-buffer existing-buffer)
      (jsoa/project-terminal tool start-command))

     (t
      (let ((default-directory project-root))

        (vterm buffer-name)

        (let ((buffer
               (get-buffer buffer-name)))

          (jsoa/display-project-terminal buffer)

          (run-at-time
           0.25
           nil
           (lambda (buffer command)
             (when (and
                    (buffer-live-p buffer)
                    (jsoa/vterm-buffer-live-p buffer))

               (with-current-buffer buffer
                 (vterm-send-string command)
                 (vterm-send-return))))
           buffer
           start-command)

          buffer))))))

(defun jsoa/kill-project-terminal (tool)
  "Kill the dedicated TOOL vterm terminal for the current project."

  (let ((buffer-name
         (jsoa/project-terminal-buffer-name tool)))

    (if-let ((buffer
              (get-buffer buffer-name)))

        (progn
          (kill-buffer buffer)
          (message "Killed %s" buffer-name))

      (message "No %s buffer found for %s" tool buffer-name))))

;;; ---------------------------------------------------------------------------
;;; Codex
;;; ---------------------------------------------------------------------------

(defun jsoa/project-codex ()
  "Open a dedicated Codex terminal for the current project.

Return the Codex buffer."

  (interactive)

  (jsoa/project-terminal "codex" "codex --no-alt-screen"))

(defun jsoa/kill-project-codex ()
  "Kill the dedicated Codex terminal for the current project."

  (interactive)

  (jsoa/kill-project-terminal "codex"))

;; Claude Code has its own dedicated integration instead of a vterm
;; terminal here -- see modules/+claude-code-ide.el, which gives it real
;; MCP-based Emacs awareness (current buffer, selection, diagnostics)
;; that this vterm setup has no way to provide.

(map! :leader
      :desc "Codex"      "v c" #'jsoa/project-codex
      :desc "Kill Codex" "v C" #'jsoa/kill-project-codex)
