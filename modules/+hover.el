;;; modules/+hover.el -*- lexical-binding: t; -*-

(load! "hover/jsoa-hover")

(setq jsoa-hover-delay 0.25
      jsoa-hover-max-height 20
      jsoa-hover-max-width 120)


(map! :leader
      (:prefix ("c h" . "hover")
       :desc "Scroll Down" "j" #'jsoa-hover-scroll-down
       :desc "Scroll Up"   "k" #'jsoa-hover-scroll-up
       :desc "Close Hover" "q" #'jsoa-hover-close
       :desc "Review"      "r" #'jsoa-hover-test-review
       :desc "Copy Hover"  "y" #'jsoa-hover-copy
       :desc "Open Hover"  "o" #'jsoa-hover-open))


(defun jsoa-hover-test-review ()
  (interactive)
  (jsoa-hover-run-action ?r))


(defun my-review-async (callback)
  "Asynchronously review the current document."

  (jsoa-transport-send-async
   'review
   'codex

   (lambda (response)

     (funcall
      callback

      (jsoa-hover-view-create
       "Review"
       response)))))

(jsoa-hover-register-action
 ?r
 "Review"
 'view
 #'my-review-async
 :async t)

(jsoa-hover-mode 1)
