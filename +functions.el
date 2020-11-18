;;; ~/.doom.d/+functions.el -*- lexical-binding: t; -*-

;;
;; Custom functions
;;


;; https://stackoverflow.com/questions/1292936/line-wrapping-within-emacs-compilation-buffer
(defun jsoa/compilation-mode-hook ()
  (setq truncate-lines nil) ;; automatically becomes buffer local
  (set (make-local-variable 'truncate-partial-width-windows) nil))


;; https://emacs.stackexchange.com/questions/13080/reloading-directory-local-variables
(defun jsoa/reload-dir-locals-for-current-buffer ()
  "reload dir locals for the current buffer"
  (interactive)
  (let ((enable-local-variables :all))
    (hack-dir-local-variables-non-file-buffer)))


(defun jsoa/file-info ()
  (interactive)
  (let ((dired-listing-switches "-alh"))
    (dired-other-window buffer-file-name)))


;; ref: http://www.emacswiki.org/emacs/TabCompletion
(defun smart-tab ()
  "This smart tab is minibuffer compliant: it acts as usual in
   the minibuffer. Else, if mark is active, indents region. Else if
   point is at the end of a symbol, expands it. Else indents the
   current line."
   (interactive)
   (if (minibufferp)
     (unless (minibuffer-complete)
       (dabbrev-expand nil))
     (if mark-active
       (indent-region (region-beginning)
         (region-end))
       (if (looking-at "\\_>")
         (dabbrev-expand nil)
         (indent-for-tab-command)))))


;; Insert a commit message prefix, i.e. [ticket number]
;; If a branch name starts with "NAME-NUMBER", get it and supply
;; a commit prefix of [NAME-NUMBER] otherwise insert [-]
(defun jsoa/git-commit-setup ()
  (let ((branch-name (magit-get-current-branch)))
    (save-match-data ; is usually a good idea
      (if (string-match "^\\(\\w+-[0-9]+\\)" branch-name)
        (insert (concat "[" (match-string 1 branch-name) "] "))
        (insert "[-] ")))))
