;;; +env.el -*- lexical-binding: t; -*-

(require 'seq)
(require 'subr-x)

(defun jsoa/prepend-path (dir)
  "Prepend DIR to PATH and exec-path if it exists."
  (when (file-directory-p dir)
    (unless (member dir exec-path)
      (add-to-list 'exec-path dir))
    (setenv "PATH"
            (concat dir path-separator (getenv "PATH")))))

(defun jsoa/setup-node-path ()
  "Configure Node.js for the current platform."

  (cond

   ;; ------------------------------------------------------------
   ;; NVM (Linux or macOS)
   ;; ------------------------------------------------------------
   ((file-directory-p (expand-file-name "~/.nvm"))
    (when-let* ((npx
                 (string-trim
                  (shell-command-to-string
                   (format "%s -lc 'source ~/.nvm/nvm.sh >/dev/null 2>&1 && command -v npx'"
                           shell-file-name))))
                ((not (string-empty-p npx))))
      (jsoa/prepend-path (file-name-directory npx))
      (message "Node (NVM): %s" npx)))

   ;; ------------------------------------------------------------
   ;; Homebrew (Apple Silicon)
   ;; ------------------------------------------------------------
   ((file-exists-p "/opt/homebrew/bin/node")
    (jsoa/prepend-path "/opt/homebrew/bin")
    (message "Node (Homebrew): /opt/homebrew/bin"))

   ;; ------------------------------------------------------------
   ;; Homebrew (Intel)
   ;; ------------------------------------------------------------
   ((file-exists-p "/usr/local/bin/node")
    (jsoa/prepend-path "/usr/local/bin")
    (message "Node (Homebrew): /usr/local/bin"))))

(jsoa/setup-node-path)
