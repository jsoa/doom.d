;;; modules/+private.el -*- lexical-binding: t; -*-

(defconst js/private-doom-directory
  (expand-file-name
   ".doom-private/"
   (file-name-directory
    (directory-file-name doom-user-dir)))
  "Directory containing the optional private Doom configuration.")

(defun js/load-private-doom-config ()
  "Load the private Doom configuration when available."
  (let ((private-config
         (expand-file-name
          "config.el"
          js/private-doom-directory)))
    (when (file-readable-p private-config)
      (load private-config nil nil))))

(js/load-private-doom-config)
