;;; ~/.doom.d/modes/lsp.el -*- lexical-binding: t; -*-

;;
;; LSP
;;

(after! lsp-mode
  (setq lsp-completion-provider :none)

  ;; Performance
  (setq lsp-headerline-breadcrumb-enable nil)
  (setq read-process-output-max (* 1024 1024)
        lsp-idle-delay 0.5
        lsp-log-io nil)

  ;; Python (recommended modern setup)
  (setq lsp-pyright-python-executable-cmd "python3")

  ;; Angular (no hardcoded Node paths)
  (setq lsp-angular-language-server-command
        '("npx" "@angular/language-server" "--stdio")))

(after! lsp-ui
  (setq lsp-ui-doc-delay 0.3
        lsp-ui-doc-position 'at-point))
