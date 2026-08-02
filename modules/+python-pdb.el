;;; modules/+python-pdb.el -*- lexical-binding: t; -*-

(require 'gud)
(require 'project)

(defgroup js/python-pdb nil
  "Python PDB integration."
  :group 'tools)

(defcustom js/python-pdb-python-command nil
  "Explicit Python executable used by PDB.

When nil, resolve Python from the current environment."
  :type '(choice (const :tag "Current environment" nil)
                 string)
  :group 'js/python-pdb)

(defcustom js/python-pdb-django-command
  '("manage.py" "runserver" "--noreload")
  "Arguments used to start Django under PDB."
  :type '(repeat string)
  :group 'js/python-pdb)

(defun js/python-pdb--project-root ()
  "Return the current project root."
  (if-let ((project (project-current)))
      (project-root project)
    default-directory))

(defun js/python-pdb--python ()
  "Return the Python executable to use."
  (or js/python-pdb-python-command
      (executable-find "python")
      (executable-find "python3")
      (user-error "Could not find a Python executable")))

(defun js/python-pdb--python-version ()
  "Return the configured Python version as a list.

For example, Python 3.13.4 returns `(3 13 4)`."
  (let* ((output
          (string-trim
           (shell-command-to-string
            (format "%s --version 2>&1"
                    (shell-quote-argument
                     (js/python-pdb--python))))))
         (version
          (and (string-match
                "Python \\([0-9]+\\)\\.\\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?"
                output)
               (list
                (string-to-number (match-string 1 output))
                (string-to-number (match-string 2 output))
                (string-to-number
                 (or (match-string 3 output) "0"))))))
    (or version
        (user-error "Could not determine Python version from: %s"
                    output))))

(defun js/python-pdb--supports-attach-p ()
  "Return non-nil when the configured Python supports PID attachment."
  (version-list-<= '(3 14 0)
                   (js/python-pdb--python-version)))

(defun js/python-pdb--shell-command (arguments)
  "Build a shell command from Python ARGUMENTS."
  (mapconcat #'shell-quote-argument
             (cons (js/python-pdb--python) arguments)
             " "))

(defun js/python-pdb--start (arguments)
  "Start PDB with Python ARGUMENTS."
  (let ((default-directory (js/python-pdb--project-root)))
    (pdb
     (js/python-pdb--shell-command
      (append '("-m" "pdb") arguments)))))

(defun js/python-pdb--buffer ()
  "Return the current live GUD PDB buffer."
  (cond
   ((and gud-comint-buffer
         (buffer-live-p gud-comint-buffer))
    gud-comint-buffer)
   ((get-buffer "*gud-pdb*"))
   (t nil)))

(defun js/python-pdb--require-session ()
  "Return the active PDB buffer or signal an error."
  (let ((buffer
         (cond
          ((and gud-comint-buffer
                (buffer-live-p gud-comint-buffer))
           gud-comint-buffer)
          ((get-buffer "*gud-pdb*"))
          (t nil))))
    (unless (and buffer
                 (process-live-p (get-buffer-process buffer)))
      (user-error "No active PDB session"))
    buffer))

(defun js/python-pdb--send-command (command)
  "Send COMMAND directly to the active PDB process."
  (let* ((buffer (js/python-pdb--require-session))
         (process (get-buffer-process buffer)))
    (comint-send-string process (concat command "\n"))))

(defun js/python-pdb--expression-at-point ()
  "Return the active region or Python expression at point."
  (let ((expression
         (cond
          ((use-region-p)
           (buffer-substring-no-properties
            (region-beginning)
            (region-end)))
          ((thing-at-point 'symbol t))
          (t nil))))
    (setq expression
          (and expression
               (string-trim expression)))

    (when (or (null expression)
              (string-empty-p expression))
      (setq expression
            (read-string "PDB expression: ")))

    (when (string-match-p "[\n\r]" expression)
      (user-error "PDB expression cannot contain a newline"))

    expression))

;;;###autoload
(defun js/python-pdb-file ()
  "Start PDB on the current buffer's file."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (js/python-pdb--start
   (list (expand-file-name buffer-file-name))))

;;;###autoload
(defun js/python-pdb-django ()
  "Start PDB wrapping the Django dev server.

Uses `js/python-pdb-django-command'."
  (interactive)
  (js/python-pdb--start js/python-pdb-django-command))

;;;###autoload
(defun js/python-pdb-attach (pid)
  "Attach PDB to the running process PID.

Requires Python 3.14 or newer."
  (interactive
   (list (read-number "PID to attach to: ")))
  (unless (js/python-pdb--supports-attach-p)
    (user-error "PDB attach requires Python 3.14 or newer"))
  (js/python-pdb--start
   (list "-p" (number-to-string pid))))

;;;###autoload
(defun js/python-pdb-command (command)
  "Send an arbitrary COMMAND to the active PDB session."
  (interactive
   (list (read-string "PDB command: ")))
  (js/python-pdb--send-command command))

;;;###autoload
(defun js/python-pdb-stop ()
  "Stop the active PDB session."
  (interactive)
  (js/python-pdb--send-command "quit"))

;;;###autoload
(defun js/python-pdb-break ()
  "Set a PDB breakpoint at the current source line."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (js/python-pdb--send-command
   (format "break %s:%d"
           (expand-file-name buffer-file-name)
           (line-number-at-pos))))

;;;###autoload
(defun js/python-pdb-next ()
  "Execute the next source line."
  (interactive)
  (js/python-pdb--send-command "next"))

;;;###autoload
(defun js/python-pdb-step ()
  "Step into the next function call."
  (interactive)
  (js/python-pdb--send-command "step"))

;;;###autoload
(defun js/python-pdb-continue ()
  "Continue execution."
  (interactive)
  (js/python-pdb--send-command "continue"))

;;;###autoload
(defun js/python-pdb-finish ()
  "Continue until the current function returns."
  (interactive)
  (js/python-pdb--send-command "return"))

;;;###autoload
(defun js/python-pdb-up ()
  "Move to the next outer stack frame."
  (interactive)
  (js/python-pdb--send-command "up"))

;;;###autoload
(defun js/python-pdb-down ()
  "Move to the next inner stack frame."
  (interactive)
  (js/python-pdb--send-command "down"))

;;;###autoload
(defun js/python-pdb-print (expression)
  "Evaluate EXPRESSION in the current PDB stack frame."
  (interactive
   (list (js/python-pdb--expression-at-point)))
  (js/python-pdb--send-command
   (concat "p " expression)))

(map! :leader
      (:prefix-map ("d" . "debug")
       (:prefix ("P" . "pdb")
        :desc "PDB current file" "p" #'js/python-pdb-file
        :desc "PDB Django"     "d" #'js/python-pdb-django
        :desc "PDB attach"     "a" #'js/python-pdb-attach
        :desc "PDB command"    "x" #'js/python-pdb-command
        :desc "PDB stop"       "q" #'js/python-pdb-stop
        :desc "Breakpoint"     "b" #'js/python-pdb-break
        :desc "Next"           "n" #'js/python-pdb-next
        :desc "Step"           "s" #'js/python-pdb-step
        :desc "Continue"       "c" #'js/python-pdb-continue
        :desc "Finish"         "r" #'js/python-pdb-finish
        :desc "Stack up"       "u" #'js/python-pdb-up
        :desc "Stack down"     "D" #'js/python-pdb-down
        :desc "Evaluate"       "e" #'js/python-pdb-print)))

(provide '+python-pdb)
