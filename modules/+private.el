;;; modules/+private.el -*- lexical-binding: t; -*-

;;; modules/+private.el -*- lexical-binding: t; -*-

(require 'seq)

(defconst js/private-doom-directory-candidates
  (delq
   nil
   (list
    ;; Explicit override. Best for weird machine-specific layouts.
    (getenv "DOOM_PRIVATE_DIR")

    ;; Current behavior: sibling of `doom-user-dir`.
    ;; Example:
    ;;   ~/.doom-config/      -> ~/.doom-private/
    ;;   ~/.config/doom.d/    -> ~/.config/.doom-private/
    (expand-file-name
     ".doom-private/"
     (file-name-directory
      (directory-file-name doom-user-dir)))

    ;; Common home-level private config.
    (expand-file-name "~/.doom-private/")

    ;; Common .config layouts.
    (expand-file-name "~/.config/.doom-private/")
    (expand-file-name "~/.config/doom-private/")

    ;; Optional non-hidden variants.
    (expand-file-name "~/doom-private/")
    (expand-file-name "~/.config/doom-private/")))
  "Candidate directories containing optional private Doom configuration.")

(defun js/private-doom-directory-valid-p (directory)
  "Return non-nil if DIRECTORY contains a readable private Doom config."

  (and
   directory
   (file-directory-p directory)
   (file-readable-p
    (expand-file-name "config.el" directory))))

(defun js/find-private-doom-directory ()
  "Return the first valid private Doom configuration directory."

  (seq-find
   #'js/private-doom-directory-valid-p
   js/private-doom-directory-candidates))

(defconst js/private-doom-directory
  (when-let ((directory
              (js/find-private-doom-directory)))

    (file-name-as-directory
     (file-truename directory)))
  "Resolved private Doom configuration directory, or nil when unavailable.")

(defun js/load-private-doom-config ()
  "Load the private Doom configuration when available."

  (when js/private-doom-directory
    (load
     (expand-file-name
      "config.el"
      js/private-doom-directory)
     nil
     nil)))

(js/load-private-doom-config)
