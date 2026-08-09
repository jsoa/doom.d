;;; +env.el -*- lexical-binding: t; -*-

(require 'seq)
(require 'subr-x)

(defun jsoa/prepend-path (dir)
  "Prepend DIR to PATH and `exec-path' if it exists.

Both are guarded against re-adding DIR: this runs again on every
`doom/reload', and only `exec-path' used to be checked, so PATH grew
another copy of the same directory each time."
  (when (file-directory-p dir)
    (unless (member dir exec-path)
      (add-to-list 'exec-path dir))

    (let ((path (or (getenv "PATH") "")))
      (unless (member dir (split-string path path-separator t))
        (setenv "PATH" (concat dir path-separator path))))))

(defun jsoa/setup-node-path-nvm-async ()
  "Resolve NVM's active `npx' directory asynchronously and prepend it.

Sourcing `nvm.sh' to resolve the active Node version is slow -- often
several hundred milliseconds or more -- and this previously ran via a
synchronous `shell-command-to-string' at startup, blocking all of
Emacs for however long that took on every single launch (the same
class of bug `du -sh .' was in the project dashboard). Using
`make-process' instead means startup itself never waits on it: nothing
that actually needs `npx'/`node' on PATH (LSP servers, Prettier, etc.)
runs until well after startup finishes, once a relevant buffer is
opened."

  (make-process
   :name "jsoa-nvm-npx"
   :buffer (generate-new-buffer " *jsoa-nvm-npx*")
   :command
   (list shell-file-name shell-command-switch
         (format "%s -lc 'source ~/.nvm/nvm.sh >/dev/null 2>&1 && command -v npx'"
                 shell-file-name))
   :noquery t
   :sentinel
   (lambda (process _event)
     (when (memq (process-status process) '(exit signal))
       (let ((npx
              (string-trim
               (with-current-buffer (process-buffer process)
                 (buffer-string)))))
         (kill-buffer (process-buffer process))

         (unless (string-empty-p npx)
           (jsoa/prepend-path (file-name-directory npx))
           (message "Node (NVM): %s" npx)))))))

(defun jsoa/setup-node-path ()
  "Configure Node.js for the current platform."

  (cond

   ;; ------------------------------------------------------------
   ;; NVM (Linux or macOS)
   ;; ------------------------------------------------------------
   ((file-directory-p (expand-file-name "~/.nvm"))
    (jsoa/setup-node-path-nvm-async))

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
