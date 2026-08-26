;;; expose-relations-test.el --- Tests for expose-relations -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-relations)

;; Not shared with `expose-signals-test.el''s identical helper: test
;; files in this suite load independently and alphabetically, so a
;; macro defined there is not guaranteed to exist yet by the time this
;; file's own top-level forms run.
(defmacro expose-relations-test-with-files (bindings &rest body)
  "Create temp files named by BINDINGS ((VAR CONTENT) ...), run BODY, clean up."

  (declare (indent 1))

  (let ((files (mapcar #'car bindings)))
    `(let* ,(mapcar
             (lambda (binding)
               `(,(car binding)
                 (make-temp-file "expose-relations-test" nil ".py" ,(cadr binding))))
             bindings)
       (unwind-protect
           (progn ,@body)
         ,@(mapcar (lambda (file) `(delete-file ,file)) files)))))

;;; ---------------------------------------------------------------------------
;;; expose-relations-field-line-at
;;; ---------------------------------------------------------------------------

(ert-deftest expose-relations-test-field-line-at-bare-class-same-line ()
  (expose-relations-test-with-files
      ((file "class Comment(models.Model):\n    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n"))
    (should (expose-relations-field-line-at file 2))))

(ert-deftest expose-relations-test-field-line-at-quoted-same-app ()
  (expose-relations-test-with-files
      ((file "class Comment(models.Model):\n    event = models.ForeignKey(\"Event\", on_delete=models.CASCADE)\n"))
    (should (expose-relations-field-line-at file 2))))

(ert-deftest expose-relations-test-field-line-at-quoted-qualified ()
  (expose-relations-test-with-files
      ((file "class Comment(models.Model):\n    event = models.ForeignKey(\"events.Event\", on_delete=models.CASCADE)\n"))
    (should (expose-relations-field-line-at file 2))))

(ert-deftest expose-relations-test-field-line-at-wrapped-call ()
  "The call and its target routinely land on different lines when the
call itself wraps onto several."

  (expose-relations-test-with-files
      ((file (concat "class Comment(models.Model):\n"
                      "    event = models.ForeignKey(\n"
                      "        Event,\n"
                      "        on_delete=models.CASCADE,\n"
                      "    )\n")))
    (should (expose-relations-field-line-at file 3))))

(ert-deftest expose-relations-test-field-line-at-nil-when-not-a-relationship-field ()
  "The model's name appearing near a paren for some unrelated reason --
a plain function call, say -- must not be mistaken for one."

  (expose-relations-test-with-files
      ((file "def build_event(name=Event):\n    pass\n"))
    (should-not (expose-relations-field-line-at file 1))))

(ert-deftest expose-relations-test-field-line-at-nil-beyond-lookback ()
  (let ((expose-relations-lookback-lines 2))
    (expose-relations-test-with-files
        ((file "models.ForeignKey(\n\n\n\n    Event,\n)\n"))
      (should-not (expose-relations-field-line-at file 5)))))

;;; ---------------------------------------------------------------------------
;;; expose-relations-enclosing-class
;;; ---------------------------------------------------------------------------

(ert-deftest expose-relations-test-enclosing-class-finds-the-nearest-one ()
  (with-temp-buffer
    (insert "class First(models.Model):\n    pass\n\n"
            "class Second(models.Model):\n"
            "    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n")
    (goto-char (point-min))
    (forward-line 4)
    (let ((result (expose-relations-enclosing-class (point))))
      (should (equal "Second" (car result)))
      (should (= 4 (cdr result))))))

(ert-deftest expose-relations-test-enclosing-class-nil-with-no-class ()
  (with-temp-buffer
    (insert "def plain_function():\n    pass\n")
    (goto-char (point-max))
    (should-not (expose-relations-enclosing-class (point)))))

;;; ---------------------------------------------------------------------------
;;; expose-relations-class-body
;;; ---------------------------------------------------------------------------

(ert-deftest expose-relations-test-class-body-bounded-by-next-top-level ()
  (expose-relations-test-with-files
      ((file (concat "class Comment(models.Model):\n"
                      "    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n"
                      "    text = models.TextField()\n"
                      "\n"
                      "class Unrelated(models.Model):\n"
                      "    pass\n")))
    (let ((body (expose-relations-class-body file 1)))
      (should (string-match-p "event = models.ForeignKey" body))
      (should (string-match-p "text = models.TextField" body))
      (should-not (string-match-p "Unrelated" body)))))

(ert-deftest expose-relations-test-class-body-stops-at-end-of-file ()
  (expose-relations-test-with-files
      ((file "class Comment(models.Model):\n    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n"))
    (should (string-match-p "\\`class Comment" (expose-relations-class-body file 1)))))

(ert-deftest expose-relations-test-class-body-nil-for-unreadable-file ()
  (should-not (expose-relations-class-body "/no/such/file.py" 1)))

(ert-deftest expose-relations-test-class-body-truncates-long-bodies ()
  (let ((expose-relations-max-model-length 20))
    (expose-relations-test-with-files
        ((file (concat "class Comment(models.Model):\n"
                        "    " (make-string 200 ?x) " = models.TextField()\n")))
      (should
       (string-match-p "\\[EXPOSE: truncated\\]" (expose-relations-class-body file 1))))))

;;; ---------------------------------------------------------------------------
;;; expose-relations-grep-matches
;;; ---------------------------------------------------------------------------

(ert-deftest expose-relations-test-grep-matches-finds-real-matches ()
  (let* ((dir (make-temp-file "expose-relations-test" t))
         (file (expand-file-name "comments.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class Comment(models.Model):\n    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n")
            (write-file file))
          (let ((matches (expose-relations-grep-matches "Event" dir)))
            (should (= 1 (length matches)))
            (should (equal file (car (car matches))))
            (should (= 2 (cdr (car matches))))))
      (delete-directory dir t))))

(ert-deftest expose-relations-test-grep-matches-empty-when-none-found ()
  (let* ((dir (make-temp-file "expose-relations-test" t))
         (file (expand-file-name "comments.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class Comment(models.Model):\n    text = models.TextField()\n")
            (write-file file))
          (should-not (expose-relations-grep-matches "Event" dir)))
      (delete-directory dir t))))

;;; ---------------------------------------------------------------------------
;;; expose-relations-find-referencing-models: end to end
;;; ---------------------------------------------------------------------------

(ert-deftest expose-relations-test-find-referencing-models-end-to-end ()
  (let* ((dir (make-temp-file "expose-relations-test" t))
         (file (expand-file-name "comments.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class Comment(models.Model):\n"
                    "    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n"
                    "    text = models.TextField()\n")
            (write-file file))

          (cl-letf (((symbol-function 'expose-relations-project-root) (lambda () dir)))
            (let ((models (expose-relations-find-referencing-models "Event")))
              (should (= 1 (length models)))
              (should (equal file (plist-get (car models) :file)))
              (should (= 1 (plist-get (car models) :line)))
              (should (string-match-p "class Comment" (plist-get (car models) :code)))
              (should (string-match-p "text = models.TextField" (plist-get (car models) :code))))))
      (delete-directory dir t))))

(ert-deftest expose-relations-test-find-referencing-models-excludes-self-reference ()
  "A model referencing itself (a `parent' field, say) must not be
reported as something else pointing at it."

  (let* ((dir (make-temp-file "expose-relations-test" t))
         (file (expand-file-name "events.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class Event(models.Model):\n"
                    "    parent = models.ForeignKey(\"Event\", null=True, on_delete=models.CASCADE)\n")
            (write-file file))

          (cl-letf (((symbol-function 'expose-relations-project-root) (lambda () dir)))
            (should-not (expose-relations-find-referencing-models "Event"))))
      (delete-directory dir t))))

(ert-deftest expose-relations-test-find-referencing-models-excludes-given-file ()
  "A model in the same file as the one being diagrammed is already part
of its ordinary :code context and must not be sent again."

  (let* ((dir (make-temp-file "expose-relations-test" t))
         (file (expand-file-name "models.py" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class Event(models.Model):\n"
                    "    pass\n\n"
                    "class Comment(models.Model):\n"
                    "    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n")
            (write-file file))

          (cl-letf (((symbol-function 'expose-relations-project-root) (lambda () dir)))
            (should-not (expose-relations-find-referencing-models "Event" file))
            ;; Without the exclusion, the very same model is found --
            ;; proving the exclusion is what did the work above, not
            ;; some other reason it came back empty.
            (should (expose-relations-find-referencing-models "Event"))))
      (delete-directory dir t))))

(ert-deftest expose-relations-test-find-referencing-models-nil-without-a-project ()
  (cl-letf (((symbol-function 'expose-relations-project-root) (lambda () nil)))
    (should-not (expose-relations-find-referencing-models "Event"))))

(ert-deftest expose-relations-test-find-referencing-models-dedups-and-caps ()
  "Two relationship fields on the same model, both pointing at the same
target, must produce one model, not two; the total is capped to
`expose-relations-max-models'."

  (let* ((dir (make-temp-file "expose-relations-test" t))
         (file (expand-file-name "comments.py" dir))
         (expose-relations-max-models 1))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert "class Comment(models.Model):\n"
                    "    event = models.ForeignKey(Event, on_delete=models.CASCADE)\n"
                    "    related_event = models.ForeignKey(Event, on_delete=models.SET_NULL, null=True)\n")
            (write-file file))

          (cl-letf (((symbol-function 'expose-relations-project-root) (lambda () dir)))
            (let ((models (expose-relations-find-referencing-models "Event")))
              (should (= 1 (length models))))))
      (delete-directory dir t))))

(provide 'expose-relations-test)

;;; expose-relations-test.el ends here
