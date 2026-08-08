;;; site-lisp/expose/expose-review-source.el -*- lexical-binding: t; -*-

;;; expose-review-source.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(require 'expose-popup)
(require 'expose-review-context)
(require 'expose-review-store)
(require 'diff-mode nil t)
(require 'expose-hover)
(require 'expose-review-request)

(defgroup expose-review-source nil
  "Source-buffer annotations for Expose Review."
  :group 'expose-review)

(defcustom expose-review-source-hover-delay 0.20
  "Idle delay before showing a review hover in source buffers."
  :type 'number
  :group 'expose-review-source)

(defcustom expose-review-source-show-range-face t
  "Whether to lightly highlight source ranges with review comments.

Patch target ranges are highlighted separately and more strongly."
  :type 'boolean
  :group 'expose-review-source)

(defcustom expose-review-source-fringe-side 'right-fringe
  "Fringe side used for Expose Review source indicators.

Use `right-fringe' to avoid colliding with Git gutter/fringe indicators."
  :type '(choice
          (const :tag "Left fringe" left-fringe)
          (const :tag "Right fringe" right-fringe))
  :group 'expose-review-source)

(defface expose-review-source-patch-target-face
  '((t (:underline (:color "#4db5bd" :style wave) :extend nil)))
  "Face for suggested patch target ranges.

A squiggly underline in doom-one's teal, in the same style as
`expose-watch-item-face' and `expose-review-region-item-face' -- rather
than filled with a background (previously inherited from
`diff-refine-added', which also brought along its yellow-green
foreground and tinted the underlying text), so it reads as \"annotated\"
without competing with syntax highlighting. `:extend nil' keeps the
underline from bleeding across the blank tail of each line, matching
those other two faces.

Teal is full review's own color in this scheme -- Watch uses magenta
and region review uses blue -- so which of the three flagged a given
line is visible at a glance."
  :group 'expose-review-source)

(defface expose-review-source-high-face
  '((t :inherit error))
  "Face for high-severity review indicators.")

(defface expose-review-source-medium-face
  '((t :inherit warning))
  "Face for medium-severity review indicators.")

(defface expose-review-source-low-face
  '((t :inherit font-lock-doc-face))
  "Face for low-severity review indicators.")

(defface expose-review-source-info-face
  '((t :inherit shadow))
  "Face for info-severity review indicators.")

(defface expose-review-source-range-face
  '((t (:background "#2a2f38" :extend t)))
  "Subtle face for review source comment ranges."
  :group 'expose-review-source)

(defvar-local expose-review-source-session nil
  "Active review session associated with the current buffer.")

(defvar-local expose-review-source-overlays nil
  "Review overlays in the current buffer.")

(defvar-local expose-review-source-hover-timer nil
  "Idle timer for source review hovers.")

(defun expose-review-source-dashboard-severity-face (severity)
  "Return dashboard-like severity face for SEVERITY."

  (pcase severity
    ('high
     (if (facep 'expose-review-high-face)
         'expose-review-high-face
       'error))
    ("high"
     (if (facep 'expose-review-high-face)
         'expose-review-high-face
       'error))

    ('medium
     (if (facep 'expose-review-medium-face)
         'expose-review-medium-face
       'warning))
    ("medium"
     (if (facep 'expose-review-medium-face)
         'expose-review-medium-face
       'warning))

    ('low
     (if (facep 'expose-review-low-face)
         'expose-review-low-face
       'font-lock-doc-face))
    ("low"
     (if (facep 'expose-review-low-face)
         'expose-review-low-face
       'font-lock-doc-face))

    ('info
     (if (facep 'expose-review-info-face)
         'expose-review-info-face
       'shadow))
    ("info"
     (if (facep 'expose-review-info-face)
         'expose-review-info-face
       'shadow))

    (_
     'shadow)))

(defun expose-review-source-subsection-face ()
  "Return face used for review hover subsection labels."

  (if (facep 'expose-review-low-face)
      'expose-review-low-face
    'font-lock-doc-face))

(defun expose-review-source-hover-width ()
  "Return preferred hover text width."

  (max
   60
   (min
    100
    (if (boundp 'expose-popup-max-width)
        (- expose-popup-max-width 4)
      96))))

(defun expose-review-source-fill-string (text)
  "Return TEXT filled for review hover display."

  (with-temp-buffer
    (let ((fill-column
           (expose-review-source-hover-width))

          (adaptive-fill-mode t))

      (insert
       (string-trim-right
        (or text "")))

      (goto-char (point-min))
      (fill-region
       (point-min)
       (point-max))

      (buffer-string))))

(defun expose-review-source-insert-filled-text (text &optional face)
  "Insert filled TEXT, optionally using FACE."

  (let ((filled
         (expose-review-source-fill-string text)))

    (if face
        (insert
         (propertize filled 'face face))
      (insert filled))

    (unless (string-suffix-p "\n" filled)
      (insert "\n"))))

(defun expose-review-source-insert-label (label)
  "Insert hover subsection LABEL."

  (insert
   (propertize
    (format "%s:\n" label)
    'face
    (expose-review-source-subsection-face))))

(defun expose-review-source-insert-section (label value)
  "Insert hover section LABEL and VALUE when VALUE is present."

  (when (and value
             (not
              (string-empty-p
               (string-trim
                (format "%s" value)))))

    (expose-review-source-insert-label label)
    (expose-review-source-insert-filled-text value)
    (insert "\n")))

(defun expose-review-source-fontify-diff (text)
  "Return TEXT fontified as a unified diff."

  (if (not
       (fboundp 'diff-mode))

      text

    (with-temp-buffer
      (delay-mode-hooks
        (diff-mode))

      (font-lock-mode 1)

      (insert
       (string-trim-right
        (or text "")))

      (font-lock-ensure
       (point-min)
       (point-max))

      (buffer-string))))

(defun expose-review-source-insert-patch (patch)
  "Insert PATCH with diff highlighting."

  (expose-review-source-insert-label "Patch")

  (insert
   (expose-review-source-fontify-diff patch))

  (unless (bolp)
    (insert "\n"))

  (insert "\n"))

(define-fringe-bitmap
  'expose-review-source-fringe-bitmap
  [#b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11100000]
  nil
  nil
  'center)

(defun expose-review-source-project-root ()
  "Return current project root, or nil."

  (when-let ((project
              (project-current nil)))

    (file-name-as-directory
     (expand-file-name
      (project-root project)))))

(defun expose-review-source-git-dir (project-root)
  "Return the resolved .git directory for PROJECT-ROOT, or nil.

Handles both a plain repository (.git is a directory) and a worktree or
submodule (.git is a file pointing elsewhere), without spawning a git
process."

  (let ((dotgit
         (expand-file-name ".git" project-root)))

    (cond
     ((file-directory-p dotgit)
      dotgit)

     ((file-readable-p dotgit)
      (with-temp-buffer
        (insert-file-contents dotgit)

        (let ((content
               (string-trim (buffer-string))))

          (when (string-match "\\`gitdir: \\(.+\\)\\'" content)

            (let ((gitdir
                   (match-string 1 content)))

              (if (file-name-absolute-p gitdir)
                  gitdir
                (expand-file-name gitdir project-root))))))))))

(defun expose-review-source-current-branch (project-root)
  "Return current branch for PROJECT-ROOT.

This is looked up on every `find-file' via
`expose-review-source-global-mode', so it reads git's HEAD file directly
instead of spawning `git rev-parse' -- always fresh (unlike the git-path
caches elsewhere in Expose, the branch can legitimately change mid-session
via an external checkout, so this must never return stale data), just
without the subprocess cost on the common path. Falls back to the
subprocess-based lookup if the HEAD file cannot be read or parsed."

  (or
   (when-let* ((git-dir
                (expose-review-source-git-dir project-root))

               (head-file
                (expand-file-name "HEAD" git-dir))

               (readable
                (file-readable-p head-file)))

     (with-temp-buffer
       (insert-file-contents head-file)

       (let ((content
              (string-trim (buffer-string))))

         (cond
          ((string-match "\\`ref: refs/heads/\\(.+\\)\\'" content)
           (match-string 1 content))

          ;; Detached HEAD: `git rev-parse --abbrev-ref HEAD' reports "HEAD".
          ((string-match-p "\\`[0-9a-fA-F]\\{7,40\\}\\'" content)
           "HEAD")))))

   (string-trim
    (expose-review-context-call-git
     project-root
     "rev-parse"
     "--abbrev-ref"
     "HEAD"))))

(defun expose-review-source-active-session ()
  "Return active review session for the current buffer, or nil."

  (when-let* ((project-root
               (expose-review-source-project-root))

              (branch
               (expose-review-source-current-branch project-root)))

    (expose-review-store-read-active
     project-root
     branch)))

(defun expose-review-source-active-session-p (session)
  "Return non-nil if SESSION is active enough for source annotations."

  (and session
       (memq
        (plist-get session :state)
        '(ready running preparing sending))))

(defun expose-review-source-relative-file (project-root)
  "Return current buffer file relative to PROJECT-ROOT."

  (when-let ((file
              (buffer-file-name)))

    (file-relative-name
     file
     project-root)))

(defun expose-review-source-items-for-file (session relative-file)
  "Return review items from SESSION for RELATIVE-FILE."

  (seq-filter
   (lambda (item)
     (string=
      (or
       (plist-get item :file)
       "")
      relative-file))
   (plist-get session :items)))

(defun expose-review-source-severity-face (severity)
  "Return source indicator face for SEVERITY."

  (pcase severity
    ('high 'expose-review-source-high-face)
    ("high" 'expose-review-source-high-face)

    ('medium 'expose-review-source-medium-face)
    ("medium" 'expose-review-source-medium-face)

    ('low 'expose-review-source-low-face)
    ("low" 'expose-review-source-low-face)

    ('info 'expose-review-source-info-face)
    ("info" 'expose-review-source-info-face)

    (_ 'expose-review-source-info-face)))

(defun expose-review-source-number (value fallback)
  "Return VALUE as a number, or FALLBACK."

  (cond
   ((numberp value)
    value)

   ((and
     (stringp value)
     (string-match-p "\\`[0-9]+\\'" value))
    (string-to-number value))

   (t
    fallback)))

(defun expose-review-source-item-line-start (item)
  "Return review comment start line for ITEM."

  (max
   1
   (expose-review-source-number
    (or
     (plist-get item :line-start)
     (plist-get item :line_start))
    1)))

(defun expose-review-source-item-line-end (item)
  "Return review comment end line for ITEM."

  (max
   (expose-review-source-item-line-start item)
   (expose-review-source-number
    (or
     (plist-get item :line-end)
     (plist-get item :line_end))
    (expose-review-source-item-line-start item))))

(defun expose-review-source-line-position (line)
  "Return buffer position at beginning of LINE."

  (save-excursion
    (goto-char (point-min))
    (forward-line
     (1-
      (max 1 line)))
    (line-beginning-position)))

(defun expose-review-source-line-end-position (line)
  "Return buffer position after LINE."

  (save-excursion
    (goto-char
     (expose-review-source-line-position line))
    (forward-line 1)
    (line-beginning-position)))

(defun expose-review-source-line-number-at-position (position)
  "Return one-based line number at POSITION."

  (save-excursion
    (goto-char position)
    (line-number-at-pos)))

(defun expose-review-source-region-line-range (region)
  "Return line range for REGION cons cell."

  (let ((start
         (car region))

        (end
         (cdr region)))

    (cons
     (expose-review-source-line-number-at-position start)
     (expose-review-source-line-number-at-position
      (max start
           (1- end))))))

(defun expose-review-source-non-empty-string-p (value)
  "Return non-nil if VALUE is a non-empty string."

  (and
   (stringp value)
   (not
    (string-empty-p
     (string-trim value)))))

(defun expose-review-source-search-text-region (text start end)
  "Search TEXT between START and END.

Return a cons cell of match beginning and end, or nil."

  (when (expose-review-source-non-empty-string-p text)

    (save-excursion
      (goto-char start)

      (when (search-forward text end t)

        (cons
         (match-beginning 0)
         (match-end 0))))))

(defun expose-review-source-item-anchor-line-range (item)
  "Return resolved anchor-text line range for ITEM."

  (let ((anchor
         (string-trim
          (or
           (plist-get item :anchor-text)
           ""))))

    (when (expose-review-source-non-empty-string-p anchor)

      (when-let ((region
                  (expose-review-source-search-text-region
                   anchor
                   (point-min)
                   (point-max))))

        (expose-review-source-region-line-range region)))))

(defun expose-review-source-patch-content-lines (patch prefix)
  "Return meaningful PATCH lines starting with PREFIX."

  (let (lines)

    (dolist (line
             (split-string
              (or patch "")
              "\n"
              t))

      (when (and
             (string-prefix-p prefix line)

             ;; Ignore diff headers.
             (not
              (string-prefix-p "+++" line))
             (not
              (string-prefix-p "---" line)))

        (let ((content
               (string-trim
                (substring line 1))))

          (when (expose-review-source-non-empty-string-p content)
            (push content lines)))))

    (nreverse lines)))

(defun expose-review-source-expanded-raw-search-bounds (item)
  "Return search bounds around ITEM's raw model range."

  (let* ((line-start
          (max
           1
           (-
            (expose-review-source-item-line-start item)
            25)))

         (line-end
          (+
           (expose-review-source-item-line-end item)
           25))

         (start
          (expose-review-source-line-position line-start))

         (end
          (expose-review-source-line-end-position line-end)))

    (cons start end)))

(defun expose-review-source-search-line-content (content start end)
  "Return line number where CONTENT appears between START and END."

  (when (expose-review-source-non-empty-string-p content)

    (save-excursion
      (goto-char start)

      (when (search-forward content end t)
        (expose-review-source-line-number-at-position
         (match-beginning 0))))))

(defun expose-review-source-patch-search-range (item)
  "Return patch target range for ITEM by searching patch contents."

  (let* ((patch
          (expose-review-source-suggestion-patch item))

         ;; The current source buffer usually contains the pre-patch code, so
         ;; removed lines are the best target for delete/replace patches.
         (candidate-lines
          (append
           (expose-review-source-patch-content-lines patch "-")
           (expose-review-source-patch-content-lines patch "+")))

         (bounds
          (expose-review-source-expanded-raw-search-bounds item))

         found-lines)

    (dolist (content candidate-lines)

      (when-let ((line
                  (or
                   ;; Prefer near the model's rough range.
                   (expose-review-source-search-line-content
                    content
                    (car bounds)
                    (cdr bounds))

                   ;; Fall back to the whole file.
                   (expose-review-source-search-line-content
                    content
                    (point-min)
                    (point-max)))))

        (push line found-lines)))

    (when found-lines
      (cons
       (apply #'min found-lines)
       (apply #'max found-lines)))))

(defun expose-review-source-item-comment-line-range (item)
  "Return resolved review comment line range for ITEM.

The comment location prefers the exact anchor text. The model-provided
line range is only a fallback."

  (or
   (expose-review-source-item-anchor-line-range item)

   (cons
    (expose-review-source-item-line-start item)
    (expose-review-source-item-line-end item))))

(defun expose-review-source-clear-overlays ()
  "Delete all Expose Review source overlays in the current buffer."

  (mapc #'delete-overlay expose-review-source-overlays)
  (setq expose-review-source-overlays nil))

(defun expose-review-source-fringe-string (face)
  "Return a fringe indicator string using FACE."

  (propertize
   "!"
   'display
   `(,expose-review-source-fringe-side
     expose-review-source-fringe-bitmap
     ,face)
   'face
   face))

(defun expose-review-source-make-range-overlay (item start end face)
  "Create source range overlay for ITEM from START to END using FACE."

  (let ((overlay
         (make-overlay start end nil t nil)))

    (overlay-put overlay 'expose-review-item item)
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'help-echo "Expose Review comment")
    (overlay-put overlay 'priority 30)

    (when expose-review-source-show-range-face
      (overlay-put overlay 'face 'expose-review-source-range-face))

    (push overlay expose-review-source-overlays)))

(defun expose-review-source-make-line-indicator (item line face)
  "Create left-fringe indicator for ITEM on LINE using FACE."

  (let* ((position
          (expose-review-source-line-position line))

         (overlay
          (make-overlay position position nil t nil)))

    (overlay-put overlay 'expose-review-item item)
    (overlay-put overlay 'before-string
                 (expose-review-source-fringe-string face))
    (overlay-put overlay 'help-echo "Expose Review comment")
    (push overlay expose-review-source-overlays)))

(defun expose-review-source-add-item-overlays (item)
  "Add source overlays for review ITEM."

  (let* ((line-start
          (expose-review-source-item-line-start item))

         (line-end
          (expose-review-source-item-line-end item))

         (start
          (expose-review-source-line-position line-start))

         (end
          (expose-review-source-line-end-position line-end))

         (face
          (expose-review-source-severity-face
           (plist-get item :severity))))

    ;; Subtle background over the review/comment range.
    (expose-review-source-make-range-overlay
     item
     start
     end
     face)

    ;; One right-fringe marker for the review item.
    (expose-review-source-make-line-indicator
     item
     line-start
     face)

    ;; Stronger background over the suggested patch target.
    (expose-review-source-make-patch-target-overlay item)))

(defun expose-review-source-refresh-overlays ()
  "Refresh review overlays in the current buffer."

  (expose-review-source-clear-overlays)

  (when-let* ((session
               expose-review-source-session)

              (project-root
               (plist-get session :project-root))

              (relative-file
               (expose-review-source-relative-file project-root))

              (items
               (expose-review-source-items-for-file session relative-file)))

    (dolist (item items)
      (expose-review-source-add-item-overlays item))))

(defun expose-review-source-buffer-eligible-p ()
  "Return non-nil if the current buffer can show review annotations."

  (and
   (buffer-file-name)
   (not
    (minibufferp))
   (not
    (string-prefix-p
     " "
     (buffer-name)))))

(defun expose-review-source-refresh-buffer ()
  "Enable or disable `expose-review-source-mode' for the current buffer."

  (when (expose-review-source-buffer-eligible-p)

    (let* ((session
            (expose-review-source-active-session))

           (project-root
            (plist-get session :project-root))

           (relative-file
            (when project-root
              (expose-review-source-relative-file project-root)))

           (items
            (when relative-file
              (expose-review-source-items-for-file session relative-file))))

      (if (and
           (expose-review-source-active-session-p session)
           items)

          (progn
            (setq expose-review-source-session session)
            (unless expose-review-source-mode
              (expose-review-source-mode 1))
            (expose-review-source-refresh-overlays))

        (when expose-review-source-mode
          (expose-review-source-mode -1))))))

(defun expose-review-source-refresh-all ()
  "Refresh Expose Review source annotations in all file buffers."

  (dolist (buffer
           (buffer-list))

    (with-current-buffer buffer
      (when (expose-review-source-buffer-eligible-p)
        (expose-review-source-refresh-buffer)))))

(defun expose-review-source-refresh-project (project-root)
  "Refresh Expose Review source annotations for PROJECT-ROOT."

  (let ((root
         (file-name-as-directory
          (expand-file-name project-root))))

    (dolist (buffer
             (buffer-list))

      (with-current-buffer buffer
        (when-let ((file
                    (buffer-file-name)))

          (when (string-prefix-p
                 root
                 (expand-file-name file))

            (expose-review-source-refresh-buffer)))))))

(defun expose-review-source-item-at-point ()
  "Return review item at point, or nil."

  (seq-some
   (lambda (overlay)
     (overlay-get overlay 'expose-review-item))
   (overlays-at (point))))

(defun expose-review-source-format-location (item)
  "Return display location for ITEM."

  (let ((file
         (plist-get item :file))

        (line-start
         (expose-review-source-item-line-start item))

        (line-end
         (expose-review-source-item-line-end item)))

    (if (= line-start line-end)
        (format "%s:%s" file line-start)
      (format "%s:%s-%s" file line-start line-end))))

(defun expose-review-source-patch-new-range (patch)
  "Return new-file line range from unified PATCH.

The result is a cons cell like (START . END), or nil when PATCH does
not contain a unified-diff hunk header."

  (when (and patch
             (stringp patch)
             (not
              (string-empty-p patch)))

    (catch 'range
      (dolist (line
               (split-string patch "\n" t))

        ;; Examples:
        ;; @@ -112,3 +121,3 @@
        ;; @@ -112 +121 @@
        ;; @@ -112,0 +121,2 @@
        ;; @@ -112,3 +121,3 @@ some context
        (when (string-match
               "^@@[[:space:]]+-[0-9]+\\(?:,[0-9]+\\)?[[:space:]]+\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?[[:space:]]+@@"
               line)

          (let* ((start
                  (string-to-number
                   (match-string 1 line)))

                 (raw-length
                  (match-string 2 line))

                 (length
                  (if raw-length
                      (string-to-number raw-length)
                    1))

                 (end
                  (if (> length 0)
                      (+ start
                         (1- length))
                    start)))

            (throw 'range
                   (cons start end))))))))

(defun expose-review-source-suggestion-stored-patch-range (item)
  "Return stored patch target range for ITEM."

  (let* ((suggestion
          (plist-get item :suggestion))

         (line-start
          (plist-get suggestion :patch-line-start))

         (line-end
          (plist-get suggestion :patch-line-end)))

    (when (and line-start
               line-end
               (> line-start 0)
               (> line-end 0))

      (cons line-start line-end))))

(defun expose-review-source-suggestion-patch-range (item)
  "Return patch target range for ITEM."

  (let ((patch
         (expose-review-source-suggestion-patch item)))

    (or
     ;; Best case: numeric unified diff hunk.
     (expose-review-source-patch-new-range patch)

     ;; Header-only patch case:
     ;; @@
     ;; -        obj.reason = 'this was changed'
     (expose-review-source-patch-search-range item)

     ;; Fallback for already-normalized sessions.
     (expose-review-source-suggestion-stored-patch-range item))))

(defun expose-review-source-patch-target-location (item)
  "Return patch target display location for ITEM."

  (when-let ((range
              (expose-review-source-suggestion-patch-range item)))

    (let ((file
           (plist-get item :file))

          (line-start
           (car range))

          (line-end
           (cdr range)))

      (if (= line-start line-end)
          (format "%s:%s" file line-start)
        (format "%s:%s-%s" file line-start line-end)))))

(defun expose-review-source-make-patch-target-overlay (item)
  "Create an inline highlight for ITEM's patch target."

  (when-let ((range
              (expose-review-source-suggestion-patch-range item)))

    (let* ((line-start
            (car range))

           (line-end
            (cdr range))

           (start
            (expose-review-source-line-position line-start))

           (end
            (expose-review-source-line-end-position line-end)))

      (when (< start end)

        (let ((overlay
               (make-overlay start end nil t nil)))

          (overlay-put overlay 'expose-review-item item)
          (overlay-put overlay 'expose-review-patch-target t)
          (overlay-put overlay 'face 'expose-review-source-patch-target-face)
          (overlay-put overlay 'priority 90)
          (overlay-put overlay 'help-echo "Expose Review patch target")

          (push overlay expose-review-source-overlays))))))

(defun expose-review-source-suggestion-kind (item)
  "Return suggestion kind for ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :kind)
   'none))

(defun expose-review-source-suggestion-text (item)
  "Return suggestion text for ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :text)
   ""))

(defun expose-review-source-suggestion-patch (item)
  "Return suggestion patch for ITEM."

  (or
   (plist-get
    (plist-get item :suggestion)
    :patch)
   ""))

(defun expose-review-source-diagnostics-at-point ()
  "Return compact Flycheck diagnostics at point."

  (when (and
         (bound-and-true-p flycheck-mode)
         (fboundp 'flycheck-overlay-errors-at))

    (let ((errors
           (flycheck-overlay-errors-at (point))))

      (when errors
        (string-join
         (mapcar
          (lambda (error)
            (format
             "[%s] %s"
             (flycheck-error-level error)
             (flycheck-error-message error)))
          errors)
         "\n")))))

(defun expose-review-source-lsp-hover-signature ()
  "Return compact LSP hover signature at point, or nil."

  (when (and
         (fboundp 'lsp-feature?)
         (fboundp 'lsp-request)
         (fboundp 'lsp--text-document-position-params)
         (lsp-feature? "textDocument/hover"))

    (condition-case _error
        (when-let* ((hover
                     (lsp-request
                      "textDocument/hover"
                      (lsp--text-document-position-params)))

                    (value
                     (expose-hover-hover-value hover))

                    (signature
                     (expose-hover-clean-signature value)))

          signature)

      (error nil))))

(defun expose-review-source-eldoc-signature ()
  "Return compact Eldoc signature at point, or nil."

  (when (and
         (fboundp 'expose-hover-eldoc-available-p)
         (expose-hover-eldoc-available-p))

    (let ((result nil))

      (catch 'done
        (dolist (function
                 (expose-hover-eldoc-functions))

          (expose-hover-call-eldoc-function
           function
           (lambda (documentation &rest _props)
             (when-let* ((text
                          (expose-hover-normalize-eldoc-documentation
                           documentation))

                         (signature
                          (expose-hover-clean-signature text)))

               (setq result signature)
               (throw 'done result))))))

      result)))

(defun expose-review-source-context-empty-p (context)
  "Return non-nil if CONTEXT has nothing useful to render."

  (not
   (or
    (plist-get context :symbol)
    (plist-get context :signature)
    (plist-get context :diagnostics)
    (plist-get context :mode))))

(defun expose-review-source-insert-context (context)
  "Insert colorized source CONTEXT."

  (unless (expose-review-source-context-empty-p context)

    (expose-review-source-insert-label "Context")

    (when-let ((symbol
                (plist-get context :symbol)))
      (insert
       (propertize
        "Symbol: "
        'face
        (expose-review-source-subsection-face)))

      (insert symbol)
      (insert "\n\n"))

    (when-let ((signature
                (plist-get context :signature)))
      (insert
       (propertize
        "Type:\n"
        'face
        (expose-review-source-subsection-face)))

      ;; Same rendering path as normal Expose hover.
      ;; Do not fill this as prose; fontify it as source code.
      (insert
       (expose-hover-fontify
        signature
        (or
         (plist-get context :mode)
         major-mode)))

      (unless (bolp)
        (insert "\n"))

      (insert "\n"))

    (when-let ((diagnostics
                (plist-get context :diagnostics)))
      (insert
       (propertize
        "Diagnostics:\n"
        'face
        (expose-review-source-subsection-face)))

      (expose-review-source-insert-filled-text diagnostics)
      (insert "\n"))

    (when-let ((mode
                (plist-get context :mode)))
      (insert
       (propertize
        "Mode: "
        'face
        (expose-review-source-subsection-face)))

      (insert
       (format "%s\n" mode)))))

(defun expose-review-source-compact-type-info ()
  "Return compact source context plist for the review hover."

  (list
   :symbol
   (thing-at-point 'symbol t)

   :signature
   (or
    (expose-review-source-lsp-hover-signature)
    (expose-review-source-eldoc-signature))

   :diagnostics
   (expose-review-source-diagnostics-at-point)

   :mode
   major-mode))

(defun expose-review-source-hover-body (item)
  "Return colorized hover body for review ITEM."

  (let* ((severity
          (plist-get item :severity))

         (severity-face
          (expose-review-source-dashboard-severity-face severity))

         (suggestion-kind
          (expose-review-source-suggestion-kind item))

         (suggestion-text
          (expose-review-source-suggestion-text item))

         (suggestion-patch
          (expose-review-source-suggestion-patch item))

         (type-info
          (expose-review-source-compact-type-info)))

    (with-temp-buffer

      ;; Header.
      (insert
       (propertize
        (format
         "[%s] %s · %s · %s\n"
         (upcase
          (format "%s" severity))
         (plist-get item :id)
         (plist-get item :category)
         (plist-get item :status))
        'face
        severity-face))

      ;; Click-looking location.
      (insert
       (propertize
        (expose-review-source-format-location item)
        'face
        'link))

      (insert "\n\n")

      (when-let ((patch-target
                  (expose-review-source-patch-target-location item)))

        (insert
         (propertize
          "Patch target: "
          'face
          (expose-review-source-subsection-face)))

        (insert
         (propertize
          patch-target
          'face
          'link))

        (insert "\n\n"))

      ;; Title.
      (expose-review-source-insert-filled-text
       (or
        (plist-get item :title)
        "Untitled review item")
       'bold)

      (insert "\n")

      ;; Body sections.
      (expose-review-source-insert-section
       "Comment"
       (plist-get item :comment))

      (expose-review-source-insert-section
       "Anchor"
       (plist-get item :anchor-text))

      ;; Suggestion.
      (cond
       ((and
         (eq suggestion-kind 'patch)
         (not
          (string-empty-p suggestion-patch)))

        (when (not
               (string-empty-p suggestion-text))
          (expose-review-source-insert-section
           "Suggestion"
           suggestion-text))

        (expose-review-source-insert-patch suggestion-patch))

       ((and
         (eq suggestion-kind 'text)
         (not
          (string-empty-p suggestion-text)))

        (expose-review-source-insert-section
         "Suggestion"
         suggestion-text)))

      (expose-review-source-insert-context type-info)

      (buffer-string))))

(defun expose-review-source-show-hover (buffer position)
  "Show review hover for BUFFER at POSITION."

  (when (buffer-live-p buffer)

    (with-current-buffer buffer

      (when (and
             expose-review-source-mode
             (= position
                (point)))

        (when-let ((item
                    (expose-review-source-item-at-point)))

          (expose-popup-show-view
           (list
            :title "Expose Review"
            :body
            (expose-review-source-hover-body item)
            :history nil)))))))

(defun expose-review-source-schedule-hover ()
  "Schedule source review hover for current point."

  (when expose-review-source-hover-timer
    (cancel-timer expose-review-source-hover-timer)
    (setq expose-review-source-hover-timer nil))

  (setq expose-review-source-hover-timer
        (run-with-idle-timer
         expose-review-source-hover-delay
         nil
         #'expose-review-source-show-hover
         (current-buffer)
         (point))))

(defun expose-review-source-cancel-hover ()
  "Cancel pending source review hover."

  (when expose-review-source-hover-timer
    (cancel-timer expose-review-source-hover-timer)
    (setq expose-review-source-hover-timer nil)))

(defun expose-review-source-post-command ()
  "Schedule review hover when point is inside a review range."

  (cond
   ;; Popup commands such as C-j/C-k should only scroll the popup.
   ;; Do not reschedule the review hover, or it will redraw the popup
   ;; and reset scroll back to the top.
   ((and
     (symbolp this-command)
     (fboundp 'expose-popup-command-p)
     (expose-popup-command-p this-command))

    (expose-review-source-cancel-hover))

   ((and
     (expose-review-source-item-at-point)
     (not (expose-hover-corfu-active-p)))

    (expose-review-source-schedule-hover))

   (t
    (expose-review-source-cancel-hover))))

;;;###autoload
(define-minor-mode expose-review-source-mode
  "Annotate source buffers with active Expose Review comments."
  :lighter " ExReview"

  (if expose-review-source-mode

      (progn
        (add-hook
         'post-command-hook
         #'expose-review-source-post-command
         nil
         t)

        (add-hook
         'after-save-hook
         #'expose-review-source-refresh-buffer
         nil
         t)

        (expose-review-source-refresh-overlays))

    (remove-hook
     'post-command-hook
     #'expose-review-source-post-command
     t)

    (remove-hook
     'after-save-hook
     #'expose-review-source-refresh-buffer
     t)

    (expose-review-source-cancel-hover)
    (expose-review-source-clear-overlays)
    (setq expose-review-source-session nil)))

;;;###autoload
(define-minor-mode expose-review-source-global-mode
  "Automatically enable Expose Review annotations in project files."
  :global t

  (if expose-review-source-global-mode

      (progn
        (add-hook
         'find-file-hook
         #'expose-review-source-refresh-buffer)

        (add-hook
         'after-revert-hook
         #'expose-review-source-refresh-buffer)

        (expose-review-source-refresh-all))

    (remove-hook
     'find-file-hook
     #'expose-review-source-refresh-buffer)

    (remove-hook
     'after-revert-hook
     #'expose-review-source-refresh-buffer)

    (dolist (buffer
             (buffer-list))

      (with-current-buffer buffer
        (when expose-review-source-mode
          (expose-review-source-mode -1))))))

(provide 'expose-review-source)
