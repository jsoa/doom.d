;;; +html.el -*- lexical-binding: t; -*-

(add-to-list 'auto-mode-alist '("\\.html\\'" . html-ts-mode))


(defun jsoa/angular-ensure-ts-loaded ()
  (when (and buffer-file-name
             (string-match "\\.html\\'" buffer-file-name))
    (let ((ts-file (replace-regexp-in-string "\\.html\\'" ".ts" buffer-file-name)))
      (when (file-exists-p ts-file)
        (find-file-noselect ts-file)))))

(add-hook 'html-ts-mode-hook #'my/angular-ensure-ts-loaded)

(add-hook 'html-ts-mode-hook
          (lambda ()
            (when (projectile-project-p)
              (lsp-deferred))))
