;;; expose-review-request-test.el --- Tests for expose-review-request -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-review-request)

;;; ---------------------------------------------------------------------------
;;; expose-review-request-strip-json-fence
;;; ---------------------------------------------------------------------------

(ert-deftest expose-review-request-test-strip-json-fence-with-language-tag ()
  (should
   (equal
    (expose-review-request-strip-json-fence "```json\n{\"a\": 1}\n```")
    "{\"a\": 1}")))

(ert-deftest expose-review-request-test-strip-json-fence-without-language-tag ()
  (should
   (equal
    (expose-review-request-strip-json-fence "```\n{\"a\": 1}\n```")
    "{\"a\": 1}")))

(ert-deftest expose-review-request-test-strip-json-fence-no-fence-is-noop ()
  (should
   (equal
    (expose-review-request-strip-json-fence "{\"a\": 1}")
    "{\"a\": 1}")))

;;; ---------------------------------------------------------------------------
;;; expose-review-request-extract-balanced-json
;;; ---------------------------------------------------------------------------

(ert-deftest expose-review-request-test-extract-balanced-json-nested-object ()
  (let ((text "{\"a\": {\"b\": 1}, \"c\": [1, 2]} trailing garbage"))

    (should
     (equal
      (expose-review-request-extract-balanced-json text 0)
      "{\"a\": {\"b\": 1}, \"c\": [1, 2]}"))))

(ert-deftest expose-review-request-test-extract-balanced-json-ignores-braces-in-strings ()
  (let ((text "{\"comment\": \"use a { here\"} tail"))

    (should
     (equal
      (expose-review-request-extract-balanced-json text 0)
      "{\"comment\": \"use a { here\"}"))))

(ert-deftest expose-review-request-test-extract-balanced-json-handles-escaped-quotes ()
  (let ((text "{\"comment\": \"she said \\\"hi\\\"\"} tail"))

    (should
     (equal
      (expose-review-request-extract-balanced-json text 0)
      "{\"comment\": \"she said \\\"hi\\\"\"}"))))

;;; ---------------------------------------------------------------------------
;;; expose-review-request-parse-items: the happy path
;;; ---------------------------------------------------------------------------

(ert-deftest expose-review-request-test-parse-items-well-formed-response ()
  (let* ((response
          "{\"summary\": \"ok\", \"items\": [
             {\"id\": \"R1\", \"severity\": \"high\", \"category\": \"security\",
              \"file\": \"app.py\", \"line_start\": 10, \"line_end\": 12,
              \"title\": \"SQL injection\", \"comment\": \"Use parameters.\",
              \"anchor_text\": \"query = ...\",
              \"suggestion\": {\"kind\": \"text\", \"text\": \"Parameterize it.\"}}
           ]}")

         (items
          (expose-review-request-parse-items response))

         (item
          (car items)))

    (should
     (= (length items) 1))
    (should
     (equal (plist-get item :id) "R1"))
    (should
     (eq (plist-get item :severity) 'high))
    (should
     (eq (plist-get item :category) 'security))
    (should
     (equal (plist-get item :file) "app.py"))
    (should
     (= (plist-get item :line-start) 10))
    (should
     (= (plist-get item :line-end) 12))
    (should
     (eq (plist-get (plist-get item :suggestion) :kind) 'text))))

(ert-deftest expose-review-request-test-parse-items-strips-code-fence ()
  (let* ((response
          "```json\n{\"items\": [{\"file\": \"app.py\", \"comment\": \"x\"}]}\n```")

         (items
          (expose-review-request-parse-items response)))

    (should
     (= (length items) 1))
    (should
     (equal (plist-get (car items) :file) "app.py"))))

(ert-deftest expose-review-request-test-parse-items-tolerates-leading-commentary ()
  (let* ((response
          "Sure, here is the review:\n\n{\"items\": [{\"file\": \"app.py\", \"comment\": \"x\"}]}")

         (items
          (expose-review-request-parse-items response)))

    (should
     (= (length items) 1))))

(ert-deftest expose-review-request-test-parse-items-empty-items-is-not-an-error ()
  (should
   (null
    (expose-review-request-parse-items
     "{\"summary\": \"clean\", \"items\": []}"))))

(ert-deftest expose-review-request-test-parse-items-line-end-defaults-to-line-start ()
  (let* ((response
          "{\"items\": [{\"file\": \"app.py\", \"comment\": \"x\", \"line_start\": 7}]}")

         (item
          (car
           (expose-review-request-parse-items response))))

    (should
     (= (plist-get item :line-start) 7))
    (should
     (= (plist-get item :line-end) 7))))

(ert-deftest expose-review-request-test-parse-items-missing-line-numbers-default-to-one ()
  (let* ((response
          "{\"items\": [{\"file\": \"app.py\", \"comment\": \"x\"}]}")

         (item
          (car
           (expose-review-request-parse-items response))))

    (should
     (= (plist-get item :line-start) 1))
    (should
     (= (plist-get item :line-end) 1))))

;;; ---------------------------------------------------------------------------
;;; expose-review-request-parse-items: placeholder / echoed-schema detection
;;; ---------------------------------------------------------------------------

(ert-deftest expose-review-request-test-parse-items-rejects-echoed-schema-example ()
  ;; A provider that fails and echoes the prompt's own JSON schema example
  ;; back verbatim must not be silently treated as "zero findings".
  (let ((response
         "{\"items\": [
            {\"id\": \"R1\", \"severity\": \"high|medium|low|info\",
             \"category\": \"correctness|security|performance|maintainability|tests|typing|style\",
             \"file\": \"app.py\", \"line_start\": 123, \"line_end\": 126,
             \"title\": \"Short title\", \"comment\": \"Review comment.\",
             \"anchor_text\": \"Relevant source line or phrase.\",
             \"suggestion\": {\"kind\": \"none|text|patch\",
                              \"text\": \"Suggested fix or implementation direction.\"}}
          ]}"))

    (should-error
     (expose-review-request-parse-items response))))

(ert-deftest expose-review-request-test-parse-items-rejects-item-missing-file ()
  ;; An item that normalizes away to nothing (no usable :file) leaves the
  ;; response with a non-empty raw item list but zero real findings, which
  ;; is treated the same as an echoed schema: surface it, don't go silent.
  (let ((response
         "{\"items\": [{\"comment\": \"no file field\"}]}"))

    (should-error
     (expose-review-request-parse-items response))))

;;; ---------------------------------------------------------------------------
;;; expose-review-request-normalize-suggestion
;;; ---------------------------------------------------------------------------

(ert-deftest expose-review-request-test-normalize-suggestion-infers-patch-kind ()
  (let ((suggestion
         (expose-review-request-normalize-suggestion
          '(:patch "-old\n+new"))))

    (should
     (eq (plist-get suggestion :kind) 'patch))))

(ert-deftest expose-review-request-test-normalize-suggestion-infers-text-kind ()
  (let ((suggestion
         (expose-review-request-normalize-suggestion
          '(:text "do it differently"))))

    (should
     (eq (plist-get suggestion :kind) 'text))))

(ert-deftest expose-review-request-test-normalize-suggestion-defaults-to-none ()
  (let ((suggestion
         (expose-review-request-normalize-suggestion nil)))

    (should
     (eq (plist-get suggestion :kind) 'none))))

(provide 'expose-review-request-test)

;;; expose-review-request-test.el ends here
