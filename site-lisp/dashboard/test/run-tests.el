;;; run-tests.el --- ERT runner for the dashboard package -*- lexical-binding: t; -*-

;; Usage: emacs -Q --batch -l test/run-tests.el
;; Run from the `dashboard' package root, or point --batch at this file's
;; absolute path from anywhere.

(require 'ert)
(require 'cl-lib)

(let* ((test-dir
        (file-name-directory
         (or load-file-name buffer-file-name)))

       (dashboard-dir
        (expand-file-name ".." test-dir))

       (stubs-dir
        (expand-file-name "stubs" test-dir)))

  (add-to-list 'load-path stubs-dir)
  (add-to-list 'load-path dashboard-dir)

  ;; See stubs/doom-macros.el: dashboard.el calls Doom's `map!'/`cmd!' at
  ;; top level, so these must exist *before* it loads.
  (load (expand-file-name "doom-macros.el" stubs-dir))

  (require 'dashboard)

  (dolist (file
           (directory-files test-dir t "-test\\.el\\'"))
    (load file nil t)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
