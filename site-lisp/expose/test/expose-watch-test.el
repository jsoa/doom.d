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
;;; Inline comment card: pure text/logic helpers
;;;
;;; The card's actual rendering (overlays, the shared Expose popup) needs a
;;; real display and is verified via ad hoc scripts instead, matching this
;;; project's established pattern -- but the helpers below are pure string
;;; and face-resolution logic with no display dependency, so they're
;;; covered here like any other pure-logic module.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-watch-test-card-fit-width-uses-longest-text ()
  (should
   (= 10
      (expose-watch-card-fit-width "short" "0123456789"))))

(ert-deftest expose-watch-test-card-fit-width-caps-at-card-width ()
  (let ((expose-watch-card-width 8))
    (should
     (= 8
        (expose-watch-card-fit-width "this text is much longer than the cap")))))

(ert-deftest expose-watch-test-card-pad-pads-short-text-to-width ()
  (should
   (= 10
      (length
       (expose-watch-card-pad "abc" 10)))))

(ert-deftest expose-watch-test-card-pad-truncates-long-text-to-width ()
  (should
   (= 10
      (length
       (expose-watch-card-pad "this text is much longer than ten columns" 10)))))

(ert-deftest expose-watch-test-card-collapsed-text-includes-chevron-severity-and-title ()
  (let ((text
         (expose-watch-card-collapsed-text
          (list :severity "high" :title "Stray early return"))))

    (should
     (string-prefix-p "▸ " text))
    (should
     (string-match-p "\\[HIGH\\]" text))
    (should
     (string-match-p "Stray early return" text))))

(ert-deftest expose-watch-test-card-collapsed-text-defaults-when-fields-missing ()
  (let ((text
         (expose-watch-card-collapsed-text (list))))

    (should
     (string-match-p "\\[INFO\\]" text))
    (should
     (string-match-p "Watch comment" text))))

(ert-deftest expose-watch-test-card-hint-text-reads-expose-shortcut ()
  (let ((text
         (expose-watch-card-hint-text)))

    (should
     (string= "EXPOSE C-<tab>" text))
    (should
     (eq
      (get-text-property 0 'face text)
      'mode-line-buffer-id))
    (should
     (eq
      (get-text-property (1- (length text)) 'face text)
      'font-lock-keyword-face))))

(ert-deftest expose-watch-test-card-content-row-frames-text-with-given-borders ()
  (let ((row
         (expose-watch-card-content-row "middle" "<" ">")))

    (should
     (string= "<middle>" row))
    (should
     (eq
      (get-text-property 0 'face row)
      'expose-watch-card-border-face))
    (should
     (eq
      (get-text-property (1- (length row)) 'face row)
      'expose-watch-card-border-face))))

(ert-deftest expose-watch-test-resolve-face-background-falls-back-to-plain-face ()
  ;; No `face-remapping-alist' entry for the face: should just be the
  ;; face's own (theme) background, the same as plain `face-attribute'.
  (with-temp-buffer
    (should
     (equal
      (expose-watch-card-resolve-face-background 'default)
      (face-attribute 'default :background nil t)))))

(ert-deftest expose-watch-test-resolve-face-background-honors-face-remapping ()
  ;; Regression guard: `face-attribute' alone does not see a buffer-local
  ;; `face-remapping-alist' entry (the mechanism `solaire-mode' and similar
  ;; packages use to dim "unreal" buffers) -- an earlier version of
  ;; `expose-watch-card-sync-faces' used plain `face-attribute' and so
  ;; silently missed exactly this case, defeating the point of reading the
  ;; real Expose popup's actual rendered color instead of guessing.
  (with-temp-buffer
    (face-remap-add-relative 'default :background "#123456")

    (should
     (string= "#123456"
              (expose-watch-card-resolve-face-background 'default)))))

(ert-deftest expose-watch-test-resolve-face-background-honors-face-symbol-remapping ()
  ;; `face-remap-add-relative' also accepts a face SYMBOL (not just a spec
  ;; plist) as the remapping target -- the way `solaire-mode' itself
  ;; actually remaps `default' (e.g. to `solaire-default-face').
  (with-temp-buffer
    (face-remap-add-relative 'default 'font-lock-warning-face)

    (should
     (string= (face-attribute 'font-lock-warning-face :background nil t)
              (expose-watch-card-resolve-face-background 'default)))))

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
