;;; expose-codex.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'markdown-mode)
(require 'expose-log)

(defcustom expose-provider-codex-command
  "codex"
  "Path to the Codex executable."
  :type 'string
  :group 'expose)

(defcustom expose-provider-codex-arguments
  '("exec" "--skip-git-repo-check")
  "Arguments passed to the Codex executable."
  :type '(repeat string)
  :group 'expose)

(defun expose-provider-codex-version ()
  "Return the installed Codex version."

  (interactive)

  (with-temp-buffer
    (call-process
     expose-provider-codex-command
     nil
     t
     nil
     "--version")

    (buffer-string)))

(defun expose-provider-codex-command-line (output)
  "Build the Codex command line using OUTPUT as the output file."

  (append
   (list expose-provider-codex-command)
   expose-provider-codex-arguments
   (list "--output-last-message" output)))

(defun expose-provider-codex-read-file (file)
  "Return the contents of FILE."

  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun expose-provider-codex-process-output (process)
  "Return PROCESS buffer output."

  (when-let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-string)))))

(defun expose-provider-codex-render (text)
  "Render Codex markdown TEXT."

  (with-temp-buffer
    (insert text)
    (markdown-mode)
    (font-lock-ensure)
    (buffer-string)))

(defun expose-provider-codex-render-error (message)
  "Render Codex error MESSAGE."

  (expose-provider-codex-render
   (format "# Codex Error\n\n%s" message)))

(defun expose-provider-codex-send (document)
  "Send DOCUMENT to Codex and return the rendered assistant response."

  (let ((output
         (make-temp-file "expose-codex-")))

    (unwind-protect
        (with-temp-buffer
          (insert document)

          (let ((status
                 (apply
                  #'call-process-region
                  (point-min)
                  (point-max)
                  expose-provider-codex-command
                  t
                  nil
                  nil
                  (append
                   expose-provider-codex-arguments
                   (list "--output-last-message" output)))))

            (if (= status 0)
                (expose-provider-codex-render
                 (expose-provider-codex-read-file output))

              (expose-provider-codex-render-error
               (format "Codex exited with status %d." status)))))

      (ignore-errors
        (delete-file output)))))

(defun expose-provider-codex-send-async (document callback)
  "Send DOCUMENT to Codex asynchronously, then call CALLBACK with a rendered view."

  (let ((output
         (make-temp-file "expose-codex-"))

        (process-buffer
         (generate-new-buffer " *expose-codex*"))

        process)

    (expose-log
     "Codex"
     "Creating process.")

    (setq process
          (make-process
           :name "expose-codex"
           :command (expose-provider-codex-command-line output)
           :connection-type 'pipe
           :buffer process-buffer
           :sentinel
           (lambda (process event)
             (expose-provider-codex-sentinel
              process
              event
              output
              callback))))

    (expose-log
     "Codex"
     "Process started (pid=%s)."
     (process-id process))

    (expose-log
     "Codex"
     "Sending %d bytes."
     (length document))

    (process-send-string process document)

    (expose-log
     "Codex"
     "Sending EOF.")

    (process-send-eof process)))

(defun expose-provider-codex-sentinel (process event output callback)
  "Handle Codex PROCESS EVENT, read OUTPUT, and call CALLBACK."

  (when (memq (process-status process) '(exit signal))

    (let ((event-name
           (string-trim event))

          (status
           (process-exit-status process)))

      (expose-log
       "Codex"
       "Sentinel: %s"
       event-name)

      (expose-log
       "Codex"
       "Exit status: %d"
       status)

      (unwind-protect
          (if (= status 0)
              (progn
                (expose-log
                 "Codex"
                 "Reading output file.")

                (let ((text
                       (expose-provider-codex-read-file output)))

                  (expose-log
                   "Codex"
                   "Read %d bytes."
                   (length text))

                  (expose-log
                   "Codex"
                   "Invoking callback.")

                  (funcall
                   callback
                   (expose-provider-codex-render text))

                  (expose-log
                   "Codex"
                   "Callback returned.")))

            (let ((message
                   (or
                    (expose-provider-codex-process-output process)
                    (format "Codex exited with status %d." status))))

              (expose-log
               "Codex"
               "Process failed.")

              (expose-log
               "Codex"
               "Process output:\n%s"
               message)

              (funcall
               callback
               (expose-provider-codex-render-error message))))

        (ignore-errors
          (delete-file output))

        (when-let ((buffer (process-buffer process)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(provide 'expose-codex)
