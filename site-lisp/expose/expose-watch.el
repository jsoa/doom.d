;;; expose-watch.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'expose-log)
(require 'expose-popup)
(require 'expose-provider)
(require 'expose-hover)
(require 'expose-review-request)
(require 'expose-transport)
(require 'expose-redact)
(require 'nerd-icons nil t)


(defgroup expose-watch nil
  "Background watch reviews for changed hunks."
  :group 'expose)

(defcustom expose-watch-show-fringe-markers nil
  "When non-nil, show Expose Watch markers in the right fringe.

This is disabled by default because diagnostics, Git gutters, and other
tools may already use the same fringe space."
  :type 'boolean
  :group 'expose-watch)

(defcustom expose-watch-response-storage-max-length 50000
  "Maximum number of provider response characters stored by Expose Watch.

Set to nil to store full responses."
  :type '(choice integer
          (const :tag "No limit" nil))
  :group 'expose-watch)

(defcustom expose-watch-context-lines 60
  "Number of source context lines included around each changed hunk."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-max-hunks-per-run 4
  "Maximum changed hunks reviewed in one Expose Watch run."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-max-items-per-run 3
  "Maximum findings requested from one Expose Watch run."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-mode-line-icon "nf-fa-eye"
  "Nerd Icons icon name shown when Expose Watch is active."
  :type 'string
  :group 'expose-watch)

(defcustom expose-watch-provider-timeout-seconds 180
  "Seconds to wait for an AI provider before failing an Expose Watch run."
  :type 'integer
  :group 'expose-watch)

(defcustom expose-watch-card-width 60
  "Maximum width, in columns, of the inline Expose Watch comment card.

The card is only ever as wide as its longer line (summary or hint)
actually needs -- it hugs its content rather than padding out empty
space to a fixed size -- but never wider than this, so an unusually
long title gets truncated instead of stretching the card out."
  :type 'integer
  :group 'expose-watch)

(defvar expose-provider-default)

(defvar-local expose-watch-source-overlays nil
  "Source overlays for Expose Watch comments in the current buffer.")

(defvar-local expose-watch-state 'idle
  "Current Expose Watch state for this buffer.

Expected values are `idle', `running', and `error'.")

(defvar-local expose-watch-visible-item-count 0
  "Number of active Expose Watch comments in this buffer.

Counted the same whether or not their inline markers are actually
shown -- see `expose-watch-hidden' -- so the mode-line count stays
accurate even while markers are hidden.")

(defvar expose-watch-hidden nil
  "When non-nil, Expose Watch's inline underline/card markers are
suppressed in every watched buffer, without affecting anything else --
Watch keeps reviewing changed hunks, storing comments, and counting
them normally in the background. Toggle with
`expose-watch-toggle-hidden'.

Useful for decluttering a large change: hide the inline markers while
skimming a big diff, then reveal them again once ready to work through
the comments. `expose-watch-open-active-list' reads stored state
directly and is unaffected by this either way, so it stays a good way
to see what Watch has found while markers are hidden.")

(defvar-local expose-watch-pending-hashes nil
  "Hunk hashes currently being reviewed for this buffer.")

(defvar-local expose-watch-active-process nil
  "Live provider process for the in-flight Expose Watch run in this buffer, if any.")

(defvar expose-watch--restoring nil
  "Non-nil while restoring watch mode from stored state.")

(defconst expose-watch-list-buffer-name
  "*EXPOSE Watch*")

(defvar-local expose-watch-list-project-root nil
  "Project root displayed by the current Expose Watch list buffer.")

(defconst expose-watch-active-buffer-name
  "*EXPOSE Watch Active*")

(defvar-local expose-watch-active-project-root nil
  "Project root displayed by the current Expose Watch active-items buffer.")

;;; ---------------------------------------------------------------------------
;;; Faces / Fringe
;;; ---------------------------------------------------------------------------

(defface expose-watch-hunk-face
  '((t (:background "#262b33" :extend t)))
  "Subtle face for reviewed changed hunks."
  :group 'expose-watch)

(defface expose-watch-item-face
  '((t (:underline (:color "#c678dd" :style wave) :extend nil)))
  "Face for concrete Expose Watch comment lines.

A squiggly underline in doom-one's magenta, rather than filled with a
background, so it reads as \"annotated\" without competing with syntax
highlighting, and stands out more than a plain line underline would.
`:extend nil' keeps the underline from bleeding across the blank tail
of each line -- the source overlay this face is applied to spans full
lines (including each trailing newline) to cover multi-line items, and
without this the underline would stretch to the window's right edge on
every line instead of stopping at the actual code."
  :group 'expose-watch)

(defface expose-watch-card-face
  '((t (:background "#262b33" :overline "#666666")))
  "Background/top-border face for the inline Expose Watch card's summary line.

Layered on top of the card's own severity/title colors via
`add-face-text-property' (not a plain :inherit) so both apply. Its
`:background' is overwritten at render time by
`expose-watch-card-sync-faces' to match the real Expose popup's own
body background exactly (whatever the current theme, and `solaire-mode'
if active, render that as) rather than staying a hardcoded guess.

`:overline' (not `:box'): a dedicated top/bottom border ROW (a separate
line of `-'/`+' characters) is itself extra line-height, which is
exactly what read as unwanted padding around the card. `:overline'
draws the top border directly on this line's own text instead of
needing a line for it; `:underline' on `expose-watch-card-hint-line-face'
below does the same for the bottom border. Manual `|' characters (see
`expose-watch-card-content-row') provide the left/right edges, so the
full card is still bordered on all four sides -- just without a line
between the two rows, and without either border needing a row of its
own."
  :group 'expose-watch)

(defface expose-watch-card-hint-line-face
  '((t (:background "#1c1f26" :underline (:color "#666666" :style line))))
  "Background/bottom-border face for the Expose Watch card's hint line.

Its `:background' is overwritten at render time by
`expose-watch-card-sync-faces' to match `mode-line-inactive' --
mirroring how the real Expose popup's own bottom bar
(`:respect-mode-line t') renders, since posframes essentially never
have real input focus, so it's always the *inactive* mode-line face
that ends up showing there, not `mode-line'.

`:underline' with `:style line' (a straight rule, not the wavy style
`expose-watch-item-face' uses to mark flagged code) draws the card's
bottom border directly on this line -- see
`expose-watch-card-face's docstring for why that's preferable to a
separate border row."
  :group 'expose-watch)

(defface expose-watch-card-border-face
  '((t (:foreground "#666666")))
  "Foreground face for the inline Expose Watch card's border characters.

Same border color the real Expose popup itself uses (see
`expose-popup-show-buffer's `:border-color \"#666666\"')."
  :group 'expose-watch)

(defface expose-watch-fringe-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for Expose Watch right-fringe markers."
  :group 'expose-watch)

(defface expose-watch-mode-line-face
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Face for active Expose Watch mode-line indicator."
  :group 'expose-watch)

(defface expose-watch-mode-line-running-face
  '((t (:inherit warning :weight bold)))
  "Face for running Expose Watch mode-line indicator."
  :group 'expose-watch)

(defface expose-watch-mode-line-error-face
  '((t (:inherit error :weight bold)))
  "Face for failed Expose Watch mode-line indicator."
  :group 'expose-watch)

(defface expose-watch-list-title-face
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Face for Expose Watch list titles."
  :group 'expose-watch)

(defface expose-watch-list-meta-face
  '((t (:inherit shadow)))
  "Face for Expose Watch list metadata."
  :group 'expose-watch)

(defface expose-watch-list-label-face
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Face for Expose Watch list labels."
  :group 'expose-watch)

(defface expose-watch-high-face
  '((t (:inherit error :weight bold)))
  "Face for high severity Expose Watch comments."
  :group 'expose-watch)

(defface expose-watch-medium-face
  '((t (:inherit warning :weight bold)))
  "Face for medium severity Expose Watch comments."
  :group 'expose-watch)

(defface expose-watch-low-face
  '((t (:inherit success :weight bold)))
  "Face for low severity Expose Watch comments."
  :group 'expose-watch)

(defface expose-watch-info-face
  '((t (:inherit font-lock-doc-face :weight bold)))
  "Face for info severity Expose Watch comments."
  :group 'expose-watch)

(defun expose-watch-apply-faces ()

  "Force Expose Watch faces to current theme values."

  (set-face-attribute
   'expose-watch-fringe-face
   nil
   :foreground 'unspecified
   :inherit 'font-lock-keyword-face))

(define-fringe-bitmap
  'expose-watch-fringe-bitmap
  [#b00000000
   #b01110000
   #b01110000
   #b01110000
   #b01110000
   #b01110000
   #b00000000
   #b00000000]
  nil
  nil
  'center)

(expose-watch-apply-faces)

;;; ---------------------------------------------------------------------------
;;; Mode line
;;; ---------------------------------------------------------------------------

(defun expose-watch-mode-line-icon ()
  "Return the Expose Watch mode-line icon."

  (if (fboundp 'nerd-icons-faicon)

      (nerd-icons-faicon
       expose-watch-mode-line-icon
       :height 0.9
       :v-adjust -0.02)

    "👁"))

(defun expose-watch-mode-line-face ()
  "Return mode-line face for current Expose Watch state."

  (pcase expose-watch-state
    ('running
     'expose-watch-mode-line-running-face)

    ('error
     'expose-watch-mode-line-error-face)

    (_
     'expose-watch-mode-line-face)))

(defun expose-watch-mode-line-state-label ()
  "Return compact state label for Expose Watch mode line."

  (pcase expose-watch-state
    ('running
     "…")

    ('error
     "!")

    (_
     "")))

(defun expose-watch-mode-line-count-label ()
  "Return compact visible item count label for Expose Watch mode line."

  (if (> expose-watch-visible-item-count 0)

      (format
       ":%d"
       expose-watch-visible-item-count)

    ""))

(defun expose-watch-mode-line-hidden-label ()
  "Return a compact label when Expose Watch's inline markers are hidden."

  (if expose-watch-hidden
      "⊘"
    ""))

(defun expose-watch-mode-line ()
  "Return Expose Watch mode-line indicator."

  (propertize
   (format
    " %s%s%s%s "
    (expose-watch-mode-line-icon)
    (expose-watch-mode-line-state-label)
    (expose-watch-mode-line-count-label)
    (expose-watch-mode-line-hidden-label))
   'face
   (expose-watch-mode-line-face)
   'help-echo
   (pcase expose-watch-state
     ('running
      "Expose Watch is reviewing changed hunks")

     ('error
      "Expose Watch is active, but the last review failed")

     (_
      (if expose-watch-hidden
          "Expose Watch is active for this buffer; markers are hidden"
        "Expose Watch is active for this buffer")))))

(defun expose-watch-refresh-mode-line ()
  "Refresh mode-line for Expose Watch."

  (force-mode-line-update t))

(defvar expose-watch-mode-line-indicator
  '(:eval
    (when (bound-and-true-p expose-watch-mode)
      (expose-watch-mode-line)))
  "Mode-line construct for Expose Watch.")

(defun expose-watch-install-mode-line ()
  "Install Expose Watch mode-line indicator.

This installs into `mode-line-misc-info' so normal Emacs and
Doom modeline's `misc-info' segment can display it without requiring
user config to redefine the whole modeline."

  (unless (member
           expose-watch-mode-line-indicator
           mode-line-misc-info)

    (setq mode-line-misc-info
          (append
           mode-line-misc-info
           (list expose-watch-mode-line-indicator)))))

(defun expose-watch-uninstall-mode-line ()
  "Remove Expose Watch mode-line indicator."

  (setq mode-line-misc-info
        (remove
         expose-watch-mode-line-indicator
         mode-line-misc-info)))

;;; ---------------------------------------------------------------------------
;;; Basic helpers
;;; ---------------------------------------------------------------------------

(defun expose-watch-refresh-running-state (&optional failed)
  "Refresh Expose Watch running state.

When FAILED is non-nil, show the error state. Otherwise keep showing
running while any hunk hashes are still pending."

  (cond
   (failed
    (expose-watch-set-state 'error))

   (expose-watch-pending-hashes
    (expose-watch-set-state 'running))

   (t
    (expose-watch-set-state 'idle))))


(defun expose-watch-finish-pending-hashes (hashes &optional failed)
  "Remove HASHES from pending Watch state and refresh mode line.

When FAILED is non-nil, leave Watch in the error state."

  (setq expose-watch-pending-hashes
        (seq-difference
         expose-watch-pending-hashes
         hashes
         #'string=))

  (expose-watch-refresh-running-state failed))

(defun expose-watch-now ()
  "Return current timestamp string."

  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun expose-watch-storage-response (response)
  "Return provider RESPONSE normalized for persistent storage."

  (expose-transport-storage-response
   response
   expose-watch-response-storage-max-length))

(defun expose-watch-string (value)
  "Return VALUE as a display string."

  (cond
   ((null value)
    "")

   ((stringp value)
    value)

   ((symbolp value)
    (symbol-name value))

   ((numberp value)
    (number-to-string value))

   (t
    (format "%s" value))))

(defun expose-watch-blank-p (value)
  "Return non-nil when VALUE is nil or blank."

  (string-empty-p
   (string-trim
    (expose-watch-string value))))

(defun expose-watch-plist-get-any (plist keys)
  "Return first value in PLIST matching one of KEYS."

  (catch 'value
    (dolist (key keys)
      (when (plist-member plist key)
        (throw 'value
               (plist-get plist key))))
    nil))

(defun expose-watch-escape (text)
  "Escape TEXT for XML-ish request bodies."

  (let ((value
         (expose-watch-string text)))

    (setq value
          (replace-regexp-in-string "&" "&amp;" value t t))

    (setq value
          (replace-regexp-in-string "<" "&lt;" value t t))

    (setq value
          (replace-regexp-in-string ">" "&gt;" value t t))

    value))

(defun expose-watch-project-root ()
  "Return current project root, or raise an error."

  (if-let ((project
            (project-current nil)))

      (file-name-as-directory
       (project-root project))

    (user-error "Expose Watch requires a project")))

(defun expose-watch-current-project-root ()
  "Return current project root, or nil."

  (when-let ((project
              (project-current nil)))

    (file-name-as-directory
     (project-root project))))

(defun expose-watch-buffer-file (project-root)
  "Return current buffer file relative to PROJECT-ROOT."

  (unless buffer-file-name
    (user-error "Expose Watch requires a file buffer"))

  (file-relative-name
   buffer-file-name
   project-root))

(defun expose-watch-current-buffer-file ()
  "Return current buffer file relative to its project."

  (when-let ((project-root
              (expose-watch-current-project-root)))

    (when buffer-file-name
      (file-relative-name
       buffer-file-name
       project-root))))

(defun expose-watch-call-git (project-root &rest args)
  "Run git with ARGS in PROJECT-ROOT and return stdout.

Return nil when git fails."

  (let ((default-directory project-root))

    (with-temp-buffer
      (let ((status
             (apply
              #'call-process
              "git"
              nil
              t
              nil
              args)))

        (when (= status 0)
          (buffer-string))))))

(defvar expose-watch--git-path-cache
  (make-hash-table :test 'equal)
  "Cache of (PROJECT-ROOT . PATH) to resolved `git rev-parse --git-path'.

This resolution is stable for the life of the Emacs session, but it is
looked up on every `find-file' via `expose-watch-global-mode', so caching
it avoids spawning a git process on every single file open in every
project, most of which have never used Expose Watch at all.")

(defun expose-watch-git-path (project-root path)
  "Return git-private PATH under PROJECT-ROOT."

  (let ((cache-key
         (cons project-root path)))

    (or
     (gethash cache-key expose-watch--git-path-cache)

     (let ((result
            (expose-watch-call-git
             project-root
             "rev-parse"
             "--git-path"
             path)))

       (unless result
         (user-error "Not inside a Git repository"))

       (puthash
        cache-key
        (expand-file-name
         (string-trim result)
         project-root)
        expose-watch--git-path-cache)))))

;;; ---------------------------------------------------------------------------
;;; Storage
;;; ---------------------------------------------------------------------------

(defun expose-watch-store-dir (project-root)
  "Return Expose Watch storage directory for PROJECT-ROOT."

  (expose-watch-git-path
   project-root
   "expose/watch"))

(defun expose-watch-active-path (project-root)
  "Return active Expose Watch session path for PROJECT-ROOT."

  (expand-file-name
   "active.eld"
   (expose-watch-store-dir project-root)))

(defun expose-watch-read-file (path)
  "Read Lisp data from PATH.

If PATH contains unreadable data, move it aside and return nil."

  (when (file-readable-p path)

    (condition-case error-data

        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (read (current-buffer)))

      (error
       (let ((bad-path
              (format
               "%s.bad.%s"
               path
               (format-time-string "%Y%m%d%H%M%S"))))

         (ignore-errors
           (rename-file path bad-path t))

         (expose-log
          "Watch"
          "Failed to read %s: %s. Moved bad file to %s."
          path
          (error-message-string error-data)
          bad-path)

         nil)))))

(defun expose-watch-write-file (path data)
  "Write DATA to PATH."

  (make-directory
   (file-name-directory path)
   t)

  (with-temp-file path
    (let ((print-length nil)
          (print-level nil)
          (print-circle t))

      (prin1
       (expose-transport-readable-value data)
       (current-buffer)))))

(defun expose-watch-empty-session (project-root)
  "Return empty Expose Watch session for PROJECT-ROOT."

  (list
   :kind 'watch
   :project-root project-root
   :created-at (expose-watch-now)
   :updated-at (expose-watch-now)
   :files nil))

(defun expose-watch-load-session (project-root)
  "Load Expose Watch session for PROJECT-ROOT."

  (or
   (expose-watch-read-file
    (expose-watch-active-path project-root))
   (expose-watch-empty-session project-root)))

(defun expose-watch-save-session (session)
  "Persist Expose Watch SESSION."

  (setq session
        (plist-put
         session
         :updated-at
         (expose-watch-now)))

  (expose-watch-write-file
   (expose-watch-active-path
    (plist-get session :project-root))
   session)

  session)

(defun expose-watch-file-state (session file)
  "Return watch file state for FILE in SESSION."

  (cl-find
   file
   (plist-get session :files)
   :test #'string=
   :key
   (lambda (state)
     (plist-get state :file))))

(defun expose-watch-new-file-state (file)
  "Return new watch state for FILE."

  (list
   :file file
   :enabled t
   :created-at (expose-watch-now)
   :updated-at (expose-watch-now)
   :last-save-at nil
   :last-error nil
   :reviewed-hunks nil))

(defun expose-watch-put-file-state (session state)
  "Put file STATE into SESSION and return SESSION."

  (let* ((file
          (plist-get state :file))

         (files
          (seq-remove
           (lambda (existing)
             (string=
              file
              (plist-get existing :file)))
           (plist-get session :files))))

    (plist-put
     session
     :files
     (append files
             (list state)))))

(defun expose-watch-ensure-file-state (session file)
  "Ensure SESSION has state for FILE."

  (or
   (expose-watch-file-state session file)
   (expose-watch-new-file-state file)))

(defun expose-watch-enable-file-state (project-root file)
  "Mark FILE watched in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file)))

    (setq state
          (plist-put state :enabled t))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-disable-file-state (project-root file)
  "Mark FILE unwatched in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file)))

    (setq state
          (plist-put state :enabled nil))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-file-enabled-p (project-root file)
  "Return non-nil when FILE is watched in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-file-state session file)))

    (and state
         (plist-get state :enabled))))

(defun expose-watch-project-auto-enabled-p (project-root)
  "Return non-nil when PROJECT-ROOT has Expose Watch auto-arming enabled.

When enabled, editing any file in the project for the first time
auto-enables `expose-watch-mode' for that file (see
`expose-watch-arm-auto-watch')."

  (plist-get
   (expose-watch-load-session project-root)
   :auto-watch))

(defun expose-watch-set-project-auto-enabled (project-root enabled)
  "Set Expose Watch auto-arming for PROJECT-ROOT to ENABLED."

  (expose-watch-save-session
   (plist-put
    (expose-watch-load-session project-root)
    :auto-watch
    enabled)))

(defun expose-watch-reviewed-hunk-hashes (state)
  "Return reviewed hunk hashes from file STATE."

  (mapcar
   (lambda (hunk)
     (plist-get hunk :hash))
   (plist-get state :reviewed-hunks)))

(defun expose-watch-hunk-reviewed-p (state hunk)
  "Return non-nil if HUNK was already reviewed in STATE."

  (member
   (plist-get hunk :hash)
   (expose-watch-reviewed-hunk-hashes state)))

(defun expose-watch-record-hunk-into-state (state hunk items response &optional error)
  "Return STATE with HUNK recorded using ITEMS, RESPONSE, and optional ERROR.

Pure state transform: performs no I/O, so callers can record several hunks
against one loaded STATE before saving it once."

  (let* ((hash
          (plist-get hunk :hash))

         (existing
          (seq-remove
           (lambda (entry)
             (string=
              hash
              (plist-get entry :hash)))
           (plist-get state :reviewed-hunks)))

         (entry
          (list
           :hash hash
           :line-start (plist-get hunk :line-start)
           :line-end (plist-get hunk :line-end)
           :created-at (expose-watch-now)
           :items (expose-transport-readable-value items)
           :response
           (expose-watch-storage-response response)
           :error
           (when error
             (expose-watch-string error)))))

    (setq state
          (plist-put state :enabled t))

    (setq state
          (plist-put state :last-save-at
                     (expose-watch-now)))

    (setq state
          (plist-put state :last-error
                     (when error
                       (expose-watch-string error))))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (setq state
          (plist-put state :reviewed-hunks
                     (append existing
                             (list entry))))

    state))

(defun expose-watch-prune-stale-hunks-in-state (state current-hashes)
  "Return STATE with reviewed hunks whose hash is not in CURRENT-HASHES removed.

Pure state transform: performs no I/O. This is how already-reviewed hunks
that no longer exist in the working-tree diff (committed, reverted, or
superseded by further edits) stop accumulating forever in storage."

  (plist-put
   state
   :reviewed-hunks
   (seq-filter
    (lambda (entry)
      (member
       (plist-get entry :hash)
       current-hashes))
    (plist-get state :reviewed-hunks))))

(defun expose-watch-sync-file-state (project-root file &optional hunk-items-alist response)
  "Load FILE's watch state for PROJECT-ROOT, update it, and save at most once.

Always prunes reviewed hunks that no longer exist in the current diff.
HUNK-ITEMS-ALIST, when non-nil, is a list of (HUNK . ITEMS) conses newly
reviewed with RESPONSE; each is recorded into the same state before the
single save, instead of one load/save per hunk."

  (let* ((session
          (expose-watch-load-session project-root))

         (original-state
          (expose-watch-ensure-file-state session file))

         ;; `plist-put' mutates an existing key in place, so capture the
         ;; original :reviewed-hunks value now -- comparing the whole STATE
         ;; plist against ORIGINAL-STATE later would always look equal, since
         ;; pruning mutates ORIGINAL-STATE's own :reviewed-hunks binding too.
         (original-hunks
          (plist-get original-state :reviewed-hunks))

         (state
          (expose-watch-prune-stale-hunks-in-state
           original-state
           (expose-watch-current-hunk-hashes project-root file))))

    (dolist (pair hunk-items-alist)
      (setq state
            (expose-watch-record-hunk-into-state
             state
             (car pair)
             (cdr pair)
             response)))

    (when (or hunk-items-alist
              (not
               (equal
                (plist-get state :reviewed-hunks)
                original-hunks)))

      (expose-watch-save-session
       (expose-watch-put-file-state session state)))))

(defun expose-watch-clear-file (project-root file)
  "Clear stored watch comments for FILE in PROJECT-ROOT."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file)))

    (setq state
          (plist-put state :reviewed-hunks nil))

    (setq state
          (plist-put state :last-error nil))

    (setq state
          (plist-put state :updated-at
                     (expose-watch-now)))

    (expose-watch-save-session
     (expose-watch-put-file-state session state))))

(defun expose-watch-clear-project-session (project-root)
  "Clear all stored watch comments for PROJECT-ROOT."

  (let ((session
         (expose-watch-load-session project-root)))

    (dolist (state
             (plist-get session :files))

      (setq state
            (plist-put state :reviewed-hunks nil))

      (setq state
            (plist-put state :last-error nil)))

    (setq session
          (plist-put
           session
           :files
           (mapcar
            (lambda (state)
              (plist-put state :updated-at
                         (expose-watch-now)))
            (plist-get session :files))))

    (expose-watch-save-session session)))

;;; ---------------------------------------------------------------------------
;;; Git hunks
;;; ---------------------------------------------------------------------------

(defun expose-watch-hunk-range-end (line-start raw-length)
  "Return hunk end line from LINE-START and RAW-LENGTH."

  (let ((length
         (if raw-length
             (string-to-number raw-length)
           1)))

    (if (> length 0)
        (+ line-start
           (1- length))
      line-start)))

(defun expose-watch-hunk-hash (file line-start line-end text)
  "Return stable hash for FILE LINE-START LINE-END TEXT."

  (secure-hash
   'sha1
   (format
    "%s:%s:%s:%s"
    file
    line-start
    line-end
    text)))

(defun expose-watch-parse-diff-hunks (file diff)
  "Parse unified DIFF for FILE into changed hunks."

  (let (hunks
        current)

    (dolist (line
             (split-string
              (or diff "")
              "\n"))

      (if (string-match
           "^@@ .* \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
           line)

          (progn
            (when current
              (push current hunks))

            (let* ((line-start
                    (string-to-number
                     (match-string 1 line)))

                   (line-end
                    (expose-watch-hunk-range-end
                     line-start
                     (match-string 2 line))))

              (setq current
                    (list
                     :file file
                     :line-start line-start
                     :line-end line-end
                     :lines (list line)))))

        (when current
          (setq current
                (plist-put
                 current
                 :lines
                 (append
                  (plist-get current :lines)
                  (list line)))))))

    (when current
      (push current hunks))

    (mapcar
     (lambda (hunk)
       (let* ((text
               (string-join
                (plist-get hunk :lines)
                "\n"))

              (line-start
               (plist-get hunk :line-start))

              (line-end
               (plist-get hunk :line-end)))

         (setq hunk
               (plist-put hunk :text text))

         (setq hunk
               (plist-put hunk :hash
                          (expose-watch-hunk-hash
                           file
                           line-start
                           line-end
                           text)))

         hunk))
     (nreverse hunks))))

(defun expose-watch-current-file-diff (project-root file)
  "Return git diff for FILE in PROJECT-ROOT."

  (or
   (expose-watch-call-git
    project-root
    "diff"
    "--no-ext-diff"
    "--unified=20"
    "HEAD"
    "--"
    file)
   ""))

(defun expose-watch-current-file-hunks (project-root file)
  "Return changed hunks for FILE in PROJECT-ROOT."

  (if (expose-redact-excluded-path-p file project-root)

      (progn
        (expose-redact-log-excluded-path file project-root)
        nil)

    (expose-watch-parse-diff-hunks
     file
     (expose-watch-current-file-diff
      project-root
      file))))

;;; ---------------------------------------------------------------------------
;;; Source text / request
;;; ---------------------------------------------------------------------------

(defun expose-watch-buffer-line-count ()
  "Return number of lines in the current buffer."

  (line-number-at-pos
   (point-max)))

(defun expose-watch-line-start-position (line)
  "Return buffer position at beginning of LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))
    (point)))

(defun expose-watch-line-end-position (line)
  "Return buffer position at end of LINE, before its newline."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))
    (line-end-position)))

(defun expose-watch-line-after-position (line)
  "Return buffer position at beginning of the line after LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0 line))
    (point)))

(defun expose-watch-line-content-bounds (line)
  "Return (START . END) bounding LINE's non-blank content, or nil if blank.

START skips leading indentation; END stops before trailing whitespace.
Used to keep source overlays hugging real code instead of underlining
indentation or trailing blank space."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (max 0
          (1- line)))

    (let ((eol
           (line-end-position)))

      (skip-chars-forward " \t" eol)

      (unless (= (point) eol)

        (let ((start
               (point)))

          (goto-char eol)
          (skip-chars-backward " \t" start)
          (cons start (point)))))))

(defun expose-watch-numbered-text (text start-line)
  "Return TEXT with line numbers starting at START-LINE."

  (let* ((lines
          (split-string
           (or text "")
           "\n"))

         (end-line
          (+ start-line
             (max 0
                  (1- (length lines)))))

         (width
          (length
           (number-to-string end-line)))

         (line-number
          (1- start-line)))

    (mapconcat
     (lambda (line)
       (setq line-number
             (1+ line-number))

       (format
        (format "%%%dd | %%s" width)
        line-number
        line))
     lines
     "\n")))

(defun expose-watch-hunk-context (hunk)
  "Return numbered source context for HUNK."

  (let* ((line-start
          (plist-get hunk :line-start))

         (line-end
          (plist-get hunk :line-end))

         (context-start-line
          (max
           1
           (- line-start
              expose-watch-context-lines)))

         (context-end-line
          (min
           (expose-watch-buffer-line-count)
           (+ line-end
              expose-watch-context-lines)))

         (context-start
          (expose-watch-line-start-position context-start-line))

         (context-end
          (expose-watch-line-after-position context-end-line))

         (text
          (buffer-substring-no-properties
           context-start
           context-end)))

    (expose-watch-numbered-text
     text
     context-start-line)))

(defun expose-watch-request-hunk-block (hunk)
  "Return request block for HUNK."

  (format
   "  <changed-hunk file=\"%s\" line_start=\"%s\" line_end=\"%s\" hash=\"%s\">
    <diff>
%s
    </diff>
    <source-context numbered=\"true\">
%s
    </source-context>
  </changed-hunk>"
   (expose-watch-escape
    (plist-get hunk :file))
   (plist-get hunk :line-start)
   (plist-get hunk :line-end)
   (plist-get hunk :hash)
   (expose-watch-escape
    (plist-get hunk :text))
   (expose-watch-escape
    (expose-watch-hunk-context hunk))))

(defun expose-watch-diagnostic-file-current-p (diagnostic-file)
  "Return non-nil when DIAGNOSTIC-FILE belongs to current buffer."

  (or
   (not diagnostic-file)
   (not buffer-file-name)
   (ignore-errors
     (file-equal-p diagnostic-file buffer-file-name))))


(defun expose-watch-diagnostics ()
  "Return current buffer diagnostics as plain text."

  (let (lines)

    (when (boundp 'flycheck-current-errors)

      (dolist (error flycheck-current-errors)

        (when (and
               (fboundp 'flycheck-error-message)
               (fboundp 'flycheck-error-line)
               (fboundp 'flycheck-error-level)
               (expose-watch-diagnostic-file-current-p
                (when (fboundp 'flycheck-error-filename)
                  (flycheck-error-filename error))))

          (push
           (format
            "%s:%s: %s"
            (or
             (flycheck-error-line error)
             "?")
            (flycheck-error-level error)
            (flycheck-error-message error))
           lines))))

    (if lines
        (string-join
         (nreverse lines)
         "\n")
      "No editor diagnostics reported.")))

(defun expose-watch-request (file hunks)
  "Build Expose Watch request for FILE and HUNKS."

  (let ((diagnostics
         (expose-watch-diagnostics)))

    (format
     "<expose-watch-request>
  <instruction>
    You are watching me code. Review only the changed hunks below.

    Rules:
    - Return valid JSON only.
    - Do not return Markdown.
    - Do not wrap JSON in code fences.
    - Only comment when something is genuinely useful.
    - Prefer no findings over noisy findings.
    - Do not review unchanged code except as supporting context.
    - Do not suggest broad rewrites.
    - Maximum findings: %s.
    - Every finding must use real file line_start and line_end values.
    - Findings should point to the smallest useful changed-line range.
    - Keep each comment to 1-2 sentences.
    - Keep suggestion text to 1-2 sentences; only include a patch when a small, precise
      diff is clearly better than prose.

    Scope / name-resolution rules:
    - All changed-hunk blocks are from the same current file.
    - A variable, function, import, class, or type may be declared outside the shown hunk.
    - Absence from the shown context is not evidence that a name is undeclared.
    - Do not report undefined-variable, undeclared-variable, missing-import, or unknown-name findings unless the editor diagnostics explicitly report that problem.
    - If editor diagnostics do not report an undefined-name problem, assume name resolution is unknown and do not create that finding.

    Return exactly this shape:

    {
      \"summary\": \"Short optional summary.\",
      \"items\": [
        {
          \"id\": \"W1\",
          \"severity\": \"high|medium|low|info\",
          \"category\": \"correctness|security|performance|maintainability|tests|typing|style\",
          \"file\": \"%s\",
          \"line_start\": 123,
          \"line_end\": 126,
          \"title\": \"Short title\",
          \"comment\": \"Useful comment.\",
          \"anchor_text\": \"Relevant source line or phrase.\",
          \"suggestion\": {
            \"kind\": \"none|text|patch\",
            \"text\": \"Suggested fix or implementation direction.\",
            \"patch\": \"\"
          }
        }
      ]
    }

    If there are no useful findings, return:

    {
      \"summary\": \"No useful watch comments.\",
      \"items\": []
    }
  </instruction>

  <location file=\"%s\" major_mode=\"%s\" />

  <editor-diagnostics>
%s
  </editor-diagnostics>

%s
</expose-watch-request>"
     expose-watch-max-items-per-run
     (expose-watch-escape file)
     (expose-watch-escape file)
     major-mode
     (expose-watch-escape diagnostics)
     (string-join
      (mapcar
       #'expose-watch-request-hunk-block
       hunks)
      "\n\n"))))

;;; ---------------------------------------------------------------------------
;;; Review item helpers
;;; ---------------------------------------------------------------------------

(defun expose-watch-item-line-start (item &optional fallback)
  "Return ITEM line start or FALLBACK."

  (or
   (expose-watch-plist-get-any
    item
    '(:line-start :line_start))
   fallback
   1))

(defun expose-watch-item-line-end (item &optional fallback)
  "Return ITEM line end or FALLBACK."

  (or
   (expose-watch-plist-get-any
    item
    '(:line-end :line_end))
   (expose-watch-item-line-start item fallback)))

(defun expose-watch-item-overlaps-hunk-p (item hunk)
  "Return non-nil when ITEM overlaps HUNK."

  (let ((item-start
         (expose-watch-item-line-start item))

        (item-end
         (expose-watch-item-line-end item))

        (hunk-start
         (plist-get hunk :line-start))

        (hunk-end
         (plist-get hunk :line-end)))

    (and
     (<= item-start hunk-end)
     (<= hunk-start item-end))))

(defun expose-watch-items-for-hunk (items hunk)
  "Return ITEMS that overlap HUNK."

  (seq-filter
   (lambda (item)
     (expose-watch-item-overlaps-hunk-p item hunk))
   items))

(defun expose-watch-current-hunk-hashes (project-root file)
  "Return hashes for currently changed hunks in FILE."

  (mapcar
   (lambda (hunk)
     (plist-get hunk :hash))
   (expose-watch-current-file-hunks project-root file)))


(defun expose-watch-current-buffer-active-hunk-entries ()
  "Return reviewed hunk entries that still match the current file diff.

This prevents stale Watch comments from remaining attached to source
lines after the changed code was edited again or removed."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file))

              (entries
               (expose-watch-current-buffer-hunk-entries)))

    (let ((current-hashes
           (expose-watch-current-hunk-hashes project-root file)))

      (seq-filter
       (lambda (entry)
         (member
          (plist-get entry :hash)
          current-hashes))
       entries))))

(defun expose-watch-current-buffer-hunk-entries ()
  "Return reviewed hunk entries for current buffer."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file))

              (session
               (expose-watch-load-session project-root))

              (state
               (expose-watch-file-state session file)))

    (plist-get state :reviewed-hunks)))

(defun expose-watch-file-active-hunk-entries (project-root file state)
  "Return STATE's reviewed hunk entries for FILE that still match the live diff.

Same staleness filter as `expose-watch-current-buffer-active-hunk-entries',
parameterized on PROJECT-ROOT/FILE/STATE instead of the current buffer, so
it can be applied to files that aren't currently open."

  (let ((current-hashes
         (expose-watch-current-hunk-hashes project-root file)))

    (seq-filter
     (lambda (entry)
       (member
        (plist-get entry :hash)
        current-hashes))
     (plist-get state :reviewed-hunks))))

(defun expose-watch-project-active-entries (project-root)
  "Return a flat list of (:file :item) plists for PROJECT-ROOT's active items.

Only includes items belonging to enabled files whose reviewed hunk still
matches that file's live working-tree diff -- files don't need an open
buffer for this, since staleness is determined by re-running `git diff'."

  (let ((session
         (expose-watch-load-session project-root))
        entries)

    (dolist (state (plist-get session :files))
      (when (plist-get state :enabled)
        (let ((file
               (plist-get state :file)))

          (dolist (hunk
                   (expose-watch-file-active-hunk-entries
                    project-root file state))

            (dolist (item
                     (plist-get hunk :items))

              (push
               (list :file file :item item)
               entries))))))

    (nreverse entries)))

(defun expose-watch-current-buffer-items ()
  "Return all Expose Watch items for current buffer."

  (apply
   #'append
   (mapcar
    (lambda (hunk)
      (plist-get hunk :items))
    (or
     (expose-watch-current-buffer-hunk-entries)
     nil))))

(defun expose-watch-severity-face (severity)
  "Return face for SEVERITY."

  (pcase
      (downcase
       (expose-watch-string severity))

    ("high"
     'expose-watch-high-face)

    ("medium"
     'expose-watch-medium-face)

    ("low"
     'expose-watch-low-face)

    (_
     'expose-watch-info-face)))

(defun expose-watch-format-location (file line-start line-end)
  "Format FILE LINE-START LINE-END."

  (if (= line-start line-end)

      (format "%s:%s" file line-start)

    (format "%s:%s-%s" file line-start line-end)))

(defun expose-watch-suggestion-text (item)
  "Return suggestion text from ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :text)
   ""))

(defun expose-watch-suggestion-patch (item)
  "Return suggestion patch from ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :patch)
   ""))

;;; ---------------------------------------------------------------------------
;;; Source overlays
;;; ---------------------------------------------------------------------------

(defun expose-watch-source-clear ()
  "Clear Expose Watch source overlays."

  (mapc
   #'delete-overlay
   expose-watch-source-overlays)

  (setq expose-watch-source-overlays nil)
  (setq expose-watch-visible-item-count 0)
  (expose-watch-refresh-mode-line))

(defun expose-watch-source-add-hunk-overlay (_hunk)
  "Do not visually mark reviewed hunks.

Expose Watch only marks concrete comments in the source buffer."
  nil)

(defun expose-watch-source-add-fringe-overlay (item file)
  "Add right-fringe marker for ITEM in FILE."

  (let* ((line
          (expose-watch-item-line-start item))

         (position
          (expose-watch-line-start-position line))

         (overlay
          (make-overlay position position nil t nil)))

    (overlay-put overlay 'priority 46)
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'help-echo "Expose Watch comment")
    (overlay-put overlay 'expose-watch-item item)
    (overlay-put overlay 'expose-watch-file file)
    (overlay-put overlay 'expose-watch-fringe t)

    (overlay-put
     overlay
     'before-string
     (propertize
      "!"
      'face
      'expose-watch-fringe-face
      'display
      '(right-fringe
        expose-watch-fringe-bitmap
        expose-watch-fringe-face)))

    (push overlay expose-watch-source-overlays)))

;;; ---------------------------------------------------------------------------
;;; Inline comment cards
;;;
;;; Each item gets a small, always-visible, fixed-width two-line card
;;; rendered under (not in) the commented code via an overlay
;;; `after-string': a severity/title summary line, and a dimmer hint line
;;; below it explaining how to see the full comment. The card itself
;;; never expands -- C-<tab> (or a click) opens the full comment in
;;; Expose's normal shared popup instead, the same one used for hover,
;;; review comments, etc., with all its existing behavior (auto-hides on
;;; unrelated commands, C-j/C-k scrolling, copy, open-in-buffer) for free.
;;; ---------------------------------------------------------------------------

(defun expose-watch-card-collapsed-text (item)
  "Return the always-visible inline one-line summary for ITEM.

The leading chevron is a static affordance marking the line as
expandable (into the shared Expose popup, via C-<tab> or a click) --
it does not track any open/closed state of its own, since the card
itself never expands."

  (let* ((severity
          (expose-watch-string
           (or
            (plist-get item :severity)
            "info")))

         (title
          (expose-watch-string
           (or
            (plist-get item :title)
            "Watch comment"))))

    (concat
     (propertize
      "▸ "
      'face
      'expose-watch-list-meta-face)
     (propertize
      (format "[%s] " (upcase severity))
      'face
      (expose-watch-severity-face severity))
     (propertize title 'face 'expose-watch-list-meta-face))))

(defun expose-watch-card-hint-text ()
  "Return the Expose Watch card's second-line hint.

Styled like the shared Expose popup's own bottom mode-line bar
(`expose-popup-mode-line-info'): \"EXPOSE\" in the same buffer-id face,
and the shortcut in the same blue keyword face used there for the
Expose leader prefix (\"SPC c h\")."

  (concat
   (propertize "EXPOSE" 'face 'mode-line-buffer-id)
   " "
   (propertize "C-<tab>" 'face 'font-lock-keyword-face)))

(defun expose-watch-card-pad (text width)
  "Pad or truncate TEXT to WIDTH columns."

  (truncate-string-to-width text width 0 ?\s t))

(defun expose-watch-card-fit-width (&rest texts)
  "Return the column width an Expose Watch card containing TEXTS should use.

The longest of TEXTS, capped at `expose-watch-card-width' -- the card
hugs its content (so there's no dead space between text and border)
rather than always padding out to a fixed size."

  (min expose-watch-card-width
       (apply #'max (mapcar #'length texts))))

(defun expose-watch-card-ensure-popup-buffer ()
  "Return the shared Expose popup buffer, creating/mode-enabling it if needed.

Only used to read its actual rendered background color (see
`expose-watch-card-sync-faces') -- never shown or otherwise touched --
so the inline card's summary-line background matches the real popup's
body exactly, under whatever theme (and `solaire-mode', if active) is
currently active, rather than a hardcoded guess."

  (let ((buffer
         (get-buffer-create expose-popup-buffer-name)))

    (with-current-buffer buffer
      (unless (derived-mode-p 'expose-popup-mode)
        (expose-popup-mode)))

    buffer))

(defun expose-watch-card-resolve-face-background (face)
  "Return FACE's effective background color in the current buffer.

Unlike plain `face-attribute', this also resolves a buffer-local
`face-remapping-alist' entry for FACE, if one exists. Remapping FACE
this way -- not a theme's face spec for it -- is exactly how e.g.
`solaire-mode' gives \"unreal\" buffers (which the real Expose popup's
own buffer, a `special-mode' buffer with no file, qualifies as) a
different background than a plain theme lookup would find."

  (let ((remap
         (cdr
          (assq face face-remapping-alist))))

    (or
     (cl-loop
      for spec in remap
      thereis
      (cond
       ((facep spec)
        (face-attribute spec :background nil t))

       ((and (listp spec)
             (plist-member spec :background))
        (plist-get spec :background))))

     (face-attribute face :background nil t))))

(defun expose-watch-card-sync-faces ()
  "Sync the Watch card's background faces to the real Expose popup's colors.

`expose-watch-card-face' (summary line) mirrors the popup body's own
`default' background; `expose-watch-card-hint-line-face' (hint line)
mirrors `mode-line-inactive', since posframes essentially never have
real input focus, so the popup's own `:respect-mode-line t' bar always
renders with the inactive mode-line face. Both are read fresh each time
rather than cached, so a theme switch is picked up automatically."

  (with-current-buffer (expose-watch-card-ensure-popup-buffer)

    (set-face-attribute
     'expose-watch-card-face nil
     :background
     (expose-watch-card-resolve-face-background 'default))

    (set-face-attribute
     'expose-watch-card-hint-line-face nil
     :background
     (expose-watch-card-resolve-face-background 'mode-line-inactive))))

(defun expose-watch-card-content-row (text left right)
  "Return TEXT framed with LEFT and RIGHT border characters (strings).

Plain ASCII `|'. Two Unicode corner-glyph attempts were tried and
rejected: thin box-drawing corners (`┌'/`┐'/`└'/`┘') rendered visibly
shorter than a full-height `|', breaking the connection to the
`:overline'/`:underline' rule above/below them; block-element quadrant
corners (`▛'/`▜'/`▙'/`▟') rendered fine but weren't wanted after all.
Plain `|' is the one that reliably looked right."

  (concat
   (propertize left 'face 'expose-watch-card-border-face)
   text
   (propertize right 'face 'expose-watch-card-border-face)))

(defun expose-watch-card-popup-body (item)
  "Return full detail text for ITEM, for the Expose popup."

  (let* ((severity
          (expose-watch-string
           (or
            (plist-get item :severity)
            "info")))

         (category
          (expose-watch-string
           (or
            (plist-get item :category)
            "")))

         (title
          (expose-watch-string
           (or
            (plist-get item :title)
            "Watch comment")))

         (comment
          (expose-watch-string
           (or
            (plist-get item :comment)
            "")))

         (suggestion-text
          (expose-watch-suggestion-text item))

         (patch
          (expose-watch-suggestion-patch item)))

    (with-temp-buffer
      (insert
       (propertize
        (format "[%s]" (upcase severity))
        'face
        (expose-watch-severity-face severity)))

      (unless (expose-watch-blank-p category)
        (insert
         (propertize
          (format " %s" category)
          'face
          'shadow)))

      (insert "\n")
      (insert (propertize title 'face 'bold))
      (insert "\n\n")

      (unless (expose-watch-blank-p comment)
        (insert comment)
        (insert "\n\n"))

      (unless (expose-watch-blank-p suggestion-text)
        (insert
         (propertize "Suggestion\n" 'face 'font-lock-keyword-face))
        (insert suggestion-text)
        (insert "\n\n"))

      (unless (expose-watch-blank-p patch)
        (insert
         (propertize "Patch\n" 'face 'font-lock-keyword-face))
        (insert patch)
        (insert "\n"))

      (string-trim (buffer-string)))))

(defun expose-watch-source-show-card-at-point ()
  "Show the full Expose Watch comment for the item at point.

Displays it in Expose's normal shared popup (`expose-popup-show-view')
-- the same one used for hover and other Review comments -- rather than
a bespoke window of its own, so it gets that popup's existing, already
correct behavior (auto-hides on unrelated commands, C-j/C-k scrolling,
copy, open-in-buffer) for free."

  (interactive)

  (if-let ((overlay
            (cl-loop
             for ov in (overlays-at (point))
             when (overlay-get ov 'expose-watch-item)
             return ov)))

      (expose-popup-show-view
       (expose-popup-view-create
        "Expose Watch"
        (expose-watch-card-popup-body
         (overlay-get overlay 'expose-watch-item))))

    (user-error "No Expose Watch item here")))

(defvar expose-watch-source-item-map
  (let ((map
         (make-sparse-keymap)))

    (define-key map (kbd "C-<tab>") #'expose-watch-source-show-card-at-point)
    (define-key map (kbd "<mouse-1>") #'expose-watch-source-show-card-at-point)

    map)
  "Keymap active when point is on an Expose Watch source item.

Set as the overlay `keymap' property, so it only intercepts keys while
point is actually within an item's overlay -- everywhere else in the
buffer, C-<tab> (and everything else) behaves completely normally. This
takes effect regardless of Evil state, since a `keymap' overlay
property is consulted ahead of Evil's own state keymaps.

Neither RET nor plain TAB: RET risks hijacking a genuine newline if
you're editing the exact flagged span (e.g. splitting that line), and
plain TAB is corfu's own primary accept/complete key -- with
`corfu-auto' enabled, a completion popup can be showing and claiming
TAB before it ever reaches this overlay's keymap. C-<tab> isn't claimed
by either.")

(defun expose-watch-source-add-item-card (item file hunk-hash line-end)
  "Add the always-visible two-line summary card for ITEM after LINE-END.

FILE and HUNK-HASH identify ITEM's hunk. The card is a bordered box
sized to hug its own content up to `expose-watch-card-width', framing
two rows: a severity/title summary row, and a darker hint row below it
explaining how to see the full comment. The border is drawn on the
rows' own faces (`:overline'/`:underline'; see `expose-watch-card-face')
plus manual `|' side bars -- not a separate top/bottom border row of
characters, which is itself extra line-height. The card itself never
expands or resizes."

  (expose-watch-card-sync-faces)

  (let* ((position
          (expose-watch-line-end-position line-end))

         (overlay
          (make-overlay position position nil nil nil))

         (raw-summary
          (expose-watch-card-collapsed-text item))

         (raw-hint
          (expose-watch-card-hint-text))

         (width
          (expose-watch-card-fit-width raw-summary raw-hint))

         (summary-line
          (expose-watch-card-pad raw-summary width))

         (hint-line
          (expose-watch-card-pad raw-hint width)))

    (add-face-text-property 0 (length summary-line) 'expose-watch-card-face nil summary-line)
    (add-face-text-property 0 (length hint-line) 'expose-watch-card-hint-line-face nil hint-line)

    (overlay-put
     overlay
     'after-string
     (concat
      "\n" (expose-watch-card-content-row summary-line "|" "|")
      "\n" (expose-watch-card-content-row hint-line "|" "|")))

    (overlay-put overlay 'priority 49)
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'help-echo "C-<tab> (or click) shows the full comment")
    (overlay-put overlay 'expose-watch-item item)
    (overlay-put overlay 'expose-watch-file file)
    (overlay-put overlay 'expose-watch-hunk-hash hunk-hash)
    (overlay-put overlay 'expose-watch-card t)
    (overlay-put overlay 'keymap expose-watch-source-item-map)

    (push overlay expose-watch-source-overlays)))

(defun expose-watch-source-add-item-overlay (item file hunk-hash)
  "Add visible source overlay(s), inline card, and fringe marker for ITEM.

FILE and HUNK-HASH identify ITEM's hunk. Two kinds of overlay per line
in ITEM's range: a full-line \"interactive\" overlay (indentation,
trailing whitespace, and all) carrying the toggle keymap, so C-<tab>
works no matter where on the line point is -- and, only on non-blank
lines, a second overlay trimmed to that line's actual content, carrying
just the underline face, so the *visible* marker still only covers real
code. Plus one collapsible inline card after the item's last line (see
`expose-watch-source-add-item-card').

Walks the range with a single forward pass (one `goto-char' to
LINE-START, then `forward-line' between each line) rather than calling
something like `expose-watch-line-content-bounds' per line, which would
independently re-seek from `point-min' every time -- fine for a single
lookup, but quadratic here across a multi-line range."

  (let* ((line-start
          (expose-watch-item-line-start item))

         (line-end
          (expose-watch-item-line-end item line-start)))

    (save-excursion
      (goto-char (point-min))
      (forward-line
       (max 0
            (1- line-start)))

      (cl-loop
       for line from line-start to line-end
       do
       (let* ((bol
               (point))

              (eol
               (line-end-position))

              ;; Covers the whole line -- including leading indentation and
              ;; any trailing whitespace, not just the trimmed code the
              ;; underline decorates -- so C-<tab> triggers no matter where
              ;; on the line point happens to be. Extends through the line's
              ;; own trailing newline (when there is one) for the same
              ;; reason the blank-line case below needs real width: a
              ;; zero-width overlay's `keymap' isn't consulted for keyboard
              ;; commands, only real characters make that work.
              (interactive-overlay
               (make-overlay
                bol
                (min (1+ eol) (point-max))
                nil t nil)))

         (overlay-put interactive-overlay 'evaporate nil)
         (overlay-put interactive-overlay 'expose-watch-item item)
         (overlay-put interactive-overlay 'expose-watch-file file)
         (overlay-put interactive-overlay 'expose-watch-hunk-hash hunk-hash)
         (overlay-put interactive-overlay 'keymap expose-watch-source-item-map)

         (push interactive-overlay expose-watch-source-overlays)

         (skip-chars-forward " \t" eol)

         (unless (= (point) eol)

           (let* ((start
                   (point))

                  (end
                   (progn
                     (goto-char eol)
                     (skip-chars-backward " \t" start)
                     (point)))

                  (overlay
                   (make-overlay start end nil t nil)))

             ;; Per-line marker is the primary Watch indicator. This avoids
             ;; relying on the right fringe, which may already be used by
             ;; diagnostics or Git.
             (overlay-put overlay 'face 'expose-watch-item-face)
             (overlay-put overlay 'priority 48)
             (overlay-put overlay 'evaporate nil)
             (overlay-put overlay 'help-echo "Expose Watch comment (C-<tab> toggles detail)")

             (push overlay expose-watch-source-overlays)))

         (goto-char eol)
         (forward-line 1))))

    (expose-watch-source-add-item-card item file hunk-hash line-end)

    (when expose-watch-show-fringe-markers
      (expose-watch-source-add-fringe-overlay item file))))

(defun expose-watch-source-refresh ()
  "Refresh Expose Watch source overlays for current buffer.

While `expose-watch-hidden' is non-nil, the inline underline/card/fringe
markers are skipped entirely, but `expose-watch-visible-item-count' is
still updated as usual, so the mode-line count and the review pipeline
both keep working normally -- only the in-buffer rendering is
suppressed."

  (expose-watch-source-clear)

  (when (and
         expose-watch-mode
         buffer-file-name)

    (let ((file
           (expose-watch-current-buffer-file)))

      ;; Only show overlays for reviewed hunks that still exist in the
      ;; current working-tree diff. Old comments remain in the Watch list,
      ;; but they should not hover over changed/removed code.
      (dolist (hunk
               (expose-watch-current-buffer-active-hunk-entries))

        (dolist (item
                 (plist-get hunk :items))

          (unless expose-watch-hidden
            (expose-watch-source-add-item-overlay
             item
             file
             (plist-get hunk :hash)))

          (setq expose-watch-visible-item-count
                (1+ expose-watch-visible-item-count))))))

  (expose-watch-refresh-mode-line))

(defun expose-watch-source-refresh-all ()
  "Refresh Expose Watch overlays in all file buffers."

  (dolist (buffer
           (buffer-list))

    (when (buffer-live-p buffer)

      (with-current-buffer buffer
        (when (bound-and-true-p expose-watch-mode)
          (expose-watch-source-refresh))))))

;;;###autoload
(defun expose-watch-toggle-hidden ()
  "Toggle whether Expose Watch's inline markers are shown or hidden.

Applies across every watched buffer at once. Watch keeps reviewing
changed hunks and storing comments normally while hidden -- only the
inline underline/card/fringe rendering is suppressed. See
`expose-watch-hidden'."

  (interactive)

  (setq expose-watch-hidden
        (not expose-watch-hidden))

  (expose-watch-source-refresh-all)

  (message
   (if expose-watch-hidden
       "Expose Watch: markers hidden (still reviewing in the background)"
     "Expose Watch: markers shown")))

;;; ---------------------------------------------------------------------------
;;; Review current changed hunks
;;; ---------------------------------------------------------------------------

(defun expose-watch-new-hunks (project-root file)
  "Return changed hunks for FILE that have not already been reviewed."

  (let* ((session
          (expose-watch-load-session project-root))

         (state
          (expose-watch-ensure-file-state session file))

         (hunks
          (expose-watch-current-file-hunks project-root file)))

    (seq-take
     (seq-remove
      (lambda (hunk)
        (or
         (expose-watch-hunk-reviewed-p state hunk)
         (member
          (plist-get hunk :hash)
          expose-watch-pending-hashes)))
      hunks)
     expose-watch-max-hunks-per-run)))

(defun expose-watch-set-state (state)
  "Set Expose Watch STATE for current buffer."

  (setq expose-watch-state state)
  (expose-watch-refresh-mode-line))

;;;###autoload
(defun expose-watch-review-current-buffer ()
  "Review changed hunks in the current watched buffer."

  (interactive)

  (unless buffer-file-name
    (user-error "Expose Watch requires a file buffer"))

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-watch-project-root))

         (file
          (expose-watch-buffer-file project-root)))

    (when (expose-redact-excluded-path-p file project-root)
      (expose-redact-log-excluded-path file project-root)
      (user-error "Expose Watch refuses to review excluded path: %s" file))

    (let* ((hunks
            (expose-watch-new-hunks project-root file)))

      (unless hunks
        ;; Nothing new to send the provider, but this is still a good time to
        ;; drop any reviewed-hunk entries whose hunk no longer exists in the
        ;; current diff, so storage doesn't grow forever on files that keep
        ;; getting saved without producing new hunks.
        (expose-watch-sync-file-state project-root file)

        (when (called-interactively-p 'interactive)
          (message "Expose Watch: no new changed hunks to review")))

      (when hunks
        (let* ((provider
                expose-provider-default)

               (document
                (expose-watch-request file hunks))

               (hashes
                (mapcar
                 (lambda (hunk)
                   (plist-get hunk :hash))
                 hunks))

               (completed nil)
               timeout-timer)

          (setq expose-watch-pending-hashes
                (append
                 expose-watch-pending-hashes
                 hashes))

          (expose-watch-set-state 'running)

          (expose-log
           "Watch"
           "Reviewing %d changed hunk(s) in %s using %s."
           (length hunks)
           file
           provider)

          (setq timeout-timer
                (run-at-time
                 expose-watch-provider-timeout-seconds
                 nil
                 (lambda ()
                   (unless completed
                     (setq completed t)

                     (when (buffer-live-p source-buffer)
                       (with-current-buffer source-buffer

                         (when (and expose-watch-active-process
                                    (process-live-p expose-watch-active-process))

                           (expose-log
                            "Watch"
                            "Killing provider process for %s after timeout."
                            file)

                           (delete-process expose-watch-active-process))

                         (setq expose-watch-active-process nil)

                         (setq expose-watch-pending-hashes
                               (seq-difference
                                expose-watch-pending-hashes
                                hashes
                                #'string=))

                         (expose-watch-set-state 'error)

                         (expose-log
                          "Watch"
                          "Watch review timed out after %d seconds for %s while using %s."
                          expose-watch-provider-timeout-seconds
                          file
                          provider)))))))

          (setq expose-watch-active-process
                (expose-transport-send-document-async
                 provider
                 document

                 (lambda (response-text)

                   (unless completed
                     (setq completed t)

                     (when (timerp timeout-timer)
                       (cancel-timer timeout-timer))

                     (when (buffer-live-p source-buffer)

                       (with-current-buffer source-buffer

                         (setq expose-watch-active-process nil)

                         (setq expose-watch-pending-hashes
                               (seq-difference
                                expose-watch-pending-hashes
                                hashes
                                #'string=))

                         (condition-case parse-error

                             (let ((items
                                    (expose-review-request-parse-items response-text)))

                               (expose-watch-sync-file-state
                                project-root
                                file
                                (mapcar
                                 (lambda (hunk)
                                   (cons
                                    hunk
                                    (expose-watch-items-for-hunk items hunk)))
                                 hunks)
                                response-text)

                               (expose-watch-set-state 'idle)
                               (expose-watch-source-refresh)

                               (expose-log
                                "Watch"
                                "Watch review completed for %s with %d item(s)."
                                file
                                (length items)))

                           (error
                            (expose-watch-set-state 'error)

                            (expose-log
                             "Watch"
                             "Watch review failed to parse response for %s: %s"
                             file
                             (error-message-string parse-error))))))))

                 project-root

                 (lambda (error-data)

                   (unless completed
                     (setq completed t)

                     (when (timerp timeout-timer)
                       (cancel-timer timeout-timer))

                     (when (buffer-live-p source-buffer)

                       (with-current-buffer source-buffer

                         (setq expose-watch-active-process nil)

                         (setq expose-watch-pending-hashes
                               (seq-difference
                                expose-watch-pending-hashes
                                hashes
                                #'string=))

                         (expose-watch-set-state 'error)

                         (expose-log
                          "Watch"
                          "Watch review failed for %s: %s"
                          file
                          (error-message-string error-data)))))))))))))

(defun expose-watch-after-save ()
  "Run Expose Watch after saving the current buffer."

  (when expose-watch-mode
    ;; First remove any source markers whose old hunk hash no longer exists.
    ;; This keeps removed/changed code from showing misleading hovers while
    ;; the next Watch review is running.
    (expose-watch-source-refresh)

    (expose-watch-review-current-buffer)))

;;; ---------------------------------------------------------------------------
;;; Watch list buffer
;;; ---------------------------------------------------------------------------

(defvar expose-watch-list-mode-map
  (let ((map
         (make-sparse-keymap)))

    (set-keymap-parent map special-mode-map)

    (define-key map (kbd "q") #'quit-window)

    map)
  "Keymap for `expose-watch-list-mode'.")

(define-derived-mode expose-watch-list-mode special-mode "ExposeWatch"
  "Read-only Expose Watch list buffer."

  (setq truncate-lines nil)
  (setq buffer-read-only t))

(defun expose-watch-list-insert-label (label value)
  "Insert LABEL and VALUE."

  (unless (expose-watch-blank-p value)

    (insert
     (propertize
      label
      'face
      'expose-watch-list-label-face))

    (insert " ")

    (insert
     (propertize
      (expose-watch-string value)
      'face
      'expose-watch-list-meta-face))

    (insert "\n")))

(defun expose-watch-list-insert-item (item file created-at)
  "Insert watch ITEM for FILE CREATED-AT."

  (let* ((severity
          (expose-watch-string
           (or
            (plist-get item :severity)
            "info")))

         (category
          (expose-watch-string
           (or
            (plist-get item :category)
            "")))

         (title
          (expose-watch-string
           (or
            (plist-get item :title)
            "Watch comment")))

         (comment
          (expose-watch-string
           (or
            (plist-get item :comment)
            "")))

         (line-start
          (expose-watch-item-line-start item))

         (line-end
          (expose-watch-item-line-end item))

         (face
          (expose-watch-severity-face severity)))

    (insert
     (propertize
      (format "[%s] " (upcase severity))
      'face
      face))

    (insert
     (propertize
      title
      'face
      'expose-watch-list-title-face))

    (unless (expose-watch-blank-p category)
      (insert
       (propertize
        (format " (%s)" category)
        'face
        'expose-watch-list-meta-face)))

    (insert "\n")

    (insert "  ")

    (insert
     (propertize
      (expose-watch-format-location
       file
       line-start
       line-end)
      'face
      'font-lock-constant-face))

    (unless (expose-watch-blank-p created-at)
      (insert
       (propertize
        (format "  —  %s" created-at)
        'face
        'expose-watch-list-meta-face)))

    (insert "\n")

    (unless (expose-watch-blank-p comment)
      (dolist (line
               (split-string comment "\n"))

        (insert "  ")
        (insert line)
        (insert "\n")))

    (insert "\n")))

(defun expose-watch-list-render ()
  "Render the current Expose Watch list buffer."

  (let* ((inhibit-read-only t)

         (default-directory
          expose-watch-list-project-root)

         (session
          (expose-watch-load-session
           expose-watch-list-project-root)))

    (erase-buffer)

    (insert
     (propertize
      "Expose Watch\n"
      'face
      'expose-watch-list-title-face))

    (insert "\n")

    (expose-watch-list-insert-label
     "Project:"
     (abbreviate-file-name expose-watch-list-project-root))

    (insert "q quits.\n\n")

    (let ((files
           (plist-get session :files)))

      (if files

          (dolist (state files)

            (let ((file
                   (plist-get state :file))

                  (enabled
                   (plist-get state :enabled))

                  (hunks
                   (plist-get state :reviewed-hunks)))

              (insert
               (propertize
                (format
                 "%s %s\n"
                 (if enabled "●" "○")
                 file)
                'face
                (if enabled
                    'expose-watch-list-title-face
                  'expose-watch-list-meta-face)))

              (if hunks

                  (dolist (hunk hunks)

                    (let ((items
                           (plist-get hunk :items))

                          (created-at
                           (plist-get hunk :created-at))

                          (error
                           (plist-get hunk :error)))

                      (cond
                       (items
                        (dolist (item items)
                          (expose-watch-list-insert-item
                           item
                           file
                           created-at)))

                       (error
                        (insert
                         (propertize
                          (format "  Watch failed: %s\n\n" error)
                          'face
                          'expose-watch-high-face)))

                       (t
                        (insert
                         (propertize
                          (format
                           "  %s:%s-%s — no useful comments. %s\n\n"
                           file
                           (plist-get hunk :line-start)
                           (plist-get hunk :line-end)
                           created-at)
                          'face
                          'expose-watch-list-meta-face))))))

                (insert
                 (propertize
                  "  No watch comments yet.\n\n"
                  'face
                  'expose-watch-list-meta-face)))))

        (insert "No watched files yet.\n")))

    (goto-char (point-min))))

;;;###autoload
(defun expose-watch-open-list ()
  "Open Expose Watch list for the current project."

  (interactive)

  (let* ((project-root
          (expose-watch-project-root))

         (buffer
          (get-buffer-create expose-watch-list-buffer-name)))

    (with-current-buffer buffer
      (setq default-directory project-root)
      (expose-watch-list-mode)
      (setq default-directory project-root)
      (setq expose-watch-list-project-root project-root)
      (expose-watch-list-render))

    (switch-to-buffer buffer)))

;;; ---------------------------------------------------------------------------
;;; Active items buffer
;;;
;;; Unlike the list buffer above (a full history, including comments for
;;; hunks that no longer match the current diff), this only shows items
;;; that are still live right now -- the same view across every watched
;;; file in the project instead of just the one you happen to have open.
;;; ---------------------------------------------------------------------------

(defun expose-watch-active-item-file-path (project-root file)
  "Return absolute path for FILE under PROJECT-ROOT, or nil if it escapes it.

FILE comes from Watch's own stored state, which is always written by
`expose-watch-buffer-file' as a path relative to PROJECT-ROOT -- but this
resolves it defensively anyway, the same way
`expose-review-buffer-item-file-path' does, since it ultimately still
traces back to an AI-provided `:file' value."

  (let ((resolved
         (expand-file-name file project-root)))

    (when (file-in-directory-p resolved project-root)
      resolved)))

(defun expose-watch-active-insert-item (file item)
  "Insert active-items entry for ITEM in FILE.

Tags the whole block with an `expose-watch-active-item' text property so
navigation/jump commands work from anywhere inside it."

  (let* ((block-start
          (point))

         (severity
          (expose-watch-string
           (or
            (plist-get item :severity)
            "info")))

         (category
          (expose-watch-string
           (or
            (plist-get item :category)
            "")))

         (title
          (expose-watch-string
           (or
            (plist-get item :title)
            "Watch comment")))

         (comment
          (expose-watch-string
           (or
            (plist-get item :comment)
            "")))

         (line-start
          (expose-watch-item-line-start item))

         (line-end
          (expose-watch-item-line-end item))

         (face
          (expose-watch-severity-face severity)))

    (insert
     (propertize
      (expose-watch-format-location file line-start line-end)
      'face 'link
      'help-echo "RET jumps to this line"))

    (insert "\n")

    (insert
     (propertize
      (format "[%s] " (upcase severity))
      'face
      face))

    (insert
     (propertize
      title
      'face
      'expose-watch-list-title-face))

    (unless (expose-watch-blank-p category)
      (insert
       (propertize
        (format " (%s)" category)
        'face
        'expose-watch-list-meta-face)))

    (insert "\n")

    (unless (expose-watch-blank-p comment)
      (dolist (line
               (split-string comment "\n"))

        (insert "  ")
        (insert line)
        (insert "\n")))

    (insert "\n")

    (add-text-properties
     block-start
     (point)
     (list
      'expose-watch-active-item
      (list :file file :item item)))))

(defun expose-watch-active-render ()
  "Render the current Expose Watch active-items buffer."

  (let* ((inhibit-read-only t)

         (project-root
          expose-watch-active-project-root)

         (default-directory
          project-root)

         (entries
          (expose-watch-project-active-entries project-root)))

    (erase-buffer)

    (insert
     (propertize
      "Expose Watch — Active Items\n"
      'face
      'expose-watch-list-title-face))

    (insert "\n")

    (expose-watch-list-insert-label
     "Project:"
     (abbreviate-file-name project-root))

    (insert
     "TAB/S-TAB moves between items. RET jumps to the source line. g refreshes. q quits.\n\n")

    (if entries

        (dolist (entry entries)
          (expose-watch-active-insert-item
           (plist-get entry :file)
           (plist-get entry :item)))

      (insert "No active watch items right now.\n"))

    (goto-char (point-min))))

(defun expose-watch-active-current-item ()
  "Return active-items entry at point."

  (or
   (get-text-property
    (point)
    'expose-watch-active-item)

   (get-text-property
    (line-beginning-position)
    'expose-watch-active-item)

   (get-text-property
    (max
     (point-min)
     (1- (line-end-position)))
    'expose-watch-active-item)))

(defun expose-watch-active-next-item-position ()
  "Return position of the next active item after point."

  (let ((current
         (expose-watch-active-current-item))

        (position
         (point))

        found)

    (while (and
            (not found)
            (< position
               (point-max)))

      (setq position
            (next-single-property-change
             position
             'expose-watch-active-item
             nil
             (point-max)))

      (let ((item
             (get-text-property
              position
              'expose-watch-active-item)))

        (when (and item
                   (not
                    (eq item current)))
          (setq found position))))

    found))

(defun expose-watch-active-previous-item-position ()
  "Return position of the previous active item before point."

  (let ((current
         (expose-watch-active-current-item))

        (position
         (point))

        found)

    (while (and
            (not found)
            (> position
               (point-min)))

      (setq position
            (previous-single-property-change
             position
             'expose-watch-active-item
             nil
             (point-min)))

      ;; Step back into the previous property range.
      (let* ((probe
              (max
               (point-min)
               (1- position)))

             (item
              (get-text-property
               probe
               'expose-watch-active-item)))

        (when (and item
                   (not
                    (eq item current)))
          (setq found probe))))

    found))

(defun expose-watch-active-next-item ()
  "Move to next active Expose Watch item."

  (interactive)

  (if-let ((position
            (expose-watch-active-next-item-position)))

      (progn
        (goto-char position)
        (beginning-of-line))

    (message "No next active item")))

(defun expose-watch-active-previous-item ()
  "Move to previous active Expose Watch item."

  (interactive)

  (if-let ((position
            (expose-watch-active-previous-item-position)))

      (progn
        (goto-char position)
        (beginning-of-line))

    (message "No previous active item")))

(defun expose-watch-active-open-item ()
  "Open the active Expose Watch item at point."

  (interactive)

  (let ((entry
         (expose-watch-active-current-item)))

    (unless entry
      (user-error "No active watch item on this line"))

    (let* ((item
            (plist-get entry :item))

           (line
            (or
             (plist-get item :line-start)
             1))

           (path
            (expose-watch-active-item-file-path
             expose-watch-active-project-root
             (plist-get entry :file))))

      (unless path
        (user-error
         "Watch item file is missing or outside the project: %s"
         (plist-get entry :file)))

      (unless (file-exists-p path)
        (user-error "File does not exist: %s" path))

      (find-file path)
      (goto-char (point-min))
      (forward-line
       (max 0
            (1- line)))
      (recenter))))

(defun expose-watch-active-reload ()
  "Reload the current Expose Watch active-items buffer from disk."

  (interactive)

  (unless expose-watch-active-project-root
    (user-error "No Expose Watch project in this buffer"))

  (expose-watch-active-render))

(defvar expose-watch-active-mode-map
  (let ((map
         (make-sparse-keymap)))

    (set-keymap-parent map special-mode-map)

    (define-key map (kbd "TAB") #'expose-watch-active-next-item)
    (define-key map (kbd "<backtab>") #'expose-watch-active-previous-item)
    (define-key map (kbd "RET") #'expose-watch-active-open-item)
    (define-key map (kbd "g") #'expose-watch-active-reload)
    (define-key map (kbd "q") #'quit-window)

    map)
  "Keymap for `expose-watch-active-mode'.")

(define-derived-mode expose-watch-active-mode special-mode "ExposeWatch-Active"
  "Read-only buffer listing every currently-active Expose Watch item."

  (setq truncate-lines nil)
  (setq buffer-read-only t))

(with-eval-after-load 'evil
  ;; Keep normal Evil movement/copy/search behavior; only override the
  ;; navigation keys this mode actually defines.
  (evil-define-key* 'normal expose-watch-active-mode-map
    (kbd "TAB") #'expose-watch-active-next-item
    (kbd "<backtab>") #'expose-watch-active-previous-item
    (kbd "RET") #'expose-watch-active-open-item
    (kbd "g") #'expose-watch-active-reload
    (kbd "q") #'quit-window)

  (evil-define-key* 'motion expose-watch-active-mode-map
    (kbd "TAB") #'expose-watch-active-next-item
    (kbd "<backtab>") #'expose-watch-active-previous-item
    (kbd "RET") #'expose-watch-active-open-item
    (kbd "g") #'expose-watch-active-reload
    (kbd "q") #'quit-window)

  (evil-set-initial-state 'expose-watch-active-mode 'normal))

;;;###autoload
(defun expose-watch-open-active-list ()
  "Open the Expose Watch active-items buffer for the current project."

  (interactive)

  (let* ((project-root
          (expose-watch-project-root))

         (buffer
          (get-buffer-create expose-watch-active-buffer-name)))

    (with-current-buffer buffer
      (setq default-directory project-root)
      (expose-watch-active-mode)
      (setq default-directory project-root)
      (setq expose-watch-active-project-root project-root)
      (expose-watch-active-render))

    (switch-to-buffer buffer)))

;;; ---------------------------------------------------------------------------
;;; Minor modes / commands
;;; ---------------------------------------------------------------------------

(defun expose-watch-enable-if-watched ()
  "Enable `expose-watch-mode' when current file is stored as watched."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file)))

    (when (expose-watch-file-enabled-p project-root file)

      (let ((expose-watch--restoring t))
        (expose-watch-mode 1)))))

(defun expose-watch-auto-enable-on-first-change ()
  "Enable `expose-watch-mode' for the current buffer, if not already on.

Added to `first-change-hook', which Emacs runs the first time a buffer
becomes modified -- including again after a save, since saving clears
the modified flag. The latter is harmless here: once Watch is on for a
file it stays on, so this is a no-op on every save after the first."

  (unless expose-watch-mode
    (expose-watch-mode 1)))

(defun expose-watch-arm-auto-watch ()
  "Arm the current buffer to auto-enable Expose Watch on its first edit.

Only takes effect when the current project has auto-arming enabled (see
`expose-watch-toggle-project-auto') and the file isn't already watched
or excluded from Expose requests."

  (when-let* ((project-root
               (expose-watch-current-project-root))

              (file
               (expose-watch-current-buffer-file)))

    (when (and
           (not expose-watch-mode)
           (expose-watch-project-auto-enabled-p project-root)
           (not (expose-redact-excluded-path-p file project-root)))

      (add-hook 'first-change-hook #'expose-watch-auto-enable-on-first-change nil t))))

;;;###autoload
(defun expose-watch-toggle-project-auto ()
  "Toggle Expose Watch auto-arming for the current project.

When enabled, editing any file in this project for the first time
automatically enables `expose-watch-mode' for that file -- the first
save after that runs Expose Watch exactly as if you'd enabled it by
hand. Applies immediately to already-open buffers in this project, and
via `expose-watch-global-mode' to any file opened afterward."

  (interactive)

  (let* ((project-root
          (expose-watch-project-root))

         (enabled
          (not (expose-watch-project-auto-enabled-p project-root))))

    (expose-watch-set-project-auto-enabled project-root enabled)

    (when enabled
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when buffer-file-name
            (expose-watch-arm-auto-watch)))))

    (message
     "Expose Watch auto-arming %s for %s"
     (if enabled "enabled" "disabled")
     (abbreviate-file-name project-root))))

;;;###autoload
(define-minor-mode expose-watch-mode
  "Watch this buffer for changed hunks and background review comments."
  :lighter nil

  (if expose-watch-mode

      (progn
        (unless expose-watch--restoring
          (let* ((project-root
                  (expose-watch-project-root))

                 (file
                  (expose-watch-buffer-file project-root)))

            (expose-watch-enable-file-state project-root file)))

        (setq expose-watch-state 'idle)

        (add-hook 'after-save-hook #'expose-watch-after-save nil t)

        (expose-watch-source-refresh)
        (expose-watch-refresh-mode-line))

    (remove-hook 'after-save-hook #'expose-watch-after-save t)

    ;; expose-watch-mode is already nil at this point, so this just clears
    ;; overlays (the loop that would rebuild them never runs).
    (expose-watch-source-refresh)

    (setq expose-watch-state 'idle)
    (setq expose-watch-visible-item-count 0)

    (unless expose-watch--restoring
      (when-let* ((project-root
                   (expose-watch-current-project-root))

                  (file
                   (expose-watch-current-buffer-file)))

        (expose-watch-disable-file-state project-root file)))

    (expose-watch-refresh-mode-line)))

;;;###autoload
(define-minor-mode expose-watch-global-mode
  "Restore Expose Watch mode for watched files, and arm auto-watch projects."
  :global t

  (if expose-watch-global-mode

      (progn
        (add-hook 'find-file-hook #'expose-watch-enable-if-watched)
        (add-hook 'find-file-hook #'expose-watch-arm-auto-watch)

        (dolist (buffer
                 (buffer-list))
          (with-current-buffer buffer
            (when buffer-file-name
              (expose-watch-enable-if-watched)
              (expose-watch-arm-auto-watch)))))

    (remove-hook 'find-file-hook #'expose-watch-enable-if-watched)
    (remove-hook 'find-file-hook #'expose-watch-arm-auto-watch)))

;;;###autoload
(defun expose-watch-current-buffer ()
  "Enable Expose Watch for the current buffer."

  (interactive)

  (expose-watch-mode 1)

  (message
   "Expose Watch enabled for %s."
   (or
    (expose-watch-current-buffer-file)
    (buffer-name))))

;;;###autoload
(defun expose-watch-unwatch-current-buffer ()
  "Disable Expose Watch for the current buffer."

  (interactive)

  (expose-watch-mode -1)

  (message
   "Expose Watch disabled for %s."
   (or
    (expose-watch-current-buffer-file)
    (buffer-name))))

;;;###autoload
(defun expose-watch-clear-current-buffer ()
  "Clear Expose Watch comments for the current buffer."

  (interactive)

  (let* ((project-root
          (expose-watch-project-root))

         (file
          (expose-watch-buffer-file project-root)))

    (expose-watch-clear-file project-root file)
    (expose-watch-source-refresh)

    (message
     "Expose Watch comments cleared for %s."
     file)))

;;;###autoload
(defun expose-watch-clear-project ()
  "Clear Expose Watch comments for the current project."

  (interactive)

  (let ((project-root
         (expose-watch-project-root)))

    (expose-watch-clear-project-session project-root)
    (expose-watch-source-refresh-all)

    (message "Expose Watch project comments cleared.")))

(expose-watch-install-mode-line)

(provide 'expose-watch)
