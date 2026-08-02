;;; modules/+python-debug.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'project)

(defgroup jsoa/python-debug nil
  "Python and Django debugging through Dape."
  :group 'tools)

(defcustom jsoa/python-debug-python-command "python"
  "Python executable used to launch debugpy.

The executable must resolve inside the environment inherited by Emacs.
For pyenv or direnv projects, this will normally remain `python'."
  :type 'string
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-manage-py "manage.py"
  "Path to manage.py relative to the project root."
  :type 'string
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-server-address "127.0.0.1:8086"
  "Address passed to Django's runserver command."
  :type 'string
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-django-settings-module nil
  "Optional Django settings module.

When non-nil, DJANGO_SETTINGS_MODULE is added to the debugged process
environment."
  :type '(choice (const :tag "Use project default" nil)
          string)
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-environment nil
  "Additional environment variables for the debugged process.

This must be a property list. For example:

  (:DJANGO_CONFIGURATION \"Development\"
   :MY_SETTING \"value\")"
  :type '(repeat sexp)
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-just-my-code t
  "When non-nil, avoid stepping into third-party Python libraries."
  :type 'boolean
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-stop-on-entry nil
  "When non-nil, stop when the Django process starts."
  :type 'boolean
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-attach nil
  "When non-nil, attach to an existing debugpy server.

When nil, Dape launches Django locally. Enable this on machines where
Django is started externally, such as through Docker Compose."
  :type 'boolean
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-attach-host "127.0.0.1"
  "Host used when attaching to an existing debugpy server."
  :type 'string
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-attach-port 5678
  "Port used when attaching to an existing debugpy server."
  :type 'integer
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-remote-root nil
  "Project root as seen by the remote Python process.

When nil, local and remote paths are assumed to be identical. For a
Docker container where the project is mounted at /code, set this to
\"/code/\"."
  :type '(choice
          (const :tag "Same paths as local machine" nil)
          string)
  :group 'jsoa/python-debug)

(defcustom jsoa/python-debug-window-arrangement 'right
  "Window arrangement used by Dape.

Common values are `right', `left', and `gud'."
  :type '(choice
          (const :tag "Right side" right)
          (const :tag "Left side" left)
          (const :tag "GUD-style" gud))
  :group 'jsoa/python-debug)

(defun jsoa/python-debug--project-root ()
  "Return the current project root as an absolute directory."
  (or (when-let ((project (project-current nil)))
        (expand-file-name (project-root project)))
      (when (fboundp 'doom-project-root)
        (when-let ((root (doom-project-root)))
          (expand-file-name root)))
      (user-error "Current buffer is not inside a recognized project")))

(defun jsoa/python-debug--manage-py ()
  "Return the absolute path to the configured manage.py."
  (let ((path
         (expand-file-name
          jsoa/python-debug-manage-py
          (jsoa/python-debug--project-root))))
    (unless (file-exists-p path)
      (user-error "Django manage.py was not found at %s" path))
    path))

(defun jsoa/python-debug--environment ()
  "Return the environment plist for the debugged Django process."
  (let ((environment (copy-sequence jsoa/python-debug-environment)))
    (when jsoa/python-debug-django-settings-module
      (setq environment
            (plist-put
             environment
             :DJANGO_SETTINGS_MODULE
             jsoa/python-debug-django-settings-module)))
    environment))

(defun jsoa/python-debug--launch-configuration (&optional include-library-code)
  "Build a complete Dape plist for local Django debugging.

When INCLUDE-LIBRARY-CODE is non-nil, permit stepping into third-party
Python libraries."
  (let ((root (jsoa/python-debug--project-root)))
    `(command ,jsoa/python-debug-python-command
      command-args ("-m"
                    "debugpy.adapter"
                    "--host"
                    "127.0.0.1"
                    "--port"
                    :autoport)
      command-cwd ,root
      port :autoport

      :request "launch"
      :type "python"
      :cwd ,root
      :program ,(jsoa/python-debug--manage-py)
      :args ["runserver"
             ,jsoa/python-debug-server-address
             "--noreload"]
      :django t
      :justMyCode ,(and (not include-library-code)
                        jsoa/python-debug-just-my-code)
      :stopOnEntry ,jsoa/python-debug-stop-on-entry
      :showReturnValue t
      :terminateDebuggee nil
      :console "integratedTerminal"

      ,@(when-let ((environment (jsoa/python-debug--environment)))
          `(:env ,environment)))))

(defun jsoa/python-debug--attach-configuration
    (&optional include-library-code)
  "Build a Dape configuration that attaches to debugpy.

When INCLUDE-LIBRARY-CODE is non-nil, permit stepping into third-party
Python libraries."
  (let ((local-root
         (file-name-as-directory
          (jsoa/python-debug--project-root))))
    `(host ,jsoa/python-debug-attach-host
      port ,jsoa/python-debug-attach-port

      :request "attach"
      :type "python"
      :justMyCode ,(and (not include-library-code)
                        jsoa/python-debug-just-my-code)
      :terminateDebuggee nil
      :showReturnValue t

      ,@(when jsoa/python-debug-remote-root
          `(:pathMappings
            [(:localRoot
              ,local-root
              :remoteRoot
              ,(file-name-as-directory
                jsoa/python-debug-remote-root))])))))

(defun jsoa/python-debug--configuration
    (&optional include-library-code)
  "Build the configured Django Dape configuration.

Attach to an existing debugpy server when
`jsoa/python-debug-attach' is non-nil. Otherwise, launch Django locally."
  (if jsoa/python-debug-attach
      (jsoa/python-debug--attach-configuration
       include-library-code)
    (jsoa/python-debug--launch-configuration
     include-library-code)))

(defun jsoa/python-debug--require-dape ()
  "Load Dape or report a useful configuration error."
  (unless (require 'dape nil t)
    (user-error
     "Dape is unavailable; enable Doom's :tools debugger module and run doom sync")))

(defun jsoa/python-debug-start ()
  "Start or attach to the current Django debug session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (save-some-buffers t)
  (dape (jsoa/python-debug--configuration)))

(defun jsoa/python-debug-start-framework ()
  "Start or attach while allowing third-party library debugging."
  (interactive)
  (jsoa/python-debug--require-dape)
  (save-some-buffers t)
  (dape (jsoa/python-debug--configuration t)))

(defun jsoa/python-debug-toggle-breakpoint ()
  "Toggle a breakpoint on the current source line."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-breakpoint-toggle))

(defun jsoa/python-debug-conditional-breakpoint ()
  "Set or edit a conditional breakpoint on the current line."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-breakpoint-expression))

(defun jsoa/python-debug-log-breakpoint ()
  "Set or edit a log breakpoint on the current line."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-breakpoint-log))

(defun jsoa/python-debug-delete-all-breakpoints ()
  "Delete every Dape breakpoint."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-breakpoint-remove-all))

(defun jsoa/python-debug-continue ()
  "Continue execution of the selected debug session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-continue))

(defun jsoa/python-debug-pause ()
  "Pause execution of the selected debug session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-pause))

(defun jsoa/python-debug-step-over ()
  "Execute the current line without entering called functions."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-next))

(defun jsoa/python-debug-step-in ()
  "Step into the function called on the current line."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-step-in))

(defun jsoa/python-debug-step-out ()
  "Continue until the current function returns."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-step-out))

(defun jsoa/python-debug-restart ()
  "Restart the selected or most recent debug session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-restart))

(defun jsoa/python-debug--detach (conn)
  "Disconnect CONN without terminating its debuggee."
  (when (and conn (jsonrpc-running-p conn))
    (dape--with-request
        (dape-request conn
                      :disconnect
                      '(:restart :json-false
                        :terminateDebuggee :json-false))
      (dape--shutdown conn))))

(defun jsoa/python-debug-stop ()
  "Stop the current Dape session.

Detach without terminating the debuggee for attach sessions.
Terminate normally for sessions launched by Dape."
  (interactive)
  (jsoa/python-debug--require-dape)
  (if jsoa/python-debug-attach
      (let ((conn (dape--live-connection 'parent)))
        (if conn
            (jsoa/python-debug--detach conn)
          (user-error "No active Dape connection")))
    (call-interactively #'dape-quit)))

(defun jsoa/python-debug-toggle-watch ()
  "Add or remove a watch expression.

The active region or symbol at point is offered as the default."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-watch-dwim))

(defun jsoa/python-debug-show-info ()
  "Display Dape's variables, watches, stack, and breakpoint buffers."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-info))

(defun jsoa/python-debug-select-session ()
  "Select another active Dape session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-select-session))

(defun jsoa/python-debug-select-thread ()
  "Select a thread in the current debug session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-select-thread))

(defun jsoa/python-debug-select-stack-frame ()
  "Select a stack frame in the current debug session."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-select-stack))

(defun jsoa/python-debug-stack-up ()
  "Select the next older stack frame."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-stack-select-up))

(defun jsoa/python-debug-stack-down ()
  "Select the next newer stack frame."
  (interactive)
  (jsoa/python-debug--require-dape)
  (call-interactively #'dape-stack-select-down))

(defun jsoa/python-debug-evaluate ()
  "Open Dape's REPL for evaluating expressions in the selected frame.

When a region is active, copy its text into the REPL input area without
executing it. Otherwise, open the REPL and place point at its prompt."
  (interactive)
  (jsoa/python-debug--require-dape)

  (let ((expression
         (when (use-region-p)
           (buffer-substring-no-properties
            (region-beginning)
            (region-end)))))
    (dape-repl)

    (when expression
      (goto-char (point-max))
      (insert expression))))

(defcustom jsoa/python-debug-panel-height 18
  "Height of the debugger panels opened below the source window."
  :type 'integer
  :group 'jsoa/python-debug)

(defvar jsoa/python-debug--ui-opened nil
  "Non-nil after the debugger UI has been arranged.")

(defvar jsoa/python-debug--ui-opening nil
  "Non-nil while the debugger UI is being arranged.")

(defvar jsoa/python-debug--window-configuration nil
  "Window configuration saved before the first Dape session starts.")

(defun jsoa/python-debug--configure-repl-buffer ()
  "Configure Dape's REPL for unrestricted evaluation output.

This changes variable rendering only in the current REPL buffer.
The compact column limits used by Locals and Watch remain unchanged."
  (setq-local
   dape-info-variable-table-row-config
   '((name . 0)
     (value . 0)
     (type . 0)))

  ;; Wrap long results instead of hiding them beyond the window edge.
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

(defun jsoa/python-debug--capture-window-configuration ()
  "Save the current window configuration unless one is already saved."
  (unless (window-configuration-p
           jsoa/python-debug--window-configuration)
    (setq jsoa/python-debug--window-configuration
          (current-window-configuration))))

(defun jsoa/python-debug--restore-window-configuration ()
  "Restore the window configuration saved before debugging started."
  (let ((configuration jsoa/python-debug--window-configuration))
    (setq jsoa/python-debug--window-configuration nil
          jsoa/python-debug--ui-opened nil
          jsoa/python-debug--ui-opening nil)

    (when (window-configuration-p configuration)
      (condition-case error-data
          (set-window-configuration configuration)
        (error
         (message
          "Unable to restore debugger window layout: %s"
          (error-message-string error-data)))))))

(defun jsoa/python-debug--reset-ui-state ()
  "Prepare the custom UI before the first Dape session starts.

`dape-start-hook' runs before Dape creates its connection. When Dape is
already active, another session is being added and the existing shared
debugger UI should remain in place."
  (unless dape-active-mode
    (setq jsoa/python-debug--ui-opened nil
          jsoa/python-debug--ui-opening nil)
    (jsoa/python-debug--capture-window-configuration)))

(defun jsoa/python-debug--maybe-restore-window-configuration ()
  "Restore the previous layout after the final Dape session ends.

Dape briefly disables `dape-active-mode' during some restart paths, so
the layout is restored only when its connection list is also empty."
  (when (and (not dape-active-mode)
             (or (not (boundp 'dape--connections))
                 (null (symbol-value 'dape--connections))))
    (jsoa/python-debug--restore-window-configuration)))

(defun jsoa/python-debug--buffer-with-mode (mode)
  "Return the first live buffer whose major mode derives from MODE."
  (cl-find-if
   (lambda (buffer)
     (with-current-buffer buffer
       (derived-mode-p mode)))
   (buffer-list)))

(defun jsoa/python-debug--locals-buffer ()
  "Return Dape's first scope buffer, normally the Locals buffer."
  (or (when (fboundp 'dape--info-get-live-buffer)
        (dape--info-get-live-buffer
         'dape-info-scope-mode
         0))
      (jsoa/python-debug--buffer-with-mode
       'dape-info-scope-mode)))

(defun jsoa/python-debug--delete-buffer-windows (buffer)
  "Delete all deletable windows displaying BUFFER."
  (when (buffer-live-p buffer)
    (dolist (window (get-buffer-window-list buffer nil t))
      (when (and (window-live-p window)
                 (window-deletable-p window))
        (delete-window window)))))

(defun jsoa/python-debug--open-panels ()
  "Display Dape information and REPL panels side by side.

The information panel is placed at the bottom left and the REPL at the
bottom right. The currently selected source window remains above them.
Return non-nil when the layout was created."
  (when dape-active-mode
    ;; Create and update both buffers without selecting them.
    (dape-info)
    (dape-repl)

    (let ((info-buffer
           (jsoa/python-debug--locals-buffer))
          (repl-buffer
           (get-buffer "*dape-repl*")))

      (unless (buffer-live-p info-buffer)
        (user-error "Dape locals buffer could not be found"))

      (unless (buffer-live-p repl-buffer)
        (user-error "Dape REPL buffer could not be found"))

      ;; Remove Dape's automatically displayed windows while retaining
      ;; their buffers and the selected source window.
      (jsoa/python-debug--delete-buffer-windows info-buffer)
      (jsoa/python-debug--delete-buffer-windows repl-buffer)

      (let* ((source-window (selected-window))
             (source-height (window-total-height source-window))
             (requested-height
              (min jsoa/python-debug-panel-height
                   (max 8 (/ source-height 2))))
             (info-window
              (split-window
               source-window
               (- requested-height)
               'below))
             (repl-window
              (split-window info-window nil 'right)))

        (set-window-buffer info-window info-buffer)
        (set-window-buffer repl-window repl-buffer)
        (select-window source-window)
        t))))

(defun jsoa/python-debug--finish-opening-panels ()
  "Finish opening the custom debugger panels after Dape has stopped."
  (unwind-protect
      (when (jsoa/python-debug--open-panels)
        (setq jsoa/python-debug--ui-opened t))
    (setq jsoa/python-debug--ui-opening nil)))

(defun jsoa/python-debug--open-panels-on-first-stop ()
  "Open the debugger panels the first time execution stops."
  (unless (or jsoa/python-debug--ui-opened
              jsoa/python-debug--ui-opening)
    (setq jsoa/python-debug--ui-opening t)

    ;; Let Dape finish updating scopes and stack frames first.
    (run-at-time
     0 nil
     #'jsoa/python-debug--finish-opening-panels)))

(after! dape
  (setq dape-buffer-window-arrangement
        jsoa/python-debug-window-arrangement

        ;; Keep long values out of source buffers.
        dape-inlay-hints nil

        ;; Use one tabbed information panel.
        dape-info-buffer-window-groups
        '((dape-info-scope-mode
           dape-info-watch-mode
           dape-info-stack-mode
           dape-info-breakpoints-mode
           dape-info-threads-mode
           dape-info-modules-mode
           dape-info-sources-mode))

        ;; Keep Locals and Watch compact.
        dape-info-variable-table-aligned t

        dape-info-variable-table-row-config
        '((name . 24)
          (value . 80)
          (type . 24))

        dape-variable-auto-expand-alist
        '((0 . 1)
          (hover . 1)
          (repl . 0)
          (watch . 1)))

  ;; Do not show Dape's default windows at process startup. The custom
  ;; two-panel layout opens when execution first stops.
  (remove-hook 'dape-start-hook #'dape-repl)
  (remove-hook 'dape-start-hook #'dape-info)

  (add-hook 'dape-repl-mode-hook
            #'jsoa/python-debug--configure-repl-buffer)

  (add-hook 'dape-start-hook
            #'jsoa/python-debug--reset-ui-state)

  (add-hook 'dape-stopped-hook
            #'jsoa/python-debug--open-panels-on-first-stop)

  (add-hook 'dape-active-mode-hook
            #'jsoa/python-debug--maybe-restore-window-configuration)

  (add-hook 'python-mode-hook
            #'eldoc-mode)

  (add-hook 'python-ts-mode-hook
            #'eldoc-mode))

(map!
 :leader
 (:prefix-map
  ("d" . "debug")

  :desc "Start Python debugger"
  "d" #'jsoa/python-debug-start

  :desc "Start Python debugger with libraries"
  "D" #'jsoa/python-debug-start-framework

  :desc "Toggle breakpoint"
  "b" #'jsoa/python-debug-toggle-breakpoint

  :desc "Conditional breakpoint"
  "C" #'jsoa/python-debug-conditional-breakpoint

  :desc "Log breakpoint"
  "L" #'jsoa/python-debug-log-breakpoint

  :desc "Delete all breakpoints"
  "B" #'jsoa/python-debug-delete-all-breakpoints

  :desc "Continue"
  "c" #'jsoa/python-debug-continue

  :desc "Pause"
  "p" #'jsoa/python-debug-pause

  :desc "Step over"
  "n" #'jsoa/python-debug-step-over

  :desc "Step in"
  "i" #'jsoa/python-debug-step-in

  :desc "Step out"
  "o" #'jsoa/python-debug-step-out

  :desc "Restart"
  "r" #'jsoa/python-debug-restart

  :desc "Stop debugging"
  "q" #'jsoa/python-debug-stop

  :desc "Evaluate expression"
  "e" #'jsoa/python-debug-evaluate

  :desc "Toggle watch"
  "w" #'jsoa/python-debug-toggle-watch

  :desc "Show debugger info"
  "l" #'jsoa/python-debug-show-info

  :desc "Select session"
  "s" #'jsoa/python-debug-select-session

  :desc "Select thread"
  "t" #'jsoa/python-debug-select-thread

  :desc "Select stack frame"
  "f" #'jsoa/python-debug-select-stack-frame

  :desc "Older stack frame"
  "u" #'jsoa/python-debug-stack-up

  :desc "Newer stack frame"
  "j" #'jsoa/python-debug-stack-down))

(provide '+python-debug)
