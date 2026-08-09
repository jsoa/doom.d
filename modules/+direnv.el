;;; modules/+direnv.el -*- lexical-binding: t; -*-

;; Doom's `:tools direnv' module does the actual integration, via `envrc'
;; (not the similarly-named `direnv' package, which isn't installed):
;; it arms `envrc-global-mode' on first file, applies each buffer's
;; `.envrc' environment *before* that buffer's mode hooks run -- so an
;; LSP server started by a mode hook inherits the project's vars -- and
;; restarts LSP/eglot clients after a direnv reload. None of that needs
;; repeating here, and an earlier version of this file that re-registered
;; `envrc-global-mode' did nothing at all: Doom already registers the same
;; symbol, and `add-hook' de-duplicates.
;;
;; What no one binds is envrc's own commands. envrc ships them
;; deliberately unreachable -- `envrc-mode-map' is an empty keymap, and
;; `envrc-command-map' only becomes usable once you give it a prefix
;; yourself (see its docstring) -- and Doom's module doesn't either. So
;; without the below, `envrc-allow', which you need every time an
;; `.envrc' is added or edited, is `M-x'-only.
;;
;; `SPC e' is unclaimed: Doom's own `e' prefixes are all *localleader*
;; ("SPC m e", inside language modules), not the top-level leader.
;;
;; Guarded on `locate-library' because `envrc' is declared solely by
;; `:tools direnv's own packages.el -- drop that module from init.el and
;; the package goes away with it, which would otherwise leave these keys
;; bound to commands that no longer exist.

(when (locate-library "envrc")

  (map! :leader
        (:prefix ("e" . "env")

         ;; `envrc-allow' is the one worth a key: direnv refuses to load
         ;; any `.envrc' until it's been explicitly trusted, and it
         ;; re-blocks on every edit to that file.
         :desc "Allow .envrc"           "a" #'envrc-allow
         :desc "Deny .envrc"            "d" #'envrc-deny

         ;; Re-runs direnv for this buffer's environment; the `-all'
         ;; variant does every envrc-managed buffer, which is what you
         ;; want after editing an `.envrc' several projects share.
         :desc "Reload environment"     "r" #'envrc-reload
         :desc "Reload all environments" "R" #'envrc-reload-all

         ;; direnv's own stderr. The first place to look when an `.envrc'
         ;; silently fails to apply.
         :desc "Show direnv log"        "l" #'envrc-show-log)))
