;;; expose-history.el -*- lexical-binding: t; -*-

(defconst expose-history-buffer-name
  "*EXPOSE History*")

(defun expose-history-add (view)
  "Append VIEW to the popup history."

  (let ((buffer
         (get-buffer-create
          expose-history-buffer-name)))

    (with-current-buffer buffer

      (let ((inhibit-read-only t))

        (goto-char (point-max))

        (unless (= (point-min) (point-max))
          (insert "\n\n"))

        (expose-history-insert-entry view)

        (goto-char (point-max))

        (view-mode 1)))

    buffer))

(defun expose-history-insert-entry (view)
  "Insert VIEW as a popup history entry."

  (insert
   (make-string 72 ?=))

  (insert "\n")

  (insert
   (plist-get view :title))

  (insert "  ")

  (insert
   (format-time-string
    "%Y-%m-%d %H:%M:%S"))

  (insert "\n\n")

  (insert
   (plist-get view :body)))

(defun expose-history-open ()
  "Open the popup history."

  (interactive)

  (pop-to-buffer
   (get-buffer-create
    expose-history-buffer-name)))

(provide 'expose-history)
