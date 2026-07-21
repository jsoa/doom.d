;;; modules/+private.el -*- lexical-binding: t; -*-


(defcustom js/private-doom-directory
  (expand-file-name "~/.doom-private/")
  "Directory containing the optional private Doom configuration."
  :type 'directory
  :group 'doom)

(defun js/load-private-doom-config ()
  "Load the private Doom configuration when it is available.

The private repository is expected to contain a machine-local
`config.el' entry point. If the repository or entry point does not
exist, do nothing."
  (let ((private-config
         (expand-file-name
          "config.el"
          js/private-doom-directory)))
    (when (file-readable-p private-config)
      (load private-config nil nil))))

(js/load-private-doom-config)
