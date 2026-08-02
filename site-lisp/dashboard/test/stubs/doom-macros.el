;;; doom-macros.el --- minimal stand-ins for Doom's ambient macros -*- lexical-binding: t; -*-

;; dashboard.el assumes Doom core (which defines `map!' and `cmd!') is
;; already loaded -- true in real usage, since config.el (where the
;; dashboard module is loaded) always runs after Doom core. These
;; no-op stand-ins let the file load standalone for testing, `load'ed
;; explicitly by run-tests.el before `dashboard' is required (not
;; `require'd by dashboard.el itself, so a plain load-path addition
;; wouldn't be enough on its own).

(unless (fboundp 'map!)
  (defmacro map! (&rest _) nil))

(unless (fboundp 'cmd!)
  (defmacro cmd! (&rest _) nil))

(provide 'doom-macros)

;;; doom-macros.el ends here
