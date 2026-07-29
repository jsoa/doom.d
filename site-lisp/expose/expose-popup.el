;;; expose-popup.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'posframe)
(require 'expose-history)
(require 'expose-log)
(require 'markdown-mode nil t)

(declare-function posframe-hide "posframe")
(declare-function posframe-show "posframe")
(declare-function posframe-refresh "posframe")

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

(defun expose-popup-key-prefix-label ()
  "Return the Expose key prefix label."

  (format
   "SPC %s"
   (if (boundp 'expose-key-prefix)
       expose-key-prefix
     "c h")))

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

     expose-popup-mode-line-status))
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

(defun expose-popup-run-view-action (action)
  "Run a popup view ACTION."

  (let ((label
         (plist-get action :label))

        (async
         (plist-get action :async)))

    (expose-log
     "Popup"
     "Showing loading view for %s."
     label)

    (expose-popup-show-view
     (expose-popup-loading-view label))

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
           #'expose-popup-show-view))

      (expose-log
       "Popup"
       "Starting sync view action: %s."
       label)

      (expose-popup-show-view
       (funcall
        (plist-get action :command))))))

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

(defun expose-popup-show-view (view)
  "Display VIEW in the popup."

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
  "Open the current popup in a normal buffer."

  (interactive)

  (let ((source (get-buffer expose-popup-buffer-name))
        (target (generate-new-buffer "*EXPOSE Popup*")))

    (when source

      (with-current-buffer target

        (insert-buffer-substring source)

        (goto-char (point-min)))

      (pop-to-buffer target))))

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
