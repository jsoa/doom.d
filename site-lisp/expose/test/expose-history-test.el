;;; expose-history-test.el --- Tests for expose-history -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-history)

;;; ---------------------------------------------------------------------------
;;; expose-history-open: placement only. Real window operations, not
;;; mocked -- see expose-side-panel-test.el for the underlying
;;; algorithm's own coverage; this is about the wiring using it
;;; correctly, not re-proving it.
;;; ---------------------------------------------------------------------------

(defmacro expose-history-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-history-buffer-name)
       (kill-buffer expose-history-buffer-name))))

(ert-deftest expose-history-test-open-places-beside-source ()
  (expose-history-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "eht-src.py"))
    (expose-history-open)
    (should (equal "eht-src.py" (buffer-name (window-buffer (frame-first-window)))))
    (should (equal expose-history-buffer-name
                   (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))))

(ert-deftest expose-history-test-open-selects-the-history-buffer ()
  (expose-history-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "eht-src2.py"))
    (expose-history-open)
    (should (equal expose-history-buffer-name (buffer-name (current-buffer))))))

(provide 'expose-history-test)

;;; expose-history-test.el ends here
