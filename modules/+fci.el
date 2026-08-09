;;; +fci.el -*- lexical-binding: t; -*-


(setq-default fill-column 80)

(defun jsoa/maybe-enable-fci ()
  "Turn on the fill-column indicator, except in large/minified buffers.

Defers to `jsoa/large-file-p' (modules/+large-file.el, loaded earlier
in `config.el') rather than repeating its own size threshold and
minified-name check -- those used to disagree, so a file between the
two limits got the indicator here while `+large-file.el' was busy
turning it back off."
  (unless (and (fboundp 'jsoa/large-file-p)
               (jsoa/large-file-p))
    (display-fill-column-indicator-mode)))

(add-hook 'prog-mode-hook #'jsoa/maybe-enable-fci)

(after! display-fill-column-indicator
  (set-face-attribute 'fill-column-indicator nil
                      :foreground "#222"))
