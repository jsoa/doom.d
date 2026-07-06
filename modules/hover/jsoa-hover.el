;;; jsoa-hover.el -*- lexical-binding: t; -*-

(require 'posframe)
(declare-function posframe-hide "posframe")
(declare-function posframe-show "posframe")

(defgroup jsoa-hover nil
  "Hover popup."
  :group 'tools)

(defcustom jsoa-hover-delay 0.25
  "Delay before showing hover."
  :type 'number
  :group 'jsoa-hover)

(defcustom jsoa-hover-max-width 120
  "Maximum width of the hover popup."
  :type 'integer
  :group 'jsoa-hover)

(defcustom jsoa-hover-max-height 20
  "Maximum height of the hover popup."
  :type 'integer
  :group 'jsoa-hover)

(defvar jsoa-hover-mode 'hover)

;;; ---------------------------------------------------------------------------
;;; Actions
;;; ---------------------------------------------------------------------------

(defvar jsoa-hover-action-registry nil
  "Registered hover actions.")

(defun jsoa-hover-register-action (key label kind command &rest props)
  "Register a hover action."

  (push
   (append
    (list
     :key key
     :label label
     :kind kind
     :command command)
    props)
   jsoa-hover-action-registry))

(defun jsoa-hover-actions ()
  "Return the registered hover actions."

  jsoa-hover-action-registry)

(defun jsoa-hover-clear-actions ()
  "Remove all registered hover actions."

  (setq jsoa-hover-action-registry nil))

(defun jsoa-hover-find-action (key)
  "Return the action registered for KEY."

  (seq-find
   (lambda (action)
     (eq (plist-get action :key) key))
   (jsoa-hover-actions)))

(defun jsoa-hover-run-action (key)
  "Run the hover action for KEY."

  (when-let ((action (jsoa-hover-find-action key)))

    (pcase (plist-get action :kind)

      ('action
       (funcall
        (plist-get action :command)))

      ('view
       (jsoa-hover-run-view-action action))
      )))

(defun jsoa-hover-run-view-action (action)
  "Run a hover view ACTION."

  (jsoa-hover-show-view
   (jsoa-hover-loading-view
    (plist-get action :label)))

  (if (plist-get action :async)

      (funcall
       (plist-get action :command)
       #'jsoa-hover-show-view)

    (jsoa-hover-show-view
     (funcall
      (plist-get action :command)))))

;;; ---------------------------------------------------------------------------
;;; Views
;;; ---------------------------------------------------------------------------

(defun jsoa-hover-view-create (title body)
  "Create a hover view."

  (list
   :title title
   :body body))

(defun jsoa-hover-view-title (view)
  "Return VIEW's title."

  (plist-get view :title))

(defun jsoa-hover-view-body (view)
  "Return VIEW's body."

  (plist-get view :body))

(defun jsoa-hover-show-view (view)
  "Display VIEW in the hover popup."

  (setq jsoa-hover-mode 'view)

  (let ((buffer (get-buffer-create jsoa-hover-buffer-name)))

    (with-current-buffer buffer

      (unless (derived-mode-p 'jsoa-hover-popup-mode)
        (jsoa-hover-popup-mode))

      (setq buffer-read-only nil)
      (erase-buffer)

      (insert
       (propertize
        (plist-get view :title)
        'face 'jsoa-hover-signature-face))

      (insert "\n")

      (jsoa-hover-insert-separator)

      (insert "\n")

      (insert
       (plist-get view :body)
       )

      (goto-char (point-min))
      (setq buffer-read-only t))

    (posframe-refresh jsoa-hover-buffer-name)

    (posframe-show
     jsoa-hover-buffer-name
     :position (point)
     :border-width 1
     :border-color "#666666"
     :internal-border-width 8
     :left-fringe 8
     :right-fringe 8
     :respect-header-line t
     :respect-mode-line t
     :min-width 65
     :max-width jsoa-hover-max-width
     :min-height 1
     :max-height jsoa-hover-max-height)

    (setq jsoa-hover-visible t)))

(defun jsoa-hover-loading-view (title)
  "Return a loading view."

  (jsoa-hover-view-create
   title
   "Loading..."))

;;; ---------------------------------------------------------------------------
;;; Renderer
;;; ---------------------------------------------------------------------------

(defun jsoa-hover-render-actions ()
  "Return the hover action footer."

  (let (result)

    (dolist (action (jsoa-hover-actions))

      (setq result
            (append
             result
             (list
              (propertize
               (format "[%c]" (plist-get action :key))
               'face
               'font-lock-keyword-face)

              " "

              (plist-get action :label)

              "   "))))

    result)
  )

(defconst jsoa-hover-buffer-name
  " *jsoa-hover*")
(defvar jsoa-hover-timer nil)
(defvar jsoa-hover-visible nil)
(defvar jsoa-hover-last-point nil)
(defvar jsoa-hover-scroll-indicator "")
(defvar jsoa-hover-data nil)
(defvar jsoa-hover-request-point nil)

(defface jsoa-hover-mode-line-face
  '((t (:inherit mode-line
        :height 0.9)))
  "Mode line for hover popups.")

(defun jsoa-hover-suppressed-p ()
  (or (minibufferp)
      (and (bound-and-true-p corfu--frame)
           (frame-visible-p corfu--frame))))

(defface jsoa-hover-signature-face
  '((t (:inherit mode-line
        :extend t)))
  "Face for the hover signature.")

(define-derived-mode jsoa-hover-popup-mode special-mode "Hover"
  "Major mode for JSOA hover."

  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)

  (setq-local
   mode-line-format
   (append
    '(" "
      (:propertize "SPC c h"
                   'face
                   'mode-line-buffer-id)
      "   ")
    (jsoa-hover-render-actions))))

(defun jsoa-hover-render-current ()
  "Render the current hover model."

  (unless (eq jsoa-hover-mode 'hover)
    (cl-return-from jsoa-hover-render-current))

  (when jsoa-hover-data
    (jsoa-hover-render
     jsoa-hover-data
     major-mode)))

(defun jsoa-hover-update-scroll-indicator ()
  (setq jsoa-hover-scroll-indicator
        (when-let ((window (get-buffer-window jsoa-hover-buffer-name t)))
          (let ((above (> (window-start window) (point-min)))
                (below (< (window-end window t) (point-max))))
            (cond
             ((and above below) "▲ ▼")
             (above "▲")
             (below "▼")
             (t "")))))

  (force-mode-line-update t))

(defun jsoa-hover-copy ()
  "Copy the current hover contents to the kill ring."
  (interactive)

  (when-let ((buffer (get-buffer jsoa-hover-buffer-name)))
    (with-current-buffer buffer
      (kill-new (buffer-string))
      (message "Hover copied"))))

(defun jsoa-hover-open ()
  "Open the current hover in a normal window."
  (interactive)

  (when-let ((buffer (get-buffer jsoa-hover-buffer-name)))
    (jsoa-hover-hide)
    (pop-to-buffer buffer)))

(defun jsoa-hover-command-p (command)
  "Return non-nil if COMMAND is a registered hover action."

  (seq-some
   (lambda (action)
     (eq command
         (plist-get action :command)))
   (jsoa-hover-actions)))

(defun jsoa-hover-close ()
  (interactive)
  (setq jsoa-hover-last-point (point))
  (jsoa-hover-hide))

(defun jsoa-hover-insert-separator ()
  (insert
   (propertize
    (make-string 60 ?─)
    'face 'shadow)))

(defun jsoa-hover-scroll-down ()
  (interactive)

  (when-let ((window (get-buffer-window jsoa-hover-buffer-name t)))
    (with-selected-window window
      (ignore-errors
        (scroll-up-command)
        (jsoa-hover-update-scroll-indicator)
        ))))

(defun jsoa-hover-scroll-up ()
  (interactive)

  (when-let ((window (get-buffer-window jsoa-hover-buffer-name t)))
    (with-selected-window window
      (ignore-errors
        (scroll-down-command)
        (jsoa-hover-update-scroll-indicator)
        ))))

(defun jsoa-hover-hide ()
  (setq jsoa-hover-visible nil)
  (posframe-hide jsoa-hover-buffer-name))

(defun jsoa-hover-build ()
  "Collect synchronous hover information for the current point."
  (list
   :errors
   (when (fboundp 'flycheck-overlay-errors-at)
     (flycheck-overlay-errors-at (point)))
   :signature nil))

(defun jsoa-hover-show ()
  "Display diagnostics immediately and request hover asynchronously."

  (setq jsoa-hover-mode 'hover)
  (unless (or jsoa-hover-visible
              (jsoa-hover-suppressed-p))

    (setq jsoa-hover-last-point (point))
    (setq jsoa-hover-request-point (point))

    ;; Build our initial model.
    (setq jsoa-hover-data
          (list
           :errors
           (when (fboundp 'flycheck-overlay-errors-at)
             (flycheck-overlay-errors-at (point)))
           :signature nil))

    ;; Render immediately.
    (jsoa-hover-render-current)

    ;; Ask LSP for documentation.
    (when (and (fboundp 'lsp-feature?)
               (lsp-feature? "textDocument/hover"))

      (lsp-request-async
       "textDocument/hover"
       (lsp--text-document-position-params)

       (lambda (hover)

         ;; Ignore stale responses.
         (when (and (eq (current-buffer) (window-buffer))
                    (= (point) jsoa-hover-request-point))

           (let* ((contents (plist-get hover :contents))
                  (value
                   (cond
                    ((stringp contents)
                     contents)

                    ((plist-get contents :value)
                     (plist-get contents :value))

                    ((and (listp contents)
                          (plist-get (car contents) :value))
                     (plist-get (car contents) :value)))))

             (when value
               (setq jsoa-hover-data
                     (plist-put
                      jsoa-hover-data
                      :signature
                      (string-trim
                       (replace-regexp-in-string
                        "```[[:alpha:]]*\n\\|```"
                        ""
                        value))))

               (jsoa-hover-render-current)))))

       :mode 'alive))))

;; TODO: Preserve syntax highlighting more faithfully.
(defun jsoa-hover-fontify (text mode)
  (with-temp-buffer
    (funcall mode)
    (font-lock-mode 1)
    (insert text)
    (font-lock-ensure)
    (buffer-substring (point-min) (point-max))))

(defun jsoa-hover-render (data mode)
  (let ((errors (plist-get data :errors))
        (signature (plist-get data :signature))
        (buffer (get-buffer-create jsoa-hover-buffer-name)))
    (when (or errors signature)

      (with-current-buffer buffer

        (unless (derived-mode-p 'jsoa-hover-popup-mode)
          (jsoa-hover-popup-mode))

        (setq buffer-read-only nil)
        (erase-buffer)

        ;; Signature
        (when signature
          (let ((start (point)))
            (insert
             (jsoa-hover-fontify signature mode))

            (when errors
              (insert "\n\n")
              (jsoa-hover-insert-separator)
              (insert "\n\n"))))

        ;; Diagnostics
        (dolist (err errors)
          (insert
           (propertize
            (upcase (symbol-name (flycheck-error-level err)))
            'face
            (pcase (flycheck-error-level err)
              ('error 'error)
              ('warning 'warning)
              (_ 'success))))

          (insert "\n")

          (insert
           (propertize
            (flycheck-error-message err)
            'face 'default))

          (insert "\n\n"))


        (goto-char (point-min))
        (setq buffer-read-only t))

      (posframe-show
       jsoa-hover-buffer-name
       :position (point)
       :border-width 1
       :border-color "#666666"
       :internal-border-width 8
       :left-fringe 8
       :right-fringe 8
       :respect-header-line t
       :respect-mode-line t
       :min-width 65
       :max-width jsoa-hover-max-width
       :min-height 1
       :max-height jsoa-hover-max-height)
      (jsoa-hover-update-scroll-indicator)
      ))

  (setq jsoa-hover-visible t))


(defun jsoa-hover-pre-command ()
  (unless (jsoa-hover-command-p this-command)
    (jsoa-hover-hide)))

(defun jsoa-hover-post-command ()
  (when (timerp jsoa-hover-timer)
    (cancel-timer jsoa-hover-timer))

  ;; Don't recreate the hover unless point has moved.
  (unless (or jsoa-hover-visible
              (eq (point) jsoa-hover-last-point)
              (jsoa-hover-suppressed-p))
    (setq jsoa-hover-timer
          (run-with-idle-timer
           jsoa-hover-delay
           nil
           #'jsoa-hover-show))))

(define-minor-mode jsoa-hover-mode
  "Hover popup."
  :global t

  (if jsoa-hover-mode
      (progn
        (add-hook 'pre-command-hook #'jsoa-hover-pre-command)
        (add-hook 'post-command-hook #'jsoa-hover-post-command))
    (remove-hook 'pre-command-hook #'jsoa-hover-pre-command)
    (remove-hook 'post-command-hook #'jsoa-hover-post-command)))

(jsoa-hover-register-action
 ?j
 "↓"
 'action
 #'jsoa-hover-scroll-down)

(jsoa-hover-register-action
 ?k
 "↑"
 'action
 #'jsoa-hover-scroll-up)

(jsoa-hover-register-action
 ?y
 "Copy"
 'action
 #'jsoa-hover-copy)

;;;;;;;;;;;;;;;;;;;;;;;;
(jsoa-hover-register-action
 ?t
 "Test"
 'view
 #'jsoa-hover-test-view)

(provide 'jsoa-hover)
