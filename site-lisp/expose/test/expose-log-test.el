;;; expose-log-test.el --- Tests for expose-log -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-log)

;;; ---------------------------------------------------------------------------
;;; expose-log-open: placement only -- see expose-side-panel-test.el
;;; for the underlying algorithm's own coverage.
;;; ---------------------------------------------------------------------------

(defmacro expose-log-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-log-buffer-name)
       (kill-buffer expose-log-buffer-name))))

(ert-deftest expose-log-test-open-places-beside-source ()
  (expose-log-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "elt-src.py"))
    (expose-log-open)
    (should (equal "elt-src.py" (buffer-name (window-buffer (frame-first-window)))))
    (should (equal expose-log-buffer-name
                   (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))))

(ert-deftest expose-log-test-open-selects-the-log-buffer ()
  (expose-log-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "elt-src2.py"))
    (expose-log-open)
    (should (equal expose-log-buffer-name (buffer-name (current-buffer))))))

(provide 'expose-log-test)

;;; expose-log-test.el ends here
