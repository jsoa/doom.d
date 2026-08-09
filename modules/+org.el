;;; modules/+org.el -*- lexical-binding: t; -*-


(after! org
  (setq org-columns-default-format "%50ITEM(Task) %10CLOCKSUM %16LASTWORKED %16CLOSED")

  ;; Guarded on the directory existing: `directory-files-recursively'
  ;; signals `file-missing' rather than returning nil for a missing
  ;; directory, which would take the whole `after! org' body -- and so
  ;; org itself -- down on any machine without an ~/org yet.
  (setq org-agenda-files
        (when (file-directory-p org-directory)
          (directory-files-recursively org-directory "\\.org\\'"))))

(after! org-re-reveal
  (setq org-re-reveal-root (concat (getenv "HOME") "/.doom.d/private/reveal.js"))
  )
