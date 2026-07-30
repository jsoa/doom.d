;;; expose-review-context.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'expose-log)
(require 'expose-review-store)
(require 'json)

(defcustom expose-review-base-branch nil
  "Base branch used for Expose code review.

When nil, Expose tries `origin/main', `main', `origin/master', then `master'."
  :type '(choice
          (const nil)
          string)
  :group 'expose-review)

(defcustom expose-review-context-include-frontend-diagnostics t
  "Whether Expose Review should include TypeScript/ESLint diagnostics."
  :type 'boolean
  :group 'expose-review)

(defcustom expose-review-context-base-branch-candidates
  '("develop" "main" "master")
  "Preferred base branch candidates for Expose full review.

Expose scores existing local/remote candidates by merge-base recency and picks
the branch whose merge-base with HEAD is newest."
  :type '(repeat string)
  :group 'expose-review)

(defun expose-review-context-git-string (project-root &rest args)
  "Run git ARGS in PROJECT-ROOT and return trimmed output, or nil."

  (condition-case nil
      (let ((result
             (apply
              #'expose-review-context-call-git
              project-root
              args)))

        (when-let ((text
                    (and result
                         (string-trim result))))

          (unless (string-empty-p text)
            text)))

    (error nil)))


(defun expose-review-context-git-ref-exists-p (project-root ref)
  "Return non-nil if git REF exists in PROJECT-ROOT."

  (not
   (null
    (expose-review-context-git-string
     project-root
     "rev-parse"
     "--verify"
     "--quiet"
     ref))))


(defun expose-review-context-normalize-base-branch (branch)
  "Return display-friendly branch name for BRANCH."

  (when branch
    (let ((name
           (string-trim branch)))

      (setq name
            (replace-regexp-in-string
             "\\`refs/heads/"
             ""
             name))

      (setq name
            (replace-regexp-in-string
             "\\`refs/remotes/"
             ""
             name))

      (setq name
            (replace-regexp-in-string
             "\\`origin/"
             ""
             name))

      name)))


(defun expose-review-context-base-branch-ref-candidates (project-root)
  "Return existing base branch refs for PROJECT-ROOT."

  (let (refs)

    (dolist (branch expose-review-context-base-branch-candidates)

      (let ((local-ref branch)
            (remote-ref
             (format "origin/%s" branch)))

        (when (expose-review-context-git-ref-exists-p
               project-root
               local-ref)

          (push local-ref refs))

        (when (expose-review-context-git-ref-exists-p
               project-root
               remote-ref)

          (push remote-ref refs))))

    (nreverse refs)))


(defun expose-review-context-merge-base-time (project-root ref)
  "Return merge-base commit timestamp for REF against HEAD."

  (when-let ((merge-base
              (expose-review-context-git-string
               project-root
               "merge-base"
               ref
               "HEAD")))

    (let ((timestamp
           (expose-review-context-git-string
            project-root
            "show"
            "-s"
            "--format=%ct"
            merge-base)))

      (when timestamp
        (string-to-number timestamp)))))


(defun expose-review-context-score-base-branch-ref (project-root ref)
  "Return score cons for base branch REF in PROJECT-ROOT."

  (cons
   ref
   (or
    (expose-review-context-merge-base-time project-root ref)
    0)))


(defun expose-review-context-best-base-branch-ref (project-root)
  "Return the best base branch ref for PROJECT-ROOT."

  (let* ((refs
          (expose-review-context-base-branch-ref-candidates project-root))

         (scored
          (mapcar
           (lambda (ref)
             (expose-review-context-score-base-branch-ref project-root ref))
           refs)))

    (car
     (car
      (sort
       scored
       (lambda (left right)
         (> (cdr left)
            (cdr right))))))))


(defun expose-review-context-detect-base-branch (project-root)
  "Return the base branch ref for PROJECT-ROOT.

Prefer `expose-review-base-branch' when explicitly configured.
Otherwise use the newer merge-base scoring logic, which considers
develop/main/master locally and remotely."
  (or
   expose-review-base-branch
   (expose-review-context-best-base-branch-ref project-root)
   (seq-find
    (lambda (candidate)
      (expose-review-context-ref-exists-p
       project-root
       candidate))
    expose-review-base-branch-candidates)
   "HEAD~1"))

(defcustom expose-review-base-branch-candidates
  '("origin/develop"
    "develop"
    "origin/main"
    "main"
    "origin/master"
    "master")
  "Base branch candidates used when `expose-review-base-branch' is nil."
  :type '(repeat string)
  :group 'expose-review)

(defcustom expose-review-context-max-diff-length 120000
  "Maximum number of characters included from each review diff."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-max-metadata-file-length 12000
  "Maximum number of characters read from each project metadata file."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-metadata-files
  '("README.md"
    "AGENTS.md"
    "CLAUDE.md"
    ".github/copilot-instructions.md"
    "pyproject.toml"
    "package.json")
  "Project metadata files included in Expose review context when present."
  :type '(repeat string)
  :group 'expose-review)

(defcustom expose-review-context-include-untracked-files t
  "Whether Expose Review should include untracked file contents."
  :type 'boolean
  :group 'expose-review)

(defcustom expose-review-context-max-untracked-files 20
  "Maximum number of untracked files included in review context."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-max-untracked-file-length 20000
  "Maximum characters included from a single untracked file."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-max-untracked-total-length 80000
  "Maximum total characters included from all untracked files."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-reviewable-file-regexp
  "\\(?:\\.\\(?:py\\|el\\|sh\\|bash\\|zsh\\|toml\\|json\\|ya?ml\\|md\\|txt\\|ini\\|cfg\\|conf\\|sql\\|html\\|css\\|scss\\|js\\|jsx\\|ts\\|tsx\\)\\'\\|\\(?:^\\|/\\)Dockerfile\\(?:\\..*\\)?\\'\\|\\(?:^\\|/\\)docker-compose\\(?:\\..*\\)?\\.ya?ml\\'\\)"
  "Regexp matching untracked files safe/useful to include in review context."
  :type 'regexp
  :group 'expose-review)

(defcustom expose-review-context-max-changed-file-contents 20
  "Maximum number of tracked changed file contents included in review context."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-max-changed-file-length 40000
  "Maximum characters included from a single tracked changed file."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-max-changed-total-length 120000
  "Maximum total characters included from tracked changed files."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-include-diagnostics t
  "Whether Expose Review should include diagnostics for changed files."
  :type 'boolean
  :group 'expose-review)

(defcustom expose-review-context-max-diagnostics 120
  "Maximum diagnostics included in Expose Review context."
  :type 'integer
  :group 'expose-review)

(defcustom expose-review-context-max-diagnostic-output-length 200000
  "Maximum diagnostic command output length parsed by Expose Review."
  :type 'integer
  :group 'expose-review)

(defun expose-review-context-frontend-file-p (relative-path)
  "Return non-nil if RELATIVE-PATH is a frontend file."

  (and
   relative-path
   (string-match-p
    "\\.\\(?:ts\\|tsx\\|js\\|jsx\\|mjs\\|cjs\\|html\\)\\'"
    relative-path)))

(defun expose-review-context-typescript-file-p (relative-path)
  "Return non-nil if RELATIVE-PATH is checked by TypeScript."

  (and
   relative-path
   (string-match-p
    "\\.\\(?:ts\\|tsx\\|js\\|jsx\\|mjs\\|cjs\\)\\'"
    relative-path)))

(defun expose-review-context-existing-frontend-files (project-root files)
  "Return existing frontend FILES relative to PROJECT-ROOT."

  (seq-filter
   (lambda (relative-path)
     (let ((path
            (expand-file-name relative-path project-root)))

       (and
        (expose-review-context-frontend-file-p relative-path)
        (file-readable-p path)
        (file-regular-p path))))
   files))

(defun expose-review-context-node-tool-command (project-root tool)
  "Return executable path for frontend TOOL in PROJECT-ROOT."

  (let ((local-tool
         (expand-file-name
          (concat "node_modules/.bin/" tool)
          project-root)))

    (cond
     ((file-executable-p local-tool)
      local-tool)

     ((executable-find tool)
      (executable-find tool))

     (t
      nil))))

(defun expose-review-context-call-node-tool (project-root tool args)
  "Run frontend TOOL with ARGS in PROJECT-ROOT."

  (if-let ((command
            (expose-review-context-node-tool-command
             project-root
             tool)))

      (expose-review-context-call-command
       project-root
       command
       args)

    (list
     :status nil
     :stdout ""
     :stderr
     (format
      "%s executable not found in node_modules/.bin or PATH"
      tool))))

(defun expose-review-context-typescript-project-args (project-root)
  "Return arguments for running TypeScript in PROJECT-ROOT."

  (cond
   ((file-readable-p
     (expand-file-name "tsconfig.json" project-root))
    '("-p" "tsconfig.json" "--noEmit" "--pretty" "false"))

   (t
    '("--noEmit" "--pretty" "false"))))

(defun expose-review-context-parse-typescript (project-root output changed-files)
  "Parse TypeScript OUTPUT for PROJECT-ROOT filtered to CHANGED-FILES."

  (let ((changed-files
         (mapcar
          #'file-relative-name
          changed-files))

        results)

    (dolist (line
             (split-string
              (or output "")
              "\n"
              t))

      ;; Example:
      ;; src/app/foo.ts(10,5): error TS2322: Type 'x' is not assignable...
      (when (string-match
             "^\\(.+\\)(\\([0-9]+\\),\\([0-9]+\\)): \\(error\\|warning\\) \\(TS[0-9]+\\): \\(.*\\)$"
             line)

        (let* ((file
                (expose-review-context-relative-path
                 project-root
                 (match-string 1 line)))

               (line-number
                (string-to-number
                 (match-string 2 line)))

               (severity
                (match-string 4 line))

               (code
                (match-string 5 line))

               (message
                (match-string 6 line)))

          (when (member file changed-files)
            (push
             (list
              :tool 'typescript
              :file file
              :line line-number
              :severity severity
              :code code
              :message message)
             results)))))

    (nreverse results)))

(defun expose-review-context-eslint-severity (severity)
  "Return display severity for ESLint SEVERITY."

  (pcase severity
    (2 "error")
    (1 "warning")
    (_ "info")))

(defun expose-review-context-parse-eslint (project-root output)
  "Parse ESLint JSON OUTPUT for PROJECT-ROOT."

  (let ((json
         (expose-review-context-json-parse-safe output))

        results)

    (when (listp json)

      (dolist (file-result json)

        (let ((file
               (expose-review-context-relative-path
                project-root
                (or
                 (plist-get file-result :filePath)
                 ""))))

          (dolist (message
                   (plist-get file-result :messages))

            (push
             (list
              :tool 'eslint
              :file file
              :line
              (expose-review-context-json-number
               (plist-get message :line)
               1)
              :severity
              (expose-review-context-eslint-severity
               (plist-get message :severity))
              :code
              (or
               (plist-get message :ruleId)
               "")
              :message
              (or
               (plist-get message :message)
               ""))
             results)))))

    (nreverse results)))

(defun expose-review-context-command-error (result items)
  "Return command error for RESULT when ITEMS are empty and status failed."

  (let ((status
         (plist-get result :status)))

    (when (and
           status
           (not
            (equal status 0))
           (not items))

      (string-trim
       (string-join
        (seq-filter
         (lambda (text)
           (and text
                (not
                 (string-empty-p text))))
         (list
          (plist-get result :stderr)
          (plist-get result :stdout)))
        "\n")))))

(defun expose-review-context-run-typescript (project-root frontend-files)
  "Run TypeScript diagnostics for FRONTEND-FILES in PROJECT-ROOT."

  (let ((typescript-files
         (seq-filter
          #'expose-review-context-typescript-file-p
          frontend-files)))

    (if (and
         expose-review-context-include-frontend-diagnostics
         typescript-files)

        (let* ((result
                (expose-review-context-call-node-tool
                 project-root
                 "tsc"
                 (expose-review-context-typescript-project-args
                  project-root)))

               (items
                (expose-review-context-parse-typescript
                 project-root
                 (plist-get result :stdout)
                 typescript-files)))

          (list
           :tool 'typescript
           :status
           (plist-get result :status)
           :items items
           :error
           (expose-review-context-command-error
            result
            items)))

      (list
       :tool 'typescript
       :status nil
       :items nil
       :error nil))))

(defun expose-review-context-run-eslint (project-root frontend-files)
  "Run ESLint diagnostics for FRONTEND-FILES in PROJECT-ROOT."

  (if (and
       expose-review-context-include-frontend-diagnostics
       frontend-files)

      (let* ((result
              (expose-review-context-call-node-tool
               project-root
               "eslint"
               (append
                '("--format" "json" "--no-error-on-unmatched-pattern")
                frontend-files)))

             (items
              (expose-review-context-parse-eslint
               project-root
               (plist-get result :stdout))))

        (list
         :tool 'eslint
         :status
         (plist-get result :status)
         :items items
         :error
         (expose-review-context-command-error
          result
          items)))

    (list
     :tool 'eslint
     :status nil
     :items nil
     :error nil)))

(defun expose-review-context-python-file-p (relative-path)
  "Return non-nil if RELATIVE-PATH is a Python file."

  (and
   relative-path
   (string-suffix-p ".py" relative-path)))

(defun expose-review-context-existing-python-files (project-root files)
  "Return existing Python FILES relative to PROJECT-ROOT."

  (seq-filter
   (lambda (relative-path)
     (let ((path
            (expand-file-name relative-path project-root)))

       (and
        (expose-review-context-python-file-p relative-path)
        (file-readable-p path)
        (file-regular-p path))))
   files))

(defun expose-review-context-relative-path (project-root path)
  "Return PATH relative to PROJECT-ROOT when possible."

  (let ((expanded-root
         (file-name-as-directory
          (expand-file-name project-root)))

        (expanded-path
         (expand-file-name path)))

    (if (string-prefix-p expanded-root expanded-path)
        (file-relative-name expanded-path expanded-root)
      path)))

(defun expose-review-context-call-command (project-root command args)
  "Run COMMAND with ARGS in PROJECT-ROOT.

Return a plist containing :status, :stdout, and :stderr."
  (let ((stdout-buffer
         (generate-new-buffer " *expose-review-stdout*"))

        (stderr-file
         (make-temp-file "expose-review-stderr-")))

    (unwind-protect

        (let ((status
               (let ((default-directory project-root))
                 (apply
                  #'call-process
                  command
                  nil
                  ;; For `call-process', stderr must be a file path here,
                  ;; not a buffer.
                  (list stdout-buffer stderr-file)
                  nil
                  args))))

          (list
           :status status

           :stdout
           (with-current-buffer stdout-buffer
             (expose-review-context-truncate
              (buffer-string)
              expose-review-context-max-diagnostic-output-length))

           :stderr
           (if (file-readable-p stderr-file)
               (with-temp-buffer
                 (insert-file-contents stderr-file)
                 (expose-review-context-truncate
                  (buffer-string)
                  expose-review-context-max-diagnostic-output-length))
             "")))

      (when (buffer-live-p stdout-buffer)
        (kill-buffer stdout-buffer))

      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun expose-review-context-json-parse-safe (text)
  "Parse TEXT as JSON, returning nil on failure."

  (condition-case nil
      (json-parse-string
       text
       :object-type 'plist
       :array-type 'list
       :null-object nil
       :false-object nil)
    (error nil)))

(defun expose-review-context-json-number (value fallback)
  "Return VALUE as a number, or FALLBACK."

  (cond
   ((numberp value)
    value)

   ((stringp value)
    (string-to-number value))

   (t
    fallback)))

(defun expose-review-context-diagnostic-line-from-range (range)
  "Return one-based line number from Pyright RANGE."

  (let* ((start
          (plist-get range :start))

         (line
          (plist-get start :line)))

    (1+
     (expose-review-context-json-number line 0))))

(defun expose-review-context-normalize-pyright-diagnostic (project-root raw)
  "Normalize RAW Pyright diagnostic for PROJECT-ROOT."

  (let* ((file
          (plist-get raw :file))

         (range
          (plist-get raw :range))

         (severity
          (or
           (plist-get raw :severity)
           "information"))

         (message
          (or
           (plist-get raw :message)
           ""))

         (rule
          (or
           (plist-get raw :rule)
           "")))

    (list
     :tool 'pyright
     :file
     (expose-review-context-relative-path
      project-root
      file)
     :line
     (expose-review-context-diagnostic-line-from-range range)
     :severity severity
     :code rule
     :message message)))

(defun expose-review-context-parse-pyright (project-root output)
  "Parse Pyright OUTPUT for PROJECT-ROOT."

  (let* ((json
          (expose-review-context-json-parse-safe output))

         (diagnostics
          (plist-get json :generalDiagnostics)))

    (mapcar
     (lambda (raw)
       (expose-review-context-normalize-pyright-diagnostic
        project-root
        raw))
     diagnostics)))

(defun expose-review-context-normalize-ruff-diagnostic (_project-root raw)
  "Normalize RAW Ruff diagnostic."

  (let* ((location
          (plist-get raw :location))

         (filename
          (or
           (plist-get raw :filename)
           ""))

         (row
          (plist-get location :row))

         (code
          (or
           (plist-get raw :code)
           ""))

         (message
          (or
           (plist-get raw :message)
           "")))

    (list
     :tool 'ruff
     :file filename
     :line
     (expose-review-context-json-number row 1)
     :severity "warning"
     :code code
     :message message)))

(defun expose-review-context-parse-ruff (project-root output)
  "Parse Ruff OUTPUT for PROJECT-ROOT."

  (let ((json
         (expose-review-context-json-parse-safe output)))

    (when (listp json)
      (mapcar
       (lambda (raw)
         (expose-review-context-normalize-ruff-diagnostic
          project-root
          raw))
       json))))

(defun expose-review-context-run-pyright (project-root python-files)
  "Run Pyright for PYTHON-FILES in PROJECT-ROOT."

  (if-let ((pyright
            (executable-find "pyright")))

      (let* ((result
              (expose-review-context-call-command
               project-root
               pyright
               (append
                '("--outputjson")
                python-files)))

             (stdout
              (plist-get result :stdout))

             (items
              (expose-review-context-parse-pyright
               project-root
               stdout)))

        (list
         :tool 'pyright
         :status
         (plist-get result :status)
         :items items
         :error
         (unless items
           (string-trim
            (or
             (plist-get result :stderr)
             "")))))

    (list
     :tool 'pyright
     :status nil
     :items nil
     :error "pyright executable not found")))

(defun expose-review-context-run-ruff (project-root python-files)
  "Run Ruff for PYTHON-FILES in PROJECT-ROOT."

  (if-let ((ruff
            (executable-find "ruff")))

      (let* ((result
              (expose-review-context-call-command
               project-root
               ruff
               (append
                '("check" "--output-format" "json")
                python-files)))

             (stdout
              (plist-get result :stdout))

             (items
              (expose-review-context-parse-ruff
               project-root
               stdout)))

        (list
         :tool 'ruff
         :status
         (plist-get result :status)
         :items items
         :error
         (unless items
           (string-trim
            (or
             (plist-get result :stderr)
             "")))))

    (list
     :tool 'ruff
     :status nil
     :items nil
     :error "ruff executable not found")))

(defun expose-review-context-tool-items (result)
  "Return diagnostic items from RESULT."

  (or
   (plist-get result :items)
   nil))

(defun expose-review-context-diagnostic-results (project-root changed-files)
  "Return diagnostic results for CHANGED-FILES in PROJECT-ROOT."

  (when expose-review-context-include-diagnostics

    (let* ((python-files
            (expose-review-context-existing-python-files
             project-root
             changed-files))

           (frontend-files
            (expose-review-context-existing-frontend-files
             project-root
             changed-files))

           (pyright
            (when python-files
              (expose-review-context-run-pyright
               project-root
               python-files)))

           (ruff
            (when python-files
              (expose-review-context-run-ruff
               project-root
               python-files)))

           (typescript
            (when frontend-files
              (expose-review-context-run-typescript
               project-root
               frontend-files)))

           (eslint
            (when frontend-files
              (expose-review-context-run-eslint
               project-root
               frontend-files)))

           (items
            (seq-take
             (append
              (expose-review-context-tool-items pyright)
              (expose-review-context-tool-items ruff)
              (expose-review-context-tool-items typescript)
              (expose-review-context-tool-items eslint))
             expose-review-context-max-diagnostics)))

      (list
       :python-files python-files
       :frontend-files frontend-files
       :pyright pyright
       :ruff ruff
       :typescript typescript
       :eslint eslint
       :items items))))

(defun expose-review-context-hidden-path-p (relative-path)
  "Return non-nil if RELATIVE-PATH contains a hidden path segment."

  (seq-some
   (lambda (part)
     (and
      (> (length part) 0)
      (string-prefix-p "." part)))
   (split-string
    relative-path
    "/"
    t)))

(defun expose-review-context-tracked-changed-files (project-root base-branch)
  "Return tracked changed files for PROJECT-ROOT relative to BASE-BRANCH."

  (delete-dups
   (append
    ;; Committed branch changes.
    (expose-review-context-lines
     (expose-review-context-call-git
      project-root
      "diff"
      "--name-only"
      (format "%s...HEAD" base-branch)))

    ;; Unstaged tracked changes.
    (expose-review-context-lines
     (expose-review-context-call-git
      project-root
      "diff"
      "--name-only"))

    ;; Staged tracked changes.
    (expose-review-context-lines
     (expose-review-context-call-git
      project-root
      "diff"
      "--cached"
      "--name-only")))))

(defun expose-review-context-read-changed-file (project-root relative-path max-length)
  "Read RELATIVE-PATH from PROJECT-ROOT as tracked changed file context."

  (let ((path
         (expand-file-name relative-path project-root)))

    (when (and
           (file-readable-p path)
           (file-regular-p path)
           (expose-review-context-reviewable-file-p relative-path)
           (not
            (expose-review-context-file-binary-p path)))

      (let* ((size
              (expose-review-context-file-size path))

             (content
              (expose-review-context-read-limited-file
               path
               max-length))

             (truncated
              (> size max-length)))

        (list
         :file relative-path
         :size size
         :truncated truncated
         :content content)))))

(defun expose-review-context-changed-file-contents (project-root base-branch)
  "Return bounded tracked changed file contents for PROJECT-ROOT."

  (let ((remaining-total
         expose-review-context-max-changed-total-length)

        (included-count 0)

        results)

    (dolist (relative-path
             (expose-review-context-tracked-changed-files
              project-root
              base-branch))

      (when (and
             (< included-count
                expose-review-context-max-changed-file-contents)

             (> remaining-total 0)

             (expose-review-context-reviewable-file-p relative-path))

        (let* ((max-length
                (min
                 expose-review-context-max-changed-file-length
                 remaining-total))

               (entry
                (expose-review-context-read-changed-file
                 project-root
                 relative-path
                 max-length)))

          (when entry
            (cl-incf included-count)

            (setq remaining-total
                  (- remaining-total
                     (length
                      (plist-get entry :content))))

            (push entry results)))))

    (nreverse results)))

(defun expose-review-context-untracked-files (project-root)
  "Return untracked non-ignored, non-hidden files for PROJECT-ROOT."

  (seq-remove
   #'expose-review-context-hidden-path-p
   (expose-review-context-lines
    (expose-review-context-call-git
     project-root
     "ls-files"
     "--others"
     "--exclude-standard"))))

(defun expose-review-context-all-untracked-files (project-root)
  "Return all untracked non-ignored files for PROJECT-ROOT."

  (expose-review-context-lines
   (expose-review-context-call-git
    project-root
    "ls-files"
    "--others"
    "--exclude-standard")))

(defun expose-review-context-reviewable-file-p (relative-path)
  "Return non-nil if RELATIVE-PATH should be included in review context."

  (and
   relative-path
   (string-match-p
    expose-review-context-reviewable-file-regexp
    relative-path)))

(defun expose-review-context-file-size (path)
  "Return file size for PATH, or 0."

  (or
   (nth 7
        (file-attributes path))
   0))

(defun expose-review-context-file-binary-p (path)
  "Return non-nil if PATH appears to be binary."

  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents-literally path nil 0 4096)
      (goto-char (point-min))
      (search-forward "\0" nil t))))

(defun expose-review-context-read-limited-file (path max-length)
  "Read at most MAX-LENGTH characters from PATH."

  (with-temp-buffer
    (insert-file-contents path nil 0 max-length)
    (buffer-string)))

(defun expose-review-context-read-untracked-file (project-root relative-path max-length)
  "Read RELATIVE-PATH from PROJECT-ROOT as untracked review context."

  (let ((path
         (expand-file-name relative-path project-root)))

    (when (and
           (file-readable-p path)
           (file-regular-p path)
           (not
            (expose-review-context-file-binary-p path)))

      (let* ((size
              (expose-review-context-file-size path))

             (content
              (expose-review-context-read-limited-file
               path
               max-length))

             (truncated
              (> size max-length)))

        (list
         :file relative-path
         :size size
         :truncated truncated
         :content content)))))

(defun expose-review-context-untracked-file-contents (project-root)
  "Return bounded untracked file contents for PROJECT-ROOT."

  (when expose-review-context-include-untracked-files

    (let ((remaining-total
           expose-review-context-max-untracked-total-length)

          (included-count 0)

          results)

      (dolist (relative-path
               (expose-review-context-untracked-files project-root))

        (when (and
               (< included-count
                  expose-review-context-max-untracked-files)

               (> remaining-total 0)

               (expose-review-context-reviewable-file-p relative-path))

          (let* ((max-length
                  (min
                   expose-review-context-max-untracked-file-length
                   remaining-total))

                 (entry
                  (expose-review-context-read-untracked-file
                   project-root
                   relative-path
                   max-length)))

            (when entry
              (cl-incf included-count)

              (setq remaining-total
                    (- remaining-total
                       (length
                        (plist-get entry :content))))

              (push entry results)))))

      (nreverse results))))

(defun expose-review-context-now ()
  "Return an ISO-like timestamp."

  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun expose-review-context-call-git (project-root &rest args)
  "Call git with ARGS in PROJECT-ROOT and return trimmed stdout.

Return nil when git exits unsuccessfully."

  (when (executable-find "git")
    (with-temp-buffer
      (let* ((default-directory project-root)

             (status
              (apply
               #'call-process
               "git"
               nil
               t
               nil
               args)))

        (if (= status 0)

            (string-trim
             (buffer-string))

          (expose-log
           "ReviewGit"
           "Git command failed: git %s"
           (string-join args " "))

          nil)))))

(defun expose-review-context-project-root ()
  "Return the current project root."

  (file-name-as-directory
   (or
    (when (fboundp 'projectile-project-root)
      (ignore-errors
        (projectile-project-root)))

    (when-let ((project
                (project-current nil)))
      (project-root project))

    (expose-review-context-call-git
     default-directory
     "rev-parse"
     "--show-toplevel")

    default-directory)))

(defun expose-review-context-project-name (project-root)
  "Return display name for PROJECT-ROOT."

  (file-name-nondirectory
   (directory-file-name project-root)))

(defun expose-review-context-current-branch (project-root)
  "Return current branch for PROJECT-ROOT."

  (let ((branch
         (expose-review-context-call-git
          project-root
          "branch"
          "--show-current")))

    (if (and branch
             (not
              (string-empty-p branch)))

        branch

      (let ((head
             (expose-review-context-call-git
              project-root
              "rev-parse"
              "--short"
              "HEAD")))

        (if head
            (format "detached-%s" head)
          "detached")))))

(defun expose-review-context-ref-exists-p (project-root ref)
  "Return non-nil if REF exists in PROJECT-ROOT."

  (not
   (null
    (expose-review-context-call-git
     project-root
     "rev-parse"
     "--verify"
     "--quiet"
     ref))))

(defun expose-review-context-merge-base (project-root base-branch)
  "Return merge-base between HEAD and BASE-BRANCH."

  (expose-review-context-call-git
   project-root
   "merge-base"
   "HEAD"
   base-branch))

(defun expose-review-context-truncate (text max-length)
  "Return TEXT truncated to MAX-LENGTH."

  (if (and text
           (> (length text)
              max-length))

      (concat
       (substring text 0 max-length)
       "\n\n[EXPOSE truncated this section]\n")

    text))

(defun expose-review-context-lines (text)
  "Return non-empty lines from TEXT."

  (seq-filter
   (lambda (line)
     (not
      (string-empty-p line)))
   (split-string
    (or text "")
    "\n")))

(defun expose-review-context-changed-files (project-root base-branch)
  "Return files in review scope for PROJECT-ROOT relative to BASE-BRANCH."

  (delete-dups
   (append
    (expose-review-context-tracked-changed-files
     project-root
     base-branch)

    ;; Untracked non-ignored files.
    (expose-review-context-untracked-files project-root))))

(defun expose-review-context-input-stats (context)
  "Return review input stats for CONTEXT."

  (let* ((untracked-contents
          (plist-get context :untracked-file-contents))

         (changed-file-contents
          (plist-get context :changed-file-contents))

         (untracked-bytes
          (apply
           #'+
           (mapcar
            (lambda (entry)
              (length
               (or
                (plist-get entry :content)
                "")))
            untracked-contents)))

         (changed-file-bytes
          (apply
           #'+
           (mapcar
            (lambda (entry)
              (length
               (or
                (plist-get entry :content)
                "")))
            changed-file-contents))))

    (list
     :changed-files
     (length
      (plist-get context :changed-files))

     :branch-diff-bytes
     (length
      (or
       (plist-get context :branch-diff)
       ""))

     :staged-diff-bytes
     (length
      (or
       (plist-get context :staged-diff)
       ""))

     :unstaged-diff-bytes
     (length
      (or
       (plist-get context :unstaged-diff)
       ""))

     :tracked-files-included
     (length changed-file-contents)

     :tracked-file-bytes
     changed-file-bytes

     :untracked-files
     (length
      (plist-get context :untracked-files))

     :untracked-included
     (length untracked-contents)

     :untracked-bytes
     untracked-bytes

     :hidden-untracked-files
     (length
      (plist-get context :hidden-untracked-files))

     :metadata-files
     (length
      (plist-get context :project-metadata))

     :diagnostic-files
     (length
      (plist-get
       (plist-get context :diagnostics)
       :python-files))

     :pyright-diagnostics
     (length
      (plist-get
       (plist-get
        (plist-get context :diagnostics)
        :pyright)
       :items))

     :ruff-diagnostics
     (length
      (plist-get
       (plist-get
        (plist-get context :diagnostics)
        :ruff)
       :items))
     :python-diagnostic-files
     (length
      (plist-get
       (plist-get context :diagnostics)
       :python-files))

     :frontend-diagnostic-files
     (length
      (plist-get
       (plist-get context :diagnostics)
       :frontend-files))

     :diagnostic-files
     (+
      (length
       (plist-get
        (plist-get context :diagnostics)
        :python-files))
      (length
       (plist-get
        (plist-get context :diagnostics)
        :frontend-files)))

     :typescript-diagnostics
     (length
      (plist-get
       (plist-get
        (plist-get context :diagnostics)
        :typescript)
       :items))

     :eslint-diagnostics
     (length
      (plist-get
       (plist-get
        (plist-get context :diagnostics)
        :eslint)
       :items))

     :diagnostics-total
     (length
      (plist-get
       (plist-get context :diagnostics)
       :items))
     )))

(defun expose-review-context-read-metadata-file (project-root relative-path)
  "Read RELATIVE-PATH from PROJECT-ROOT as review metadata."

  (let ((path
         (expand-file-name relative-path project-root)))

    (when (file-readable-p path)
      (with-temp-buffer
        (insert-file-contents
         path
         nil
         0
         expose-review-context-max-metadata-file-length)

        (list
         :file relative-path
         :content
         (buffer-string))))))

(defun expose-review-context-project-metadata (project-root)
  "Return project metadata for PROJECT-ROOT."

  (delq
   nil
   (mapcar
    (lambda (relative-path)
      (expose-review-context-read-metadata-file
       project-root
       relative-path))
    expose-review-context-metadata-files)))

(defun expose-review-context-build-local (project-root)
  "Build local review context for PROJECT-ROOT."

  (let* ((branch
          (expose-review-context-current-branch project-root))

         (base-branch
          (expose-review-context-detect-base-branch project-root))

         (merge-base
          (expose-review-context-merge-base
           project-root
           base-branch))

         (git-status
          (expose-review-context-call-git
           project-root
           "status"
           "--short"))

         (all-untracked-files
          (expose-review-context-all-untracked-files project-root))

         (untracked-files
          (seq-remove
           #'expose-review-context-hidden-path-p
           all-untracked-files))

         (hidden-untracked-files
          (seq-filter
           #'expose-review-context-hidden-path-p
           all-untracked-files))

         (changed-files
          (expose-review-context-changed-files
           project-root
           base-branch)))

    (list
     :project-root project-root
     :project-name
     (expose-review-context-project-name project-root)
     :branch branch
     :base-branch base-branch
     :merge-base merge-base
     :git-status git-status
     :changed-files changed-files
     :untracked-files untracked-files
     :hidden-untracked-files hidden-untracked-files
     )))

(defun expose-review-context-build-ai (project-root)
  "Build AI review context for PROJECT-ROOT."

  (let* ((local
          (expose-review-context-build-local project-root))

         (base-branch
          (plist-get local :base-branch))

         ;; Use --function-context so the model sees the surrounding
         ;; function/method when Git can identify it.
         (branch-diff
          (expose-review-context-call-git
           project-root
           "diff"
           "--relative"
           "--function-context"
           (format "%s...HEAD" base-branch)))

         (unstaged-diff
          (expose-review-context-call-git
           project-root
           "diff"
           "--relative"
           "--function-context"))

         (staged-diff
          (expose-review-context-call-git
           project-root
           "diff"
           "--cached"
           "--relative"
           "--function-context"))

         (commit-log
          (expose-review-context-call-git
           project-root
           "log"
           "--oneline"
           (format "%s..HEAD" base-branch)))

         (metadata
          (expose-review-context-project-metadata project-root))

         (changed-file-contents
          (expose-review-context-changed-file-contents
           project-root
           base-branch))

         (untracked-file-contents
          (expose-review-context-untracked-file-contents project-root))

         (diagnostics
          (expose-review-context-diagnostic-results
           project-root
           (plist-get local :changed-files)))

         (context
          (append
           local
           (list
            :branch-diff
            (expose-review-context-truncate
             branch-diff
             expose-review-context-max-diff-length)

            :unstaged-diff
            (expose-review-context-truncate
             unstaged-diff
             expose-review-context-max-diff-length)

            :staged-diff
            (expose-review-context-truncate
             staged-diff
             expose-review-context-max-diff-length)


            :commit-log commit-log
            :project-metadata metadata
            :changed-file-contents changed-file-contents
            :untracked-file-contents untracked-file-contents

            :diagnostics diagnostics
            ))))

    (plist-put
     context
     :review-input-stats
     (expose-review-context-input-stats context))))

(defun expose-review-context-create-session (project-root provider)
  "Create a new review session for PROJECT-ROOT using PROVIDER."

  (let ((local
         (expose-review-context-build-local project-root)))

    (append
     (list
      :version expose-review-session-version
      :id
      (format
       "%s-%s"
       (expose-review-store-branch-slug
        (plist-get local :branch))
       (format-time-string "%Y%m%dT%H%M%S"))
      :state 'running
      :provider provider
      :created-at
      (expose-review-context-now)
      :updated-at
      (expose-review-context-now)
      :items nil
      :error nil)
     local)))

(provide 'expose-review-context)
