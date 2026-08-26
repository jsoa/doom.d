;;; expose-action-buffer-test.el --- Tests for expose-action-buffer -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-popup)
(require 'expose-action-buffer)

;;; ---------------------------------------------------------------------------
;;; Placement: real window operations, not mocked -- the whole point of
;;; this module is *which* window ends up where, so a stub would test
;;; nothing that matters. `--batch' Emacs still has a real (if headless)
;;; frame and window tree, so this runs for real.
;;; ---------------------------------------------------------------------------

(defun expose-action-buffer-test-reset (buffer)
  "Make BUFFER the sole window of the frame; return that window."

  (delete-other-windows)
  (switch-to-buffer buffer)
  (selected-window))

(defmacro expose-action-buffer-test-with-clean-frame (&rest body)
  "Run BODY, then tear back down to a single window.

Each test builds its own window layout from scratch; without this a
failure partway through one test could leave windows behind for the
next."

  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)))

(ert-deftest expose-action-buffer-test-place-one-buffer-splits ()
  "One buffer open: split, actioned buffer keeps its (now left) window."

  (expose-action-buffer-test-with-clean-frame
    (let* ((left (get-buffer-create "eabt-left.py"))
           (source (expose-action-buffer-test-reset left)))
      (expose-action-buffer-place source)
      (should (= 2 (length (window-list))))
      (should (equal "eabt-left.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-action-buffer-name
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-action-buffer-test-place-actioned-on-left ()
  "Two buffers, actioned one already on the left: right pane becomes the result."

  (expose-action-buffer-test-with-clean-frame
    (let* ((left (get-buffer-create "eabt-left2.py"))
           (right (get-buffer-create "eabt-right2.py"))
           (source (expose-action-buffer-test-reset left)))
      (set-window-buffer (split-window-right) right)
      (expose-action-buffer-place source)
      (should (equal "eabt-left2.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-action-buffer-name
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-action-buffer-test-place-actioned-on-right-moves-left ()
  "Two buffers, actioned one on the right: it moves left, its old window
becomes the result pane."

  (expose-action-buffer-test-with-clean-frame
    (let* ((left (get-buffer-create "eabt-left3.py"))
           (right (get-buffer-create "eabt-right3.py"))
           (source (expose-action-buffer-test-reset left))
           (right-window (split-window-right)))
      (set-window-buffer right-window right)
      (expose-action-buffer-place right-window)
      (should (equal "eabt-right3.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-action-buffer-name
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-action-buffer-test-place-repeat-action-is-idempotent ()
  "A second action from the same source, result window already in place,
disturbs nothing."

  (expose-action-buffer-test-with-clean-frame
    (let* ((left (get-buffer-create "eabt-left4.py"))
           (source (expose-action-buffer-test-reset left)))
      (expose-action-buffer-place source)
      (let ((before (window-list)))
        (expose-action-buffer-place source)
        (should (equal before (window-list)))
        (should (equal "eabt-left4.py" (buffer-name (window-buffer (frame-first-window)))))
        (should (equal expose-action-buffer-name
                       (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))))))

(ert-deftest expose-action-buffer-test-place-recreates-after-window-closed ()
  "If the result window was closed since the last action, the next action
recreates it rather than erroring or doing nothing."

  (expose-action-buffer-test-with-clean-frame
    (let* ((left (get-buffer-create "eabt-left5.py"))
           (source (expose-action-buffer-test-reset left)))
      (expose-action-buffer-place source)
      (delete-window (window-in-direction 'right (frame-first-window)))
      (should (= 1 (length (window-list))))
      (expose-action-buffer-place source)
      (should (= 2 (length (window-list))))
      (should (equal expose-action-buffer-name
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-action-buffer-test-place-dead-source-window-falls-back ()
  "A dead/killed SOURCE-WINDOW -- what a captured window looks like once
its split closes mid-request -- falls back to the selected window
instead of signaling."

  (expose-action-buffer-test-with-clean-frame
    (let ((left (get-buffer-create "eabt-left6.py")))
      (expose-action-buffer-test-reset left)
      (let ((stale-window (split-window)))
        (delete-window stale-window)
        (should-not (window-live-p stale-window))
        (expose-action-buffer-place stale-window)
        (should (member expose-action-buffer-name
                        (mapcar (lambda (w) (buffer-name (window-buffer w))) (window-list))))))))

;;; ---------------------------------------------------------------------------
;;; expose-action-buffer-source-window: where a refinement asked for
;;; from *inside* this buffer should place its result -- not
;;; `(selected-window)', which from in here is this buffer's own.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-action-buffer-test-source-window-finds-buffer-showing-source ()
  (expose-action-buffer-test-with-clean-frame
    (let* ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-sw1.py"))))
      (expose-action-buffer-show
       (list :title "T" :body "b" :format 'plain) source)
      (with-selected-window (get-buffer-window expose-action-buffer-name)
        (should (equal "eabt-sw1.py"
                       (buffer-name (window-buffer (expose-action-buffer-source-window)))))))))

(ert-deftest expose-action-buffer-test-source-window-falls-back-to-left-window ()
  "Even if `expose-action-buffer-source' is stale (its buffer no longer
shown anywhere), the window to the left is still the right answer as
long as the usual two-pane layout is intact."

  (expose-action-buffer-test-with-clean-frame
    (let* ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-sw2.py"))))
      (expose-action-buffer-show
       (list :title "T" :body "b" :format 'plain) source)
      (let ((left (window-in-direction 'left (get-buffer-window expose-action-buffer-name))))
        (set-window-buffer left (get-buffer-create "eabt-sw2-replaced.py")))
      (with-selected-window (get-buffer-window expose-action-buffer-name)
        (should (equal "eabt-sw2-replaced.py"
                       (buffer-name (window-buffer (expose-action-buffer-source-window)))))))))

(ert-deftest expose-action-buffer-test-source-window-falls-back-to-selected-as-last-resort ()
  "No source buffer recorded, and no window to the left (this is the
only window) -- the selected window is the only thing left to offer."

  (expose-action-buffer-test-with-clean-frame
    (let ((sole (expose-action-buffer-test-reset (get-buffer-create "eabt-sw3"))))
      (with-current-buffer "eabt-sw3"
        (expose-action-buffer-mode)
        (setq expose-action-buffer-source nil))
      (should (eq sole (expose-action-buffer-source-window))))))

;;; ---------------------------------------------------------------------------
;;; End to end: rendering plus placement together.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-action-buffer-test-show-end-to-end ()
  (expose-action-buffer-test-with-clean-frame
    (let* ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-src.py")))
           (view (list :title "Explain" :body "**bold** and `code` and a paragraph."
                       :format 'markdown))
           (buffer (expose-action-buffer-show view source)))
      (with-current-buffer buffer
        (should (derived-mode-p 'expose-action-buffer-mode))
        (should buffer-read-only)
        (should (text-property-not-all (point-min) (point-max) 'face nil))
        (should (string-match-p "Explain" (buffer-string)))
        (should (equal "eabt-src.py" (buffer-name expose-action-buffer-source))))
      (should (equal "eabt-src.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-action-buffer-name
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-action-buffer-test-show-replaces-not-duplicates ()
  "A second action from the same source replaces content and reuses the
window, rather than opening a second result window or leaking the
previous result's text."

  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-src2.py"))))
      (expose-action-buffer-show
       (list :title "Explain" :body "the first answer" :format 'plain) source)
      (let ((before (window-list)))
        (expose-action-buffer-show
         (list :title "Fix" :body "a different answer" :format 'plain) source)
        (should (equal before (window-list)))
        (with-current-buffer expose-action-buffer-name
          (should (string-match-p "a different answer" (buffer-string)))
          (should-not (string-match-p "the first answer" (buffer-string))))))))

;;; ---------------------------------------------------------------------------
;;; Refine data and rendering. This module only carries `:refine' and
;;; renders around it opaquely -- what it actually means, and the
;;; command that acts on it, live in `expose-commands.el' and are
;;; tested there.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-action-buffer-test-stashes-refine-from-view ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-refine1.py"))))
      (expose-action-buffer-show
       (list :title "Tests" :body "b" :format 'plain
             :refine (list :type 'tests :context '(:file "x") :refinements '("also add C")))
       source)
      (with-current-buffer expose-action-buffer-name
        (should
         (equal
          '(:type tests :context (:file "x") :refinements ("also add C"))
          expose-action-buffer-refine))))))

(ert-deftest expose-action-buffer-test-refine-absent-when-view-has-none ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-refine2.py"))))
      (expose-action-buffer-show (list :title "Explain" :body "b" :format 'plain) source)
      (with-current-buffer expose-action-buffer-name
        (should-not expose-action-buffer-refine)))))

(ert-deftest expose-action-buffer-test-refine-does-not-leak-into-next-unrelated-result ()
  "A later, unrelated result (no `:refine' of its own) must not inherit
the previous one's -- otherwise `r' would silently offer to refine
something it has no actual data for."

  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-refine3.py"))))
      (expose-action-buffer-show
       (list :title "Tests" :body "b" :format 'plain
             :refine (list :type 'tests :context '(:file "x") :refinements nil))
       source)
      (expose-action-buffer-show (list :title "Explain" :body "b2" :format 'plain) source)
      (with-current-buffer expose-action-buffer-name
        (should-not expose-action-buffer-refine)))))

(ert-deftest expose-action-buffer-test-renders-refinements-list-and-hint ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-refine4.py"))))
      (expose-action-buffer-show
       (list :title "Tests" :body "b" :format 'plain
             :refine (list :type 'tests :context '(:file "x")
                           :refinements '("also add C" "nvm undo that")))
       source)
      (with-current-buffer expose-action-buffer-name
        (should (string-match-p "1) also add C" (buffer-string)))
        (should (string-match-p "2) nvm undo that" (buffer-string)))
        (should (string-match-p "r: refine" (buffer-string)))))))

(ert-deftest expose-action-buffer-test-no-refinements-list-when-none-applied-yet ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-refine5.py"))))
      (expose-action-buffer-show
       (list :title "Tests" :body "b" :format 'plain
             :refine (list :type 'tests :context '(:file "x") :refinements nil))
       source)
      (with-current-buffer expose-action-buffer-name
        (should-not (string-match-p "Refinements:" (buffer-string)))
        ;; Still refinable, hint still shown, even with nothing applied yet.
        (should (string-match-p "r: refine" (buffer-string)))))))

(ert-deftest expose-action-buffer-test-no-hint-when-not-refinable ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-refine6.py"))))
      (expose-action-buffer-show (list :title "Explain" :body "b" :format 'plain) source)
      (with-current-buffer expose-action-buffer-name
        (should-not (string-match-p "r: refine" (buffer-string)))))))

;;; ---------------------------------------------------------------------------
;;; History: every kind of result this buffer shows -- a `SPC c h h'
;;; action, a Region Review result -- is meant to keep landing in popup
;;; history exactly as it did when `expose-popup-show-view' was the one
;;; adding it, now that this buffer is what actually shows them.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-action-buffer-test-show-records-to-history ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-hist.py")))
          (view (expose-popup-view-create "Explain" "the answer"))
          recorded)
      (cl-letf (((symbol-function 'expose-history-add) (lambda (v) (setq recorded v))))
        (expose-action-buffer-show view source)
        (should (eq recorded view))))))

(ert-deftest expose-action-buffer-test-show-skips-history-for-history-nil-view ()
  "A view marked `:history nil' -- the transient `Loading...' placeholder,
or a caller's own quick error message -- is shown but not recorded."

  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-hist2.py")))
          (view (list :title "Explain" :body "Loading..." :history nil))
          recorded)
      (cl-letf (((symbol-function 'expose-history-add) (lambda (v) (setq recorded v))))
        (expose-action-buffer-show view source)
        (should-not recorded)))))

;;; ---------------------------------------------------------------------------
;;; Markdown markup hiding: `expose-popup-render-body' marks a rendered
;;; `**bold**''s asterisks `invisible markdown-markup', but a property
;;; alone hides nothing -- `buffer-invisibility-spec' must also name that
;;; symbol. Checked directly against a synthetic `invisible'-propertized
;;; character rather than by asking `expose-popup-render-markdown' to
;;; produce one: the test suite runs against `test/stubs/markdown-mode.el',
;;; a minimal stub with no real major mode to fontify with, so that
;;; function correctly falls back to unfontified text here by design (see
;;; its `(not (fboundp 'markdown-mode))' branch) -- this test is about
;;; what `expose-action-buffer-mode' itself is responsible for, not about
;;; re-proving that already-tested fallback.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-action-buffer-test-markdown-markup-is-in-invisibility-spec ()
  (expose-action-buffer-test-with-clean-frame
    (let ((source (expose-action-buffer-test-reset (get-buffer-create "eabt-src3.py"))))
      (expose-action-buffer-show
       (list :title "Explain" :body "plain text" :format 'plain)
       source)
      (with-current-buffer expose-action-buffer-name
        (should (memq 'markdown-markup buffer-invisibility-spec))
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize "**" 'invisible 'markdown-markup)))
        (should (invisible-p (1- (point-max))))))))

;;; ---------------------------------------------------------------------------
;;; Copy commands. Evil-specific parts (that `c'/`q' are actually bound
;;; to these, in the right states) are not exercised here, the same as
;;; this package's other Evil integrations -- see the
;;; `with-eval-after-load 'evil' block in `expose-action-buffer.el' --
;;; none of which load Evil in this test suite either. Verified once,
;;; live, against real Evil, when this was built.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-action-buffer-test-code-blocks-finds-one ()
  (with-temp-buffer
    (insert "prose\n\n```python\ndef foo():\n    pass\n```\n\nmore prose\n")
    (should
     (equal
      '("def foo():\n    pass\n")
      (mapcar (lambda (b) (buffer-substring-no-properties (car b) (cdr b)))
              (expose-action-buffer-code-blocks))))))

(ert-deftest expose-action-buffer-test-code-blocks-finds-several-in-order ()
  (with-temp-buffer
    (insert "```python\na = 1\n```\n\nbetween\n\n```python\nb = 2\n```\n")
    (should
     (equal
      '("a = 1\n" "b = 2\n")
      (mapcar (lambda (b) (buffer-substring-no-properties (car b) (cdr b)))
              (expose-action-buffer-code-blocks))))))

(ert-deftest expose-action-buffer-test-code-blocks-none-in-plain-text ()
  (with-temp-buffer
    (insert "no fences here at all")
    (should-not (expose-action-buffer-code-blocks))))

(ert-deftest expose-action-buffer-test-code-blocks-ignores-unterminated-fence ()
  (with-temp-buffer
    (insert "```python\nno closing fence\nkeeps going\n")
    (should-not (expose-action-buffer-code-blocks))))

(ert-deftest expose-action-buffer-test-copy-code-at-point-inside-a-block ()
  (with-temp-buffer
    (expose-action-buffer-mode)
    (let ((inhibit-read-only t))
      (insert "```python\ndef foo():\n    return 42\n```\n"))
    (goto-char (point-min))
    (search-forward "return 42")
    (expose-action-buffer-copy-code-at-point)
    (should (equal "def foo():\n    return 42\n" (current-kill 0)))))

(ert-deftest expose-action-buffer-test-copy-code-at-point-outside-but-only-one-block ()
  "Point does not have to be inside the block when there is only one --
requiring that would be friction for the common case."

  (with-temp-buffer
    (expose-action-buffer-mode)
    (let ((inhibit-read-only t))
      (insert "some prose\n\n```python\ndef foo():\n    return 42\n```\n"))
    (goto-char (point-min))
    (expose-action-buffer-copy-code-at-point)
    (should (equal "def foo():\n    return 42\n" (current-kill 0)))))

(ert-deftest expose-action-buffer-test-copy-code-at-point-outside-with-several-blocks ()
  "More than one block and point is not inside any of them: this must
say so, not guess which one was meant."

  (with-temp-buffer
    (expose-action-buffer-mode)
    (let ((inhibit-read-only t))
      (insert "```python\na = 1\n```\n\nbetween\n\n```python\nb = 2\n```\n"))
    (goto-char (point-min))
    (search-forward "between")
    (let ((kill-ring nil) (kill-ring-yank-pointer nil))
      (expose-action-buffer-copy-code-at-point)
      (should-not kill-ring))))

(ert-deftest expose-action-buffer-test-copy-code-at-point-no-blocks ()
  (with-temp-buffer
    (expose-action-buffer-mode)
    (let ((kill-ring nil) (kill-ring-yank-pointer nil))
      (expose-action-buffer-copy-code-at-point)
      (should-not kill-ring))))

(provide 'expose-action-buffer-test)
