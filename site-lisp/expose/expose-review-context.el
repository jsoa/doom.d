;;; expose-review-context.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'expose-log)
(require 'expose-review-store)

(defcustom expose-review-base-branch nil
  "Base branch used for Expose code review.

When nil, Expose tries `origin/main', `main', `origin/master', then `master'."
  :type '(choice
          (const nil)
          string)
  :group 'expose-review)

(defcustom expose-review-base-branch-candidates
  '("origin/main"
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
    ".github/copilot-instructions.md"
    "pyproject.toml"
    "package.json")
  "Project metadata files included in Expose review context when present."
  :type '(repeat string)
  :group 'expose-review)

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

(defun expose-review-context-detect-base-branch (project-root)
  "Return the base branch for PROJECT-ROOT."

  (or
   expose-review-base-branch

   (seq-find
    (lambda (candidate)
      (expose-review-context-ref-exists-p
       project-root
       candidate))
    expose-review-base-branch-candidates)

   "HEAD~1"))

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
  "Return changed files for PROJECT-ROOT relative to BASE-BRANCH plus dirty files."

  (delete-dups
   (append
    (expose-review-context-lines
     (expose-review-context-call-git
      project-root
      "diff"
      "--name-only"
      (format "%s...HEAD" base-branch)))

    (expose-review-context-lines
     (expose-review-context-call-git
      project-root
      "diff"
      "--name-only"))

    (expose-review-context-lines
     (expose-review-context-call-git
      project-root
      "diff"
      "--cached"
      "--name-only")))))

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
     :changed-files changed-files)))

(defun expose-review-context-build-ai (project-root)
  "Build AI review context for PROJECT-ROOT."

  (let* ((local
          (expose-review-context-build-local project-root))

         (base-branch
          (plist-get local :base-branch))

         (branch-diff
          (expose-review-context-call-git
           project-root
           "diff"
           "--relative"
           (format "%s...HEAD" base-branch)))

         (unstaged-diff
          (expose-review-context-call-git
           project-root
           "diff"
           "--relative"))

         (staged-diff
          (expose-review-context-call-git
           project-root
           "diff"
           "--cached"
           "--relative"))

         (commit-log
          (expose-review-context-call-git
           project-root
           "log"
           "--oneline"
           (format "%s..HEAD" base-branch)))

         (metadata
          (expose-review-context-project-metadata project-root)))

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
      :project-metadata metadata))))

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
