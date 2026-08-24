;;; expose-review-archive-test.el --- Tests for expose-review-archive -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-review-archive)

;;; ---------------------------------------------------------------------------
;;; expose-review-archive-open: placement only -- see
;;; expose-side-panel-test.el for the underlying algorithm's own
;;; coverage. Rendering is stubbed out; it reads real stored review
;;; state this suite has no fixture for, and is not what changed here.
;;; ---------------------------------------------------------------------------

(defmacro expose-review-archive-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(cl-letf (((symbol-function 'expose-review-archive-project-root) (lambda () "/tmp/"))
             ((symbol-function 'expose-review-archive-render) (lambda () nil)))
     (unwind-protect
         (progn ,@body)
       (delete-other-windows)
       (dolist (kind '(full region))
         (when (get-buffer (expose-review-archive-buffer-name kind))
           (kill-buffer (expose-review-archive-buffer-name kind)))))))

(ert-deftest expose-review-archive-test-open-full-places-beside-source ()
  (expose-review-archive-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "erat-src.py"))
    (expose-review-archive-open-full)
    (should (equal "erat-src.py" (buffer-name (window-buffer (frame-first-window)))))
    (should (equal (expose-review-archive-buffer-name 'full)
                   (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
    (should (equal (expose-review-archive-buffer-name 'full) (buffer-name (current-buffer))))))

(ert-deftest expose-review-archive-test-open-region-places-beside-source ()
  (expose-review-archive-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "erat-src2.py"))
    (expose-review-archive-open-region)
    (should (equal "erat-src2.py" (buffer-name (window-buffer (frame-first-window)))))
    (should (equal (expose-review-archive-buffer-name 'region)
                   (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))))

(provide 'expose-review-archive-test)

;;; expose-review-archive-test.el ends here
