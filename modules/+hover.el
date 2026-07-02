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

(define-derived-mode jsoa-hover-popup-mode special-mode "Hover"
  "Major mode for JSOA hover."

  (setq-local cursor-type nil)
  (setq-local mode-line-format nil)
  (setq-local header-line-format nil)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t))

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

(defun jsoa-hover-scroll-down ()
  (interactive)

  (when-let ((window (get-buffer-window jsoa-hover-buffer-name t)))
    (with-selected-window window
      (ignore-errors
        (scroll-up-command)))))

(defun jsoa-hover-scroll-up ()
  (interactive)

  (when-let ((window (get-buffer-window jsoa-hover-buffer-name t)))
    (with-selected-window window
      (ignore-errors
        (scroll-down-command)))))

(defun jsoa-hover-hide ()
  (setq jsoa-hover-visible nil)
  (posframe-hide jsoa-hover-buffer-name))

(defun jsoa-hover-build ()
  "Collect hover information for the current point."
  (list
   :errors (flycheck-overlay-errors-at (point))
   :signature (jsoa-hover-signature)))

(defun jsoa-hover-show ()
  (unless (or jsoa-hover-visible
              (minibufferp))
    (setq jsoa-hover-last-point (point))
    (let ((mode major-mode)
          (data (jsoa-hover-build)))
      (jsoa-hover-render data mode))))

;; TODO: Preserve syntax highlighting more faithfully.
(defun jsoa-hover-fontify (text mode)
  (with-temp-buffer
    (funcall mode)
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

        ;; Signature
        (when signature
          (insert
           (jsoa-hover-fontify signature mode)))

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
       :min-width 40
       :max-width 100
       :min-height 1
       :max-height (floor (* 0.20 (frame-height))))))

  (setq jsoa-hover-visible t))

;; TODO: Support all valid LSP Hover.contents formats.
(defun jsoa-hover-signature ()
  (when-let* ((hover
               (ignore-errors
                 (lsp-request
                  "textDocument/hover"
                  (lsp--text-document-position-params))))
              (contents (plist-get hover :contents))
              (value (plist-get contents :value)))
    (string-trim
     (replace-regexp-in-string
      "```[[:alpha:]]*\n\\|```"
      ""
      value))))

(defun jsoa-hover-pre-command ()
  (unless (jsoa-hover-command-p this-command)
    (jsoa-hover-hide)))

(defun jsoa-hover-post-command ()
  (when (timerp jsoa-hover-timer)
    (cancel-timer jsoa-hover-timer))

  ;; Don't recreate the hover unless point has moved.
  (unless (or jsoa-hover-visible
              (eq (point) jsoa-hover-last-point))
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
       :desc "Close Hover" "q" #'jsoa-hover-close))
