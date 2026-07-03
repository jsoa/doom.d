;;; +hover.el -*- lexical-binding: t; -*-

(require 'posframe)
(declare-function posframe-hide "posframe")
(declare-function posframe-show "posframe")

(defgroup jsoa-hover nil
  "Hover popup."
  :group 'tools)

(defcustom jsoa-hover-delay 0.25
  "Delay before showing hover."
  :type 'number)

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
   '(" "
     (:propertize "SPC c h" face font-lock-keyword-face)
     "  "
     (:propertize "[j]" face bold)
     " ↓  "
     (:propertize "[k]" face bold)
     " ↑  "
     (:propertize "[y]" face bold)
     " Copy  "
     (:propertize "[o]" face bold)
     " Open  "
     (:propertize "[q]" face bold)
     " Close"
     (:eval
      (propertize
       (concat
        (propertize
         " "
         'display
         `(space :align-to (- right ,(+ (length jsoa-hover-scroll-indicator) 2))))
        jsoa-hover-scroll-indicator)
       'face
       'shadow)))))

(defun jsoa-hover-render-current ()
  "Render the current hover model."

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
  (memq command
        '(jsoa-hover-close
          jsoa-hover-copy
          jsoa-hover-open
          jsoa-hover-scroll-down
          jsoa-hover-scroll-up)))

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
       :max-width 100
       :min-height 1
       :max-height (floor (* 0.20 (frame-height))))
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

(jsoa-hover-mode 1)

(map! :leader
      (:prefix ("c h" . "hover")
       :desc "Scroll Down" "j" #'jsoa-hover-scroll-down
       :desc "Scroll Up"   "k" #'jsoa-hover-scroll-up
       :desc "Close Hover" "q" #'jsoa-hover-close
       :desc "Copy Hover" "y" #'jsoa-hover-copy
       :desc "Open Hover" "o" #'jsoa-hover-open
       ))
