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

  (defcustom jsoa/ediff-ai-context-lines 40
    "Lines of surrounding code sent with a conflict region.

Without them a model sees two fragments and no indentation, scope or
neighbouring code to match, and returns something that has to be
re-indented by hand.

Wide rather than tight, because the interesting conflicts need it. When
one side has extracted a block into its own function, putting the other
side's addition inside that function means being able to read it -- and a
function defined thirty lines away is outside any window small enough to
call economical."
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

  (defcustom jsoa/ediff-ai-max-file-lines 900
    "Longest file sent whole with a conflict, in lines.

Above this only `jsoa/ediff-ai-context-lines' either side go, which is
worse but bounded: a request carrying a five thousand line file is slow,
expensive, and mostly padding."
    :type 'integer
    :group 'ediff)

  (defconst jsoa/ediff-ai-marker "<<< THE REGION TO RESOLVE GOES HERE >>>"
    "Placeholder standing in for the conflict inside the surrounding file.")

  (defun jsoa/ediff-context (n)
    "Return the code around region N in buffer C, and how it was chosen.

Returns (KIND . TEXT). KIND is `file' when the whole of buffer C fitted,
`window' when only the lines either side did.

The whole file is worth sending. What a narrow window leaves out is not
more versions of the conflict -- there are already three of those -- but
the rest of this file: the function one side extracted the block into,
the imports that say whether a name is available, the other call sites
that say what the surrounding code expects. Resolving into a structure
you cannot see is guesswork.

The region itself is replaced by a marker rather than left in place. A
model given six hundred lines and three versions of something has to be
told which part of them to rewrite, and position alone no longer says
it."

    (let ((control ediff-control-buffer))
      (with-current-buffer ediff-buffer-C
        (save-excursion
          (let ((beg (ediff-get-diff-posn 'C 'beg n control))
                (end (ediff-get-diff-posn 'C 'end n control)))

            (if (<= (count-lines (point-min) (point-max))
                    jsoa/ediff-ai-max-file-lines)

                (cons 'file
                      (concat (buffer-substring-no-properties (point-min) beg)
                              jsoa/ediff-ai-marker "\n"
                              (buffer-substring-no-properties end (point-max))))

              (cons 'window
                    (concat
                     (progn (goto-char beg)
                            (forward-line (- jsoa/ediff-ai-context-lines))
                            (buffer-substring-no-properties (point) beg))
                     jsoa/ediff-ai-marker "\n"
                     (progn (goto-char end)
                            (forward-line jsoa/ediff-ai-context-lines)
                            (buffer-substring-no-properties end (point)))))))))))

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

       ;; The file first, so the versions of the region are read against
       ;; something rather than in isolation.
       (if (eq (car context) 'file)
           "=== THE FILE, WITH THE CONFLICT REMOVED ===\n"
         (format "=== %d LINES EITHER SIDE OF THE CONFLICT ===\n"
                 jsoa/ediff-ai-context-lines))
       (cdr context) "\n"

       ;; Other conflicts in the same file are still marked up, and would
       ;; otherwise read as an invitation to deal with them too.
       (if (and (eq (car context) 'file)
                (string-match-p "^<<<<<<< " (cdr context)))
           (concat "Any other conflict markers above are regions you are"
                   " not being asked about. Leave them alone.\n\n")
         "")

       (format "These are the three versions of %s:\n\n"
               jsoa/ediff-ai-marker)

       "=== OURS ===\n" (or (jsoa/ediff-region n 'A) "") "\n"
       "=== THEIRS ===\n" (or (jsoa/ediff-region n 'B) "") "\n"
       (if ancestor (concat "=== COMMON ANCESTOR ===\n" ancestor "\n") "")

       ;; A model handed code will improve it unless told not to, and an
       ;; improvement smuggled into a conflict resolution is the worst
       ;; place to receive one: it arrives disguised as somebody else's
       ;; change, in a commit nobody reviews line by line, in a region
       ;; that is already hard to read.
       "This is a merge resolution, not a code review. The result must do"
       " exactly what OURS and THEIRS each set out to do -- no less, and"
       " nothing besides.\n\n"

       "- Keep both intentions. Where the two sides touched the same code"
       " for different reasons, the answer usually contains both changes"
       " rather than one of them.\n"
       ;; The rule this replaces said every line had to come from one side
       ;; or the other, which forbids the resolution that is often the only
       ;; correct one: if OURS extracted a block into a method and THEIRS
       ;; added to that block where it used to be, neither side's lines are
       ;; the answer -- their addition has to move inside the extraction.
       "- Apply one side's structural change to the other side's new code."
       " If OURS extracted a block into its own function and THEIRS added"
       " more code to that block where it used to live, the added code"
       " belongs inside the extracted function too -- carry the extraction"
       " across rather than leaving their addition behind at the old site."
       " Restructuring that far is the merge doing its job, not a liberty"
       " you are taking; restructuring further is not.\n"
       "- Beyond that, change nothing the merge does not force: no"
       " renaming, reordering, reformatting or simplifying.\n"
       "- Do not add or remove comments, logging, type hints, error"
       " handling or tests that neither side had.\n"
       "- Do not fix bugs you notice and do not improve code you think is"
       " wrong. Both sides may well be imperfect; preserving that is the"
       " job here, and correcting it is a separate change somebody else"
       " should get to review on its own.\n"
       "- If one side already contains everything the other does, return"
       " that side unchanged.\n"
       "- Where the two intentions genuinely cannot both be kept, return"
       " OURS unchanged rather than inventing a compromise.\n\n"

       "Return only the code that replaces "
       jsoa/ediff-ai-marker
       ": no conflict markers, no code fences, no explanation, and none of"
       " the surrounding file -- just the region itself, indented to match"
       " where it sits.")))

  (defun jsoa/ediff-region-indent (n)
    "Return the indentation the resolved region N should begin at.

Read from OURS, then THEIRS, and not from buffer C -- which is the
obvious place and the wrong one. `ediff-default-variant' is `combined'
by default, so C's region opens with ediff's own `<<<<<<< variant A'
marker sitting at column zero: asking C for the indentation returns none,
and the repair that depends on it silently does nothing.

The first line with anything on it wins, since a side can legitimately
begin with a blank line."

    (or (cl-loop for type in '(A B)
                 for text = (jsoa/ediff-region n type)
                 for line = (cl-find-if (lambda (l) (string-match-p "[^ \t]" l))
                                        (split-string (or text "") "\n"))
                 when (and line (string-match "\\`[ \t]+" line))
                 return (match-string 0 line))
        ""))

  (defun jsoa/ediff-ai-reindent (text indent)
    "Put INDENT back on TEXT's first line if something trimmed it off.

Providers normalize their output with `string-trim' -- correct for the
popup answers Expose was built around, and destructive here, because it
strips exactly one thing: the leading whitespace of the first line. The
result lands flush against the left margin while every line under it
keeps its indentation, which in Python is not a formatting complaint but
a syntax error.

Only that one line is repaired, and only when it looks trimmed rather
than deliberately dedented: a first line at column zero, indented lines
beneath it, and a region that was itself indented."

    (let ((lines (split-string text "\n")))
      (if (and (not (string-empty-p indent))
               (car lines)
               (not (string-empty-p (car lines)))
               ;; Starts at column zero...
               (not (string-match-p "\\`[ \t]" (car lines)))
               ;; ...while something below it does not.
               (cl-some (lambda (line) (string-match-p "\\`[ \t]+[^ \t]" line))
                        (cdr lines)))

          (mapconcat #'identity
                     (cons (concat indent (car lines)) (cdr lines))
                     "\n")
        text)))

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

    (let* ((control ediff-control-buffer)
           (n ediff-current-difference)
           ;; Captured now, while the region is still what the prompt
           ;; describes.
           (indent (jsoa/ediff-region-indent ediff-current-difference))
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
             (let ((text (jsoa/ediff-ai-reindent
                          (jsoa/ediff-ai-clean
                           (expose-transport-response-text response))
                          indent)))

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
