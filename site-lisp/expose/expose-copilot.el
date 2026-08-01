;;; expose-copilot.el -*- lexical-binding: t; -*-

(require 'ansi-color)
(require 'subr-x)
(require 'expose-log)
(require 'markdown-mode nil t)

(defgroup expose-provider-copilot nil
  "GitHub Copilot provider for Expose."
  :group 'expose)

(defcustom expose-provider-copilot-command "copilot"
  "GitHub Copilot CLI executable used by Expose."

  :type 'string
  :group 'expose-provider-copilot)

(defcustom expose-provider-copilot-arguments '("--silent")
  "Arguments passed to GitHub Copilot CLI.

Expose sends the request document to stdin.

\"--silent\" (\"Output only the agent response (no stats), useful for
scripting\") suppresses the trailing Changes/AI Credits/Tokens/Resume stats
block the Copilot CLI otherwise appends to every response, which Expose has
no use for and which would otherwise leak into rendered popups and any
directly-inserted text (e.g. commit messages)."

  :type '(repeat string)
  :group 'expose-provider-copilot)

;;; ---------------------------------------------------------------------------
;;; Command
;;; ---------------------------------------------------------------------------

(defun expose-provider-copilot-command-line ()
  "Return the GitHub Copilot CLI command line."

  (unless (executable-find expose-provider-copilot-command)
    (error
     "Could not find GitHub Copilot CLI executable: %s"
     expose-provider-copilot-command))

  (cons
   expose-provider-copilot-command
   expose-provider-copilot-arguments))

(defun expose-provider-copilot-version ()
  "Show GitHub Copilot CLI version/help output."

  (interactive)

  (let ((buffer
         (get-buffer-create "*EXPOSE Copilot Version*")))

    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)

      (let ((status
             (call-process
              expose-provider-copilot-command
              nil
              buffer
              nil
              "--version")))

        (unless (= status 0)
          (erase-buffer)

          (call-process
           expose-provider-copilot-command
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

(defun expose-provider-copilot-render-markdown (text)
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

(defun expose-provider-copilot-strip-ansi (text)
  "Strip ANSI escape sequences from TEXT."

  (ansi-color-filter-apply
   (or text "")))

(defun expose-provider-copilot-normalize-output (text)
  "Normalize GitHub Copilot CLI output TEXT."

  (string-trim
   (replace-regexp-in-string
    "\r"
    ""
    (expose-provider-copilot-strip-ansi text))))

(defun expose-provider-copilot-render-error (title details)
  "Return a Markdown error response with TITLE and DETAILS."

  (format
   "## %s\n\n```text\n%s\n```"
   title
   (string-trim
    (or details ""))))

(defun expose-provider-copilot-render-response (response)
  "Render GitHub Copilot RESPONSE for popup display."

  (let ((cleaned
         (expose-provider-copilot-normalize-output response)))

    (if (string-empty-p cleaned)

        (expose-provider-copilot-render-error
         "GitHub Copilot Error"
         "GitHub Copilot CLI exited successfully but produced no output.")

      (expose-provider-copilot-render-markdown cleaned))))

(defun expose-provider-copilot-buffer-string (buffer)
  "Return BUFFER contents, or an empty string."

  (if (buffer-live-p buffer)

      (with-current-buffer buffer
        (buffer-string))

    ""))

(defun expose-provider-copilot-read-file (file)
  "Return the contents of FILE, or an empty string if it is missing."

  (if (file-exists-p file)

      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))

    ""))

;;; ---------------------------------------------------------------------------
;;; Sync
;;; ---------------------------------------------------------------------------

(defun expose-provider-copilot-send (document)
  "Send DOCUMENT to GitHub Copilot CLI synchronously."

  (expose-log
   "Copilot"
   "Sending %d bytes synchronously."
   (length document))

  ;; `call-process-region' only accepts nil/t/a file name as the stderr
  ;; destination in the (REAL-BUFFER STDERR-FILE) form, so stderr has to be
  ;; captured via a temp file rather than a buffer.
  (let ((error-file
         (make-temp-file "expose-copilot-stderr-")))

    (unwind-protect
        (with-temp-buffer
          (insert document)

          (let ((status
                 (apply
                  #'call-process-region
                  (point-min)
                  (point-max)
                  expose-provider-copilot-command
                  t
                  (list t error-file)
                  nil
                  expose-provider-copilot-arguments)))

            (if (= status 0)

                (expose-provider-copilot-render-response
                 (buffer-string))

              (expose-provider-copilot-render-error
               "GitHub Copilot Error"
               (format
                "GitHub Copilot CLI exited with status %s.\n\nstdout:\n%s\n\nstderr:\n%s"
                status
                (buffer-string)
                (expose-provider-copilot-read-file error-file))))))

      (ignore-errors
        (delete-file error-file)))))

;;; ---------------------------------------------------------------------------
;;; Async
;;; ---------------------------------------------------------------------------

(defun expose-provider-copilot-send-async (document callback)
  "Send DOCUMENT to GitHub Copilot CLI asynchronously and call CALLBACK.

Returns the underlying process so callers can terminate it early (e.g. on a
client-side timeout), or nil if the process could not be started."

  (expose-log
   "Copilot"
   "Sending %d bytes asynchronously."
   (length document))

  (condition-case error

      (let* ((output-buffer
              (generate-new-buffer " *expose-copilot-output*"))

             (error-buffer
              (generate-new-buffer " *expose-copilot-error*"))

             (process
              (make-process
               :name "expose-copilot"
               :buffer output-buffer
               :stderr error-buffer
               :command (expose-provider-copilot-command-line)
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
                           (expose-provider-copilot-buffer-string
                            output-buffer))

                          (stderr
                           (expose-provider-copilot-buffer-string
                            error-buffer))

                          (response
                           (if (= status 0)

                               (expose-provider-copilot-render-response
                                stdout)

                             (expose-provider-copilot-render-error
                              "GitHub Copilot Error"
                              (format
                               "GitHub Copilot CLI exited with status %s.\n\nstdout:\n%s\n\nstderr:\n%s"
                               status
                               stdout
                               stderr)))))

                     (expose-log
                      "Copilot"
                      "GitHub Copilot CLI exited with status %s."
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
         process)

        process)

    (error
     (funcall
      callback
      (expose-provider-copilot-render-error
       "GitHub Copilot Error"
       (error-message-string error)))
     nil)))

(provide 'expose-copilot)
