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

(defun jsoa/html-mode-dispatch ()
  "Use web-mode for Angular projects, html-mode otherwise."
  (if (jsoa/angular-project-p)
      (web-mode)
    (html-mode)))

(add-to-list 'auto-mode-alist '("\\.html\\'" . jsoa/html-mode-dispatch))

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
  (when (projectile-project-p)
    (lsp-deferred)))

(after! web-mode
  ;; Ensure Angular engine is used
  (setq web-mode-engines-alist
        '(("angular" . "\\.html\\'")))

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
