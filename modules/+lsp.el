;;; ~/.doom.d/modes/lsp.el -*- lexical-binding: t; -*-

;;
;; LSP
;;

(after! lsp-mode
  (setq lsp-completion-provider :capf)

  ;; Performance
  (setq lsp-headerline-breadcrumb-enable nil
        read-process-output-max (* 1024 1024)
        lsp-idle-delay 0.5
        lsp-log-io nil)

  ;; Disable conflicting HTML server
  (setq lsp-disabled-clients '(html-ls))

  (add-to-list 'lsp-language-id-configuration
               '(html-ts-mode . "html"))

  ;; Python
  (setq lsp-pyright-python-executable-cmd "python3")

  ;; Angular (stable command)
  (setq lsp-angular-language-server-command
        '("ngserver" "--stdio"
          "--tsProbeLocations" "."
          "--ngProbeLocations" ".")))

(after! lsp-ui
  (setq lsp-ui-doc-delay 0.3
        lsp-ui-doc-position 'at-point))

(defun my/angular-ensure-ts-loaded ()
  (when (and buffer-file-name
             (string-match "\\.html\\'" buffer-file-name))
    (let ((ts-file (replace-regexp-in-string "\\.html\\'" ".ts" buffer-file-name)))
      (when (file-exists-p ts-file)
        (find-file-noselect ts-file)))))

(add-hook 'typescript-ts-mode-hook #'lsp-deferred)

(add-hook 'html-ts-mode-hook #'my/angular-ensure-ts-loaded)

(add-hook 'html-ts-mode-hook
          (lambda ()
            (when (projectile-project-p)
              (lsp-deferred))))
