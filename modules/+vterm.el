;;; +vterm.el -*- lexical-binding: t; -*-

(defun jsoa/project-vterm ()
  (interactive)
  (let* ((project-root
          (if-let ((proj (project-current)))
              (project-root proj)
            default-directory))
         (project-name
          (file-name-nondirectory
           (directory-file-name project-root)))
         (buffer-name
          (format "*vterm:%s*" project-name)))

    (if-let ((buf (get-buffer buffer-name)))
        (pop-to-buffer buf)
      (let ((default-directory project-root))
        (vterm buffer-name)))))

(defun jsoa/kill-project-vterm ()
  (interactive)
  (let* ((project-root
          (if-let ((proj (project-current)))
              (project-root proj)
            default-directory))
         (project-name
          (file-name-nondirectory
           (directory-file-name project-root)))
         (buffer-name
          (format "*vterm:%s*" project-name)))

    (when-let ((buf (get-buffer buffer-name)))
      (kill-buffer buf)
      (message "Killed %s" buffer-name))))

(after! vterm
  (setq vterm-kill-buffer-on-exit nil))

(map! :leader
      (:prefix ("o" . "open")
       :desc "Project VTerm"      "c" #'jsoa/project-vterm
       :desc "Kill Project VTerm" "C" #'jsoa/kill-project-vterm))
