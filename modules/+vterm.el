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

(defun jsoa/project-codex-buffer-name ()
  "Return the project Codex vterm buffer name."

  (format
   "*codex:%s*"
   (jsoa/project-name)))

(defun jsoa/project-codex-start-command ()
  "Return the command used to start Codex."

  "codex --no-alt-screen")

(defun jsoa/project-codex ()
  "Open a dedicated Codex terminal for the current project.

Return the Codex buffer."

  (interactive)

  (let* ((project-root
          (jsoa/project-root))

         (buffer-name
          (jsoa/project-codex-buffer-name))

         (existing-buffer
          (get-buffer buffer-name)))

    (cond
     ((and existing-buffer
           (jsoa/vterm-buffer-live-p existing-buffer))
      (pop-to-buffer existing-buffer)
      existing-buffer)

     (existing-buffer
      (kill-buffer existing-buffer)
      (jsoa/project-codex))

     (t
      (let ((default-directory project-root))

        (vterm buffer-name)

        (let ((buffer
               (get-buffer buffer-name)))

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
           (jsoa/project-codex-start-command))

          buffer))))))

(defun jsoa/kill-project-codex ()
  "Kill the dedicated Codex terminal for the current project."

  (interactive)

  (let ((buffer-name
         (jsoa/project-codex-buffer-name)))

    (if-let ((buffer
              (get-buffer buffer-name)))

        (progn
          (kill-buffer buffer)
          (message "Killed %s" buffer-name))

      (message "No Codex buffer found for %s" buffer-name))))

(map! :leader
      :desc "Codex"      "v c" #'jsoa/project-codex
      :desc "Kill Codex" "v C" #'jsoa/kill-project-codex)
