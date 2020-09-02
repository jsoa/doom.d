;;; ~/.doom.d/modes/lsp.el -*- lexical-binding: t; -*-

;;
;; LSP
;;

(after! lsp-mode
  ;; angular lsp
  (setq lsp-clients-angular-language-server-command
        `("node"
          ,(concat (getenv "HOME") "/.nvm/versions/node/v12.0.0/lib/node_modules/@angular/language-server")
          "--ngProbeLocations"
          ,(concat (getenv "HOME") "/.nvm/versions/node/v12.0.0/lib/node_modules")
          "--tsProbeLocations"
          ,(concat (getenv "HOME") "/.nvm/versions/node/v12.0.0/lib/node_modules")
          "--stdio")))
