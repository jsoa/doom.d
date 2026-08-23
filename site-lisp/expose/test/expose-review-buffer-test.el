;;; expose-review-buffer-test.el --- Tests for expose-review-buffer -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-review-buffer)

;;; ---------------------------------------------------------------------------
;;; expose-review-buffer-open: placement only. The dashboard's own
;;; rendering (`expose-review-buffer-render') is stubbed out -- it reads
;;; real git/diagnostics/project state this suite has no fixture for,
;;; and is not what changed here. Real window operations otherwise, the
;;; same as `expose-side-panel-test.el': placement is the thing this is
;;; actually about.
;;; ---------------------------------------------------------------------------

(defun expose-review-buffer-test-session ()
  (list :project-name "widgets" :branch "main" :state 'ready))

(defmacro expose-review-buffer-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(cl-letf (((symbol-function 'expose-review-buffer-render) (lambda (&rest _) nil))
             ((symbol-function 'expose-review-buffer-normalize-collapsed-sections) (lambda () nil)))
     (unwind-protect
         (progn ,@body)
       (delete-other-windows)
       (let ((buffer (get-buffer (expose-review-buffer-name (expose-review-buffer-test-session)))))
         (when buffer (kill-buffer buffer))))))

(ert-deftest expose-review-buffer-test-open-places-beside-source-not-full-screen ()
  "The whole point of this change: opening a review must not replace
the buffer it was invoked from -- it goes in the window to the right,
splitting if needed, the same as an action-buffer result."

  (expose-review-buffer-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "erbt-src.py"))
    (let ((session (expose-review-buffer-test-session)))
      (expose-review-buffer-open session)
      (should (equal "erbt-src.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal (expose-review-buffer-name session)
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(ert-deftest expose-review-buffer-test-open-selects-the-dashboard ()
  "Unlike the action buffer (a glance beside what you're doing), opening
a review dashboard is going there to read it -- focus should follow."

  (expose-review-buffer-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "erbt-src2.py"))
    (let ((session (expose-review-buffer-test-session)))
      (expose-review-buffer-open session)
      (should (equal (expose-review-buffer-name session) (buffer-name (current-buffer)))))))

(ert-deftest expose-review-buffer-test-open-with-two-buffers-source-on-left ()
  (expose-review-buffer-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "erbt-src3.py"))
    (set-window-buffer (split-window-right) (get-buffer-create "erbt-other.py"))
    (let ((session (expose-review-buffer-test-session)))
      (expose-review-buffer-open session)
      (should (equal "erbt-src3.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal (expose-review-buffer-name session)
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window)))))))))

(provide 'expose-review-buffer-test)

;;; expose-review-buffer-test.el ends here
