;;; modules/+claude-code-ide.el -*- lexical-binding: t; -*-

;; A real, interactive Claude Code CLI session with MCP-based Emacs
;; integration -- unlike Expose (site-lisp/expose), which is deliberately
;; advisory-only (one-shot requests, no execution capability), this gives
;; Claude native visibility into the current buffer/selection/diagnostics
;; via MCP, and lets it act directly (edits reviewed through ediff).
;;
;; Replaces the custom vterm-based `jsoa/project-claude' from
;; modules/+vterm.el, which had no way to tell Claude Code what buffer
;; was open short of manually typing an `@file' mention. Codex still uses
;; that vterm setup, since this package is Claude-specific.
;;
;; Guarded on `locate-library': it's declared in packages.el but only
;; actually fetched/built by `doom sync' -- on a fresh checkout that
;; hasn't been run yet (or a sync that failed), `use-package!' would
;; otherwise `require' it unconditionally and hard-error the whole config
;; load. Skipping it here just leaves the feature (and its keybindings)
;; inactive until it's actually installed.
(when (locate-library "claude-code-ide")
  (use-package! claude-code-ide
    :config
    (claude-code-ide-emacs-tools-setup)

    ;; Lets Claude evaluate arbitrary Elisp directly in this running Emacs
    ;; session via its `executeCode' MCP tool. On by default upstream, but
    ;; that's a materially different posture than everything else here
    ;; (Expose never lets the AI execute anything, only advise) -- off
    ;; until deliberately turned back on.
    (setq claude-code-ide-enable-execute-code nil))

  (map! :leader
        :desc "Claude Code"            "v l" #'claude-code-ide
        :desc "Stop Claude Code"       "v L" #'claude-code-ide-stop
        :desc "Mention file in Claude" "v m" #'claude-code-ide-insert-at-mentioned
        :desc "Claude Code menu"       "v M" #'claude-code-ide-menu))
