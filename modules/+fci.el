;;; +fci.el -*- lexical-binding: t; -*-


(setq-default fill-column 80)

(defun jsoa/maybe-enable-fci ()
  (unless (or (string-match-p "\\.min\\.js\\'" (buffer-name))
              (> (buffer-size) (* 1 1024 1024))) ;; >1MB
    (display-fill-column-indicator-mode)))

(add-hook 'prog-mode-hook #'jsoa/maybe-enable-fci)

(after! display-fill-column-indicator
  (set-face-attribute 'fill-column-indicator nil
                      :foreground "#222"))
