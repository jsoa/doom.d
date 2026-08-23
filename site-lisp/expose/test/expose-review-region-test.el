;;; expose-review-region-test.el --- Tests for expose-review-region -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-popup)
(require 'expose-action-buffer)
(require 'expose-review-region)

;;; ---------------------------------------------------------------------------
;;; Region Review results (full session, and the "reviewing..." /
;;; error-message shapes that share its `expose-action-buffer-show'
;;; call) now show in the persistent action buffer, the same as a
;;; `SPC c h h' result -- not the small hover popup. Only the per-item
;;; hover (`expose-review-region-show-item-hover') is unaffected by this
;;; and still uses the popup directly; that function is not touched
;;; here.
;;; ---------------------------------------------------------------------------

(defun expose-review-region-test-session (&rest overrides)
  "A minimal valid session plist, with OVERRIDES plist-merged in."

  (append
   overrides
   (list
    :file "widgets.py"
    :region-line-start 10
    :region-line-end 12
    :state 'ready
    :items nil)))

(defmacro expose-review-region-test-with-clean-frame (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (delete-other-windows)
     (when (get-buffer expose-action-buffer-name)
       (kill-buffer expose-action-buffer-name))))

(ert-deftest expose-review-region-test-show-full-session-uses-action-buffer ()
  (expose-review-region-test-with-clean-frame
    (let ((source (progn (delete-other-windows)
                          (switch-to-buffer (get-buffer-create "errt-src.py"))
                          (selected-window))))
      (expose-review-region-show-full-session
       (expose-review-region-test-session)
       source)
      (should (equal "errt-src.py" (buffer-name (window-buffer (frame-first-window)))))
      (should (equal expose-action-buffer-name
                     (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))
      (with-current-buffer expose-action-buffer-name
        (should (string-match-p "Region Review" (buffer-string)))
        (should (string-match-p "No findings" (buffer-string)))))))

(ert-deftest expose-review-region-test-show-full-session-defaults-to-selected-window ()
  "SOURCE-WINDOW is optional -- the synchronous \"show full at point\"
command relies on the default being the window it was invoked from."

  (expose-review-region-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "errt-src2.py"))
    (expose-review-region-show-full-session (expose-review-region-test-session))
    (should (equal "errt-src2.py" (buffer-name (window-buffer (frame-first-window)))))
    (should (equal expose-action-buffer-name
                   (buffer-name (window-buffer (window-in-direction 'right (frame-first-window))))))))

(ert-deftest expose-review-region-test-show-full-session-records-to-history ()
  "A completed session (the default `:history t' in the view this
builds) is recorded; verified here rather than assumed, since this
function builds its own view plist and a typo in that key would
silently stop recording without any test noticing."

  (expose-review-region-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "errt-src3.py"))
    (let (recorded)
      (cl-letf (((symbol-function 'expose-history-add) (lambda (v) (setq recorded v))))
        (expose-review-region-show-full-session (expose-review-region-test-session))
        (should recorded)))))

(ert-deftest expose-review-region-test-show-error-uses-action-buffer ()
  (expose-review-region-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "errt-src4.py"))
    (expose-review-region-show-error "region review could not start")
    (with-current-buffer expose-action-buffer-name
      (should (string-match-p "region review could not start" (buffer-string))))))

(ert-deftest expose-review-region-test-show-error-does-not-record-to-history ()
  (expose-review-region-test-with-clean-frame
    (delete-other-windows)
    (switch-to-buffer (get-buffer-create "errt-src5.py"))
    (let (recorded)
      (cl-letf (((symbol-function 'expose-history-add) (lambda (v) (setq recorded v))))
        (expose-review-region-show-error "region review could not start")
        (should-not recorded)))))

;;; ---------------------------------------------------------------------------
;;; The per-item hover is a different code path (`expose-popup-show-view'
;;; directly) and must stay that way -- confirmed here structurally
;;; rather than only by inspection, so a future edit that accidentally
;;; routes it through the action buffer instead gets caught.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-review-region-test-item-hover-still-uses-popup-directly ()
  (let (popup-shown action-buffer-shown)
    (cl-letf (((symbol-function 'expose-popup-show-view) (lambda (&rest _) (setq popup-shown t)))
              ((symbol-function 'expose-action-buffer-show) (lambda (&rest _) (setq action-buffer-shown t)))
              ((symbol-function 'expose-hover-corfu-active-p) (lambda () nil))
              ((symbol-function 'expose-review-region-item-at-point) (lambda () '(:title "x")))
              ((symbol-function 'expose-review-region-session-at-point)
               (lambda () (expose-review-region-test-session))))
      (expose-review-region-show-item-hover)
      (should popup-shown)
      (should-not action-buffer-shown))))

(provide 'expose-review-region-test)

;;; expose-review-region-test.el ends here
