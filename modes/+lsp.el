;;; ~/.doom.d/modes/lsp.el -*- lexical-binding: t; -*-

;;
;; LSP
;;

(after! lsp-mode
  ;; (setq-default lsp-pyls-configuration-sources ["pylint" "flake8" "pycodestyle"])
  ;; (setq lsp-pyls-plugins-pylint-enabled t)

  ;; Use the forked version of pyls
  ;; https://github.com/python-lsp/python-lsp-server
  (setq lsp-pyls-server-command "pylsp")

  ;; https://emacs-lsp.github.io/lsp-mode/page/performance/
  (setq read-process-output-max (* 1024 1024)) ;; 1mb

  ;; angular lsp
  (setq lsp-clients-angular-language-server-command
        `("node"
          ,(concat (getenv "HOME") "/.nvm/versions/node/v12.0.0/lib/node_modules/@angular/language-server")
          "--ngProbeLocations"
          ,(concat (getenv "HOME") "/.nvm/versions/node/v12.0.0/lib/node_modules")
          "--tsProbeLocations"
          ,(concat (getenv "HOME") "/.nvm/versions/node/v12.0.0/lib/node_modules")
          "--stdio"))

  ;; (defvar lsp-docker-client-packages
  ;;   '(lsp-css lsp-clients lsp-bash lsp-pyls lsp-html ))

  )
