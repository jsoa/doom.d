;;; modes/+large-file.el -*- lexical-binding: t; -*-

(setq jsoa/large-file-size (* 2 1024 1024)) ;; 2MB

(defun jsoa/large-file-p ()
  (or
   (> (buffer-size) jsoa/large-file-size)
   (when buffer-file-name
     (string-match-p "\\.min\\." buffer-file-name))))

(defun jsoa/enable-large-file-mode ()
  (when (jsoa/large-file-p)
    (message "⚡ Large file detected: optimizing...")

    (when (bound-and-true-p lsp-mode)
      (lsp-disconnect))

    (when (bound-and-true-p flycheck-mode)
      (flycheck-mode -1))

    (when (bound-and-true-p font-lock-mode)
      (font-lock-mode -1))

    ;; UI stuff
    (when (bound-and-true-p display-line-numbers-mode)
      (display-line-numbers-mode -1))

    (when (bound-and-true-p display-fill-column-indicator-mode)
      (display-fill-column-indicator-mode -1))

    ;; Disable undo (huge win)
    (setq buffer-undo-list t)

    ;; Disable bidi (massive speedup for long lines)
    (setq bidi-display-reordering nil)

    ;; Faster scrolling
    (setq-local scroll-margin 0)
    (setq-local scroll-conservatively 101)

    ;; Optional: read-only (prevents accidental edits)
    ;; (read-only-mode 1)

    (message "⚡ Large file mode enabled")))

(add-hook 'find-file-hook #'jsoa/enable-large-file-mode)
(add-hook 'after-change-major-mode-hook #'jsoa/enable-large-file-mode)
