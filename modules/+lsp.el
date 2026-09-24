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

        ;; `lsp-pyright-multi-root' defaults to t, which folds every
        ;; project ever visited in the session into ONE shared pyright
        ;; server -- genesis, greyhound, and whatever else happens to
        ;; still be open, each getting its own "service instance" but
        ;; all sharing one process's startup queue and one pythonPath
        ;; (genesis's own venv leaks into every other project's config
        ;; response, confirmed via `lsp-log-io'). With enough projects
        ;; open at once -- two of them tens of thousands of files -- a
        ;; freshly-opened file can get analysed before its own
        ;; project's config has finished loading and fall through to a
        ;; bogus, sourceless "<default>" environment instead, which is
        ;; exactly what produced spurious `reportMissingImports' on a
        ;; real, correctly-configured import. Disabling this gives each
        ;; project its own independent pyright process again.
        lsp-pyright-multi-root nil

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
