;;; HTML / Angular setup

(add-hook 'web-mode-hook #'jsoa/web-mode-angular-font-lock)

(defun jsoa/html-mode-dispatch ()
  "Use web-mode for Angular projects, html-mode otherwise."
  (if (and buffer-file-name
           (locate-dominating-file buffer-file-name "angular.json"))
      (web-mode)
    (html-mode)))

(add-to-list 'auto-mode-alist '("\\.html\\'" . jsoa/html-mode-dispatch))

(defun jsoa/angular-ensure-ts-loaded ()
  "Silently open corresponding TS file for Angular components."
  (when (and buffer-file-name
             (locate-dominating-file buffer-file-name "angular.json"))
    (let ((ts-file (replace-regexp-in-string "\\.html\\'" ".ts" buffer-file-name)))
      (when (file-exists-p ts-file)
        (find-file-noselect ts-file)))))

(defun jsoa/html-lsp-setup ()
  (when (projectile-project-p)
    (lsp-deferred)))

(after! web-mode
  ;; Ensure Angular engine is used
  (setq web-mode-engines-alist
        '(("angular" . "\\.html\\'")))

  (add-hook 'web-mode-hook
            (lambda ()
              (when (locate-dominating-file buffer-file-name "angular.json")
                (web-mode-set-engine "angular"))))

  ;; Indentation
  (setq web-mode-markup-indent-offset 2)
  (setq web-mode-code-indent-offset 2)
  (setq web-mode-css-indent-offset 2)

  ;; Behavior tweaks
  (setq web-mode-enable-auto-quoting nil)
  (setq web-mode-enable-auto-pairing t)

  ;; Hooks
  (add-hook 'web-mode-hook #'jsoa/angular-ensure-ts-loaded)
  (add-hook 'web-mode-hook #'jsoa/html-lsp-setup))

(add-hook 'html-mode-hook #'jsoa/html-lsp-setup)
