;;; expose-hover.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'eldoc)
(require 'seq)
(require 'subr-x)
(require 'expose-log)
(require 'expose-popup)

(defgroup expose-hover nil
  "Hover support for Expose."
  :group 'tools)

(defcustom expose-hover-delay 0.25
  "Delay before showing Expose hover."
  :type 'number
  :group 'expose-hover)

(defcustom expose-hover-disabled-modes
  '(special-mode
    help-mode
    helpful-mode
    view-mode
    compilation-mode
    messages-buffer-mode
    debugger-mode
    backtrace-mode
    dired-mode
    magit-mode
    magit-status-mode
    magit-diff-mode
    magit-log-mode
    treemacs-mode
    vterm-mode
    eat-mode
    term-mode
    shell-mode
    eshell-mode
    comint-mode)
  "Major modes where Expose hover should not automatically appear."
  :type '(repeat symbol)
  :group 'expose-hover)

(defcustom expose-hover-disabled-buffer-name-regexps
  '("^ \\*"
    "^\\*EXPOSE"
    "^\\*Messages\\*$"
    "^\\*Warnings\\*$"
    "^\\*Backtrace\\*$"
    "^\\*Help\\*$")
  "Buffer name regexps where Expose hover should not automatically appear."
  :type '(repeat regexp)
  :group 'expose-hover)

(defvar expose-hover-timer nil)
(defvar expose-hover-last-point nil)
(defvar expose-hover-data nil)
(defvar expose-hover-request-point nil)

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(defun expose-hover-disabled-mode-p ()
  "Return non-nil if the current major mode disables Expose hover."

  (apply
   #'derived-mode-p
   expose-hover-disabled-modes))

(defun expose-hover-disabled-buffer-p ()
  "Return non-nil if the current buffer disables Expose hover."

  (let ((name
         (buffer-name)))

    (seq-some
     (lambda (regexp)
       (string-match-p regexp name))
     expose-hover-disabled-buffer-name-regexps)))

(defun expose-hover-suppressed-p ()
  "Return non-nil if hover should currently be suppressed."

  (or
   (minibufferp)
   (expose-hover-disabled-mode-p)
   (expose-hover-disabled-buffer-p)
   (and
    (bound-and-true-p corfu--frame)
    (frame-visible-p corfu--frame))))

(defun expose-hover-clear-request ()
  "Clear the current hover request."

  (setq expose-hover-data nil)
  (setq expose-hover-request-point nil))

(defun expose-hover-request-stale-p (buffer point)
  "Return non-nil if a response for BUFFER and POINT is stale."

  (not
   (and
    (buffer-live-p buffer)
    (eq buffer (window-buffer))
    (with-current-buffer buffer
      (= (point) point)))))

;;; ---------------------------------------------------------------------------
;;; Data
;;; ---------------------------------------------------------------------------

(defun expose-hover-build ()
  "Collect synchronous hover information for the current point."

  (list
   :errors
   (when (fboundp 'flycheck-overlay-errors-at)
     (flycheck-overlay-errors-at (point)))

   :signature nil))

(defun expose-hover-update-signature (signature)
  "Update the current hover model with SIGNATURE."

  (setq expose-hover-data
        (plist-put
         expose-hover-data
         :signature
         signature)))

(defun expose-hover-hover-value (hover)
  "Return the displayable value from LSP HOVER."

  (let ((contents
         (plist-get hover :contents)))

    (cond
     ((stringp contents)
      contents)

     ((plist-get contents :value)
      (plist-get contents :value))

     ((and
       (listp contents)
       (plist-get (car contents) :value))
      (plist-get (car contents) :value)))))

(defun expose-hover-clean-signature (value)
  "Clean hover VALUE for display."

  (string-trim
   (replace-regexp-in-string
    "```[[:alpha:]]*\n\\|```"
    ""
    value)))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun expose-hover-fontify (text mode)
  "Fontify TEXT using MODE without running mode hooks."

  (with-temp-buffer
    (delay-mode-hooks
      (funcall mode))
    (font-lock-mode 1)
    (insert text)
    (font-lock-ensure)
    (buffer-substring
     (point-min)
     (point-max))))

(defun expose-hover-insert-signature (signature mode errors)
  "Insert SIGNATURE using MODE, followed by a separator when ERRORS exist."

  (when signature

    (insert
     (expose-hover-fontify signature mode))

    (when errors
      (insert "\n\n")
      (expose-popup-insert-separator)
      (insert "\n\n"))))

(defun expose-hover-insert-diagnostic (error)
  "Insert a single Flycheck ERROR."

  (insert
   (propertize
    (upcase
     (symbol-name
      (flycheck-error-level error)))
    'face
    (pcase (flycheck-error-level error)
      ('error 'error)
      ('warning 'warning)
      (_ 'success))))

  (insert "\n")

  (insert
   (propertize
    (flycheck-error-message error)
    'face
    'default))

  (insert "\n\n"))

(defun expose-hover-insert-diagnostics (errors)
  "Insert Flycheck ERRORS."

  (dolist (error errors)
    (expose-hover-insert-diagnostic error)))

(defun expose-hover-render-content (data mode)
  "Return rendered hover content for DATA using MODE."

  (let ((errors
         (plist-get data :errors))

        (signature
         (plist-get data :signature)))

    (when (or errors signature)

      (with-temp-buffer

        (expose-hover-insert-signature
         signature
         mode
         errors)

        (expose-hover-insert-diagnostics errors)

        (buffer-string)))))

(defun expose-hover-render-current ()
  "Render the current hover model."

  (when-let ((content
              (and
               expose-hover-data
               (expose-hover-render-content
                expose-hover-data
                major-mode))))

    (expose-log
     "Hover"
     "Rendering hover content (%d bytes)."
     (length content))

    (expose-popup-show-content content)))

;;; ---------------------------------------------------------------------------
;;; LSP
;;; ---------------------------------------------------------------------------

(defun expose-hover-lsp-available-p ()
  "Return non-nil if LSP hover is available in the current buffer."

  (and
   (fboundp 'lsp-feature?)
   (lsp-feature? "textDocument/hover")))

(defun expose-hover-request-lsp ()
  "Request LSP hover documentation asynchronously."

  (expose-log
   "Hover"
   "Requesting LSP hover at point %d."
   expose-hover-request-point)

  (lsp-request-async
   "textDocument/hover"
   (lsp--text-document-position-params)

   (lambda (hover)
     (expose-hover-handle-lsp-response hover))

   :mode 'alive))

(defun expose-hover-stale-response-p ()
  "Return non-nil if the current LSP hover response is stale."

  (let ((stale
         (expose-hover-request-stale-p
          (current-buffer)
          expose-hover-request-point)))

    (when stale
      (expose-log
       "Hover"
       "Ignoring stale LSP response. current-point=%d request-point=%s."
       (point)
       expose-hover-request-point))

    stale))

(defun expose-hover-handle-lsp-response (hover)
  "Handle LSP HOVER response."

  (expose-log
   "Hover"
   "Received LSP hover response.")

  (unless (expose-hover-stale-response-p)

    (if-let ((value
              (expose-hover-hover-value hover)))

        (let ((signature
               (expose-hover-clean-signature value)))

          (expose-log
           "Hover"
           "LSP hover produced signature (%d bytes)."
           (length signature))

          (expose-hover-update-signature signature)

          (expose-hover-render-current))

      (expose-log
       "Hover"
       "LSP hover response had no displayable value."))))

;;; ---------------------------------------------------------------------------
;;; Eldoc
;;; ---------------------------------------------------------------------------

(defun expose-hover-eldoc-functions ()
  "Return callable Eldoc documentation functions for the current buffer."

  (when (boundp 'eldoc-documentation-functions)
    (seq-filter
     (lambda (function)
       (and
        (not (eq function t))
        (or
         (functionp function)
         (and
          (symbolp function)
          (fboundp function)))))
     eldoc-documentation-functions)))

(defun expose-hover-eldoc-available-p ()
  "Return non-nil if Eldoc documentation is available."

  (and
   (bound-and-true-p eldoc-mode)
   (expose-hover-eldoc-functions)))

(defun expose-hover-normalize-eldoc-documentation (value)
  "Normalize Eldoc VALUE into a displayable string."

  (cond
   ((stringp value)
    value)

   ((and
     (listp value)
     (seq-some #'stringp value))
    (string-join
     (seq-filter #'stringp value)
     "\n"))

   (_
    nil)))

(defun expose-hover-call-eldoc-function (function callback)
  "Call Eldoc FUNCTION with CALLBACK."

  (condition-case error

      (let ((result
             (funcall function callback)))

        (when-let ((documentation
                    (expose-hover-normalize-eldoc-documentation result)))

          (funcall callback documentation))

        result)

    (wrong-number-of-arguments

     (condition-case fallback-error

         (when-let ((documentation
                     (expose-hover-normalize-eldoc-documentation
                      (funcall function))))

           (funcall callback documentation))

       (error
        (expose-log
         "Hover"
         "Eldoc function %s failed: %s."
         function
         fallback-error))))

    (error
     (expose-log
      "Hover"
      "Eldoc function %s failed: %s."
      function
      error))))

(defun expose-hover-request-eldoc ()
  "Request Eldoc documentation for the current point."

  (let ((buffer
         (current-buffer))

        (request-point
         expose-hover-request-point)

        (functions
         (expose-hover-eldoc-functions))

        handled)

    (expose-log
     "Hover"
     "Requesting Eldoc documentation from %d function(s)."
     (length functions))

    (dolist (function functions)

      (unless handled

        (expose-hover-call-eldoc-function
         function
         (lambda (documentation &rest _props)

           (when-let ((text
                       (expose-hover-normalize-eldoc-documentation
                        documentation)))

             (unless handled

               (setq handled t)

               (expose-hover-handle-eldoc-response
                buffer
                request-point
                text)))))))))

(defun expose-hover-handle-eldoc-response (buffer point documentation)
  "Handle Eldoc DOCUMENTATION produced for BUFFER at POINT."

  (when (buffer-live-p buffer)

    (with-current-buffer buffer

      (expose-log
       "Hover"
       "Received Eldoc response.")

      (if (expose-hover-request-stale-p buffer point)

          (expose-log
           "Hover"
           "Ignoring stale Eldoc response. current-point=%d request-point=%s."
           (point)
           point)

        (let ((signature
               (string-trim documentation)))

          (expose-log
           "Hover"
           "Eldoc produced signature (%d bytes)."
           (length signature))

          (expose-hover-update-signature signature)

          (expose-hover-render-current))))))

;;; ---------------------------------------------------------------------------
;;; Documentation Source
;;; ---------------------------------------------------------------------------

(defun expose-hover-request-documentation ()
  "Request documentation for the current point."

  (cond

   ((plist-get expose-hover-data :signature)

    (expose-log
     "Hover"
     "Skipping documentation request because signature already exists."))

   ((expose-hover-lsp-available-p)

    (expose-hover-request-lsp))

   ((expose-hover-eldoc-available-p)

    (expose-hover-request-eldoc))

   (t

    (expose-log
     "Hover"
     "No documentation source available."))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun expose-hover-show ()
  "Display diagnostics immediately and request hover documentation asynchronously."

  (unless (or
           expose-popup-visible
           (expose-hover-suppressed-p))

    (expose-log
     "Hover"
     "Showing hover at point %d."
     (point))

    (setq expose-hover-last-point (point))
    (setq expose-hover-request-point (point))
    (setq expose-hover-data (expose-hover-build))

    (expose-log
     "Hover"
     "Built hover model. errors=%d signature=%s."
     (length
      (or
       (plist-get expose-hover-data :errors)
       nil))
     (if (plist-get expose-hover-data :signature)
         "yes"
       "no"))

    (expose-hover-render-current)

    (expose-hover-request-documentation)))

(defun expose-hover-close ()
  "Close the current hover popup."

  (interactive)

  (expose-log
   "Hover"
   "Closing hover at point %d."
   (point))

  (setq expose-hover-last-point (point))

  (expose-popup-hide))

(defun expose-hover-pre-command ()
  "Hide hover before unrelated commands."

  (unless (expose-popup-command-p this-command)
    (expose-popup-hide)))

(defun expose-hover-post-command ()
  "Schedule hover after commands."

  (when (timerp expose-hover-timer)
    (cancel-timer expose-hover-timer))

  (unless (or
           expose-popup-visible
           (eq (point) expose-hover-last-point)
           (expose-hover-suppressed-p))

    (setq expose-hover-timer
          (run-with-idle-timer
           expose-hover-delay
           nil
           #'expose-hover-show))))

;;; ---------------------------------------------------------------------------
;;; Debug
;;; ---------------------------------------------------------------------------

(defun expose-hover-debug-current-buffer ()
  "Log Expose hover capabilities for the current buffer."

  (interactive)

  (let ((errors
         (when (fboundp 'flycheck-overlay-errors-at)
           (flycheck-overlay-errors-at (point)))))

    (expose-log
     "HoverDebug"
     "buffer=%s major-mode=%s point=%d"
     (buffer-name)
     major-mode
     (point))

    (expose-log
     "HoverDebug"
     "suppressed=%s disabled-mode=%s disabled-buffer=%s popup-visible=%s"
     (expose-hover-suppressed-p)
     (expose-hover-disabled-mode-p)
     (expose-hover-disabled-buffer-p)
     expose-popup-visible)

    (expose-log
     "HoverDebug"
     "flycheck-available=%s errors-at-point=%d"
     (fboundp 'flycheck-overlay-errors-at)
     (length
      (or errors nil)))

    (expose-log
     "HoverDebug"
     "lsp-hover-available=%s"
     (expose-hover-lsp-available-p))

    (expose-log
     "HoverDebug"
     "eldoc-mode=%s eldoc-functions=%s"
     (bound-and-true-p eldoc-mode)
     (when (boundp 'eldoc-documentation-functions)
       eldoc-documentation-functions))

    (message "Expose hover debug written to *EXPOSE Log*")))

;;; ---------------------------------------------------------------------------
;;; Mode
;;; ---------------------------------------------------------------------------

(define-minor-mode expose-hover-mode
  "Expose hover popup."
  :global t

  (if expose-hover-mode
      (progn
        (expose-log
         "Hover"
         "Enabling hover mode.")

        (add-hook 'pre-command-hook #'expose-hover-pre-command)
        (add-hook 'post-command-hook #'expose-hover-post-command))

    (expose-log
     "Hover"
     "Disabling hover mode.")

    (remove-hook 'pre-command-hook #'expose-hover-pre-command)
    (remove-hook 'post-command-hook #'expose-hover-post-command)))

(provide 'expose-hover)
