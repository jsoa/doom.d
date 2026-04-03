;;; ~/.doom.d/modes/org.el -*- lexical-binding: t; -*-


(after! org
  (setq org-columns-default-format "%50ITEM(Task) %10CLOCKSUM %16LASTWORKED %16CLOSED")
  (setq org-agenda-files (directory-files-recursively "~/org/" "\\.org$"))
  )

(after! org-re-reveal
  (setq org-re-reveal-root (concat (getenv "HOME") "/.doom.d/private/reveal.js"))
  )
