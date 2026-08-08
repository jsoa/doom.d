;;; modules/+python.el -*- lexical-binding: t; -*-

;;
;; Python mode
;;

(require 'cl-lib)
(require 'thingatpt)
(require 'xref)

;;; ---------------------------------------------------------------------------
;;; Remote jump-to-definition into a Docker container's site-packages
;;;
;;; Two ways to resolve the target, tried in order:
;;;
;;; 1. Reuse the local buffer's own `+lookup/definition' (LSP/xref) when it
;;;    can resolve the symbol at all -- even from a local venv that's out of
;;;    sync with (or unrelated to) what the container actually runs, since
;;;    this only needs the *relative path within* `site-packages' to match,
;;;    not the whole environment. This also covers attributes/variables
;;;    whose type was only ever inferred, not directly imported by name,
;;;    which plain text scanning has no way to resolve on its own.
;;;
;;; 2. Fall back to scanning the buffer's own import statements as plain
;;;    text when the local buffer has nothing to resolve against at all
;;;    (nothing installed locally for this import) -- there's no local jump
;;;    target to redirect in that case, since `+lookup/definition' never
;;;    found one in the first place.
;;;
;;; Either way, the final open happens via TRAMP's Docker method, into a
;;; configured site-packages root inside the container.
;;; ---------------------------------------------------------------------------

(defvar-local jsoa/docker-jump-container nil
  "Docker container to jump into for `jsoa/docker-jump-to-definition'.

Set via `.dir-locals.el' for the project -- e.g.:

  ((python-base-mode
    . ((jsoa/docker-jump-container . \"myproject-app-1\")
       (jsoa/docker-jump-site-packages . \"/usr/local/lib/python3.11/site-packages\"))))

`python-base-mode', not `python-mode': `python-mode' and
`python-ts-mode' are siblings, not parent/child, so a `python-mode'
entry would silently never apply to `python-ts-mode' buffers (or vice
versa) -- `python-base-mode' is the actual shared parent of both.")

(defvar-local jsoa/docker-jump-site-packages nil
  "Absolute site-packages path inside `jsoa/docker-jump-container'.

See `jsoa/docker-jump-container' for how to set both via `.dir-locals.el'.")

(defun jsoa/docker-jump--imported-module (name)
  "Return a plist describing the import statement in the current buffer
that binds NAME, or nil if none is found.

Plist keys: :full, the dotted module path to try first; :parent, the
`from X import ...' module X's own dotted path when NAME came from
there (nil for a plain `import X' match, where there's no such
ambiguity) -- see `jsoa/docker-jump--candidate-paths'.

Only recognizes single-line `import X[.Y] [as N]' and `from X import
A, B [as N]' statements; parenthesized multi-line imports are not
handled."

  (save-excursion
    (goto-char (point-min))

    (or
     (cl-loop
      while (re-search-forward
             "^[ \t]*from[ \t]+\\([A-Za-z_][A-Za-z0-9_.]*\\)[ \t]+import[ \t]+\\(.+\\)$"
             nil t)

      thereis
      (let ((module (match-string 1))
            (specs (split-string (match-string 2) "[ \t]*,[ \t]*" t)))

        (cl-loop
         for spec in specs
         thereis
         (let* ((parts (split-string spec "[ \t]+as[ \t]+"))
                (real (string-trim (car parts)))
                (bound (string-trim (or (cadr parts) real))))

           (when (string= bound name)
             (list :full (concat module "." real) :parent module))))))

     (progn
       (goto-char (point-min))

       (cl-loop
        while (re-search-forward
               "^[ \t]*import[ \t]+\\([A-Za-z_][A-Za-z0-9_.]*\\)\\(?:[ \t]+as[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)\\)?[ \t]*$"
               nil t)

        thereis
        (let* ((module (match-string 1))
               (alias (match-string 2))
               (bound (or alias (car (split-string module "\\.")))))

          (when (string= bound name)
            (list :full module :parent nil))))))))

(defun jsoa/docker-jump--candidate-paths (module parent)
  "Return an ordered list of plausible file paths for MODULE under
`jsoa/docker-jump-site-packages', most to least likely.

PARENT, if non-nil (only set for `from X import Y' targets), is X's
own dotted path -- included as a fallback, since Y might just be a
name defined in X's own package rather than a genuine submodule."

  (let* ((root
          (directory-file-name jsoa/docker-jump-site-packages))

         (module-path
          (mapconcat #'identity (split-string module "\\.") "/")))

    (append
     (list
      (format "%s/%s.py" root module-path)
      (format "%s/%s/__init__.py" root module-path))

     (when parent
       (let ((parent-path
              (mapconcat #'identity (split-string parent "\\.") "/")))

         (list
          (format "%s/%s.py" root parent-path)
          (format "%s/%s/__init__.py" root parent-path)))))))

(defun jsoa/docker-jump--site-packages-relative-path (path)
  "Return PATH's sub-path following its `site-packages' directory
component, or nil if PATH has no such component.

Works regardless of where the local venv or system install actually
lives -- `site-packages' is a near-universal path segment for
installed Python packages, so this doesn't need its own root
configured or detected separately from `jsoa/docker-jump-site-packages'."

  (let* ((parts
          (split-string path "/" t))

         (pos
          (cl-position "site-packages" parts :test #'string=)))

    (when pos
      (mapconcat #'identity (nthcdr (1+ pos) parts) "/"))))

(defun jsoa/docker-jump--container-running-p (container)
  "Return non-nil if Docker container CONTAINER is running.

A fast, local `docker inspect' call -- entirely independent of TRAMP,
so a stopped or nonexistent container is detected immediately instead
of waiting out TRAMP's own, much longer connection timeout (tens of
seconds) the first time a jump tries to reach it."

  (with-temp-buffer
    (and
     (zerop
      (call-process "docker" nil t nil "inspect" "-f" "{{.State.Running}}" container))
     (string-prefix-p "true" (string-trim (buffer-string))))))

(defun jsoa/docker-jump--via-import-scan ()
  "Resolve and open the module at point inside `jsoa/docker-jump-container'
from the plain text of an import statement.

Fallback used by `jsoa/docker-jump-to-definition' when the local
buffer has nothing to resolve the symbol against at all -- not from
LSP/type resolution, which has nothing to work with in that case
either. Falls back further to prompting for a dotted module path
directly when no matching import is found."

  (let* ((symbol
          (thing-at-point 'symbol t))

         (found
          (and symbol
               (jsoa/docker-jump--imported-module symbol)))

         (module
          (or (plist-get found :full)
              (read-string "Module (dotted path, e.g. requests.adapters): ")))

         (parent
          (plist-get found :parent))

         (candidates
          (jsoa/docker-jump--candidate-paths module parent))

         (found-path
          (cl-find-if
           (lambda (path)
             (file-exists-p
              (format "/docker:%s:%s" jsoa/docker-jump-container path)))
           candidates)))

    (if found-path
        (progn
          (xref-push-marker-stack)
          (find-file
           (format "/docker:%s:%s" jsoa/docker-jump-container found-path)))

      (user-error
       "No file found for `%s' in %s -- tried: %s"
       module
       jsoa/docker-jump-container
       (string-join candidates ", ")))))

;;;###autoload
(defun jsoa/docker-jump-to-definition ()
  "Jump to the definition of the symbol at point -- ordinary
`+lookup/definition' if `jsoa/docker-jump-container' and
`jsoa/docker-jump-site-packages' aren't set for this buffer (so this
is safe to bind over `gd' unconditionally, not just in
docker-jump-configured projects), otherwise via
`jsoa/docker-jump-container's TRAMP Docker connection when the target
turns out to be a dependency rather than local code. When configured,
checks `jsoa/docker-jump--container-running-p' first and fails with a
clear message if the container's down, rather than silently paying
TRAMP's own, much longer connection timeout first.

Tries `+lookup/definition' first, so a local venv's real type-aware
resolution is used whenever there is one -- even one out of sync with
the container, since only the relative path within `site-packages'
needs to match, not the whole environment. If that lands inside a
`site-packages' directory, the sub-path following it is opened at the
equivalent location inside `jsoa/docker-jump-container' instead of the
local copy -- note that this assumes the local and container copies
of a package are laid out the same way, which is usually but not
guaranteedly true; a real version mismatch between them can point this
at the wrong (or a missing) file. If it instead lands inside local
project code, that's left alone. If `+lookup/definition' can't resolve
the symbol locally at all (nothing installed locally for this import),
falls back to `jsoa/docker-jump--via-import-scan', which works from
the plain text of an import statement instead -- but only when
container/site-packages are actually configured; otherwise this
behaves exactly like plain `+lookup/definition' always has."

  (interactive)

  ;; Captured before `+lookup/definition' runs (rather than left as buffer-
  ;; local reads below): a successful jump switches to the target buffer,
  ;; where they'd otherwise read back unset (or some *other* project's
  ;; values) rather than this buffer's own configured container/site-packages.
  (let ((container jsoa/docker-jump-container)
        (site-packages jsoa/docker-jump-site-packages))

    (if (not (and container site-packages))
        ;; Not configured for this buffer/project -- exactly plain
        ;; `+lookup/definition', including its own error on failure.
        (call-interactively #'+lookup/definition)

      (unless (jsoa/docker-jump--container-running-p container)
        (user-error "Docker container `%s' is not running" container))

      (let ((local-jump-failed
             (condition-case nil
                 (progn (call-interactively #'+lookup/definition) nil)
               (user-error t))))

        (if local-jump-failed
            (jsoa/docker-jump--via-import-scan)

          (when-let* ((local-file
                       (buffer-file-name))

                      (relative
                       (jsoa/docker-jump--site-packages-relative-path local-file)))

            (find-file
             (format "/docker:%s:%s/%s"
                     container
                     (directory-file-name site-packages)
                     relative))))))))

(map! :map python-base-mode-map
      :n "gd" #'jsoa/docker-jump-to-definition
      :localleader
      :desc "Jump to definition (Docker)" "j" #'jsoa/docker-jump-to-definition)
