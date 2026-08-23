;;; expose-side-panel-test.el --- Tests for expose-side-panel -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-side-panel)

;;; ---------------------------------------------------------------------------
;;; Real window operations, not mocked -- the whole point of this module
;;; is *which* window ends up where, so a stub would test nothing that
;;; matters. `--batch' Emacs still has a real (if headless) frame and
;;; window tree, so this runs for real.
;;; ---------------------------------------------------------------------------

(defun expose-side-panel-test-reset (buffer)
  "Make BUFFER the sole window of the frame; return that window."

  (delete-other-windows)
  (switch-to-buffer buffer)
  (selected-window))

(defmacro expose-side-panel-test-with-clean-frame (&rest body)
  "Run BODY, then tear back down to a single window."

  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)))

(ert-deftest expose-side-panel-test-place-one-buffer-splits ()
  "One buffer open: split, source buffer keeps its (now left) window."

  (expose-side-panel-test-with-clean-frame
    (let* ((left (get-buffer-create "espt-left.py"))
           (target (get-buffer-create "espt-target"))
           (source (expose-side-panel-test-reset left)))
      (expose-side-panel-place source target)
      (should (= 2 (length (window-list))))
      (should (equal "espt-left.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal "espt-target"
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-side-panel-test-place-source-on-left ()
  "Two buffers, source already on the left: right pane becomes the result."

  (expose-side-panel-test-with-clean-frame
    (let* ((left (get-buffer-create "espt-left2.py"))
           (right (get-buffer-create "espt-right2.py"))
           (target (get-buffer-create "espt-target2"))
           (source (expose-side-panel-test-reset left)))
      (set-window-buffer (split-window-right) right)
      (expose-side-panel-place source target)
      (should (equal "espt-left2.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal "espt-target2"
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-side-panel-test-place-source-on-right-moves-left ()
  "Two buffers, source on the right: it moves left, its old window
becomes the result pane."

  (expose-side-panel-test-with-clean-frame
    (let* ((left (get-buffer-create "espt-left3.py"))
           (right (get-buffer-create "espt-right3.py"))
           (target (get-buffer-create "espt-target3"))
           (source (expose-side-panel-test-reset left))
           (right-window (split-window-right)))
      (set-window-buffer right-window right)
      (expose-side-panel-place right-window target)
      (should (equal "espt-right3.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal "espt-target3"
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-side-panel-test-place-repeat-is-idempotent ()
  (expose-side-panel-test-with-clean-frame
    (let* ((left (get-buffer-create "espt-left4.py"))
           (target (get-buffer-create "espt-target4"))
           (source (expose-side-panel-test-reset left)))
      (expose-side-panel-place source target)
      (let ((before (window-list)))
        (expose-side-panel-place source target)
        (should (equal before (window-list)))))))

(ert-deftest expose-side-panel-test-place-recreates-after-window-closed ()
  (expose-side-panel-test-with-clean-frame
    (let* ((left (get-buffer-create "espt-left5.py"))
           (target (get-buffer-create "espt-target5"))
           (source (expose-side-panel-test-reset left)))
      (expose-side-panel-place source target)
      (delete-window (window-in-direction 'right (frame-first-window)))
      (should (= 1 (length (window-list))))
      (expose-side-panel-place source target)
      (should (= 2 (length (window-list))))
      (should (equal "espt-target5"
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-side-panel-test-place-dead-source-window-falls-back ()
  (expose-side-panel-test-with-clean-frame
    (let ((left (get-buffer-create "espt-left6.py"))
          (target (get-buffer-create "espt-target6")))
      (expose-side-panel-test-reset left)
      (let ((stale-window (split-window)))
        (delete-window stale-window)
        (should-not (window-live-p stale-window))
        (expose-side-panel-place stale-window target)
        (should (member "espt-target6"
                        (mapcar (lambda (w) (buffer-name (window-buffer w))) (window-list))))))))

(ert-deftest expose-side-panel-test-place-different-target-buffers-both-work ()
  "Two independent callers targeting different buffers -- Full Review's
dashboard and the action buffer, say -- each just replace whatever is
in the right pane, without needing to know about each other."

  (expose-side-panel-test-with-clean-frame
    (let* ((left (get-buffer-create "espt-left7.py"))
           (target-a (get-buffer-create "espt-target-a"))
           (target-b (get-buffer-create "espt-target-b"))
           (source (expose-side-panel-test-reset left)))
      (expose-side-panel-place source target-a)
      (should (equal "espt-target-a"
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
      (expose-side-panel-place source target-b)
      (should (equal "espt-target-b"
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(provide 'expose-side-panel-test)

;;; expose-side-panel-test.el ends here
