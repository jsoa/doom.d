;;; modules/+html.el -*- lexical-binding: t; -*-

;;; HTML / Angular setup

(defun jsoa/angular-project-p ()
  "Return non-nil if the current buffer's file is inside an Angular project.

Guards on `buffer-file-name' being non-nil: `locate-dominating-file'
signals `wrong-type-argument' rather than returning nil for a buffer
that isn't visiting a file (an org-src edit buffer, a plain `M-x
web-mode' scratch buffer), and every caller here runs from a mode hook
that such a buffer can reach."

  (and buffer-file-name
       (locate-dominating-file buffer-file-name "angular.json")))

(add-to-list 'auto-mode-alist '("\\.html\\'" . web-mode))

(defun jsoa/angular-ensure-ts-loaded ()
  "Silently open corresponding TS file for Angular components."
  (when (jsoa/angular-project-p)
    (let ((ts-file (replace-regexp-in-string "\\.html\\'" ".ts" buffer-file-name)))
      (when (file-exists-p ts-file)
        (find-file-noselect ts-file)))))

(defun jsoa/web-mode-set-angular-engine ()
  "Switch web-mode to its Angular engine inside Angular projects."
  (when (jsoa/angular-project-p)
    (web-mode-set-engine "angular")))

(defun jsoa/html-lsp-setup ()
  ;; html-ls conflicts with Angular's own language server (ngserver), which
  ;; already provides completions for Angular templates -- scoped to Angular
  ;; buffers only, so it stays available for plain HTML/Django templates.
  (when (jsoa/angular-project-p)
    (setq-local lsp-disabled-clients '(html-ls)))
  (when (projectile-project-p)
    (lsp-deferred)))

;; Guessing indentation from the file is wrong for `web-mode' in a way it
;; isn't for other modes. `dtrt-indent' registers all four web-mode
;; offsets and picks ONE width for them from the whitespace it sees --
;; but a Django template is HTML, CSS, JavaScript and template tags in one
;; file, each legitimately indented differently, so there is no single
;; right answer for it to find. What it finds instead is an average: a
;; template whose markup steps by 2 and whose script block steps by 4
;; produced 3, and 3 then applied to everything.
;;
;; Its own documentation names this failure ("6 would be correct but 3 is
;; guessed"), and the buffer-local value it sets silently beats the global
;; one set below. Dropping the entry leaves it nothing to adjust here,
;; while leaving it free to do its job in single-language files.
(after! dtrt-indent
  (setq dtrt-indent-hook-mapping-list
        (assq-delete-all 'web-mode dtrt-indent-hook-mapping-list)))

(after! web-mode
  ;; Indentation
  (setq web-mode-markup-indent-offset 2)
  (setq web-mode-code-indent-offset 2)
  (setq web-mode-css-indent-offset 2)

  ;; Behavior tweaks
  (setq web-mode-enable-auto-quoting nil)
  (setq web-mode-enable-auto-pairing t)

  ;; Hooks
  (add-hook 'web-mode-hook #'jsoa/web-mode-set-angular-engine)
  (add-hook 'web-mode-hook #'jsoa/angular-ensure-ts-loaded)
  (add-hook 'web-mode-hook #'jsoa/html-lsp-setup))

(add-hook 'html-mode-hook #'jsoa/html-lsp-setup)
