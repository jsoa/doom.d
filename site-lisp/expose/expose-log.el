;;; expose-log.el -*- lexical-binding: t; -*-

(defgroup expose-log nil
  "Logging for Expose."
  :group 'tools)

(defcustom expose-log-enabled t
  "Whether Expose logging is enabled."
  :type 'boolean
  :group 'expose-log)

(defconst expose-log-buffer-name
  "*EXPOSE Log*")

(defun expose-log-buffer ()
  "Return the Expose log buffer."

  (let ((buffer
         (get-buffer-create expose-log-buffer-name)))

    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)))

    buffer))

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

        (insert "\n")))))

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
