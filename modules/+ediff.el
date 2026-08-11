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

  ;;
  ;; Asking a provider to resolve the region at point
  ;;
  ;; A merge conflict is an unusually safe place to let a model write: the
  ;; result lands in buffer C, which you are already reading, `r' puts the
  ;; region back, and nothing reaches the file until you quit and confirm.
  ;; The review step that has to be bolted onto most AI editing is already
  ;; the workflow here.

  (defcustom jsoa/ediff-ai-context-lines 12
    "Lines of surrounding code sent with a conflict region.

Without them a model sees two fragments and no indentation, scope or
neighbouring code to match, and returns something that has to be
re-indented by hand."
    :type 'integer
    :group 'ediff)

  (defun jsoa/ediff-region (n type)
    "Return region N of buffer TYPE, or nil if there isn't one.

The ancestor is absent in a two-way merge, and is the single most useful
part of the prompt when it is there -- it says what each side changed
*from*, which is what separates \"both added a line\" from \"both edited
the same line\"."

    (ignore-errors
      (ediff-get-region-contents n type ediff-control-buffer)))

  (defun jsoa/ediff-context (n)
    "Return (BEFORE . AFTER): the code surrounding region N in buffer C."

    (let ((control ediff-control-buffer))
      (with-current-buffer ediff-buffer-C
        (save-excursion
          (let* ((beg (ediff-get-diff-posn 'C 'beg n control))
                 (end (ediff-get-diff-posn 'C 'end n control))
                 (before (progn (goto-char beg)
                                (forward-line (- jsoa/ediff-ai-context-lines))
                                (buffer-substring-no-properties (point) beg)))
                 (after (progn (goto-char end)
                               (forward-line jsoa/ediff-ai-context-lines)
                               (buffer-substring-no-properties end (point)))))
            (cons before after))))))

  (defun jsoa/ediff-ai-prompt (n)
    "Return the prompt describing conflict region N."

    (let* ((context (jsoa/ediff-context n))
           (ancestor (jsoa/ediff-region n 'Ancestor))
           (file (or (buffer-file-name ediff-buffer-A)
                     (buffer-file-name ediff-buffer-B)
                     (buffer-name ediff-buffer-C))))

      (concat
       "Resolve one Git merge conflict.\n\n"
       (format "File: %s\n\n" file)

       "=== OURS ===\n" (or (jsoa/ediff-region n 'A) "") "\n"
       "=== THEIRS ===\n" (or (jsoa/ediff-region n 'B) "") "\n"
       (if ancestor (concat "=== COMMON ANCESTOR ===\n" ancestor "\n") "")

       "=== CODE IMMEDIATELY ABOVE ===\n" (car context) "\n"
       "=== CODE IMMEDIATELY BELOW ===\n" (cdr context) "\n"

       ;; A model handed code will improve it unless told not to, and an
       ;; improvement smuggled into a conflict resolution is the worst
       ;; place to receive one: it arrives disguised as somebody else's
       ;; change, in a commit nobody reviews line by line, in a region
       ;; that is already hard to read.
       "This is a merge resolution, not a code review. Reconcile the two"
       " sides and change nothing else.\n\n"

       "- Every line you return must come from OURS or THEIRS, except the"
       " minimum needed to join them -- a comma, a bracket, one level of"
       " indentation.\n"
       "- Do not refactor, rename, reorder, reformat or simplify anything.\n"
       "- Do not add or remove comments, logging, type hints, error"
       " handling or tests.\n"
       "- Do not fix bugs you notice and do not improve code you think is"
       " wrong. Both sides may well be imperfect; preserving that is the"
       " job here, and correcting it is a separate change somebody else"
       " should get to review on its own.\n"
       "- If one side already contains everything the other does, return"
       " that side unchanged.\n"
       "- Where the two intentions genuinely cannot both be kept, return"
       " OURS unchanged rather than inventing a compromise.\n\n"

       "Return only the resolved code for this region: no conflict markers,"
       " no code fences, no explanation, nothing before or after it."
       " Keep the indentation of the surrounding code.")))

  (defun jsoa/ediff-ai-clean (text)
    "Strip a Markdown code fence from TEXT without touching its indentation.

Not `expose-commands-clean-insert-text', which trims the whole string --
correct where it is used, inserting a docstring at point, and wrong here:
the first line of a conflict region is usually the most indented thing in
it, and trimming turns a method body into a top-level statement."

    (let ((body (or text "")))

      ;; Leading and trailing blank lines go; the indentation of the first
      ;; line with anything on it stays.
      (setq body (replace-regexp-in-string "\\`\\(?:[ \t]*\n\\)+" "" body))
      (setq body (replace-regexp-in-string "\\(?:[ \t]*\n\\)+\\'" "\n" body))

      (when (string-match "\\`[ \t]*```[[:alnum:]_+-]*[ \t]*\n" body)
        (setq body (substring body (match-end 0))))

      (when (string-match "\n[ \t]*```[ \t]*\n?\\'" body)
        (setq body (substring body 0 (1+ (match-beginning 0)))))

      body))

  (defun jsoa/ediff-ai-resolve ()
    "Ask the configured Expose provider to resolve the region at point.

The answer replaces the region in buffer C, where you review it like any
other -- `r' restores what was there before, and nothing is written to
the file until you quit and say yes."

    (interactive)

    (unless (fboundp 'expose-transport-send-document-async)
      (user-error "Expose is not loaded, so there is no provider to ask"))

    (unless (and (boundp 'ediff-current-difference) (>= ediff-current-difference 0))
      (user-error "Point is not on a difference"))

    (let ((control ediff-control-buffer)
          (n ediff-current-difference)
          (prompt (jsoa/ediff-ai-prompt ediff-current-difference)))

      (message "Expose: asking %s to resolve region %d..."
               expose-provider-default (1+ n))

      (expose-transport-send-document-async
       expose-provider-default
       prompt

       (lambda (response)
         ;; The session may be over, or on a different difference, by the
         ;; time this lands -- the request is asynchronous and a merge is
         ;; not a thing anybody sits still during.
         (if (not (buffer-live-p control))
             (message "Expose: the ediff session ended before the answer arrived")

           (with-current-buffer control
             (let ((text (jsoa/ediff-ai-clean
                          (expose-transport-response-text response))))

               ;; Blank, not merely empty: the cleaner strips blank
               ;; *lines*, so a reply of spaces survives as spaces and
               ;; would silently blank the region.
               (if (string-blank-p text)
                   (message "Expose: the provider returned nothing usable")

                 ;; Regions are line-based; without the newline the
                 ;; following line is pulled onto the end of this one.
                 (unless (string-suffix-p "\n" text)
                   (setq text (concat text "\n")))

                 (ediff-copy-diff n nil 'C nil text)
                 (message "Expose: region %d replaced -- `r' restores it"
                          (1+ n)))))))

       nil

       (lambda (error-data)
         (message "Expose: provider failed: %s"
                  (error-message-string error-data))))))

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
                    :n "B" #'jsoa/ediff-copy-both-to-C
                    ;; `e' is free in `ediff-mode-map' -- checked against
                    ;; the full list in `ediff-setup-keymap'.
                    :n "e" #'jsoa/ediff-ai-resolve))))
