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
  ;; One frame. The default is `ediff-setup-windows-default', which puts
  ;; the control panel in a *separate frame* on a graphical display --
  ;; which a tiling window manager then treats as a new window to place,
  ;; and which is easy to lose behind the frame you were working in.
  (setq ediff-window-setup-function #'ediff-setup-windows-plain)

  ;; Skip what Git already merged. In a three-way merge, `n' and `p'
  ;; otherwise walk every differing region, including the ones resolved
  ;; automatically -- but the reason to be in ediff at all is the regions
  ;; where both sides changed the same thing.
  (setq ediff-show-clashes-only t)

  ;; Side by side rather than stacked, for the two-way diffs reached from
  ;; magit. Merge sessions already default to a horizontal split
  ;; (`ediff-merge-split-window-function'); this makes the rest match.
  (setq ediff-split-window-function #'split-window-horizontally)

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
