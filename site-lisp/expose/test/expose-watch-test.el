;;; expose-watch-test.el --- Tests for expose-watch auto-arm -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-watch)

;;; ---------------------------------------------------------------------------
;;; Fixture
;;;
;;; Project-root/session-persistence functions shell out to git and read/
;;; write real files under `.git/expose/watch/', so these tests run against
;;; a real, disposable, git-initialized temp directory rather than mocking
;;; that layer away -- cheap to do (a bare `git init' is instant) and it
;;; exercises the actual storage path these functions rely on.
;;; ---------------------------------------------------------------------------

(defmacro expose-watch-test-with-project (&rest body)
  "Run BODY in a temp buffer visiting a file in a fresh temp git project.

Binds PROJECT-ROOT to the project's root directory for BODY's use."
  (declare (indent 0))
  `(let* ((project-root
           (file-name-as-directory
            (make-temp-file "expose-watch-test-" t))))

     (unwind-protect
         (let ((default-directory project-root))
           (call-process "git" nil nil nil "init" "-q")

           (with-temp-buffer
             (setq default-directory project-root)
             (setq buffer-file-name
                   (expand-file-name "example.py" project-root))
             ,@body))

       (delete-directory project-root t))))

;;; ---------------------------------------------------------------------------
;;; Project auto-arm flag persistence
;;; ---------------------------------------------------------------------------

(ert-deftest expose-watch-test-auto-enabled-defaults-to-nil ()
  (expose-watch-test-with-project
    (should-not
     (expose-watch-project-auto-enabled-p project-root))))

(ert-deftest expose-watch-test-auto-enabled-round-trips ()
  (expose-watch-test-with-project
    (expose-watch-set-project-auto-enabled project-root t)
    (should
     (expose-watch-project-auto-enabled-p project-root))

    (expose-watch-set-project-auto-enabled project-root nil)
    (should-not
     (expose-watch-project-auto-enabled-p project-root))))

(ert-deftest expose-watch-test-auto-enabled-does-not-clobber-file-state ()
  ;; Setting the project-level flag persists through the same session
  ;; plist as per-file watch state; a regression here would silently drop
  ;; every already-watched file's state whenever auto-arm is toggled.
  (expose-watch-test-with-project
    (expose-watch-enable-file-state project-root "example.py")
    (expose-watch-set-project-auto-enabled project-root t)

    (should
     (expose-watch-file-enabled-p project-root "example.py"))
    (should
     (expose-watch-project-auto-enabled-p project-root))))

;;; ---------------------------------------------------------------------------
;;; expose-watch-arm-auto-watch
;;; ---------------------------------------------------------------------------

(ert-deftest expose-watch-test-arm-auto-watch-noop-when-project-disabled ()
  (expose-watch-test-with-project
    (expose-watch-arm-auto-watch)

    (should-not
     (memq #'expose-watch-auto-enable-on-first-change first-change-hook))))

(ert-deftest expose-watch-test-arm-auto-watch-arms-when-project-enabled ()
  (expose-watch-test-with-project
    (expose-watch-set-project-auto-enabled project-root t)
    (expose-watch-arm-auto-watch)

    (should
     (memq #'expose-watch-auto-enable-on-first-change first-change-hook))))

(ert-deftest expose-watch-test-arm-auto-watch-skips-excluded-path ()
  (expose-watch-test-with-project
    (expose-watch-set-project-auto-enabled project-root t)
    (setq buffer-file-name
          (expand-file-name ".env" project-root))

    (expose-watch-arm-auto-watch)

    (should-not
     (memq #'expose-watch-auto-enable-on-first-change first-change-hook))))

(ert-deftest expose-watch-test-arm-auto-watch-skips-already-watched-buffer ()
  (expose-watch-test-with-project
    (expose-watch-set-project-auto-enabled project-root t)

    ;; Simulate Watch already being on for this buffer without going
    ;; through the full minor-mode body (which touches popup/overlay UI
    ;; that isn't the concern of this test).
    (setq-local expose-watch-mode t)

    (expose-watch-arm-auto-watch)

    (should-not
     (memq #'expose-watch-auto-enable-on-first-change first-change-hook))))

;;; ---------------------------------------------------------------------------
;;; expose-watch-auto-enable-on-first-change
;;; ---------------------------------------------------------------------------

(ert-deftest expose-watch-test-auto-enable-on-first-change-is-noop-when-already-on ()
  ;; Guards the documented behavior that this fires again after every save
  ;; (first-change-hook re-arms once the modified flag is cleared): it must
  ;; not try to re-run `expose-watch-mode's full enable body every time.
  (expose-watch-test-with-project
    (setq-local expose-watch-mode t)

    (let ((call-count 0))
      (cl-letf (((symbol-function 'expose-watch-mode)
                 (lambda (&rest _) (cl-incf call-count))))

        (expose-watch-auto-enable-on-first-change)

        (should
         (= call-count 0))))))

(provide 'expose-watch-test)

;;; expose-watch-test.el ends here
