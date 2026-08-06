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
           ;; Local, not global: committing below (for the active-entries
           ;; tests) needs an identity, and this must not depend on -- or
           ;; leak into -- whatever git config happens to be set up on the
           ;; machine running the tests.
           (call-process "git" nil nil nil "config" "user.email" "test@example.com")
           (call-process "git" nil nil nil "config" "user.name" "Expose Test")

           (with-temp-buffer
             (setq default-directory project-root)
             (setq buffer-file-name
                   (expand-file-name "example.py" project-root))
             ,@body))

       (delete-directory project-root t))))

(defun expose-watch-test-seed-live-diff (project-root file initial-content changed-content)
  "Commit INITIAL-CONTENT to FILE, then rewrite it (uncommitted) to
CHANGED-CONTENT -- leaves a real, computable live diff hunk for FILE that
`expose-watch-current-file-hunks' will find."

  (let ((default-directory project-root)
        (path (expand-file-name file project-root)))

    (with-temp-file path (insert initial-content))
    (call-process "git" nil nil nil "add" file)
    (call-process "git" nil nil nil "commit" "-q" "-m" "init")
    (with-temp-file path (insert changed-content))))

(defun expose-watch-test-live-hunk-hash (project-root file)
  "Return the hash of FILE's current live diff hunk in PROJECT-ROOT."

  (plist-get
   (car (expose-watch-current-file-hunks project-root file))
   :hash))

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

;;; ---------------------------------------------------------------------------
;;; expose-watch-project-active-entries
;;; ---------------------------------------------------------------------------

(ert-deftest expose-watch-test-active-entries-empty-with-no-watched-files ()
  (expose-watch-test-with-project
    (should
     (null
      (expose-watch-project-active-entries project-root)))))

(ert-deftest expose-watch-test-active-entries-excludes-stale-hunks ()
  (expose-watch-test-with-project
    (expose-watch-test-seed-live-diff
     project-root "example.py" "line1\nline2\nline3\n" "line1\nCHANGED\nline3\n")

    (let ((live-hash
           (expose-watch-test-live-hunk-hash project-root "example.py")))

      (expose-watch-enable-file-state project-root "example.py")

      (let* ((session
              (expose-watch-load-session project-root))

             (state
              (expose-watch-file-state session "example.py")))

        (setq state
              (plist-put
               state :reviewed-hunks
               (list
                (list :hash live-hash :line-start 2 :line-end 2
                      :items (list (list :title "Active finding" :line-start 2 :line-end 2)))
                (list :hash "stale-hash-does-not-exist" :line-start 10 :line-end 10
                      :items (list (list :title "Stale finding" :line-start 10 :line-end 10))))))

        (expose-watch-save-session
         (expose-watch-put-file-state session state)))

      (let ((entries
             (expose-watch-project-active-entries project-root)))

        (should
         (= (length entries) 1))
        (should
         (equal
          (plist-get (plist-get (car entries) :item) :title)
          "Active finding"))))))

(ert-deftest expose-watch-test-active-entries-excludes-disabled-files ()
  (expose-watch-test-with-project
    (expose-watch-test-seed-live-diff
     project-root "example.py" "line1\nline2\nline3\n" "line1\nCHANGED\nline3\n")

    (let ((live-hash
           (expose-watch-test-live-hunk-hash project-root "example.py")))

      (expose-watch-enable-file-state project-root "example.py")

      (let* ((session
              (expose-watch-load-session project-root))

             (state
              (expose-watch-file-state session "example.py")))

        (setq state
              (plist-put
               state :reviewed-hunks
               (list
                (list :hash live-hash :line-start 2 :line-end 2
                      :items (list (list :title "Active finding" :line-start 2 :line-end 2))))))

        (expose-watch-save-session
         (expose-watch-put-file-state session state)))

      ;; Explicitly unwatch the file; its still-live hunk must not show up.
      (expose-watch-disable-file-state project-root "example.py")

      (should
       (null
        (expose-watch-project-active-entries project-root))))))

;;; ---------------------------------------------------------------------------
;;; expose-watch-catch-up-item-cap
;;; ---------------------------------------------------------------------------

(ert-deftest expose-watch-test-catch-up-item-cap-scales-with-hunk-count ()
  (let ((expose-watch-max-items-per-run 3)
        (expose-watch-max-hunks-per-run 4))

    ;; 6 hunks: 3 * 6/4 = 4.5, rounded up to 5.
    (should
     (= 5 (expose-watch-catch-up-item-cap 6)))))

(ert-deftest expose-watch-test-catch-up-item-cap-floors-at-normal-default ()
  ;; A small backlog (fewer hunks than a normal run's own cap) should not
  ;; get a *worse* findings budget than a normal steady-state run would.
  (let ((expose-watch-max-items-per-run 3)
        (expose-watch-max-hunks-per-run 4))

    (should
     (= 3 (expose-watch-catch-up-item-cap 1)))))

(ert-deftest expose-watch-test-catch-up-item-cap-matches-normal-at-the-cap ()
  (let ((expose-watch-max-items-per-run 3)
        (expose-watch-max-hunks-per-run 4))

    (should
     (= 3 (expose-watch-catch-up-item-cap 4)))))

(provide 'expose-watch-test)

;;; expose-watch-test.el ends here
