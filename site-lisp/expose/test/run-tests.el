;;; run-tests.el --- ERT runner for the expose library -*- lexical-binding: t; -*-

;; Usage: emacs -Q --batch -l test/run-tests.el
;; Run from the `expose' library root, or point --batch at this file's
;; absolute path from anywhere.

(require 'ert)

(let* ((test-dir
        (file-name-directory
         (or load-file-name buffer-file-name)))

       (expose-dir
        (expand-file-name ".." test-dir))

       (stubs-dir
        (expand-file-name "stubs" test-dir)))

  ;; Stubs first, so lightweight stand-ins win over any real package of the
  ;; same name that happens to be on `load-path' already.
  (add-to-list 'load-path stubs-dir)
  (add-to-list 'load-path expose-dir)

  (dolist (file
           (directory-files test-dir t "-test\\.el\\'"))
    (load file nil t)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
