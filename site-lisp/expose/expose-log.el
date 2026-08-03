;;; expose-log.el -*- lexical-binding: t; -*-

(defgroup expose-log nil
  "Logging for Expose."
  :group 'tools)

(defcustom expose-log-enabled t
  "Whether Expose logging is enabled."
  :type 'boolean
  :group 'expose-log)

(defcustom expose-log-max-size nil
  "Maximum size in characters of the Expose log buffer, or nil for no limit.

When non-nil and exceeded, the oldest log lines are trimmed. Defaults to
nil (unbounded) since this buffer is the main way to see what Expose
actually did (provider requests, timeouts, failures) across a
long-running session -- it should keep everything for as long as Emacs
stays open, clearing only via `expose-log-clear' or on restart, not on
its own. Set to an integer to cap it instead."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'expose-log)

(defconst expose-log-buffer-name
  "*EXPOSE Log*")

(defun expose-log-buffer ()
  "Return the Expose log buffer."

  (let ((buffer
         (get-buffer-create expose-log-buffer-name)))

    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)

        ;; This buffer is append-only log output; nobody undoes it, so
        ;; tracking undo history for it is pure waste that would otherwise
        ;; grow right alongside the text itself.
        (setq buffer-undo-list t)))

    buffer))

(defun expose-log-trim-buffer ()
  "Trim the current Expose log buffer to `expose-log-max-size'.

Trims down to 80% of the limit rather than exactly the limit, so trimming
does not have to run again on almost every subsequent log call."

  (when (and expose-log-max-size
             (> (buffer-size) expose-log-max-size))

    (save-excursion
      (goto-char
       (max
        (point-min)
        (-
         (point-max)
         (truncate
          (* expose-log-max-size 0.8)))))

      (beginning-of-line)

      (delete-region (point-min) (point)))))

(defun expose-log (component fmt &rest args)
  "Append a log message for COMPONENT using FMT and ARGS."

  (when expose-log-enabled

    (with-current-buffer
        (expose-log-buffer)

      (let ((inhibit-read-only t))

        (goto-char (point-max))

        (insert
         (format-time-string "[%H:%M:%S] "))

        (insert
         (format "[%-12s] "
                 component))

        (insert
         (apply #'format fmt args))

        (insert "\n")

        (expose-log-trim-buffer)))))

(defun expose-log-open ()
  "Open the EXPOSE log buffer."

  (interactive)

  (pop-to-buffer
   (expose-log-buffer)))

(defun expose-log-clear ()
  "Clear the EXPOSE log buffer."

  (interactive)

  (with-current-buffer
      (expose-log-buffer)

    (let ((inhibit-read-only t))
      (erase-buffer)))

  (message "EXPOSE log cleared"))

(provide 'expose-log)
