;;; +prettier.el -*- lexical-binding: t; -*-

;;; Smart Prettier setup for Apheleia

(after! apheleia

  ;; ----------------------------
  ;; Formatters (STATIC, required)
  ;; ----------------------------
  (setf (alist-get 'prettier-html apheleia-formatters)
        '("npx" "prettier"
          "--parser=html"
          "--stdin-filepath" filepath))

  (setf (alist-get 'prettier-angular apheleia-formatters)
        '("npx" "prettier"
          "--parser=angular"
          "--stdin-filepath" filepath))

  (setf (alist-get 'prettier-vue apheleia-formatters)
        '("npx" "prettier"
          "--parser=vue"
          "--stdin-filepath" filepath))

  (setf (alist-get 'prettier-react apheleia-formatters)
        '("npx" "prettier"
          "--parser=babel"
          "--stdin-filepath" filepath))
  (setf (alist-get 'prettier-json apheleia-formatters)
        '("npx" "prettier"
          "--parser=json"
          "--stdin-filepath" filepath))

  ;; ----------------------------
  ;; Default mode associations
  ;; (fallback if detection doesn't run)
  ;; ----------------------------
  (setf (alist-get 'html-mode apheleia-mode-alist)
        '(prettier-html))

  (setf (alist-get 'web-mode apheleia-mode-alist)
        '(prettier-html))

  (setf (alist-get 'js-mode apheleia-mode-alist)
        '(prettier-react))

  (setf (alist-get 'js2-mode apheleia-mode-alist)
        '(prettier-react))

  (setf (alist-get 'typescript-mode apheleia-mode-alist)
        '(prettier-react))

  (setf (alist-get 'typescript-ts-mode apheleia-mode-alist)
        '(prettier-react))
  )

;; ----------------------------
;; Smart formatter selection
;; ----------------------------

(defun jsoa/set-prettier-formatter ()
  "Set Apheleia formatter based on file type + project."
  (when buffer-file-name
    (setq-local
     apheleia-formatter
     (cond
      ;; JSON
      ((string-match-p "\\.json\\'" buffer-file-name)
       'prettier-json)

      ;; Vue
      ((string-match-p "\\.vue\\'" buffer-file-name)
       'prettier-vue)

      ;; React
      ((or (string-match-p "\\.jsx\\'" buffer-file-name)
           (string-match-p "\\.tsx\\'" buffer-file-name))
       'prettier-react)

      ;; Angular HTML only
      ((and (string-match-p "\\.html\\'" buffer-file-name)
            (locate-dominating-file buffer-file-name "angular.json"))
       'prettier-angular)

      ;; Plain HTML
      ((string-match-p "\\.html\\'" buffer-file-name)
       'prettier-html)

      ;; fallback
      (t apheleia-formatter)))))

;; ----------------------------
;; Hooks
;; ----------------------------

(add-hook 'html-mode-hook #'jsoa/set-prettier-formatter)
(add-hook 'web-mode-hook #'jsoa/set-prettier-formatter)
(add-hook 'js-mode-hook #'jsoa/set-prettier-formatter)
(add-hook 'js2-mode-hook #'jsoa/set-prettier-formatter)
(add-hook 'typescript-mode-hook #'jsoa/set-prettier-formatter)
(add-hook 'typescript-ts-mode-hook #'jsoa/set-prettier-formatter)
