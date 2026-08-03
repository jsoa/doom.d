;;; modules/+ediff.el -*- lexical-binding: t; -*-

;;
;; EDiff
;;

;; https://stackoverflow.com/a/29757750
;; Accept diffs from both A and B
;; key bindings
;; a = accept a
;; b = accept b
;; B = accept both
(after! ediff
  (defun jsoa/ediff-copy-both-to-C ()
    "Copy both A and B changes into C."
    (interactive)
    (ediff-copy-diff
     ediff-current-difference
     nil 'C nil
     (concat
      (ediff-get-region-contents ediff-current-difference 'A ediff-control-buffer)
      (ediff-get-region-contents ediff-current-difference 'B ediff-control-buffer))))

  ;; `ediff-mode-map' is buffer-local and only a real keymap while a session
  ;; is active (its global value is nil the rest of the time) -- binding
  ;; into it here, directly in the `after! ediff' body, only ever worked
  ;; because `ediff' historically was never loaded except by actually
  ;; starting a session. `ediff-keymap-setup-hook' runs once per session,
  ;; right after `ediff-mode-map' is freshly built, which is the actual
  ;; documented extension point for this.
  (add-hook 'ediff-keymap-setup-hook
            (defun jsoa/ediff-setup-keys ()
              (map! :map ediff-mode-map
                    :n "B" #'jsoa/ediff-copy-both-to-C))))
