;;; expose-find-tests.el -*- lexical-binding: t; -*-

;;; A side-panel buffer listing the tests that reach the code at
;;; point -- the same information `expose-find-tests' used to show
;;; through `xref-show-xrefs' (grouped by file, source line in
;;; context), placed and navigated the way every other Expose result
;;; is instead of wherever `display-buffer-alist' happens to put a
;;; generic xref buffer.
;;;
;;; Visiting a test keeps this list where it is, on the right, and
;;; opens the file in the window to its left -- the mirror image of
;;; how `expose-side-panel-place' works everywhere else in Expose
;;; (there, a fixed source stays left and the result changes on the
;;; right; here, this list is what has a fixed home, and what changes
;;; is what's shown next to it). That way several tests can be opened
;;; in turn from the same search without losing the list.

(require 'subr-x)
(require 'expose-side-panel)

(defconst expose-find-tests-buffer-name "*EXPOSE Tests*"
  "Name of the Expose find-tests results buffer.")

(defface expose-find-tests-title-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the Expose find-tests buffer's title and file headings.")

(defface expose-find-tests-meta-face
  '((t :inherit shadow))
  "Face for secondary text in the Expose find-tests buffer.")

(defvar-local expose-find-tests-origin-buffer nil
  "The buffer `expose-find-tests' was run from, for `g' to search again from.")

(defvar-local expose-find-tests-origin-position nil
  "The position in `expose-find-tests-origin-buffer' to search again from.

Captured once, at the first search, rather than read from this
buffer's own point on refresh -- point here is wherever you're reading
results, which has nothing to do with what symbol the search was
about.")

(defvar-local expose-find-tests-name nil
  "The symbol name the current results are for.")

(define-derived-mode expose-find-tests-mode special-mode "Expose-Tests"
  "Major mode for the Expose find-tests results buffer."

  (setq-local truncate-lines t)

  (when (bound-and-true-p evil-local-mode)
    (evil-normal-state)))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun expose-find-tests-insert (name tests failures)
  "Render NAME's TESTS (and any FAILURES) into the current buffer."

  (let ((inhibit-read-only t))
    (erase-buffer)

    (insert
     (propertize
      (format "Tests covering %s" (or name "?"))
      'face 'expose-find-tests-title-face))

    (insert "\n\n")

    (insert
     (propertize
      (if (= 1 (length tests)) "1 test found." (format "%d tests found." (length tests)))
      'face 'expose-find-tests-meta-face))

    (when failures
      (insert
       (propertize
        (format " (incomplete: %d lookup%s failed -- see the log)"
                (length failures) (if (= 1 (length failures)) "" "s"))
        'face 'warning)))

    (insert "\n")

    (insert
     (propertize
      "TAB/S-TAB moves between tests. RET opens one to the left. g refreshes. q quits.\n\n"
      'face 'expose-find-tests-meta-face))

    (if (not tests)

        (insert "No tests found.\n")

      (let (current-file)
        (dolist (node tests)
          (let ((file (plist-get node :file)))

            (unless (equal file current-file)
              (setq current-file file)
              (when current-file (insert "\n"))
              (insert
               (propertize
                (if file (abbreviate-file-name file) "(unknown file)")
                'face 'expose-find-tests-title-face))
              (insert "\n")))

          (expose-find-tests-insert-item node))))

    (goto-char (point-min))))

(defun expose-find-tests-insert-item (node)
  "Insert one test NODE, tagged for navigation and visiting."

  (let* ((block-start (point))
         (file (plist-get node :file))
         (line (or (plist-get node :line) 1))
         (text (expose-callers-line-text file line))
         (summary
          (if (and text (not (string-blank-p text)))
              (string-trim-right text)
            (or (plist-get node :name) "?"))))

    (insert (format "  %5d  " line))
    (insert summary)
    (insert "\n")

    (add-text-properties
     block-start
     (point)
     (list 'expose-find-tests-item node))))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun expose-find-tests-current-item ()
  "Return the test node at point, or nil."

  (or
   (get-text-property (point) 'expose-find-tests-item)
   (get-text-property (line-beginning-position) 'expose-find-tests-item)
   (get-text-property (max (point-min) (1- (line-end-position))) 'expose-find-tests-item)))

(defun expose-find-tests-next-item-position ()
  "Return the position of the next test item after point."

  (let ((current (expose-find-tests-current-item))
        (position (point))
        found)

    (while (and (not found) (< position (point-max)))
      (setq position
            (next-single-property-change position 'expose-find-tests-item nil (point-max)))

      (let ((item (get-text-property position 'expose-find-tests-item)))
        (when (and item (not (eq item current)))
          (setq found position))))

    found))

(defun expose-find-tests-previous-item-position ()
  "Return the position of the previous test item before point."

  (let ((current (expose-find-tests-current-item))
        (position (point))
        found)

    (while (and (not found) (> position (point-min)))
      (setq position
            (previous-single-property-change position 'expose-find-tests-item nil (point-min)))

      (let* ((probe (max (point-min) (1- position)))
             (item (get-text-property probe 'expose-find-tests-item)))
        (when (and item (not (eq item current)))
          (setq found probe))))

    found))

(defun expose-find-tests-next-item ()
  "Move to the next test in the Expose find-tests buffer."

  (interactive)

  (if-let ((position (expose-find-tests-next-item-position)))
      (progn (goto-char position) (beginning-of-line))
    (message "No next test")))

(defun expose-find-tests-previous-item ()
  "Move to the previous test in the Expose find-tests buffer."

  (interactive)

  (if-let ((position (expose-find-tests-previous-item-position)))
      (progn (goto-char position) (beginning-of-line))
    (message "No previous test")))

;;; ---------------------------------------------------------------------------
;;; Visiting
;;; ---------------------------------------------------------------------------

(defun expose-find-tests-visit ()
  "Open the test at point, to the left of this list.

Keeps this list exactly where it is rather than replacing it, so
several tests found by the same search can be opened one after another
without losing the list they came from."

  (interactive)

  (let ((item (expose-find-tests-current-item)))
    (unless item
      (user-error "No test on this line"))

    (let ((file (plist-get item :file))
          (line (or (plist-get item :line) 1)))

      (unless (and file (file-exists-p file))
        (user-error "File does not exist: %s" file))

      (let* ((list-window (selected-window))
             (target-window
              (or (window-in-direction 'left list-window)
                  (split-window list-window nil 'left))))

        (select-window target-window)
        (find-file file)
        (goto-char (point-min))
        (forward-line (1- line))))))

;;; ---------------------------------------------------------------------------
;;; Refresh
;;; ---------------------------------------------------------------------------

(defun expose-find-tests-reload ()
  "Search again from where this search was originally started.

Runs from within this (already current) results buffer -- only the
data-collection step inside `expose-find-tests-search-and-render'
briefly visits the origin buffer, for the `thing-at-point'/LSP context
that has to come from there."

  (interactive)

  (unless (buffer-live-p expose-find-tests-origin-buffer)
    (user-error "The buffer this search started from is gone"))

  (let ((point-line (line-number-at-pos))
        (point-column (current-column)))

    (expose-find-tests-search-and-render
     expose-find-tests-origin-buffer
     expose-find-tests-origin-position)

    (goto-char (point-min))
    (forward-line (1- point-line))
    (move-to-column point-column)))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(declare-function expose-callers-collect-tests "expose-callers" ())
(declare-function expose-callers-tests-in "expose-callers" (nodes keep))
(declare-function expose-callers-line-text "expose-callers" (file line))

(defun expose-find-tests-search-and-render (origin-buffer origin-position)
  "Search from ORIGIN-BUFFER at ORIGIN-POSITION, render into the current buffer.

Callers are responsible for the current buffer already being the
Expose find-tests buffer -- data collection briefly visits
ORIGIN-BUFFER, since `thing-at-point'/LSP context has to come from
there, but `with-current-buffer' restores the results buffer as
current again before anything is rendered."

  (require 'expose-callers)

  (let* ((found
          (with-current-buffer origin-buffer
            (save-excursion
              (goto-char origin-position)
              (expose-callers-collect-tests))))

         (name
          (plist-get (plist-get found :root) :name))

         (tests
          (expose-callers-tests-in (plist-get found :nodes) (plist-get found :keep)))

         (failures
          (plist-get found :failures)))

    (setq expose-find-tests-origin-buffer origin-buffer)
    (setq expose-find-tests-origin-position origin-position)
    (setq expose-find-tests-name name)

    (expose-find-tests-insert name tests failures)

    (message "Expose: %s %s%s"
             (if (= 1 (length tests)) "1 test covers" (format "%d tests cover" (length tests)))
             name
             (if failures
                 (format " (incomplete: %d lookup%s failed -- see the log)"
                         (length failures) (if (= 1 (length failures)) "" "s"))
               ""))))

;;;###autoload
(defun expose-find-tests-open (source-window)
  "Run `expose-find-tests' from SOURCE-WINDOW and show results beside it.

SOURCE-WINDOW's buffer and point are where the search runs from -- both
for this first search and every `g' refresh after it."

  (let* ((origin-buffer (window-buffer source-window))
         (origin-position (window-point source-window))
         (buffer (get-buffer-create expose-find-tests-buffer-name)))

    (with-current-buffer buffer
      (unless (derived-mode-p 'expose-find-tests-mode)
        (expose-find-tests-mode))
      (expose-find-tests-search-and-render origin-buffer origin-position))

    (select-window (expose-side-panel-place source-window buffer))))

(with-eval-after-load 'evil
  (evil-define-key* 'normal expose-find-tests-mode-map
    (kbd "TAB") #'expose-find-tests-next-item
    (kbd "<backtab>") #'expose-find-tests-previous-item
    (kbd "RET") #'expose-find-tests-visit
    (kbd "g") #'expose-find-tests-reload
    (kbd "q") #'quit-window)

  (evil-define-key* 'motion expose-find-tests-mode-map
    (kbd "TAB") #'expose-find-tests-next-item
    (kbd "<backtab>") #'expose-find-tests-previous-item
    (kbd "RET") #'expose-find-tests-visit
    (kbd "g") #'expose-find-tests-reload
    (kbd "q") #'quit-window)

  (evil-set-initial-state 'expose-find-tests-mode 'normal))

(provide 'expose-find-tests)

;;; expose-find-tests.el ends here
