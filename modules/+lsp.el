;;; ~/.doom.d/modes/lsp.el -*- lexical-binding: t; -*-

;;
;; LSP
;;

(after! lsp-mode
  (setq lsp-completion-provider :capf
        lsp-enable-snippet t)

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

