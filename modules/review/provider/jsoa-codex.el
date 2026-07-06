;;; modules/review/provider/jsoa-codex.el -*- lexical-binding: t; -*-

(defcustom jsoa-provider-codex-command
  "codex"
  "Path to the Codex executable."
  :type 'string
  :group 'jsoa)

(defcustom jsoa-provider-codex-arguments
  '("exec" "--skip-git-repo-check")
  "Arguments passed to the Codex executable."
  :type '(repeat string)
  :group 'jsoa)

(defun jsoa-provider-codex-version ()
  (interactive)

  (with-temp-buffer
    (call-process
     "codex"
     nil
     t
     nil
     "--version")

    (buffer-string)))

(defun jsoa-provider-codex-send (document)
  "Send DOCUMENT to Codex and return the assistant response."

  (let ((output
         (make-temp-file "jsoa-codex-")))

    (unwind-protect

        (with-temp-buffer

          (insert document)

          (call-process-region
           (point-min)
           (point-max)
           "codex"
           t
           nil
           nil
           "exec"
           "--skip-git-repo-check"
           "--output-last-message"
           output)

          (with-temp-buffer
            (insert-file-contents output)
            (buffer-string)))

      (ignore-errors
        (delete-file output)))))

(defun jsoa-provider-codex-send-async (document callback)
  "Send DOCUMENT to Codex asynchronously."

  (let ((output
         (make-temp-file "jsoa-codex-"))

        process)

    (setq process

          (make-process

           :name "jsoa-codex"

           :command
           (append
            (list jsoa-provider-codex-command)
            jsoa-provider-codex-arguments
            (list
             "--output-last-message"
             output))

           :connection-type 'pipe

           :buffer nil

           :sentinel

           (lambda (_process event)

             (when (string= event "finished\n")

               (unwind-protect

                   (with-temp-buffer

                     (insert-file-contents output)

                     (funcall
                      callback
                      (buffer-string)))

                 (ignore-errors
                   (delete-file output)))))))

    (process-send-string
     process
     document)

    (process-send-eof process)))

(defun jsoa-provider-codex-test ()
  (interactive)

  (pp

   (jsoa-provider-codex-send
    "Say hello in one sentence.")

   (get-buffer-create "*JSOA Codex*"))

  (pop-to-buffer "*JSOA Codex*"))


(provide 'jsoa-codex)
