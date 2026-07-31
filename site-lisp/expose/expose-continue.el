;;; expose-continue.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'project)
(require 'expose-log)
(require 'expose-provider)
(require 'expose-transport)

(defgroup expose-continue nil
  "Project-aware inline continuation suggestions."
  :group 'expose)

(defface expose-continue-ghost-face
  '((t :inherit shadow))
  "Face used for inline Expose continuation ghost text."
  :group 'expose-continue)

(defcustom expose-continue-context-lines-before 120
  "Number of lines before point included in continuation context."
  :type 'integer
  :group 'expose-continue)

(defcustom expose-continue-context-lines-after 80
  "Number of lines after point included in continuation context."
  :type 'integer
  :group 'expose-continue)

(defcustom expose-continue-provider-timeout-seconds 180
  "Seconds to wait for an AI provider before failing an Expose continuation."
  :type 'integer
  :group 'expose-continue)

(defvar expose-provider-default)

(defvar-local expose-continue-overlay nil
  "Current inline Expose continuation overlay.")

(defvar-local expose-continue-text nil
  "Current Expose continuation text.")

(defvar-local expose-continue-anchor nil
  "Marker where the current Expose continuation should be inserted.")

(defun expose-continue-project-root ()
  "Return current project root or `default-directory'."

  (if-let ((project
            (project-current nil)))

      (file-name-as-directory
       (project-root project))

    default-directory))

(defun expose-continue-provider ()
  "Return provider used for continuation suggestions."

  (if (boundp 'expose-provider-default)
      expose-provider-default
    'clipboard))

(defun expose-continue-clear ()
  "Clear the active Expose continuation."

  (interactive)

  (when (overlayp expose-continue-overlay)
    (delete-overlay expose-continue-overlay))

  (setq expose-continue-overlay nil)
  (setq expose-continue-text nil)

  (when (markerp expose-continue-anchor)
    (set-marker expose-continue-anchor nil))

  (setq expose-continue-anchor nil))

(defun expose-continue-escape (text)
  "Escape TEXT for XML-ish request documents."

  (let ((result
         (or text "")))

    (setq result
          (replace-regexp-in-string "&" "&amp;" result t t))

    (setq result
          (replace-regexp-in-string "<" "&lt;" result t t))

    (setq result
          (replace-regexp-in-string ">" "&gt;" result t t))

    result))

(defun expose-continue-buffer-file ()
  "Return current buffer file display name."

  (or
   (when-let ((file
               (buffer-file-name)))
     (if-let ((project
               (project-current nil)))
         (file-relative-name
          file
          (project-root project))
       file))
   (buffer-name)))

(defun expose-continue-line-number ()
  "Return current one-based line number."

  (line-number-at-pos))

(defun expose-continue-context-before ()
  "Return context before point."

  (save-excursion
    (let ((end
           (point))

          start)

      (forward-line
       (- expose-continue-context-lines-before))

      (setq start
            (point))

      (buffer-substring-no-properties
       start
       end))))

(defun expose-continue-context-after ()
  "Return context after point."

  (save-excursion
    (let ((start
           (point))

          end)

      (forward-line
       expose-continue-context-lines-after)

      (setq end
            (point))

      (buffer-substring-no-properties
       start
       end))))

(defun expose-continue-current-line-prefix ()
  "Return text from line beginning to point."

  (buffer-substring-no-properties
   (line-beginning-position)
   (point)))

(defun expose-continue-diagnostics-near-point ()
  "Return compact diagnostics near point."

  (when (and
         (bound-and-true-p flycheck-mode)
         (fboundp 'flycheck-overlay-errors-in))

    (let* ((start
            (save-excursion
              (forward-line -20)
              (point)))

           (end
            (save-excursion
              (forward-line 20)
              (point)))

           (errors
            (flycheck-overlay-errors-in start end)))

      (when errors
        (string-join
         (mapcar
          (lambda (error)
            (format
             "line %s [%s] %s"
             (line-number-at-pos
              (flycheck-error-pos error))
             (flycheck-error-level error)
             (flycheck-error-message error)))
          errors)
         "\n")))))

(defun expose-continue-request ()
  "Build a project-aware continuation request."

  (format
   "<expose-continue-request>
  <instruction>
    Continue the implementation the user appears to be writing at point.

    Use the surrounding project/file context and existing conventions.
    Return only the code that should be inserted at point.
    Do not include Markdown fences.
    Do not include commentary.
    Do not rewrite unrelated code.
    Do not repeat code that already exists before point.
    Preserve indentation style.
  </instruction>

  <location file=\"%s\" line=\"%s\" major_mode=\"%s\" />

  <current-line-prefix>
%s
  </current-line-prefix>

  <before-point>
%s
  </before-point>

  <after-point>
%s
  </after-point>

  <nearby-diagnostics>
%s
  </nearby-diagnostics>
</expose-continue-request>"
   (expose-continue-escape
    (expose-continue-buffer-file))
   (expose-continue-line-number)
   major-mode
   (expose-continue-escape
    (expose-continue-current-line-prefix))
   (expose-continue-escape
    (expose-continue-context-before))
   (expose-continue-escape
    (expose-continue-context-after))
   (expose-continue-escape
    (or
     (expose-continue-diagnostics-near-point)
     ""))))

(defun expose-continue-strip-markdown (text)
  "Strip Markdown code fences from TEXT."

  (let ((result
         (string-trim
          (or text ""))))

    (when (string-match "\\`[[:space:]]*```[[:alnum:]_-]*[[:space:]\n\r]*" result)
      (setq result
            (replace-match "" t t result)))

    (when (string-match "```[[:space:]]*\\'" result)
      (setq result
            (replace-match "" t t result)))

    result))

(defun expose-continue-propertize-ghost (text)
  "Return TEXT propertized as ghost text."

  (propertize
   text
   'face
   'expose-continue-ghost-face))

(defun expose-continue-show-ghost (text)
  "Show TEXT as inline ghost continuation at point."

  (expose-continue-clear)

  (setq expose-continue-text
        (expose-continue-strip-markdown text))

  (unless (string-empty-p expose-continue-text)

    (setq expose-continue-anchor
          (copy-marker
           (point)
           t))

    (setq expose-continue-overlay
          (make-overlay
           (point)
           (point)
           nil
           t
           nil))

    (overlay-put
     expose-continue-overlay
     'after-string
     (expose-continue-propertize-ghost
      expose-continue-text))

    (overlay-put
     expose-continue-overlay
     'priority
     9999)

    (expose-continue-install-transient-map)

    (message "Expose suggestion: RET accept, ESC/C-g dismiss")))

(defun expose-continue-accept ()
  "Accept the active Expose continuation."

  (interactive)

  (unless (and
           expose-continue-text
           (markerp expose-continue-anchor))

    (user-error "No Expose continuation to accept"))

  (let ((text
         expose-continue-text)

        (position
         (marker-position expose-continue-anchor)))

    (expose-continue-clear)

    (goto-char position)
    (insert text)))

(defun expose-continue-active-p ()
  "Return non-nil when an Expose continuation is active."

  (and
   expose-continue-overlay
   expose-continue-text
   (overlayp expose-continue-overlay)))

(defun expose-continue-install-transient-map ()
  "Install temporary keymap for active continuation."

  (let ((map
         (make-sparse-keymap)))

    (define-key map (kbd "RET") #'expose-continue-accept)
    (define-key map (kbd "<return>") #'expose-continue-accept)
    (define-key map (kbd "<escape>") #'expose-continue-clear)
    (define-key map (kbd "C-g") #'expose-continue-clear)

    (set-transient-map
     map
     #'expose-continue-active-p)))

;;;###autoload
(defun expose-continue-at-point ()
  "Request a project-aware inline continuation at point."

  (interactive)

  (expose-continue-clear)

  (let* ((source-buffer
          (current-buffer))

         (project-root
          (expose-continue-project-root))

         (provider
          (expose-continue-provider))

         (document
          (expose-continue-request))

         (completed nil)
         timeout-timer
         provider-process)

    (setq expose-continue-anchor
          (copy-marker
           (point)
           t))

    (setq expose-continue-overlay
          (make-overlay
           (point)
           (point)
           nil
           t
           nil))

    (overlay-put
     expose-continue-overlay
     'after-string
     (propertize
      " …"
      'face
      'expose-continue-ghost-face))

    (expose-log
     "Continue"
     "Sending continuation request for %s using %s from %s. Request size: %d bytes."
     (expose-continue-buffer-file)
     provider
     project-root
     (length document))

    (setq timeout-timer
          (run-at-time
           expose-continue-provider-timeout-seconds
           nil
           (lambda ()
             (unless completed
               (setq completed t)

               (when (and provider-process
                          (processp provider-process)
                          (process-live-p provider-process))

                 (expose-log
                  "Continue"
                  "Killing provider process after timeout.")

                 (delete-process provider-process))

               (when (buffer-live-p source-buffer)
                 (with-current-buffer source-buffer
                   (expose-continue-clear)))

               (message
                "Expose continuation timed out after %d seconds while using %s."
                expose-continue-provider-timeout-seconds
                provider)))))

    (setq provider-process
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
                   (when (and
                          (markerp expose-continue-anchor)
                          (marker-position expose-continue-anchor))

                     (save-excursion
                       (goto-char
                        (marker-position expose-continue-anchor))

                       (expose-continue-show-ghost response-text)))))))

           project-root

           (lambda (error-data)
             (unless completed
               (setq completed t)

               (when (timerp timeout-timer)
                 (cancel-timer timeout-timer))

               (when (buffer-live-p source-buffer)
                 (with-current-buffer source-buffer
                   (expose-continue-clear)))

               (message
                "Expose continuation failed: %s"
                (error-message-string error-data))))))))

(provide 'expose-continue)
