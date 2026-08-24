;;; expose-orm-test.el --- Tests for expose-orm -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-orm)

;;; ---------------------------------------------------------------------------
;;; expose-orm-display / expose-orm-display-plan: placement only -- see
;;; expose-side-panel-test.el for the underlying algorithm's own
;;; coverage. The subprocess machinery in expose-orm-run is not
;;; exercised here (no real project/Python fixture); these call the
;;; two display functions directly, which is where SOURCE-WINDOW
;;; actually gets used.
;;; ---------------------------------------------------------------------------

(defmacro expose-orm-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-orm-buffer)
       (kill-buffer expose-orm-buffer))))

(ert-deftest expose-orm-test-display-places-beside-source ()
  (expose-orm-test-with-clean-frame
    (delete-other-windows)
    (let ((source (progn (switch-to-buffer (get-buffer-create "eot-src.py")) (selected-window))))
      (expose-orm-display
       '((model . "Widget") (table . "widgets") (sql . "SELECT 1"))
       "Widget.objects.all()"
       source)
      (should (equal "eot-src.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-orm-buffer
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
      (should (equal expose-orm-buffer (buffer-name (current-buffer)))))))

(ert-deftest expose-orm-test-display-plan-no-plan-falls-back-beside-source ()
  "Both no-plan branches (an explicit plan_error, and simply no plan)
delegate to expose-orm-display -- confirming SOURCE-WINDOW reaches it
through that indirection, not just when called directly."

  (expose-orm-test-with-clean-frame
    (delete-other-windows)
    (let ((source (progn (switch-to-buffer (get-buffer-create "eot-src2.py")) (selected-window))))
      (expose-orm-display-plan
       '((error . "no database configured"))
       "Widget.objects.all()"
       source)
      (should (equal expose-orm-buffer
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
      (should (equal "eot-src2.py" (buffer-name (window-buffer (frame-first-window))))))))

(provide 'expose-orm-test)

;;; expose-orm-test.el ends here
