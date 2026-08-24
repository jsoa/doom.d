;;; expose-popup.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'posframe)
(require 'expose-history)
(require 'expose-log)
(require 'expose-side-panel)
(require 'markdown-mode nil t)

(declare-function posframe-hide "posframe")
(declare-function posframe-show "posframe")
(declare-function posframe-refresh "posframe")
(declare-function expose-key-prefix-binding "expose")

(defgroup expose-popup nil
  "Generic EXPOSE popup UI."
  :group 'tools)

(defcustom expose-popup-scroll-lines 1
  "Number of lines Expose popup scroll commands move."
  :type 'integer
  :group 'expose-popup)

(defcustom expose-popup-max-width 160
  "Maximum width of Expose popups."
  :type 'integer
  :group 'expose-popup)

(defcustom expose-popup-max-height 30
  "Maximum height of Expose popups."
  :type 'integer
  :group 'expose-popup)

(defcustom expose-popup-min-width 80
  "Minimum width of Expose popups."
  :type 'integer
  :group 'expose-popup)

(defcustom expose-popup-min-height 1
  "Minimum height of Expose popups."
  :type 'integer
  :group 'expose-popup)

(defconst expose-popup-buffer-name
  " *expose-popup*")

(defvar expose-popup-visible nil)
(defvar expose-popup-scroll-indicator "")
(defvar expose-popup-action-registry nil
  "Registered popup actions.")
(defvar expose-popup-mode-line-title nil
  "Current title shown in the Expose popup mode line.")

(defvar expose-popup-mode-line-status nil
  "Current status shown in the Expose popup mode line.")

(defface expose-popup-title-face
  '((t (:inherit mode-line
        :extend t)))
  "Face for popup titles.")

(defun expose-popup-view-history-p (view)
  "Return non-nil if VIEW should be added to history."

  (not
   (and
    (memq :history view)
    (eq
     (plist-get view :history)
     nil))))

;;; ---------------------------------------------------------------------------
;;; Modeline
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Random tip
;;; ---------------------------------------------------------------------------
;;
;; A pure discovery mechanic, not a recommendation: it names something that
;; exists, not something worth doing right now. Anything context-aware
;; (which of these actually applies to what you're looking at) is a much
;; harder, heavier problem -- the same one declined for a "no test
;; coverage" mode-line hint elsewhere in this config, for the same reason.
;;
;; The pool is read from the real, installed keymap under
;; `expose-key-prefix' rather than a hand-maintained list next to it. A
;; second list invites exactly the drift this session already found once,
;; in the README's own keybinding table -- a binding added to the keymap
;; and never added to the list beside it. Walking the keymap means there
;; is nothing to keep in sync: whatever is actually bound is what shows.

(defcustom expose-popup-tip-exclude-commands
  '(expose-popup-scroll-down
    expose-popup-scroll-up
    expose-popup-hide
    expose-popup-copy
    expose-popup-open
    expose-history-open
    expose-log-open
    expose-log-clear
    expose-hover-debug-current-buffer)
  "Commands under `expose-key-prefix' never shown as a hover tip.

The popup's own housekeeping -- scrolling itself, closing itself,
copying itself -- which you learn by using the popup at all, not from a
tip about it."
  :type '(repeat symbol)
  :group 'expose-popup)

(defcustom expose-popup-tip-max-length 46
  "Longest a tip's description may be before it is cut with an ellipsis.

Keeps a long first line of some command's docstring from pushing the
tip mode-line segment wide enough to wrap or run off the edge of a
posframe capped at `expose-popup-max-width'."
  :type 'integer
  :group 'expose-popup)

(defvar expose-popup--tip-pool-computed nil
  "Non-nil once `expose-popup-tip-pool' has run, even if it found nothing.

Distinct from the pool being empty, so an empty project-relative keymap
\(Expose keybindings skipped, per `expose-key-prefix-conflict-p') is not
re-walked on every single hover.")

(defvar expose-popup--tip-pool nil
  "Cached (KEY-STRING . COMMAND) pairs available as a hover tip.

The keymap under `expose-key-prefix' does not change after Doom starts,
so this is computed once and reused -- walking it is cheap by keymap
standards, but there is no reason to repeat identical work on every
hover in a session that shows hundreds of them.")

(defun expose-popup-tip-collect (keymap prefix)
  "Return (KEY-STRING . COMMAND) pairs for every command bound in KEYMAP.

PREFIX is the key vector leading to KEYMAP, prepended to each binding
found. Recurses into sub-keymaps, which is how `SPC c h h'/`G'/`R'/`M'/
`W' -- prefixes of a prefix -- are reached at all."

  (let (found)
    (when (keymapp keymap)
      (map-keymap
       (lambda (event binding)
         (let ((path (vconcat prefix (vector event))))
           (cond
            ((keymapp binding)
             (setq found (append found (expose-popup-tip-collect binding path))))
            ((and (commandp binding) (symbolp binding)
                  (not (memq binding expose-popup-tip-exclude-commands)))
             (push (cons (key-description path) binding) found)))))
       keymap))
    found))

(defun expose-popup-tip-pool ()
  "Return the memoized pool of (KEY-STRING . COMMAND) tip candidates."

  (unless expose-popup--tip-pool-computed
    (setq expose-popup--tip-pool-computed t)
    (setq expose-popup--tip-pool
          (when (fboundp 'expose-key-prefix-binding)
            (when-let ((keymap (expose-key-prefix-binding)))
              (when (keymapp keymap)
                (expose-popup-tip-collect keymap []))))))
  expose-popup--tip-pool)

(defun expose-popup-tip-description (command)
  "Return a short description of COMMAND from its own docstring.

Not a separately maintained label: the first line of the docstring is
the same sentence `C-h f' would show, so it cannot describe a command
differently from what the command actually is."

  (let* ((doc (or (documentation command) ""))
         (line (car (split-string doc "\n"))))
    (if (> (length line) expose-popup-tip-max-length)
        (concat (substring line 0 expose-popup-tip-max-length) "…")
      line)))

(defun expose-popup-random-tip ()
  "Return a random \"did you know\" string, or nil if there is nothing to show."

  (when-let* ((pool (expose-popup-tip-pool))
              (entry (nth (random (length pool)) pool))
              (label (expose-popup-key-prefix-label)))
    (format "tip: %s %s -- %s"
            label (car entry)
            (expose-popup-tip-description (cdr entry)))))

(defun expose-popup-key-prefix-label ()
  "Return the Expose key prefix label."

  (format
   "SPC %s"
   (if (boundp 'expose-key-prefix)
       expose-key-prefix
     "c h")))

(defvar expose-popup--showing-hover nil
  "Non-nil while the popup buffer holds passive hover content.

Set by `expose-popup-show-content', cleared by `expose-popup-show-view'.
The tip only appears here, never on an action result: hover shows up
unasked, so a tip fits it the way it would not fit a result you
specifically requested and are trying to read.")

(defvar expose-popup--current-tip nil
  "The tip chosen for the hover currently on screen, or nil.

Picked once, when the hover is shown -- not read fresh from
`expose-popup-mode-line-info', which is the `:eval' form re-run on
every mode-line refresh. Picking there would re-randomize the tip
continuously for as long as one hover stayed on screen, flickering
rather than holding still long enough to read.")

(defun expose-popup-mode-line-info ()
  "Return compact Expose popup mode-line info."

  (string-join
   (delq
    nil
    (list
     (propertize
      "EXPOSE"
      'face
      'mode-line-buffer-id)

     (propertize
      (expose-popup-key-prefix-label)
      'face
      'font-lock-keyword-face)

     expose-popup-mode-line-title

     (when (expose-popup-scroll-indicator-visible-p)
       (propertize
        expose-popup-scroll-indicator
        'face
        'shadow))

     expose-popup-mode-line-status

     (when (and expose-popup--showing-hover expose-popup--current-tip)
       (propertize expose-popup--current-tip 'face 'shadow))))
   "   "))

(defun expose-popup-mode-line-format ()
  "Return the Expose popup mode-line format."

  '(" "
    (:eval
     (expose-popup-mode-line-info))
    " "))

(defun expose-popup-set-mode-line (title &optional status)
  "Set popup mode-line TITLE and optional STATUS."

  (setq expose-popup-mode-line-title title)
  (setq expose-popup-mode-line-status status)

  (force-mode-line-update t))

;;; ---------------------------------------------------------------------------
;;; Actions
;;; ---------------------------------------------------------------------------

(defun expose-popup-register-action (key label kind command &rest props)
  "Register a popup action."

  (let ((action
         (append
          (list
           :key key
           :label label
           :kind kind
           :command command)
          props)))

    (expose-log
     "Popup"
     "Registering action %c: %s (%s)."
     key
     label
     kind)

    (setq expose-popup-action-registry
          (append
           (seq-remove
            (lambda (existing)
              (eq
               (plist-get existing :key)
               key))
            expose-popup-action-registry)
           (list action)))))

(defun expose-popup-actions ()
  "Return the registered popup actions."

  expose-popup-action-registry)

(defun expose-popup-clear-actions ()
  "Remove all registered popup actions."

  (setq expose-popup-action-registry nil))

(defun expose-popup-find-action (key)
  "Return the action registered for KEY."

  (seq-find
   (lambda (action)
     (eq (plist-get action :key) key))
   (expose-popup-actions)))

(defun expose-popup-command-p (command)
  "Return non-nil if COMMAND is an Expose popup command."
  (and (symbolp command)
       (or
        (get command 'expose-popup-command)
        (seq-some
         (lambda (action)
           (eq command (plist-get action :command)))
         (expose-popup-actions)))))

(defun expose-popup-run-action (key)
  "Run the popup action for KEY."

  (if-let ((action
            (expose-popup-find-action key)))

      (progn
        (expose-log
         "Popup"
         "Running action %c: %s."
         key
         (plist-get action :label))

        (pcase (plist-get action :kind)

          ('action
           (funcall
            (plist-get action :command)))

          ('view
           (expose-popup-run-view-action action))

          (_
           (expose-log
            "Popup"
            "Unknown action kind for key %c: %s."
            key
            (plist-get action :kind)))))

    (expose-log
     "Popup"
     "No action registered for key %c."
     key)))

(defvar expose-popup-view-display-function #'expose-popup-show-view
  "Function called to display a view for a registered `view'-kind action.

Called as (FUNCTION VIEW SOURCE-WINDOW). Indirected through a variable,
rather than `expose-popup-run-view-action' calling
`expose-popup-show-view' directly, so a caller elsewhere can redirect
where these specific results go without this file needing to depend on
anything about what does -- `expose-commands.el' sets this to show
`SPC c h h' results in a persistent side window instead, and requiring
that from here (to call it directly) would be circular, since it in
turn requires this file for the rendering it reuses.

Every OTHER caller of `expose-popup-show-view' in this library --
Watch, Region Review, Full Review's source hover -- calls it directly
and never goes through this variable, so redirecting it here has no
effect on them.")

(defun expose-popup-run-view-action (action)
  "Run a popup view ACTION."

  (let ((label
         (plist-get action :label))

        (async
         (plist-get action :async))

        ;; Captured once, here, rather than read fresh wherever it is
        ;; used below: the async branch's callback runs later, by which
        ;; time the selected window may be anywhere.
        (source-window
         (selected-window)))

    (expose-log
     "Popup"
     "Showing loading view for %s."
     label)

    (funcall
     expose-popup-view-display-function
     (expose-popup-loading-view label)
     source-window)

    (expose-popup-set-mode-line
     (format "Loading %s" label))

    (if async

        (progn
          (expose-log
           "Popup"
           "Starting async view action: %s."
           label)

          (funcall
           (plist-get action :command)
           (lambda (view)
             (funcall expose-popup-view-display-function view source-window))))

      (expose-log
       "Popup"
       "Starting sync view action: %s."
       label)

      (funcall
       expose-popup-view-display-function
       (funcall (plist-get action :command))
       source-window))))

;;; ---------------------------------------------------------------------------
;;; Views
;;; ---------------------------------------------------------------------------

(defun expose-popup-view-create (title body)
  "Create a popup view."

  (list
   :title title
   :body body))

(defun expose-popup-view-title (view)
  "Return VIEW's title."

  (plist-get view :title))

(defun expose-popup-view-body (view)
  "Return VIEW's body."

  (plist-get view :body))

(defun expose-popup-loading-view (title)
  "Return a loading view."

  (list
   :title title
   :body "Loading..."
   :format 'plain
   :history nil))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun expose-popup-insert-separator ()
  "Insert a popup separator."

  (insert
   (propertize
    (make-string 60 ?─)
    'face 'shadow)))

(defun expose-popup-show-buffer ()
  "Show the popup buffer."

  (posframe-show
   expose-popup-buffer-name
   :position (point)
   :border-width 1
   :border-color "#666666"
   :internal-border-width 8
   :left-fringe 8
   :right-fringe 8
   :respect-header-line t
   :respect-mode-line t
   :min-width expose-popup-min-width
   :max-width expose-popup-max-width
   :min-height expose-popup-min-height
   :max-height expose-popup-max-height)

  (setq expose-popup-visible t))

(defun expose-popup-string-has-face-p (text)
  "Return non-nil if TEXT already has face properties."

  (let ((position 0)
        found)

    (while (and
            (not found)
            (< position
               (length text)))

      (when (get-text-property position 'face text)
        (setq found t))

      (setq position
            (or
             (next-single-property-change
              position
              'face
              text)
             (length text))))

    found))


(defun expose-popup-render-markdown (text)
  "Return TEXT fontified as Markdown when possible."

  (cond
   ((not
     (stringp text))
    (format "%s" text))

   ;; Do not re-fontify strings that already carry faces. Watch, Review,
   ;; Region Review, and other custom views may already build propertized
   ;; popup bodies.
   ((expose-popup-string-has-face-p text)
    text)

   ((not
     (fboundp 'markdown-mode))
    text)

   (t
    (with-temp-buffer
      (delay-mode-hooks
        (markdown-mode))

      (font-lock-mode 1)

      (insert
       (string-trim-right
        (or text "")))

      (font-lock-ensure
       (point-min)
       (point-max))

      (buffer-string)))))


(defun expose-popup-render-body (view)
  "Return rendered popup body for VIEW."

  (let ((body
         (expose-popup-view-body view))

        (format
         (or
          (plist-get view :format)
          'markdown)))

    (pcase format
      ('plain
       (if (stringp body)
           body
         (format "%s" body)))

      ('markdown
       (expose-popup-render-markdown body))

      (_
       (if (stringp body)
           body
         (format "%s" body))))))

(defun expose-popup-show-view (view &optional _source-window)
  "Display VIEW in the popup.

SOURCE-WINDOW is accepted and ignored -- present only so this remains a
valid value for `expose-popup-view-display-function', which is called
with it."

  (expose-log
   "Popup"
   "Showing view: %s (%d bytes)."
   (expose-popup-view-title view)
   (length
    (or
     (expose-popup-view-body view)
     "")))

  (expose-popup-set-mode-line
   (expose-popup-view-title view))

  ;; Not a hover: this is a result you asked for, and a tip about some
  ;; other command would compete with the answer you are trying to read.
  (setq expose-popup--showing-hover nil)
  (setq expose-popup--current-tip nil)

  (let ((buffer
         (get-buffer-create expose-popup-buffer-name)))

    (with-current-buffer buffer

      (unless (derived-mode-p 'expose-popup-mode)
        (expose-popup-mode))

      (setq buffer-read-only nil)
      (erase-buffer)

      (insert
       (propertize
        (expose-popup-view-title view)
        'face
        'expose-popup-title-face))

      (insert "\n")

      (expose-popup-insert-separator)

      (insert "\n")

      (insert
       (expose-popup-render-body view))

      (goto-char (point-min))
      (setq buffer-read-only t))

    (posframe-refresh expose-popup-buffer-name)

    (when (expose-popup-view-history-p view)
      (expose-history-add view))

    (expose-popup-show-buffer)

    (expose-popup-update-scroll-indicator)))

(defun expose-popup-show-content (content)
  "Display CONTENT in the popup buffer."

  (expose-log
   "Popup"
   "Showing hover content (%d bytes)."
   (length content))

  (expose-popup-set-mode-line
   "Hover")

  ;; Picked once, here -- not from `expose-popup-mode-line-info', which
  ;; runs on every mode-line refresh and would re-randomize the tip for
  ;; as long as this one hover stays on screen.
  (setq expose-popup--showing-hover t)
  (setq expose-popup--current-tip (expose-popup-random-tip))

  (let ((buffer
         (get-buffer-create expose-popup-buffer-name)))

    (with-current-buffer buffer

      (unless (derived-mode-p 'expose-popup-mode)
        (expose-popup-mode))

      (setq buffer-read-only nil)
      (erase-buffer)

      (insert content)

      (goto-char (point-min))
      (setq buffer-read-only t))

    (expose-popup-show-buffer)

    (expose-popup-update-scroll-indicator)))

(defun expose-popup-hide ()
  "Hide the popup."

  (when expose-popup-visible
    (expose-log
     "Popup"
     "Hiding popup."))

  (setq expose-popup-visible nil)
  (setq expose-popup-scroll-indicator "")

  (expose-popup-set-mode-line nil nil)

  (posframe-hide expose-popup-buffer-name))

(defun expose-popup-update-scroll-indicator ()
  "Update the popup scroll indicator."

  (setq expose-popup-scroll-indicator
        (if-let ((window
                  (get-buffer-window expose-popup-buffer-name t)))

            (with-current-buffer
                (get-buffer-create expose-popup-buffer-name)

              (let ((above
                     (> (window-start window)
                        (point-min)))

                    (below
                     (< (window-end window t)
                        (point-max))))

                (cond
                 ((and above below)
                  "▲ ▼")

                 (above
                  "▲")

                 (below
                  "▼")

                 (t
                  ""))))

          ""))

  (force-mode-line-update t))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun expose-popup-scroll-indicator-visible-p ()
  "Return non-nil if the popup scroll indicator should be displayed."

  (and
   expose-popup-scroll-indicator
   (not
    (string-empty-p expose-popup-scroll-indicator))))

(defun expose-popup-copy ()
  "Copy the current popup contents to the kill ring."

  (interactive)

  (when-let ((buffer (get-buffer expose-popup-buffer-name)))
    (with-current-buffer buffer
      (kill-new (buffer-string))
      (message "Popup copied"))))

(defun expose-popup-open ()
  "Open the current popup in a normal buffer.

Placed beside the buffer this was invoked from -- see
`expose-side-panel-place'. SOURCE-WINDOW is captured before anything
else runs: the posframe popup does not take keyboard focus, so
`(selected-window)' is still the real code window underneath it, not
the popup itself."

  (interactive)

  (let ((source-window (selected-window))
        (popup (get-buffer expose-popup-buffer-name))
        (target (generate-new-buffer "*EXPOSE Popup*")))

    (when popup

      (with-current-buffer target

        (insert-buffer-substring popup)

        (goto-char (point-min)))

      (select-window
       (expose-side-panel-place source-window target)))))

(defun expose-popup-window ()
  "Return the visible Expose popup window, or nil."

  (get-buffer-window expose-popup-buffer-name t))

(defun expose-popup-scroll-window (direction)
  "Scroll the Expose popup window in DIRECTION.

DIRECTION should be `down' to move farther down the popup content,
or `up' to move back toward the top."

  (when-let ((window
              (expose-popup-window)))

    (with-selected-window window
      (condition-case nil
          (pcase direction
            ('down
             ;; Emacs' `scroll-up' moves the viewport down through content.
             (scroll-up expose-popup-scroll-lines))

            ('up
             ;; Emacs' `scroll-down' moves the viewport up through content.
             (scroll-down expose-popup-scroll-lines)))
        (beginning-of-buffer nil)
        (end-of-buffer nil)))

    (expose-popup-update-scroll-indicator)))

(defun expose-popup-scroll-down ()
  "Scroll the Expose popup down by `expose-popup-scroll-lines'."

  (interactive)

  (expose-popup-scroll-window 'down))

(defun expose-popup-scroll-up ()
  "Scroll the Expose popup up by `expose-popup-scroll-lines'."

  (interactive)

  (expose-popup-scroll-window 'up))

;;; ---------------------------------------------------------------------------
;;; Hover Scroll Keys
;;; ---------------------------------------------------------------------------

(defvar expose-popup-scroll-keymap
  (let ((map
         (make-sparse-keymap)))

    ;; Same behavior as SPC c h j.
    (define-key
     map
     (kbd "C-j")
     #'expose-popup-scroll-down)

    ;; Same behavior as SPC c h k.
    (define-key
     map
     (kbd "C-k")
     #'expose-popup-scroll-up)

    map)
  "Keymap active while the Expose popup is visible.")

(defvar expose-popup-scroll-keymap-alist nil
  "Emulation keymap alist for Expose popup scroll keys.")

(setq expose-popup-scroll-keymap-alist
      `((expose-popup-visible . ,expose-popup-scroll-keymap)))

(defun expose-popup-install-scroll-keys ()
  "Install temporary Expose popup scroll keys."

  (unless (memq
           'expose-popup-scroll-keymap-alist
           emulation-mode-map-alists)

    (add-to-list
     'emulation-mode-map-alists
     'expose-popup-scroll-keymap-alist)))

(put 'expose-popup-scroll-down
     'expose-popup-command
     t)

(put 'expose-popup-scroll-up
     'expose-popup-command
     t)

(expose-popup-install-scroll-keys)

;;; ---------------------------------------------------------------------------
;;; Mode
;;; ---------------------------------------------------------------------------

(define-derived-mode expose-popup-mode special-mode "Expose"
  "Major mode for Expose popups."

  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)

  (setq-local
   mode-line-format
   (expose-popup-mode-line-format)))

;;; ---------------------------------------------------------------------------
;;; Default Actions
;;; ---------------------------------------------------------------------------

(expose-popup-register-action
 ?j
 "↓"
 'action
 #'expose-popup-scroll-down)

(expose-popup-register-action
 ?k
 "↑"
 'action
 #'expose-popup-scroll-up)

(expose-popup-register-action
 ?y
 "Copy"
 'action
 #'expose-popup-copy)

(expose-popup-register-action
 ?o
 "Open"
 'action
 #'expose-popup-open)

(expose-popup-register-action
 ?h
 "History"
 'action
 #'expose-history-open)

(provide 'expose-popup)
