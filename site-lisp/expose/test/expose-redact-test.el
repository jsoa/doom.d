;;; expose-redact-test.el --- Tests for expose-redact -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-redact)

;;; ---------------------------------------------------------------------------
;;; Excluded paths
;;; ---------------------------------------------------------------------------

(ert-deftest expose-redact-test-excluded-path-env-file ()
  (should (expose-redact-excluded-path-p ".env"))
  (should (expose-redact-excluded-path-p ".env.production"))
  (should (expose-redact-excluded-path-p "config/.env"))
  (should (expose-redact-excluded-path-p "etc/env/production")))

(ert-deftest expose-redact-test-excluded-path-secrets-and-credentials ()
  (should (expose-redact-excluded-path-p "secrets/db.yaml"))
  (should (expose-redact-excluded-path-p "app/credentials/prod.json"))
  (should (expose-redact-excluded-path-p "credentials")))

(ert-deftest expose-redact-test-excluded-path-key-material ()
  (should (expose-redact-excluded-path-p "certs/server.pem"))
  (should (expose-redact-excluded-path-p "certs/server.key"))
  (should (expose-redact-excluded-path-p "certs/server.p12"))
  (should (expose-redact-excluded-path-p "certs/server.pfx"))
  (should (expose-redact-excluded-path-p "certs/server.crt"))
  (should (expose-redact-excluded-path-p "certs/server.cert")))

(ert-deftest expose-redact-test-excluded-path-does-not-false-positive ()
  (should-not (expose-redact-excluded-path-p "src/app.py"))
  (should-not (expose-redact-excluded-path-p "README.md"))
  (should-not (expose-redact-excluded-path-p "keyboard.py"))
  (should-not (expose-redact-excluded-path-p "sentry.py")))

(ert-deftest expose-redact-test-excluded-path-project-relative ()
  (let ((root "/home/user/project/"))
    (should
     (expose-redact-excluded-path-p
      "/home/user/project/.env"
      root))
    (should-not
     (expose-redact-excluded-path-p
      "/home/user/project/src/app.py"
      root))))

(ert-deftest expose-redact-test-filter-paths-removes-only-excluded ()
  (should
   (equal
    (expose-redact-filter-paths
     '("src/app.py" ".env" "README.md" "secrets/db.yaml"))
    '("src/app.py" "README.md"))))

;;; ---------------------------------------------------------------------------
;;; Diff / XML block stripping
;;; ---------------------------------------------------------------------------

(ert-deftest expose-redact-test-strip-excluded-diff-blocks ()
  (let ((diff
         "diff --git a/src/app.py b/src/app.py
--- a/src/app.py
+++ b/src/app.py
@@ -1,1 +1,1 @@
-old
+new
diff --git a/.env b/.env
--- a/.env
+++ b/.env
@@ -1,1 +1,1 @@
-SECRET=old
+SECRET=new"))

    (let ((result
           (expose-redact-strip-excluded-diff-blocks diff)))

      (should
       (string-match-p "src/app.py" result))
      (should-not
       (string-match-p "\\.env" result))
      (should-not
       (string-match-p "SECRET" result)))))

(ert-deftest expose-redact-test-strip-excluded-xml-blocks ()
  (let ((doc
         "<file path=\"src/app.py\">
def f(): pass
</file>
<file path=\"secrets/db.yaml\">
password: hunter2
</file>"))

    (let ((result
           (expose-redact-strip-excluded-xml-blocks doc)))

      (should
       (string-match-p "def f" result))
      (should-not
       (string-match-p "hunter2" result)))))

;;; ---------------------------------------------------------------------------
;;; Token-shaped secrets
;;; ---------------------------------------------------------------------------

(ert-deftest expose-redact-test-token-patterns-aws ()
  (let ((result
         (car
          (expose-redact-token-patterns
           "AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF"))))

    (should
     (string-match-p "\\[REDACTED:AWS_ACCESS_KEY_ID\\]" result))
    (should-not
     (string-match-p "AKIA1234567890ABCDEF" result))))

(ert-deftest expose-redact-test-token-patterns-github ()
  (let ((result
         (car
          (expose-redact-token-patterns
           "token: ghp_abcdefghijklmnopqrstuvwxyz012345"))))

    (should
     (string-match-p "\\[REDACTED:GITHUB_TOKEN\\]" result))
    (should-not
     (string-match-p "ghp_" result))))

(ert-deftest expose-redact-test-token-patterns-jwt ()
  (let* ((jwt
          "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzbm90YXJlYWxzaWc")

         (result
          (car
           (expose-redact-token-patterns
            (format "Authorization-ish blob: %s" jwt)))))

    (should
     (string-match-p "\\[REDACTED:JWT\\]" result))
    (should-not
     (string-match-p (regexp-quote jwt) result))))

(ert-deftest expose-redact-test-token-patterns-bearer ()
  (let ((result
         (car
          (expose-redact-token-patterns
           "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"))))

    (should
     (string-match-p "Authorization: Bearer \\[REDACTED:BEARER_TOKEN\\]" result))))

(ert-deftest expose-redact-test-token-patterns-url-password ()
  (let ((result
         (car
          (expose-redact-token-patterns
           "DATABASE_URL=postgres://jose:my-db-password@example.com/app"))))

    (should
     (string-match-p "postgres://jose:\\[REDACTED:URL_PASSWORD\\]@example.com" result))
    (should-not
     (string-match-p "my-db-password" result))))

(ert-deftest expose-redact-test-token-patterns-url-secret-param ()
  (let ((result
         (car
          (expose-redact-token-patterns
           "https://example.com/webhook?token=abcdef123456"))))

    (should
     (string-match-p "token=\\[REDACTED:URL_SECRET_PARAM\\]" result))
    (should-not
     (string-match-p "abcdef123456" result))))

(ert-deftest expose-redact-test-token-patterns-no-false-positive-on-plain-text ()
  (let ((result
         (car
          (expose-redact-token-patterns
           "This is just a normal sentence about tokens and keys."))))

    (should-not
     (string-match-p "REDACTED" result))))

;;; ---------------------------------------------------------------------------
;;; Private key blocks
;;; ---------------------------------------------------------------------------

(ert-deftest expose-redact-test-private-key-block ()
  (let* ((pem
          "-----BEGIN RSA PRIVATE KEY-----
MIIBOgIBAAJBAK...
-----END RSA PRIVATE KEY-----")

         (result
          (car
           (expose-redact-private-key-blocks
            (format "before\n%s\nafter" pem)))))

    (should
     (string-match-p "\\[REDACTED:PRIVATE_KEY_BLOCK\\]" result))
    (should-not
     (string-match-p "MIIBOgIBAAJBAK" result))
    (should
     (string-match-p "before" result))
    (should
     (string-match-p "after" result))))

;;; ---------------------------------------------------------------------------
;;; Assignment-line redaction
;;; ---------------------------------------------------------------------------

(ert-deftest expose-redact-test-assignment-line-env-style ()
  (let ((result
         (car
          (expose-redact-assignment-line
           "DB_PASSWORD=hunter2"))))

    (should
     (string-match-p "DB_PASSWORD=\\[REDACTED:SECRET_VALUE\\]" result))))

(ert-deftest expose-redact-test-assignment-line-quoted-json-style ()
  (let ((result
         (car
          (expose-redact-assignment-line
           "  \"db_password\": \"hunter2\","))))

    (should
     (string-match-p "\\[REDACTED:SECRET_VALUE\\]" result))
    (should
     (string-suffix-p "," result))))

(ert-deftest expose-redact-test-assignment-line-export-style ()
  (let ((result
         (car
          (expose-redact-assignment-line
           "export STRIPE_SECRET_KEY=sk_live_abcdef123456"))))

    (should
     (string-match-p "\\[REDACTED:SECRET_VALUE\\]" result))))

(ert-deftest expose-redact-test-assignment-line-does-not-redact-code-expression ()
  ;; This is code reading a POST parameter, not an embedded literal secret.
  (let ((line
         "password = request.POST[\"password\"]"))

    (should
     (equal
      (expose-redact-assignment-line line)
      (cons line 0)))))

(ert-deftest expose-redact-test-assignment-line-ignores-unrelated-key ()
  (let ((line
         "ALLOWED_HOSTS=localhost,example.com"))

    (should
     (equal
      (expose-redact-assignment-line line)
      (cons line 0)))))

(ert-deftest expose-redact-test-assignment-line-already-redacted-is-idempotent ()
  (let ((line
         "DB_PASSWORD=[REDACTED:SECRET_VALUE]"))

    (should
     (equal
      (expose-redact-assignment-line line)
      (cons line 0)))))

;;; ---------------------------------------------------------------------------
;;; Full document redaction
;;; ---------------------------------------------------------------------------

(ert-deftest expose-redact-test-document-redacts-multiple-secret-kinds ()
  (let* ((sample
          "ALLOWED_HOSTS=localhost,example.com
DB_PASSWORD=123
AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF
Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456")

         (result
          (expose-redact-document sample)))

    (should
     (string-match-p "ALLOWED_HOSTS=localhost,example.com" result))
    (should-not
     (string-match-p "=123" result))
    (should-not
     (string-match-p "AKIA1234567890ABCDEF" result))
    (should-not
     (string-match-p "abcdefghijklmnopqrstuvwxyz123456" result))))

(ert-deftest expose-redact-test-document-disabled-passes-through ()
  (let ((expose-redact-enabled nil)

        (sample
         "DB_PASSWORD=hunter2"))

    (should
     (equal
      (expose-redact-document sample)
      sample))))

(ert-deftest expose-redact-test-document-nil-input ()
  (should
   (equal
    (expose-redact-document nil)
    "")))

(provide 'expose-redact-test)

;;; expose-redact-test.el ends here
