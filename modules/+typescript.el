;;; ~/.doom.d/modes/typescript.el -*- lexical-binding: t; -*-


;;
;; Typescript
;;


(after! typescript-mode
  (setq-default typescript-indent-level 2))

(add-hook 'typescript-ts-mode-hook #'lsp-deferred)
