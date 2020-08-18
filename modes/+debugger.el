;;; ~/.doom.d/modes/debugger.el -*- lexical-binding: t; -*-

;;
;; Debugger
;;

(after! dap-mode
  (require 'dap-chrome)
  (dap-ui-mode 1)
  (dap-tooltip-mode 1)
  (tooltip-mode 1))


(defun my/window-visible (b-name)
  "Return whether B-NAME is visible."
  (-> (-compose 'buffer-name 'window-buffer)
      (-map (window-list))
      (-contains? b-name)))


(defun my/show-debug-windows (session)
  "Show debug windows."
  (let ((lsp--cur-workspace (dap--debug-session-workspace session)))
    (save-excursion
      ;; display locals
      (unless (my/window-visible dap-ui--locals-buffer)
        (dap-ui-locals))
      ;; display sessions
      ;; (unless (my/window-visible dap-ui--sessions-buffer)
      ;;   (dap-ui-sessions))
      ;; display breakpoints
      ;; (unless (my/window-visible dap-ui--breakpoints-buffer)
      ;;   (dap-ui-breakpoints))
      )))

(add-hook! 'dap-stopped-hook 'my/show-debug-windows)

(defun my/hide-debug-windows (session)
  "Hide debug windows when all debug sessions are dead."
  (unless (-filter 'dap--session-running (dap--get-sessions))
    ;; (and (get-buffer dap-ui--sessions-buffer)
    ;;      (kill-buffer dap-ui--sessions-buffer))
    (and (get-buffer dap-ui--breakpoints-buffer)
         (kill-buffer dap-ui--breakpoints-buffer))
    (and (get-buffer dap-ui--locals-buffer)
         (kill-buffer dap-ui--locals-buffer))))

(add-hook! 'dap-terminated-hook 'my/hide-debug-windows)
