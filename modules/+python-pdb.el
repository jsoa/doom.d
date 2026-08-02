;;; modules/+python-pdb.el -*- lexical-binding: t; -*-

(require 'gud)
(require 'project)

(defgroup jsoa/python-pdb nil
  "Python PDB integration."
  :group 'tools)

(defcustom jsoa/python-pdb-python-command nil
  "Explicit Python executable used by PDB.

When nil, resolve Python from the current environment."
  :type '(choice (const :tag "Current environment" nil)
                 string)
  :group 'jsoa/python-pdb)

(defcustom jsoa/python-pdb-django-command
  '("manage.py" "runserver" "--noreload")
  "Arguments used to start Django under PDB."
  :type '(repeat string)
  :group 'jsoa/python-pdb)

(defun jsoa/python-pdb--project-root ()
  "Return the current project root."
  (if-let ((project (project-current)))
      (project-root project)
    default-directory))

(defun jsoa/python-pdb--python ()
  "Return the Python executable to use."
  (or jsoa/python-pdb-python-command
      (executable-find "python")
      (executable-find "python3")
      (user-error "Could not find a Python executable")))

(defun jsoa/python-pdb--python-version ()
  "Return the configured Python version as a list.

For example, Python 3.13.4 returns `(3 13 4)`."
  (let* ((output
          (string-trim
           (shell-command-to-string
            (format "%s --version 2>&1"
                    (shell-quote-argument
                     (jsoa/python-pdb--python))))))
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

(defun jsoa/python-pdb--supports-attach-p ()
  "Return non-nil when the configured Python supports PID attachment."
  (version-list-<= '(3 14 0)
                   (jsoa/python-pdb--python-version)))

(defun jsoa/python-pdb--shell-command (arguments)
  "Build a shell command from Python ARGUMENTS."
  (mapconcat #'shell-quote-argument
             (cons (jsoa/python-pdb--python) arguments)
             " "))

(defun jsoa/python-pdb--start (arguments)
  "Start PDB with Python ARGUMENTS."
  (let ((default-directory (jsoa/python-pdb--project-root)))
    (pdb
     (jsoa/python-pdb--shell-command
      (append '("-m" "pdb") arguments)))))

(defun jsoa/python-pdb--buffer ()
  "Return the current live GUD PDB buffer."
  (cond
   ((and gud-comint-buffer
         (buffer-live-p gud-comint-buffer))
    gud-comint-buffer)
   ((get-buffer "*gud-pdb*"))
   (t nil)))

(defun jsoa/python-pdb--require-session ()
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

(defun jsoa/python-pdb--send-command (command)
  "Send COMMAND directly to the active PDB process."
  (let* ((buffer (jsoa/python-pdb--require-session))
         (process (get-buffer-process buffer)))
    (comint-send-string process (concat command "\n"))))

(defun jsoa/python-pdb--expression-at-point ()
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
(defun jsoa/python-pdb-file ()
  "Start PDB on the current buffer's file."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (jsoa/python-pdb--start
   (list (expand-file-name buffer-file-name))))

;;;###autoload
(defun jsoa/python-pdb-django ()
  "Start PDB wrapping the Django dev server.

Uses `jsoa/python-pdb-django-command'."
  (interactive)
  (jsoa/python-pdb--start jsoa/python-pdb-django-command))

;;;###autoload
(defun jsoa/python-pdb-attach (pid)
  "Attach PDB to the running process PID.

Requires Python 3.14 or newer."
  (interactive
   (list (read-number "PID to attach to: ")))
  (unless (jsoa/python-pdb--supports-attach-p)
    (user-error "PDB attach requires Python 3.14 or newer"))
  (jsoa/python-pdb--start
   (list "-p" (number-to-string pid))))

;;;###autoload
(defun jsoa/python-pdb-command (command)
  "Send an arbitrary COMMAND to the active PDB session."
  (interactive
   (list (read-string "PDB command: ")))
  (jsoa/python-pdb--send-command command))

;;;###autoload
(defun jsoa/python-pdb-stop ()
  "Stop the active PDB session."
  (interactive)
  (jsoa/python-pdb--send-command "quit"))

;;;###autoload
(defun jsoa/python-pdb-break ()
  "Set a PDB breakpoint at the current source line."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (jsoa/python-pdb--send-command
   (format "break %s:%d"
           (expand-file-name buffer-file-name)
           (line-number-at-pos))))

;;;###autoload
(defun jsoa/python-pdb-next ()
  "Execute the next source line."
  (interactive)
  (jsoa/python-pdb--send-command "next"))

;;;###autoload
(defun jsoa/python-pdb-step ()
  "Step into the next function call."
  (interactive)
  (jsoa/python-pdb--send-command "step"))

;;;###autoload
(defun jsoa/python-pdb-continue ()
  "Continue execution."
  (interactive)
  (jsoa/python-pdb--send-command "continue"))

;;;###autoload
(defun jsoa/python-pdb-finish ()
  "Continue until the current function returns."
  (interactive)
  (jsoa/python-pdb--send-command "return"))

;;;###autoload
(defun jsoa/python-pdb-up ()
  "Move to the next outer stack frame."
  (interactive)
  (jsoa/python-pdb--send-command "up"))

;;;###autoload
(defun jsoa/python-pdb-down ()
  "Move to the next inner stack frame."
  (interactive)
  (jsoa/python-pdb--send-command "down"))

;;;###autoload
(defun jsoa/python-pdb-print (expression)
  "Evaluate EXPRESSION in the current PDB stack frame."
  (interactive
   (list (jsoa/python-pdb--expression-at-point)))
  (jsoa/python-pdb--send-command
   (concat "p " expression)))

(map! :leader
      (:prefix-map ("d" . "debug")
       (:prefix ("P" . "pdb")
        :desc "PDB current file" "p" #'jsoa/python-pdb-file
        :desc "PDB Django"     "d" #'jsoa/python-pdb-django
        :desc "PDB attach"     "a" #'jsoa/python-pdb-attach
        :desc "PDB command"    "x" #'jsoa/python-pdb-command
        :desc "PDB stop"       "q" #'jsoa/python-pdb-stop
        :desc "Breakpoint"     "b" #'jsoa/python-pdb-break
        :desc "Next"           "n" #'jsoa/python-pdb-next
        :desc "Step"           "s" #'jsoa/python-pdb-step
        :desc "Continue"       "c" #'jsoa/python-pdb-continue
        :desc "Finish"         "r" #'jsoa/python-pdb-finish
        :desc "Stack up"       "u" #'jsoa/python-pdb-up
        :desc "Stack down"     "D" #'jsoa/python-pdb-down
        :desc "Evaluate"       "e" #'jsoa/python-pdb-print)))

(provide '+python-pdb)
