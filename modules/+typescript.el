;;; ~/.doom.d/modes/typescript.el -*- lexical-binding: t; -*-


;;
;; Typescript
;;


(after! typescript-mode
  (setq-default typescript-indent-level 2)
  ;; (flycheck-add-next-checker 'lsp-ui 'typescript-tslint)
  ;; (map! :after dap-mode
  ;;       :localleader
  ;;       :map typescript-mode-map
  ;;       :prefix ("d" . "debugger")
  ;;       :desc "start"              "s" #'dap-debug
  ;;       :desc "hydra"              "h" #'dap-hydra
  ;;       :desc "add breakpoint"     "a" #'dap-breakpoint-add
  ;;       :desc "remove breakpoint"  "d" #'dap-breakpoint-delete
  ;;       :desc "toggle breakpoint"  "t" #'dap-breakpoint-toggle
  ;;       :desc "show locals"        "l" #'dap-ui-locals
  ;;       :desc "show session"       "S" #'dap-ui-sessions
  ;;       :desc "show breakpoints"   "B" #'dap-ui-breakpoints
  ;;       )
  )
