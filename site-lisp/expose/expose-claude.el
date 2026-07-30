;;; expose-claude.el -*- lexical-binding: t; -*-

(require 'ansi-color)
(require 'subr-x)
(require 'expose-log)
(require 'markdown-mode nil t)

(defgroup expose-provider-claude nil
  "Claude Code provider for Expose."
  :group 'expose)

(defcustom expose-provider-claude-command "claude"
  "Claude Code CLI executable used by Expose."

  :type 'string
  :group 'expose-provider-claude)

(defcustom expose-provider-claude-arguments
  '("-p" "--permission-mode" "plan")
  "Arguments passed to the Claude Code CLI.

Expose sends the request document to stdin and reads the final answer from
stdout, so this should include whatever flags your Claude Code CLI needs for
non-interactive use (print mode) plus a restriction on tool use, since Expose
already embeds all relevant context in the request document and does not
expect the provider to read or modify the project itself.

\"-p\" is Claude Code's print/non-interactive mode. \"--permission-mode plan\"
is the closest documented flag for keeping the call read/analysis-only; if
your installed CLI version exposes a more precise way to disable tool use
entirely (e.g. \"--disallowedTools\"), adjust this to match. Run
`M-x expose-provider-claude-version' or check \"claude --help\" to verify
against your installed version."

  :type '(repeat string)
  :group 'expose-provider-claude)

(defcustom expose-provider-claude-error-buffer-name
  " *expose-claude-error*"
  "Buffer name used for Claude Code provider stderr."

  :type 'string
  :group 'expose-provider-claude)

;;; ---------------------------------------------------------------------------
;;; Command
;;; ---------------------------------------------------------------------------

(defun expose-provider-claude-command-line ()
  "Return the Claude Code CLI command line."

  (unless (executable-find expose-provider-claude-command)
    (error
     "Could not find Claude Code CLI executable: %s"
     expose-provider-claude-command))

  (cons
   expose-provider-claude-command
   expose-provider-claude-arguments))

(defun expose-provider-claude-version ()
  "Show Claude Code CLI version/help output."

  (interactive)

  (let ((buffer
         (get-buffer-create "*EXPOSE Claude Version*")))

    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)

      (let ((status
             (call-process
              expose-provider-claude-command
              nil
              buffer
              nil
              "--version")))

        (unless (= status 0)
          (erase-buffer)

          (call-process
           expose-provider-claude-command
           nil
           buffer
           nil
           "--help")))

      (goto-char (point-min))
      (setq buffer-read-only t))

    (pop-to-buffer buffer)))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun expose-provider-claude-render-markdown (text)
  "Render TEXT as Markdown for popup display."

  (if (not (fboundp 'markdown-mode))

      text

    (with-temp-buffer

      (delay-mode-hooks
        (markdown-mode))

      (font-lock-mode 1)

      (insert text)

      (font-lock-ensure)

      (buffer-string))))

(defun expose-provider-claude-strip-ansi (text)
  "Strip ANSI escape sequences from TEXT."

  (ansi-color-filter-apply
   (or text "")))

(defun expose-provider-claude-normalize-output (text)
  "Normalize Claude Code CLI output TEXT."

  (string-trim
   (replace-regexp-in-string
    "\r"
    ""
    (expose-provider-claude-strip-ansi text))))

(defun expose-provider-claude-render-error (title details)
  "Return a Markdown error response with TITLE and DETAILS."

  (format
   "## %s\n\n```text\n%s\n```"
   title
   (string-trim
    (or details ""))))

(defun expose-provider-claude-render-response (response)
  "Render Claude Code RESPONSE for popup display."

  (let ((cleaned
         (expose-provider-claude-normalize-output response)))

    (if (string-empty-p cleaned)

        (expose-provider-claude-render-error
         "Claude Code Error"
         "Claude Code CLI exited successfully but produced no output.")

      (expose-provider-claude-render-markdown cleaned))))

(defun expose-provider-claude-buffer-string (buffer)
  "Return BUFFER contents, or an empty string."

  (if (buffer-live-p buffer)

      (with-current-buffer buffer
        (buffer-string))

    ""))

;;; ---------------------------------------------------------------------------
;;; Sync
;;; ---------------------------------------------------------------------------

(defun expose-provider-claude-send (document)
  "Send DOCUMENT to Claude Code CLI synchronously."

  (expose-log
   "Claude"
   "Sending %d bytes synchronously."
   (length document))

  (let ((error-buffer
         (get-buffer-create expose-provider-claude-error-buffer-name)))

    (with-current-buffer error-buffer
      (erase-buffer))

    (with-temp-buffer
      (insert document)

      (let ((status
             (apply
              #'call-process-region
              (point-min)
              (point-max)
              expose-provider-claude-command
              nil
              (list t error-buffer)
              nil
              expose-provider-claude-arguments)))

        (if (= status 0)

            (expose-provider-claude-render-response
             (buffer-string))

          (expose-provider-claude-render-error
           "Claude Code Error"
           (format
            "Claude Code CLI exited with status %s.\n\nstdout:\n%s\n\nstderr:\n%s"
            status
            (buffer-string)
            (expose-provider-claude-buffer-string error-buffer))))))))

;;; ---------------------------------------------------------------------------
;;; Async
;;; ---------------------------------------------------------------------------

(defun expose-provider-claude-send-async (document callback)
  "Send DOCUMENT to Claude Code CLI asynchronously and call CALLBACK."

  (expose-log
   "Claude"
   "Sending %d bytes asynchronously."
   (length document))

  (condition-case error

      (let* ((output-buffer
              (generate-new-buffer " *expose-claude-output*"))

             (error-buffer
              (generate-new-buffer " *expose-claude-error*"))

             (process
              (make-process
               :name "expose-claude"
               :buffer output-buffer
               :stderr error-buffer
               :command (expose-provider-claude-command-line)
               :connection-type 'pipe
               :noquery t
               :sentinel
               (lambda (process _event)

                 (when (memq
                        (process-status process)
                        '(exit signal))

                   (let* ((status
                           (process-exit-status process))

                          (stdout
                           (expose-provider-claude-buffer-string
                            output-buffer))

                          (stderr
                           (expose-provider-claude-buffer-string
                            error-buffer))

                          (response
                           (if (= status 0)

                               (expose-provider-claude-render-response
                                stdout)

                             (expose-provider-claude-render-error
                              "Claude Code Error"
                              (format
                               "Claude Code CLI exited with status %s.\n\nstdout:\n%s\n\nstderr:\n%s"
                               status
                               stdout
                               stderr)))))

                     (expose-log
                      "Claude"
                      "Claude Code CLI exited with status %s."
                      status)

                     (when (buffer-live-p output-buffer)
                       (kill-buffer output-buffer))

                     (when (buffer-live-p error-buffer)
                       (kill-buffer error-buffer))

                     (funcall callback response)))))))

        (process-send-string
         process
         document)

        (process-send-eof
         process))

    (error
     (funcall
      callback
      (expose-provider-claude-render-error
       "Claude Code Error"
       (error-message-string error))))))

(provide 'expose-claude)
