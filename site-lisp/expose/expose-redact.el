;;; expose-redact.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'expose-log)
(require 'seq)

(defgroup expose-redact nil
  "Secret redaction before Expose sends provider requests."
  :group 'expose)

(defcustom expose-redact-enabled t
  "When non-nil, redact likely secrets before sending Expose requests."
  :type 'boolean
  :group 'expose-redact)

(defcustom expose-redact-placeholder-format "[REDACTED:%s]"
  "Format used for redacted secret placeholders.

The single format argument is a short secret type label."
  :type 'string
  :group 'expose-redact)

(defcustom expose-redact-excluded-path-regexps
  '("\\`etc/env\\(?:/\\|\\'\\)"
    "\\`\\.env\\(?:\\..*\\)?\\'"
    "\\(?:/\\|\\`\\)\\.env\\(?:\\..*\\)?\\'"
    "\\(?:/\\|\\`\\)secrets?\\(?:/\\|\\'\\)"
    "\\(?:/\\|\\`\\)credentials?\\(?:/\\|\\'\\)"
    "\\.pem\\'"
    "\\.key\\'"
    "\\.p12\\'"
    "\\.pfx\\'"
    "\\.crt\\'"
    "\\.cert\\'")
  "Relative file path regexps Expose should never include in provider requests.

These are matched against project-relative paths with forward slashes."
  :type '(repeat regexp)
  :group 'expose-redact)

(defcustom expose-redact-min-assignment-value-length 1
  "Minimum assignment value length before generic key/value redaction applies."
  :type 'integer
  :group 'expose-redact)

(defconst expose-redact-token-patterns
  '((:name "AWS_ACCESS_KEY_ID"
     :regexp "\\b\\(A[KS]IA[0-9A-Z]\\{16\\}\\)\\b"
     :group 1)

    (:name "GITHUB_TOKEN"
     :regexp "\\b\\(gh[pousr]_[A-Za-z0-9_]\\{20,\\}\\)\\b"
     :group 1)

    (:name "GITHUB_TOKEN"
     :regexp "\\b\\(github_pat_[A-Za-z0-9_][A-Za-z0-9_]\\{20,\\}\\)\\b"
     :group 1)

    (:name "OPENAI_KEY"
     :regexp "\\b\\(sk-[A-Za-z0-9_-]\\{20,\\}\\)\\b"
     :group 1)

    (:name "SLACK_TOKEN"
     :regexp "\\b\\(xox[baprs]-[A-Za-z0-9-]\\{10,\\}\\)\\b"
     :group 1)

    (:name "JWT"
     :regexp "\\b\\(eyJ[A-Za-z0-9_-]\\{10,\\}\\.[A-Za-z0-9_-]\\{10,\\}\\.[A-Za-z0-9_-]\\{10,\\}\\)\\b"
     :group 1)

    (:name "BEARER_TOKEN"
     :regexp "\\b\\([Aa]uthorization[[:space:]]*:[[:space:]]*Bearer[[:space:]]+\\)\\([^[:space:]\"'<>]+\\)"
     :group 2)

    (:name "BASIC_AUTH"
     :regexp "\\b\\([Aa]uthorization[[:space:]]*:[[:space:]]*Basic[[:space:]]+\\)\\([^[:space:]\"'<>]+\\)"
     :group 2)

    (:name "URL_PASSWORD"
     :regexp "\\b\\([a-zA-Z][a-zA-Z0-9+.-]*://\\)\\([^:@/[:space:]\"'<>()]+\\):\\([^@/[:space:]\"'<>()]+\\)@"
     :group 3)

    (:name "URL_SECRET_PARAM"
     :regexp "\\([?&][^=&#[:space:]\"'<>]*\\(?:token\\|key\\|secret\\|password\\)[^=&#[:space:]\"'<>]*=\\)\\([^&#[:space:]\"'<>]+\\)"
     :group 2))
  "Token-shaped redaction regexps.

Each entry is a plist with :name, :regexp, and :group. The matched group is
replaced with a redaction placeholder.")

(defconst expose-redact-assignment-key-regexp
  (regexp-opt
   '("api_key"
     "apikey"
     "secret"
     "secret_key"
     "client_secret"
     "consumer_secret"
     "webhook_secret"
     "jwt_secret"
     "signing_key"

     "token"
     "access_token"
     "refresh_token"
     "auth_token"
     "bearer_token"

     "password"
     "passwd"
     "pwd"
     "passphrase"

     "db_password"
     "database_password"
     "postgres_password"
     "mysql_password"
     "redis_password"
     "email_host_password"
     "smtp_password"

     "database_url"
     "db_url"
     "postgres_url"
     "redis_url"
     "broker_url"
     "celery_broker_url"

     "sentry_dsn"

     "facebook_secret"
     "facebook_client_secret"
     "github_secret"
     "google_client_secret"
     "square_access_token"
     "stripe_secret_key"
     "stripe_webhook_secret"
     "aws_secret_access_key")
   t)
  "Case-insensitive key-name fragments used for assignment redaction.")

(defun expose-redact-diff-line-paths (line)
  "Return file paths mentioned by unified diff header LINE."

  (let (paths)

    (when (string-match
           "^diff --git a/\\(.+?\\) b/\\(.+\\)$"
           line)

      (push
       (match-string 1 line)
       paths)

      (push
       (match-string 2 line)
       paths))

    (when (string-match
           "^\\(?:---\\|+++\\) [ab]/\\(.+\\)$"
           line)

      (push
       (match-string 1 line)
       paths))

    (nreverse paths)))


(defun expose-redact-diff-line-excluded-p (line project-root)
  "Return non-nil if unified diff header LINE references an excluded path."

  (seq-some
   (lambda (path)
     (expose-redact-excluded-path-p path project-root))
   (expose-redact-diff-line-paths line)))


(defun expose-redact-strip-excluded-diff-blocks (text &optional project-root)
  "Remove unified diff blocks for excluded paths from TEXT."

  (let ((lines
         (split-string
          (or text "")
          "\n"))

        kept
        skipping
        skipped-count)

    (dolist (line lines)

      (cond
       ;; New diff block.
       ((string-match-p "^diff --git " line)

        (setq skipping
              (expose-redact-diff-line-excluded-p line project-root))

        (when skipping
          (setq skipped-count
                (1+ (or skipped-count 0))))

        (unless skipping
          (push line kept)))

       ;; Header inside an already-started diff block.
       ((and
         (not skipping)
         (expose-redact-diff-line-excluded-p line project-root))

        (setq skipping t)
        (setq skipped-count
              (1+ (or skipped-count 0))))

       ;; Normal line.
       (skipping
        nil)

       (t
        (push line kept))))

    (when skipped-count
      (expose-log
       "Redact"
       "Removed %d excluded diff block(s) from request."
       skipped-count))

    (string-join
     (nreverse kept)
     "\n")))


(defun expose-redact-xml-attribute-paths (line)
  "Return path-like XML attribute values from LINE."

  (let ((position 0)
        paths)

    (while (string-match
            "\\(?:file\\|path\\|name\\)=\"\\([^\"]+\\)\""
            line
            position)

      (push
       (match-string 1 line)
       paths)

      (setq position
            (match-end 0)))

    (nreverse paths)))


(defun expose-redact-xml-line-excluded-p (line project-root)
  "Return non-nil if LINE has an excluded file/path XML attribute."

  (seq-some
   (lambda (path)
     (expose-redact-excluded-path-p path project-root))
   (expose-redact-xml-attribute-paths line)))


(defun expose-redact-strip-excluded-xml-blocks (text &optional project-root)
  "Remove simple XML-ish blocks whose opening tag references an excluded path."

  (let ((lines
         (split-string
          (or text "")
          "\n"))

        kept
        skipping-tag
        skipped-count)

    (dolist (line lines)

      (cond
       ;; Start skipping a simple XML block like:
       ;; <file path=\"etc/env/prod\">
       ;; ...
       ;; </file>
       ((and
         (not skipping-tag)
         (string-match "^\\s-*<\\([A-Za-z0-9_-]+\\)\\b" line)
         (expose-redact-xml-line-excluded-p line project-root))

        (setq skipping-tag
              (match-string 1 line))

        (setq skipped-count
              (1+ (or skipped-count 0))))

       ;; End skipped block.
       ((and
         skipping-tag
         (string-match
          (format "^\\s-*</%s>" (regexp-quote skipping-tag))
          line))

        (setq skipping-tag nil))

       ;; Inside skipped block.
       (skipping-tag
        nil)

       ;; Otherwise keep.
       (t
        (push line kept))))

    (when skipped-count
      (expose-log
       "Redact"
       "Removed %d excluded XML block(s) from request."
       skipped-count))

    (string-join
     (nreverse kept)
     "\n")))


(defun expose-redact-request-document (document &optional project-root)
  "Return DOCUMENT with excluded file blocks removed and secrets redacted."

  (let* ((without-diff
          (expose-redact-strip-excluded-diff-blocks
           document
           project-root))

         (without-xml-blocks
          (expose-redact-strip-excluded-xml-blocks
           without-diff
           project-root)))

    (expose-redact-document without-xml-blocks)))

(defun expose-redact-normalize-path (path &optional project-root)
  "Return PATH normalized for exclusion checks.

When PROJECT-ROOT is non-nil, return a project-relative path when possible."

  (let* ((absolute
          (when path
            (expand-file-name path project-root)))

         (root
          (when project-root
            (file-name-as-directory
             (expand-file-name project-root))))

         (relative
          (cond
           ((not absolute)
            "")

           ((and root
                 (string-prefix-p root absolute))
            (file-relative-name absolute root))

           (t
            path))))

    (replace-regexp-in-string
     "\\\\"
     "/"
     relative)))


(defun expose-redact-excluded-path-p (path &optional project-root)
  "Return non-nil if PATH should not be included in Expose requests."

  (let ((normalized
         (expose-redact-normalize-path path project-root)))

    (seq-some
     (lambda (regexp)
       (string-match-p regexp normalized))
     expose-redact-excluded-path-regexps)))


(defun expose-redact-filter-paths (paths &optional project-root)
  "Return PATHS with excluded files removed."

  (seq-remove
   (lambda (path)
     (expose-redact-excluded-path-p path project-root))
   paths))


(defun expose-redact-log-excluded-path (path &optional project-root)
  "Log that PATH was excluded from an Expose request."

  (expose-log
   "Redact"
   "Excluded sensitive path from request: %s"
   (expose-redact-normalize-path path project-root)))

(defun expose-redact-placeholder (name)
  "Return redaction placeholder for NAME."

  (format expose-redact-placeholder-format name))

(defun expose-redact-redacted-p (text)
  "Return non-nil if TEXT already looks redacted."

  (and
   (stringp text)
   (string-match-p
    "\\[REDACTED:"
    text)))

(defun expose-redact--replace-group (text regexp group name)
  "Replace GROUP in REGEXP matches inside TEXT with redaction NAME."

  (let ((case-fold-search t)
        (position 0)
        (result nil)
        (count 0))

    (while (and
            (< position
               (length text))
            (string-match regexp text position))

      (let ((group-start
             (match-beginning group))

            (group-end
             (match-end group)))

        (if (and group-start
                 group-end
                 (> group-end group-start)
                 (not
                  (expose-redact-redacted-p
                   (substring text group-start group-end))))

            (progn
              (setq result
                    (concat
                     result
                     (substring text position group-start)
                     (expose-redact-placeholder name)))

              (setq position group-end)
              (setq count
                    (1+ count)))

          ;; Defensive fallback: if the requested group was not present,
          ;; skip the whole match so we cannot loop forever.
          (setq result
                (concat
                 result
                 (substring text position
                            (match-end 0))))

          (setq position
                (match-end 0)))))

    (cons
     (concat
      result
      (substring text position))
     count)))

(defun expose-redact-token-patterns (text)
  "Redact known token-shaped secrets in TEXT."

  (let ((current text)
        (total 0))

    (dolist (pattern expose-redact-token-patterns)
      (let* ((name
              (plist-get pattern :name))

             (regexp
              (plist-get pattern :regexp))

             (group
              (plist-get pattern :group))

             (result
              (expose-redact--replace-group
               current
               regexp
               group
               name)))

        (setq current
              (car result))

        (setq total
              (+ total
                 (cdr result)))))

    (cons current total)))

(defun expose-redact-private-key-blocks (text)
  "Redact PEM private key blocks in TEXT."

  (expose-redact--replace-group
   text
   "-----BEGIN [^-]*PRIVATE KEY-----\\(?:.\\|\n\\)*?-----END [^-]*PRIVATE KEY-----"
   0
   "PRIVATE_KEY_BLOCK"))

(defun expose-redact-assignment-line (line)
  "Return LINE with secret-looking assignment values redacted.

This intentionally only redacts simple literal-looking assignment values. It
does not redact expressions such as `password = request.POST[\"password\"]`,
because those are code, not embedded secrets."

  (let ((case-fold-search t)
        (regexp
         (format
          "^\\([[:space:]]*\\(?:export[[:space:]]+\\)?[\"']?[A-Za-z0-9_.-]*%s[A-Za-z0-9_.-]*[\"']?[[:space:]]*[:=][[:space:]]*['\"]?\\)\\([^'\"#[:space:]<>]+\\)\\(['\"]?[[:space:]]*\\(?:#.*\\)?\\)$"
          expose-redact-assignment-key-regexp)))

    (if (not
         (string-match regexp line))

        (cons line 0)

      (let ((value
             (match-string 2 line)))

        (if (or
             (not value)
             (< (length value)
                expose-redact-min-assignment-value-length)
             (expose-redact-redacted-p value))

            (cons line 0)

          (cons
           (concat
            (match-string 1 line)
            (expose-redact-placeholder "SECRET_VALUE")
            (match-string 3 line))
           1))))))

(defun expose-redact-assignments (text)
  "Redact secret-looking assignment lines in TEXT."

  (let ((lines
         (split-string text "\n" nil))

        (total 0)
        redacted-lines)

    (dolist (line lines)
      (let ((result
             (expose-redact-assignment-line line)))

        (push
         (car result)
         redacted-lines)

        (setq total
              (+ total
                 (cdr result)))))

    (cons
     (string-join
      (nreverse redacted-lines)
      "\n")
     total)))

(defun expose-redact-document (document)
  "Return DOCUMENT with likely secrets redacted."

  (if (not expose-redact-enabled)

      document

    (let* ((input
            (or document ""))

           (private-key-result
            (expose-redact-private-key-blocks input))

           (token-result
            (expose-redact-token-patterns
             (car private-key-result)))

           (assignment-result
            (expose-redact-assignments
             (car token-result)))

           (count
            (+ (cdr private-key-result)
               (cdr token-result)
               (cdr assignment-result))))

      (when (> count 0)
        (expose-log
         "Redact"
         "Redacted %d possible secret(s) before provider send."
         count))

      (car assignment-result))))

;;;###autoload
(defun expose-redact-preview-region (start end)
  "Preview redaction for region START to END."

  (interactive "r")

  (let ((redacted
         (expose-redact-document
          (buffer-substring-no-properties start end))))

    (with-current-buffer
        (get-buffer-create "*EXPOSE Redact Preview*")

      (setq buffer-read-only nil)
      (erase-buffer)
      (insert redacted)
      (goto-char (point-min))
      (special-mode)
      (pop-to-buffer
       (current-buffer)))))

(defun expose-redact-test-sample ()
  "Open a sample redaction test buffer."

  (interactive)

  (let ((sample
         "ALLOWED_HOSTS=localhost,example.com
DB_PASSWORD=123
FACEBOOK_SECRET=123
FACEBOOK_CLIENT_ID=public-ish-id
DATABASE_URL=postgres://jose:my-db-password@example.com/app
REDIS_URL=redis://:redis-password@example.com:6379/0
AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF
AWS_SECRET_ACCESS_KEY=super-secret
Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456
"))

    (with-current-buffer
        (get-buffer-create "*EXPOSE Redact Test*")

      (setq buffer-read-only nil)
      (erase-buffer)

      (insert "Original:\n\n")
      (insert sample)
      (insert "\n\nRedacted:\n\n")
      (insert
       (expose-redact-document sample))

      (goto-char (point-min))
      (special-mode)
      (pop-to-buffer
       (current-buffer)))))

(provide 'expose-redact)
