;;; modules/+large-file.el -*- lexical-binding: t; -*-

(defvar jsoa/large-file-size (* 2 1024 1024)
  "Size in bytes past which a buffer is treated as a large file.

Also consulted by `modules/+fci.el', so the fill-column indicator and
these optimizations agree on what counts as \"large\" rather than each
carrying its own threshold.")

(defvar-local jsoa/large-file-mode-enabled nil
  "Non-nil once `jsoa/enable-large-file-mode' has run in this buffer.

Only used to keep it from re-announcing itself: the work below still
re-runs on every major mode change, because switching major mode turns
`font-lock-mode' and friends back on and they need disabling again.")

(defun jsoa/large-file-p ()
  (or
   (> (buffer-size) jsoa/large-file-size)
   (when buffer-file-name
     (string-match-p "\\.min\\." buffer-file-name))))

(defun jsoa/enable-large-file-mode ()
  (when (jsoa/large-file-p)
    (unless jsoa/large-file-mode-enabled
      (message "⚡ Large file detected: optimizing..."))

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

    (unless jsoa/large-file-mode-enabled
      (setq jsoa/large-file-mode-enabled t)
      (message "⚡ Large file mode enabled"))))

(add-hook 'find-file-hook #'jsoa/enable-large-file-mode)

;; Also on major mode changes, not just on open: a new major mode turns
;; `font-lock-mode', line numbers, and the fill-column indicator back on,
;; so they need disabling again each time.
(add-hook 'after-change-major-mode-hook #'jsoa/enable-large-file-mode)
