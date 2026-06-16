;;; +vterm.el -*- lexical-binding: t; -*-

(after! vterm
  ;; Keep terminal buffers around after the shell exits.
  (setq vterm-kill-buffer-on-exit nil))

(defun jsoa/project-codex ()
  "Open a dedicated Codex terminal for the current project."
  (interactive)
  (let* ((project-root
          (if-let ((proj (project-current)))
              (project-root proj)
            default-directory))
         (project-name
          (file-name-nondirectory
           (directory-file-name project-root)))
         (buffer-name
          (format "*codex:%s*" project-name)))

    (if-let ((buf (get-buffer buffer-name)))
        (pop-to-buffer buf)
      (let ((default-directory project-root))
        (vterm buffer-name)

        ;; Give vterm a moment to initialize.
        (run-at-time
         0.25 nil
         (lambda ()
           (when-let ((buf (get-buffer buffer-name)))
             (with-current-buffer buf
               (vterm-send-string "codex --no-alt-screen")
               (vterm-send-return)))))))))

(defun jsoa/kill-project-codex ()
  (interactive)
  (let* ((project-root
          (if-let ((proj (project-current)))
              (project-root proj)
            default-directory))
         (project-name
          (file-name-nondirectory
           (directory-file-name project-root)))
         (buffer-name
          (format "*codex:%s*" project-name)))

    (when-let ((buf (get-buffer buffer-name)))
      (kill-buffer buf)
      (message "Killed %s" buffer-name))))

(map! :leader
      (:prefix ("v" . "vterm")
       :desc "Toggle VTerm"      "t" #'+vterm/toggle
       :desc "Project Codex"     "c" #'jsoa/project-codex
       :desc "Kill Codex"        "C" #'jsoa/kill-project-codex))
