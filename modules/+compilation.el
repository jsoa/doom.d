;;; ~/.doom.d/modes/compilation-mode.el -*- lexical-binding: t; -*-

;;
;; Compilation
;;

(after! compile
  (setq compilation-scroll-output t
        compilation-auto-jump-to-first-error t
        compilation-error-screen-columns nil
        next-error-message-highlight t
        compilation-always-kill t
        compilation-auto-jump-to-first-error t
        compilation-skip-threshold 2
        )

  )

(add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)
