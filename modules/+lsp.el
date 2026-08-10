;;; modules/+lsp.el -*- lexical-binding: t; -*-

(after! lsp-mode
  (setq lsp-completion-provider :capf
        lsp-enable-snippet t
        lsp-enable-symbol-highlighting t

        ;; Performance
        lsp-headerline-breadcrumb-enable nil
        read-process-output-max (* 1024 1024)
        lsp-idle-delay 0.5
        lsp-log-io nil

        ;; Python
        lsp-pyright-python-executable-cmd "python"
        lsp-pyright-disable-tagged-hints t

        ;; Angular
        lsp-angular-language-server-command
        '("ngserver" "--stdio"
          "--tsProbeLocations" "."
          "--ngProbeLocations" "."))

  (add-to-list
   'lsp-language-id-configuration
   '(html-ts-mode . "html")))

(after! lsp-ui
  ;; Expose is the hover/documentation UI now.
  ;; Keep LSP diagnostics available, but disable competing visual popups/text.
  (setq lsp-ui-doc-enable nil
        lsp-ui-doc-show-with-cursor nil
        lsp-ui-doc-show-with-mouse nil

        ;; Every specific sideline feature is disabled below, so there's
        ;; nothing left for the sideline itself to show -- keep it off
        ;; too, rather than leaving it enabled with nothing to display.
        lsp-ui-sideline-enable nil
        lsp-ui-sideline-show-hover nil
        lsp-ui-sideline-show-diagnostics nil
        lsp-ui-sideline-show-code-actions nil))
