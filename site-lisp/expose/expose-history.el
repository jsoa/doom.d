;;; expose-history.el -*- lexical-binding: t; -*-

(require 'subr-x)

(defconst expose-history-buffer-name
  "*EXPOSE History*")

(defcustom expose-history-max-entries 100
  "Maximum number of Expose popup history entries kept in memory."
  :type 'integer
  :group 'expose)

(defvar expose-history-entries nil
  "List of Expose popup history entries.

Newest entries are stored first. This survives killing the history buffer,
but not restarting Emacs.")

(defun expose-history-entry-create (view)
  "Return a history entry for VIEW."

  (list
   :title
   (or
    (plist-get view :title)
    "Expose")

   :body
   (or
    (plist-get view :body)
    "")

   :created-at
   (format-time-string "%Y-%m-%d %H:%M:%S")))

(defun expose-history-trim ()
  "Trim `expose-history-entries' to `expose-history-max-entries'."

  (when (> (length expose-history-entries)
           expose-history-max-entries)
    (setcdr
     (nthcdr
      (1- expose-history-max-entries)
      expose-history-entries)
     nil)))

(defun expose-history-add (view)
  "Append VIEW to the popup history."

  (push
   (expose-history-entry-create view)
   expose-history-entries)

  (expose-history-trim)

  ;; If the history buffer is already open, refresh it.
  (when (get-buffer expose-history-buffer-name)
    (expose-history-render-buffer))

  (get-buffer-create expose-history-buffer-name))

(defun expose-history-insert-entry (entry)
  "Insert history ENTRY."

  (insert
   (make-string 72 ?=))

  (insert "\n")

  (insert
   (or
    (plist-get entry :title)
    "Expose"))

  (insert "  ")

  (insert
   (or
    (plist-get entry :created-at)
    ""))

  (insert "\n\n")

  (insert
   (or
    (plist-get entry :body)
    "")))

(defun expose-history-render-buffer ()
  "Render `expose-history-entries' into the history buffer."

  (let ((buffer
         (get-buffer-create expose-history-buffer-name)))

    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (view-mode -1)
        (erase-buffer)

        (if expose-history-entries

            (dolist (entry
                     (reverse expose-history-entries))
              (unless (= (point-min)
                         (point-max))
                (insert "\n\n"))

              (expose-history-insert-entry entry))

          (insert "No Expose history yet.\n"))

        (goto-char (point-min))
        (view-mode 1)))

    buffer))

(defun expose-history-open ()
  "Open the popup history."

  (interactive)

  (pop-to-buffer
   (expose-history-render-buffer)))

(defun expose-history-clear ()
  "Clear Expose popup history."

  (interactive)

  (setq expose-history-entries nil)

  (when (get-buffer expose-history-buffer-name)
    (expose-history-render-buffer))

  (message "Expose history cleared."))

(provide 'expose-history)
