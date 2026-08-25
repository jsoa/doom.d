;;; expose-signals-test.el --- Tests for expose-signals -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-signals)

;;; ---------------------------------------------------------------------------
;;; Test fixtures: real files, real grep -- the whole point of this
;;; module is real project text, so these tests use real temp files
;;; rather than mocking the search itself.
;;; ---------------------------------------------------------------------------

(defmacro expose-signals-test-with-files (bindings &rest body)
  "Create temp files named by BINDINGS ((VAR CONTENT) ...), run BODY, clean up."

  (declare (indent 1))

  (let ((files (mapcar #'car bindings)))
    `(let* ,(mapcar
             (lambda (binding)
               `(,(car binding)
                 (make-temp-file "expose-signals-test" nil ".py" ,(cadr binding))))
             bindings)
       (unwind-protect
           (progn ,@body)
         ,@(mapcar (lambda (file) `(delete-file ,file)) files)))))

;;; ---------------------------------------------------------------------------
;;; expose-signals-decorator-line-at
;;; ---------------------------------------------------------------------------

(ert-deftest expose-signals-test-decorator-line-at-single-line-decorator ()
  (expose-signals-test-with-files
      ((file "@receiver(post_save, sender=Event)\ndef handle(sender, instance, **kwargs):\n    pass\n"))
    (should (= 1 (expose-signals-decorator-line-at file 1)))))

(ert-deftest expose-signals-test-decorator-line-at-wrapped-decorator ()
  "The `sender=' keyword routinely lands on its own line -- the
decorator search has to look back further than one line to find the
`@receiver(' that owns it."

  (expose-signals-test-with-files
      ((file "@receiver(\n    post_save,\n    sender=Event,\n)\ndef handle(sender, instance, **kwargs):\n    pass\n"))
    (should (= 1 (expose-signals-decorator-line-at file 3)))))

(ert-deftest expose-signals-test-decorator-line-at-nil-when-not-a-receiver ()
  "A `sender=Event' that has nothing to do with `@receiver' at all --
some unrelated function call -- must not be misread as one."

  (expose-signals-test-with-files
      ((file "def build_email(sender=Event):\n    pass\n"))
    (should-not (expose-signals-decorator-line-at file 1))))

(ert-deftest expose-signals-test-decorator-line-at-nil-beyond-lookback ()
  (let ((expose-signals-lookback-lines 2))
    (expose-signals-test-with-files
        ((file "@receiver(\n\n\n\n    sender=Event,\n)\ndef handle(**kw):\n    pass\n"))
      (should-not (expose-signals-decorator-line-at file 5)))))

;;; ---------------------------------------------------------------------------
;;; expose-signals-receiver-body
;;; ---------------------------------------------------------------------------

(ert-deftest expose-signals-test-receiver-body-single-decorator ()
  (expose-signals-test-with-files
      ((file (concat
              "@receiver(post_save, sender=Event)\n"
              "def handle(sender, instance, **kwargs):\n"
              "    do_thing(instance)\n"
              "\n"
              "def unrelated():\n"
              "    pass\n")))
    (should
     (equal
      "@receiver(post_save, sender=Event)\ndef handle(sender, instance, **kwargs):\n    do_thing(instance)"
      (expose-signals-receiver-body file 1)))))

(ert-deftest expose-signals-test-receiver-body-stacked-decorators ()
  (expose-signals-test-with-files
      ((file (concat
              "@receiver(post_save, sender=Event)\n"
              "@transaction.atomic\n"
              "def handle(sender, instance, **kwargs):\n"
              "    do_thing(instance)\n"
              "\n"
              "class Next:\n"
              "    pass\n")))
    (let ((body (expose-signals-receiver-body file 1)))
      (should (string-match-p "@transaction.atomic" body))
      (should (string-match-p "do_thing(instance)" body))
      (should-not (string-match-p "class Next" body)))))

(ert-deftest expose-signals-test-receiver-body-async-def ()
  (expose-signals-test-with-files
      ((file (concat
              "@receiver(post_save, sender=Event)\n"
              "async def handle(sender, instance, **kwargs):\n"
              "    await do_thing(instance)\n")))
    (should
     (string-match-p "await do_thing" (expose-signals-receiver-body file 1)))))

(ert-deftest expose-signals-test-receiver-body-stops-at-end-of-file ()
  (expose-signals-test-with-files
      ((file "@receiver(post_save, sender=Event)\ndef handle(**kw):\n    pass\n"))
    (should
     (string-match-p "\\`@receiver" (expose-signals-receiver-body file 1)))))

(ert-deftest expose-signals-test-receiver-body-nil-for-unreadable-file ()
  (should-not (expose-signals-receiver-body "/no/such/file.py" 1)))

(ert-deftest expose-signals-test-receiver-body-truncates-long-bodies ()
  (let ((expose-signals-max-receiver-length 20))
    (expose-signals-test-with-files
        ((file (concat "@receiver(post_save, sender=Event)\n"
                        "def handle(**kw):\n"
                        "    " (make-string 200 ?x) "\n")))
      (should
       (string-match-p "\\[EXPOSE: truncated\\]" (expose-signals-receiver-body file 1))))))

;;; ---------------------------------------------------------------------------
;;; expose-signals-grep-sender-matches
;;; ---------------------------------------------------------------------------

(ert-deftest expose-signals-test-grep-sender-matches-finds-real-matches ()
  (let* ((dir (make-temp-file "expose-signals-test" t))
         (file (expand-file-name "signals.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "@receiver(post_save, sender=Event)\ndef handle(**kw):\n    pass\n")
            (write-file file))
          (let ((matches (expose-signals-grep-sender-matches "Event" dir)))
            (should (= 1 (length matches)))
            (should (equal file (car (car matches))))
            (should (= 1 (cdr (car matches))))))
      (delete-directory dir t))))

(ert-deftest expose-signals-test-grep-sender-matches-empty-when-none-found ()
  (let* ((dir (make-temp-file "expose-signals-test" t))
         (file (expand-file-name "signals.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "def unrelated():\n    pass\n")
            (write-file file))
          (should-not (expose-signals-grep-sender-matches "Event" dir)))
      (delete-directory dir t))))

;;; ---------------------------------------------------------------------------
;;; expose-signals-find-receivers: end to end against a real directory
;;; ---------------------------------------------------------------------------

(ert-deftest expose-signals-test-find-receivers-end-to-end ()
  (let* ((dir (make-temp-file "expose-signals-test" t))
         (file (expand-file-name "signals.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert
             "@receiver(post_save, sender=Event)\n"
             "def on_save(sender, instance, **kwargs):\n"
             "    notify(instance)\n")
            (write-file file))

          (cl-letf (((symbol-function 'expose-signals-project-root) (lambda () dir)))
            (let ((receivers (expose-signals-find-receivers "Event")))
              (should (= 1 (length receivers)))
              (should (equal file (plist-get (car receivers) :file)))
              (should (= 1 (plist-get (car receivers) :line)))
              (should (string-match-p "notify(instance)" (plist-get (car receivers) :code))))))
      (delete-directory dir t))))

(ert-deftest expose-signals-test-find-receivers-nil-without-a-project ()
  (cl-letf (((symbol-function 'expose-signals-project-root) (lambda () nil)))
    (should-not (expose-signals-find-receivers "Event"))))

(ert-deftest expose-signals-test-find-receivers-dedups-and-caps ()
  "Two `sender=' matches inside the same wrapped decorator (unusual, but
possible) must not produce the same receiver twice; the total is
capped to `expose-signals-max-receivers'."

  (let* ((dir (make-temp-file "expose-signals-test" t))
         (file (expand-file-name "signals.py" dir))
         (expose-signals-max-receivers 1))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert
             "@receiver(post_save, sender=Event)\n"
             "def on_save(sender, instance, **kwargs):\n"
             "    notify(instance)\n\n"
             "@receiver(post_delete, sender=Event)\n"
             "def on_delete(sender, instance, **kwargs):\n"
             "    cleanup(instance)\n")
            (write-file file))

          (cl-letf (((symbol-function 'expose-signals-project-root) (lambda () dir)))
            (let ((receivers (expose-signals-find-receivers "Event")))
              (should (= 1 (length receivers))))))
      (delete-directory dir t))))

(provide 'expose-signals-test)

;;; expose-signals-test.el ends here
