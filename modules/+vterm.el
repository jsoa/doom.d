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

(defun jsoa/project-name ()
  "Return the current project name."

  (file-name-nondirectory
   (directory-file-name
    (jsoa/project-root))))

(defun jsoa/vterm-buffer-live-p (buffer)
  "Return non-nil if BUFFER has a live process."

  (when-let ((process
              (get-buffer-process buffer)))

    (process-live-p process)))

(defun jsoa/project-terminal-buffer-name (tool)
  "Return the project vterm buffer name for TOOL."

  (format
   "*%s:%s*"
   tool
   (jsoa/project-name)))

(defun jsoa/display-project-terminal (buffer)
  "Show and select BUFFER in a window to the right of the current one.

Reuses a window already positioned there -- replacing whatever buffer
it was showing -- instead of creating another split alongside it; only
splits when there is no window to the right yet.

`display-buffer-in-direction' looks like the built-in tool for this,
but its own notion of \"reuse\" only kicks in when that window already
shows this exact BUFFER; for any other buffer it always splits instead
of replacing, which is not what \"replace whatever's already there\"
means here.

Also closes any OTHER window already showing BUFFER: creating a vterm
buffer runs it through `display-buffer', and Doom's popup rules (e.g.
for terminal-like buffers) can already have placed it somewhere -- a
bottom popup, typically -- before this function gets a chance to
position it, leaving it visible in two places at once otherwise."

  (let ((window
         (or (window-in-direction 'right)
             (split-window-right))))

    (set-window-buffer window buffer)

    (dolist (other (get-buffer-window-list buffer nil t))
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

;;; ---------------------------------------------------------------------------
;;; Claude Code
;;; ---------------------------------------------------------------------------

(defun jsoa/project-claude ()
  "Open a dedicated, interactive Claude Code terminal for the current project.

Unlike Expose's Claude provider (a one-shot, non-interactive `-p' call
used by the action lenses and Watch), this is a real conversational
Claude Code CLI session, for when you want to talk to it directly
instead of running a single focused action.

Return the Claude buffer."

  (interactive)

  (jsoa/project-terminal "claude" "claude"))

(defun jsoa/kill-project-claude ()
  "Kill the dedicated Claude Code terminal for the current project."

  (interactive)

  (jsoa/kill-project-terminal "claude"))

(map! :leader
      :desc "Codex"        "v c" #'jsoa/project-codex
      :desc "Kill Codex"   "v C" #'jsoa/kill-project-codex
      :desc "Claude"       "v l" #'jsoa/project-claude
      :desc "Kill Claude"  "v L" #'jsoa/kill-project-claude)
