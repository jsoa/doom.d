;;; +dashboard.el -*- lexical-binding: t; -*-


;; =========================
;; Core / Utilities
;; =========================
(defvar-local jsoa/diag-token nil)

(defun jsoa/sh (cmd &optional dir)
  "Run shell CMD in DIR and return trimmed output."
  (let ((default-directory (or dir default-directory)))
    (string-trim (shell-command-to-string cmd))))

(defun jsoa/safe-str (s)
  (or s ""))

(defun jsoa/format-number (n)
  (let ((s (number-to-string n)))
    (while (string-match "\\B\\([0-9]\\{3\\}\\)+\\>" s)
      (setq s (replace-match ",\\&" t nil s)))
    s))

(defun jsoa/format-loc (n)
  "Format LOC number into human-readable string."
  (cond
   ((> n 1000000) (format "%.1fM" (/ n 1000000.0)))
   ((> n 1000)    (format "%.1fk" (/ n 1000.0)))
   (t (number-to-string n))))

(defun jsoa/short-path (file root)
  "Return last 2 segments of FILE relative to ROOT."
  (let* ((rel (file-relative-name file root))
         (parts (split-string rel "/" t)))
    (if (> (length parts) 2)
        (mapconcat #'identity (last parts 2) "/")
      rel)))

;; =========================
;; Git Layer
;; =========================

(defun jsoa/git-status-face (ahead behind changes)
  "Return face based on git state."
  (cond
   ;; dirty repo -> red
   ((> changes 0) 'error)

   ;; diverged -> warning
   ((or (> (or ahead 0) 0)
        (> (or behind 0) 0))
    'warning)

   ;; clean → success
   (t 'success)))

(defun jsoa/git-recent-files-data (root &optional limit)
  "Return recent files with commit info using ONE git call."
  (let* ((default-directory root)
         (limit (or limit 5))
         (output
          (jsoa/sh
           "git log -n 20 --name-only --pretty=format:'%s|%cr' 2>/dev/null"))
         (lines (split-string output "\n" t))
         (seen (make-hash-table :test 'equal))
         results current)

    (dolist (line lines)
      (if (string-match "|" line)
          ;; commit line
          (let* ((parts (split-string line "|" t)))
            (setq current (list :msg (car parts)
                                :age (cadr parts))))
        ;; file line
        (when (and current
                   (not (string-empty-p line))
                   (not (gethash line seen)))
          (puthash line t seen)
          (push (plist-put (copy-sequence current) :file line) results))))

    (seq-take (nreverse results) limit)))


;; =========================
;; LOC / Analysis
;; =========================

(defun jsoa/project-type (root)
  "Detect project type from ROOT."
  (cond
   ((file-exists-p (expand-file-name "angular.json" root)) 'angular)
   ((file-exists-p (expand-file-name "package.json" root)) 'node)
   ((file-exists-p (expand-file-name "pyproject.toml" root)) 'python)
   ((file-exists-p (expand-file-name "requirements.txt" root)) 'python)
   (t 'generic)))

(defun jsoa/render-loc-section (root)
  "Render vertical LOC breakdown with bars."
  (let ((data (jsoa/project-loc-by-extension root)))
    (when data
      (jsoa/start-section "Lines of Code")

      (let* ((prepared (jsoa/prepare-loc-breakdown data))
             (total (apply #'+ (mapcar #'cdr prepared)))
             (max-val (apply #'max (mapcar #'cdr prepared)))
             (all-exts (mapcar #'car data))
             (top-exts (remove "OTHER" (mapcar #'car prepared)))
             (other-exts (seq-difference all-exts top-exts))

             ;; widths
             (max-label
              (apply #'max
                     (mapcar
                      (lambda (p)
                        (let* ((ext (car p))
                               (name (if (string= ext "OTHER")
                                         "OTHER"
                                       (jsoa/ext-label ext)))
                               (icon (jsoa/ext-icon ext))
                               )
                          (string-width (concat (or icon "") (when icon " ") name))))
                      prepared)))
             (max-num   (apply #'max (mapcar (lambda (p) (length (jsoa/format-loc (cdr p)))) prepared)))

             (bar-width 20)
             )


        (cl-loop
         for pair in prepared
         for idx from 0
         do
         (let* (
                (raw-label (car pair))
                (name (if (string= raw-label "OTHER")
                          "OTHER"
                        (jsoa/ext-label raw-label)))
                (icon (jsoa/ext-icon raw-label))
                (label name)
                (val   (cdr pair))
                (pct   (* 100.0 (/ (float val) total)))

                (num-str (jsoa/format-loc val))

                (label-str (concat (or icon "") (when icon " ") label))
                (label-pad
                 (make-string
                  (max 0 (- max-label (string-width label-str)))
                  ?\s))
                (num-pad   (make-string (max 0 (- max-num (length num-str))) ?\s))

                (steps '(1.0 0.85 0.7 0.55 0.4 0.3))
                (scale (nth (min idx (1- (length steps))) steps))

                (fg (face-attribute 'success :foreground nil t))
                (fg-rgb (color-name-to-rgb fg))

                (blend (mapcar (lambda (c) (* scale c)) fg-rgb))
                (color (apply #'color-rgb-to-hex blend))

                (bar-len (max 1 (/ (* val bar-width) max-val)))
                (bar
                 (propertize
                  (make-string bar-len ?█)
                  'face `(:foreground ,color)))
                )

           (let ((line-start (point)))
             ;; label (clickable, blue)
             (when icon
               (insert (propertize icon 'face 'shadow))
               (insert " "))

             (let ((label-start (point)))
               (insert label)
               (make-text-button
                label-start (point)
                'action
                (lambda (_)
                  (let ((default-directory root))
                    (require 'consult)

                    (if (string= raw-label "OTHER")

                        ;; OTHER → exclude top extensions
                        (let* ((prepared (jsoa/prepare-loc-breakdown
                                          (jsoa/project-loc-by-extension root)))
                               (top-exts (remove "OTHER" (mapcar #'car prepared)))
                               (glob-args
                                (mapconcat
                                 (lambda (ext)
                                   (format " -g '!*.%s'" (downcase ext)))
                                 top-exts "")))

                          (let ((consult-ripgrep-args
                                 (concat consult-ripgrep-args
                                         glob-args
                                         " -g '*'"))) ;; 👈 critical
                            (consult-ripgrep root)))

                      ;; normal extension search
                      (let ((consult-ripgrep-args
                             (concat consult-ripgrep-args
                                     " -g *." (downcase raw-label))))
                        (consult-ripgrep root))))
                  )
                'follow-link t
                'face 'link))

             ;; padding after label
             (insert label-pad "  ")

             ;; count (colored for dominant)
             (insert num-pad)
             (insert
              (propertize
               num-str
               'face `(:foreground ,color)))

             (insert "  ")

             ;; percentage (colored for dominant)
             (insert
              (propertize
               (format "%5.1f%%" pct)
               'face `(:foreground ,color)))

             (insert "  ")

             ;; bar (already colored)
             (insert bar "\n")
             (when (and (string= raw-label "OTHER") other-exts)
               (let* ((shown (seq-take other-exts 5))
                      (text (string-join (mapcar #'downcase shown) ", ")))
                 (insert
                  (propertize
                   (concat "" text "\n")
                   'face 'shadow))))
             )
           ))

        (insert "\n")))))

(defun jsoa/project-loc-by-extension (root)
  "Fast LOC breakdown by file extension."
  (let ((default-directory root)
        (table (make-hash-table :test 'equal)))

    (dolist (line
             (split-string
              (shell-command-to-string
               "rg --no-heading --line-number --color never \
-g '!node_modules' \
-g '!dist' \
-g '!build' \
-g '!*.min.*' \
-g '!*.map' \
-g '!package-lock.json' \
-g '!*.lock' \
-g '!.angular/**' \
-g '!.vscode/**' \
'^' 2>/dev/null")
              "\n" t))

      ;; line format: file:line
      (when (string-match "^\\([^:]+\\):" line)
        (let* ((file (match-string 1 line))
               (ext (or (file-name-extension file) "noext")))

          ;; ignore junk extensions
          (unless (member ext '("lock" "map" "log" "tmp" "cache"))
            (puthash ext (1+ (gethash ext table 0)) table)))))

    ;; convert to alist
    (let (result)
      (maphash (lambda (k v)
                 (push (cons (upcase k) v) result))
               table)
      result)))

(defun jsoa/prepare-loc-breakdown (data)
  "Sort, take top entries, and collapse the rest into OTHER."
  (let* ((sorted (sort (copy-sequence data)
                       (lambda (a b) (> (cdr a) (cdr b)))))
         (top (seq-take sorted 4))
         (rest (nthcdr 4 sorted))
         (other-sum (apply #'+ (mapcar #'cdr rest))))

    (if (> other-sum 0)
        (append top (list (cons "OTHER" other-sum)))
      top)))

(defun jsoa/ext-label (ext)
  (or
   (cdr (assoc ext
               '(("PY"   . "Python")
                 ("TS"   . "TypeScript")
                 ("JS"   . "JavaScript")
                 ("HTML" . "HTML")
                 ("CSS"  . "CSS")
                 ("JSON" . "JSON")
                 ("MD"   . "Markdown")
                 ("SH"   . "Shell")
                 ("YML"  . "YAML")
                 ("YAML" . "YAML")
                 ("TOML" . "TOML")
                 ("CFG"  . "Config")
                 ("INI"  . "INI")
                 ("TXT"  . "Text"))))
   ext))

(defun jsoa/ext-icon (ext)
  (when (featurep 'nerd-icons)
    (or
     (pcase ext
       ("PY"   (nerd-icons-devicon "nf-dev-python" :height 0.9))
       ("TS"   (nerd-icons-devicon "nf-dev-typescript" :height 0.9))
       ("JS"   (nerd-icons-devicon "nf-dev-javascript" :height 0.9))
       ("HTML" (nerd-icons-devicon "nf-dev-html5" :height 0.9))
       ("CSS"  (nerd-icons-devicon "nf-dev-css3" :height 0.9))
       ("JSON" (nerd-icons-devicon "nf-dev-json" :height 0.9))
       ("MD"   (nerd-icons-devicon "nf-dev-markdown" :height 0.9))
       ("SH"   (nerd-icons-devicon "nf-dev-terminal" :height 0.9))
       ("OTHER" (nerd-icons-octicon "nf-oct-stack" :height 0.9))
       )

     (nerd-icons-octicon "nf-oct-file" :height 0.9))))

(defun jsoa/todo-icon (type)
  (when (featurep 'nerd-icons)
    (pcase type
      ("FIXME" (nerd-icons-octicon "nf-oct-alert" :height 0.9))
      ("TODO"  (nerd-icons-octicon "nf-oct-checklist" :height 0.9))
      ("HACK"  (nerd-icons-octicon "nf-oct-tools" :height 0.9))
      ("NOTE"  (nerd-icons-octicon "nf-oct-note" :height 0.9))
      (_       (nerd-icons-octicon "nf-oct-dot" :height 0.9)))))

(defun jsoa/top-loc-extensions (root)
  "Return top 4 file extensions by LOC."
  (let* ((data (jsoa/project-loc-by-extension root))
         (sorted (sort (copy-sequence data)
                       (lambda (a b) (> (cdr a) (cdr b))))))
    (seq-take sorted 4)))

(defun jsoa/ext-to-glob (ext)
  (if (string= ext "noext")
      ""
    (format "-g \"*.%s\"" (downcase ext))))

;; =========================
;; UI Primitives
;; =========================

(defconst jsoa/dashboard-width 90)

(defvar-local jsoa/diag-highlight-ov nil)

(defun jsoa/diag-highlight-current ()
  "Highlight the current button line in diagnostics buffer."
  (when jsoa/diag-highlight-ov
    (delete-overlay jsoa/diag-highlight-ov)
    (setq jsoa/diag-highlight-ov nil))

  (when-let ((btn (button-at (point))))
    (let* ((start (save-excursion
                    (goto-char (button-start btn))
                    (line-beginning-position)))
           (end (save-excursion
                  (goto-char (button-end btn))
                  (line-end-position)))
           (ov (make-overlay start end)))
      (overlay-put ov 'face 'jsoa/dashboard-button-active)
      (setq jsoa/diag-highlight-ov ov))))

(defface jsoa/dashboard-header
  '((t (:inherit font-lock-comment-face
        :weight bold
        :height 1.15)))
  "Dashboard section headers.")

(defface jsoa/dashboard-button-active
  '((t (:inherit warning :weight bold)))
  "Face for active dashboard button.")

(defun jsoa/start-section (title)
  (let ((start (point)))
    (insert title)
    (add-text-properties start (point) '(face jsoa/dashboard-header))
    (insert "\n"))
  (move-to-column 0))

(defun jsoa/dashboard-left-padding ()
  (max 0 (/ (- (window-width) jsoa/dashboard-width) 2)))

(defun jsoa/dashboard-separator ()
  (insert
   (propertize
    (make-string jsoa/dashboard-width ?-)
    'face 'shadow)
   "\n"))

(defun jsoa/dashboard-move-to-content ()
  (goto-char (point-min))
  (when-let ((pos (next-button (point) t)))
    (goto-char pos)))

;; =========================
;; Buttons / Interaction
;; =========================

(defun jsoa/search-with-glob (root glob)
  (let ((default-directory root))
    (consult-ripgrep root (concat glob " "))))

(defun jsoa/flash-line (&optional duration)
  "Briefly highlight the current line."
  (let* ((duration (or duration 0.4))
         (start (line-beginning-position))
         (end   (line-end-position))
         (ov (make-overlay start end)))
    (overlay-put ov 'face 'highlight)
    (run-with-timer
     duration nil
     (lambda (o)
       (when (overlayp o) (delete-overlay o)))
     ov)))

(defun jsoa/open-file-other-window (file root &optional line)
  "Open FILE in main window, keep diagnostics panel focused, flash line."
  (let* ((full (expand-file-name file root))
         (buf (find-file-noselect full))
         (win (get-largest-window)))
    (save-selected-window
      (select-window win)
      (switch-to-buffer buf)
      (when line
        (goto-char (point-min))
        (forward-line (1- line)))
      ;; 🔥 flash the line
      (jsoa/flash-line))))

(defun jsoa/insert-file-button (file root)
  (let ((start (point)))
    (insert file)
    (make-text-button
     start (point)
     'action (lambda (_)
               (jsoa/open-file-other-window file root))
     'follow-link t
     'face 'link))
  (insert "\n"))

(defun jsoa/insert-todo-button (line root)
  (when (string-match "^\\([^:]+\\):\\([0-9]+\\):\\(.*\\)$" line)
    (let* ((file (match-string 1 line))
           (linenum (string-to-number (match-string 2 line)))
           (text (string-trim (match-string 3 line)))

           ;; split TODO keyword from rest
           (parts (split-string text " " t))
           (keyword (car parts))
           (rest (string-join (cdr parts) " ")))

      ;; clickable file:line
      (let ((start (point)))
        (insert (format "%s:%d" file linenum))
        (make-text-button
         start (point)
         'action (lambda (_)
                   (jsoa/open-file-other-window file root linenum))
         'follow-link nil
         'face 'link))

      (insert ": ")

      ;; styled TODO keyword
      (insert
       (propertize
        keyword
        'face (cond
               ((string= keyword "FIXME:") 'error)
               ((string= keyword "TODO:")  'font-lock-warning-face)
               ((string= keyword "HACK:")  'font-lock-constant-face)
               ((string= keyword "NOTE:")  'font-lock-doc-face)
               (t 'default))))

      ;; rest of line (normal text)
      (when rest
        (insert " " rest))

      (insert "\n"))))

(defun jsoa/dashboard-highlight-button ()
  (when jsoa/dashboard-button-overlay
    (delete-overlay jsoa/dashboard-button-overlay)
    (setq jsoa/dashboard-button-overlay nil))

  (when-let ((btn (button-at (point))))
    (let ((ov (make-overlay (button-start btn) (button-end btn))))
      (overlay-put ov 'face 'jsoa/dashboard-button-active)
      (setq jsoa/dashboard-button-overlay ov))))

(defvar-local jsoa/dashboard-button-overlay nil)

;; =========================
;; Data Providers
;; =========================

(defun jsoa/find-readme (root)
  "Return path to README in ROOT if it exists."
  (seq-find
   (lambda (f) (file-exists-p (expand-file-name f root)))
   '("README.md" "README.org" "README.txt" "README")))

(defun jsoa/project-search-actions (root)
  "Return dynamic search actions based on LOC."
  (let ((top-exts (jsoa/top-loc-extensions root)))
    (mapcar
     (lambda (pair)
       (let ((ext (car pair)))
         (cons (jsoa/ext-label ext) (jsoa/ext-to-glob ext))))
     top-exts)))


;; =========================
;; Renderers
;; =========================

(defun jsoa/render-recent-files (items root)
  "Render recent files section from ITEMS."
  (when items
    (jsoa/start-section "Recently Modified")

    (let* ((labels (mapcar (lambda (it)
                             (jsoa/short-path (plist-get it :file) root))
                           items))
           (max-label (apply #'max (mapcar #'string-width labels)))
           (max-age (apply #'max
                           (mapcar (lambda (it)
                                     (string-width (jsoa/safe-str (plist-get it :age))))
                                   items))))

      (cl-loop
       for it in items
       for label in labels
       do
       (let* ((file (plist-get it :file))
              (raw-msg (jsoa/safe-str (plist-get it :msg)))
              (age (jsoa/safe-str (plist-get it :age)))
              (start (point))

              ;; compute available width
              (msg-width
               (max 20
                    (- jsoa/dashboard-width
                       max-label
                       max-age
                       6))) ;; spacing

              (msg (truncate-string-to-width raw-msg msg-width nil nil t)))

         ;; file (clickable)
         (insert label)
         (make-text-button
          start (point)
          'action (lambda (_) (jsoa/open-file-other-window file root))
          'follow-link t
          'face 'link
          'help-echo (file-relative-name file root))

         ;; align file column
         (insert (make-string (- max-label (string-width label)) ?\s))

         ;; message
         (let ((msg-start (point)))
           (insert "  — " msg)
           (insert (make-string (- msg-width (string-width msg)) ?\s))
           (add-text-properties msg-start (point) '(face shadow)))

         ;; age (aligned)
         (insert "  "
                 (propertize
                  (format (format "%%%ds" max-age) age)
                  'face 'font-lock-comment-face))

         (insert "\n")))

      (insert "\n"))))

;; =========================
;; Sections
;; =========================
(defun jsoa/show-pyright-diagnostics (root diagnostics &optional severity)
  (let ((buf (get-buffer-create "*jsoa-pyright*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (add-hook 'post-command-hook #'jsoa/diag-highlight-current nil t)

        ;; navigation like dashboard
        (local-set-key (kbd "TAB") #'forward-button)
        (local-set-key (kbd "<backtab>") #'backward-button)
        (local-set-key (kbd "S-TAB") #'backward-button)
        (local-set-key (kbd "RET") #'push-button)

        ;; Title
        (insert (format "Pyright %s\n"
                        (cond
                         ((equal severity "error") "Errors")
                         ((equal severity "warning") "Warnings")
                         (t "Diagnostics"))))
        (insert (make-string 50 ?-))
        (insert "\n\n")

        ;; =========================
        ;; Group diagnostics by file
        ;; =========================
        (let ((groups (make-hash-table :test 'equal)))

          ;; collect
          (dolist (d diagnostics)
            (when (or (not severity)
                      (equal (gethash "severity" d) severity))
              (let ((file (gethash "file" d)))
                (puthash file
                         (cons d (gethash file groups))
                         groups)
                )))

          ;; sort files (optional, stable order)
          (let ((files (sort (hash-table-keys groups) #'string<)))

            (dolist (file files)
              (let* ((items (nreverse (gethash file groups)))
                     (count (length items))
                     (short (jsoa/short-path file root))
                     (file-start (point)))

                ;; =========================
                ;; File header (clickable)
                ;; =========================
                (insert (format "%s (%d)\n" short count))

                (make-text-button
                 file-start (point)
                 'file file
                 'root root
                 'action (lambda (btn)
                           (let ((file (button-get btn 'file))
                                 (root (button-get btn 'root)))
                             (jsoa/open-file-other-window file root 1)))
                 'follow-link t
                 'face 'bold)

                ;; =========================
                ;; Rows
                ;; =========================
                (dolist (d items)
                  (let* ((msg (gethash "message" d))
                         (range (gethash "range" d))
                         (line (and range
                                    (1+ (gethash "line"
                                                 (gethash "start" range)))))
                         (face (if (equal (gethash "severity" d) "error")
                                   'error
                                 'warning))
                         (this-file file)
                         (this-line line)
                         (start (point)))

                    ;; clickable line number
                    (let ((start (point)))
                      (insert
                       (format "  %s:%d"
                               (jsoa/short-path this-file root)
                               (or this-line 0)))

                      (make-text-button
                       start (point)
                       'file this-file
                       'line this-line
                       'root root
                       'action (lambda (btn)
                                 (let ((file (button-get btn 'file))
                                       (root (button-get btn 'root))
                                       (line (button-get btn 'line)))
                                   (jsoa/open-file-other-window file root line)))
                       'follow-link t
                       'face 'link))

                    ;; message
                    (insert "  ")
                    (insert (propertize msg 'face face))
                    (insert "\n")))

                (insert "\n"))))))

      (goto-char (point-min))
      (when-let ((btn (next-button (point) t)))
        (goto-char btn)
        (jsoa/diag-highlight-current))
      )

    ;; display like a panel
    (display-buffer
     buf
     '((display-buffer-at-bottom)
       (window-height . 0.35)))))

(defun jsoa/python-diagnostics-section (root)
  (if (eq (jsoa/project-type root) 'python)
      (progn
        (jsoa/start-section "Diagnostics")

        (let* ((dashboard-buf (current-buffer))
               (token (gensym "diag-"))
               (start (point-marker))
               end)

          (setq-local jsoa/diag-token token)

          ;; placeholder
          (insert "Scanning...\n\n")
          (setq end (point-marker))

          (let ((proc
                 (make-process
                  :name "jsoa-pyright"
                  :buffer (generate-new-buffer " *jsoa-pyright*")
                  :command '("pyright" "--outputjson")
                  :noquery t
                  :sentinel
                  (lambda (p _event)
                    (when (eq (process-status p) 'exit)
                      (let ((output
                             (with-current-buffer (process-buffer p)
                               (buffer-string))))
                        (kill-buffer (process-buffer p))

                        (let ((data (condition-case nil
                                        (json-parse-string output
                                                           :object-type 'hash-table
                                                           :array-type 'list)
                                      (error nil))))

                          (when (and (buffer-live-p dashboard-buf)
                                     (with-current-buffer dashboard-buf
                                       (eq token jsoa/diag-token)))

                            (with-current-buffer dashboard-buf
                              (let ((inhibit-read-only t)
                                    (pad (jsoa/dashboard-left-padding)))
                                (save-excursion
                                  (goto-char start)
                                  (delete-region start end)

                                  (let ((content-start (point)))

                                    ;; === SAME RENDER CODE ===
                                    (if (not data)
                                        (insert "Pyright failed\n\n")

                                      (let* ((diags (gethash "generalDiagnostics" data))
                                             (errors 0)
                                             (warnings 0)
                                             (items '()))

                                        (dolist (d diags)
                                          (let ((severity (gethash "severity" d)))
                                            (cond
                                             ((equal severity "error")
                                              (setq errors (1+ errors)))
                                             ((equal severity "warning")
                                              (setq warnings (1+ warnings))))
                                            (push d items)))

                                        ;; header
                                        (let ((err-start (point)))
                                          (insert (format "Errors: %d" errors))
                                          (make-text-button
                                           err-start (point)
                                           'action (lambda (_)
                                                     (jsoa/show-pyright-diagnostics root diags "error"))
                                           'follow-link t
                                           'face '(:inherit error :underline t))

                                          (insert "   ")

                                          (let ((warn-start (point)))
                                            (insert (format "Warnings: %d" warnings))
                                            (make-text-button
                                             warn-start (point)
                                             'action (lambda (_)
                                                       (jsoa/show-pyright-diagnostics root diags "warning"))
                                             'follow-link t
                                             'face '(:inherit warning :underline t)))

                                          (insert "\n\n"))

                                        ;; rows
                                        (dolist (d (seq-take (nreverse items) 5))
                                          (let* ((file (gethash "file" d))
                                                 (msg  (gethash "message" d))
                                                 (range (gethash "range" d))
                                                 (line (and range
                                                            (1+ (gethash "line"
                                                                         (gethash "start" range)))))
                                                 (label (format "%s:%d"
                                                                (jsoa/short-path file root)
                                                                (or line 0)))
                                                 (start (point)))

                                            ;; clickable file:line
                                            (insert label)
                                            (make-text-button
                                             start (point)
                                             'file file
                                             'line line
                                             'root root
                                             'action (lambda (btn)
                                                       (jsoa/open-file-other-window
                                                        (button-get btn 'file)
                                                        (button-get btn 'root)
                                                        (button-get btn 'line)))
                                             'follow-link t
                                             'face 'link)

                                            ;; message
                                            (insert "  ")
                                            (insert
                                             (truncate-string-to-width msg 80 nil nil t))
                                            (insert "\n"))
                                          )

                                        (insert "\n")))

                                    (indent-rigidly content-start (point) pad)))))))))))))

            )))
    t)
  nil)

(defun jsoa/project-info (root)
  "Render enhanced project info for ROOT."
  (let* ((name (file-name-nondirectory (directory-file-name root)))
         (default-directory root)

         ;; --- File count ---
         (files
          (if (file-directory-p (expand-file-name ".git" root))
              (length (split-string
                       (shell-command-to-string
                        "git ls-files --others --cached --exclude-standard")
                       "\n" t))
            (length (directory-files-recursively root ".*" nil nil t))))

         ;; --- Git info ---
         (branch (ignore-errors
                   (string-trim
                    (shell-command-to-string
                     "git rev-parse --abbrev-ref HEAD"))))

         (ahead (ignore-errors
                  (string-to-number
                   (string-trim
                    (shell-command-to-string
                     "git rev-list --count @{u}..HEAD 2>/dev/null")))))

         (behind (ignore-errors
                   (string-to-number
                    (string-trim
                     (shell-command-to-string
                      "git rev-list --count HEAD..@{u} 2>/dev/null")))))

         (changes (length
                   (split-string
                    (shell-command-to-string
                     "git status --porcelain")
                    "\n" t)))

         ;; --- Last commit ---
         (last-commit (ignore-errors
                        (string-trim
                         (shell-command-to-string
                          "git log -1 --pretty=format:'%h|%ar — %s'"))))

         ;; --- Project type ---
         (ptype (jsoa/project-type root))

         ;; --- Python env ---
         (venv (getenv "VIRTUAL_ENV"))
         (python-version (ignore-errors
                           (string-trim
                            (shell-command-to-string
                             "python --version 2>/dev/null"))))

         ;; --- Project size ---
         (size (ignore-errors
                 (string-trim
                  (shell-command-to-string
                   "du -sh . 2>/dev/null | cut -f1")))))

    ;; =========================
    ;; Render
    ;; =========================

    (insert "\n")
    (jsoa/start-section (format "Project: %s" name))

    ;; Top block
    (insert
     (format "Type:    %s\n" (capitalize (symbol-name ptype)))
     (format "Files:   %d\n" files)
     (format "Size:    %s\n\n" (or size "N/A")))

    ;; Git block
    (when branch
      (let* ((status-face (jsoa/git-status-face ahead behind changes))
             (status-text
              (concat
               (if (> (or ahead 0) 0) (format "↑%d " ahead) "")
               (if (> (or behind 0) 0) (format "↓%d " behind) "")
               (if (> changes 0) (format "✗%d" changes) ""))))

        ;; Branch label
        (insert "Branch:  ")

        ;; clickable branch
        (let ((start (point)))
          (insert branch)
          (make-text-button
           start (point)
           'action (lambda (_)
                     (let ((default-directory root))
                       (magit-status root)))
           'follow-link t
           'face 'link))

        ;; space
        (insert " ")

        ;; colored git status
        (insert
         (propertize status-text 'face status-face))

        (insert "\n"))

      ;; Last commit
      (when last-commit
        (when (string-match "^\\([^|]+\\)|\\(.*\\)$" last-commit)
          (let ((hash (match-string 1 last-commit))
                (msg  (match-string 2 last-commit)))

            (insert "Last:    ")

            ;; clickable commit hash
            (let ((start (point)))
              (insert hash)
              (make-text-button
               start (point)
               'action (lambda (_)
                         (let ((default-directory root))
                           (magit-show-commit hash)))
               'follow-link t
               'face 'link))

            ;; rest of message
            (insert " " msg "\n"))))

      (insert "\n"))

    ;; Environment block (Python only)
    (when (eq ptype 'python)
      (insert
       (format "Env:     %s %s\n"
               (or (and venv (file-name-nondirectory venv)) "none")
               (or python-version ""))))))


(defun jsoa/git-recent-files-section (root start-index)
  (let ((items (jsoa/git-recent-files-data root 5)))
    (jsoa/render-recent-files items root)
    start-index))

(defun jsoa/dashboard-actions (root start-index)
  (jsoa/start-section "Actions")

  (let ((actions
         (list
          (list "Magit Status"
                (lambda () (let ((default-directory root)) (magit-status root))))
          (list "Find File"
                (lambda () (let ((default-directory root))
                             (call-interactively #'projectile-find-file))))
          (list "Search"
                (lambda () (let ((default-directory root))
                             (call-interactively #'+default/search-project)))))))

    ;; Add README if it exists
    (when-let ((readme (jsoa/find-readme root)))
      (setq actions
            (append actions
                    (list
                     (list "Open README"
                           (lambda ()
                             (find-file (expand-file-name readme root))))))))

    ;; assign numbers
    (setq jsoa/dashboard-actions-list
          (cl-loop for (label fn) in actions
                   for i from start-index
                   collect (list i label fn)))

    ;; map for keybindings
    (setq jsoa/dashboard-actions-map
          (mapcar (lambda (a) (cons (nth 0 a) (nth 2 a)))
                  jsoa/dashboard-actions-list))

    ;; render
    (let ((start (point)))
      (insert
       (mapconcat (lambda (a)
                    (format "[%d] %s" (nth 0 a) (nth 1 a)))
                  jsoa/dashboard-actions-list
                  "   ")
       "\n\n")

      ;; attach buttons
      (dolist (a jsoa/dashboard-actions-list)
        (let ((text (format "[%d] %s" (nth 0 a) (nth 1 a)))
              (fn   (nth 2 a)))
          (save-excursion
            (goto-char start)
            (when (search-forward text nil t)
              (make-text-button
               (match-beginning 0) (match-end 0)
               'action (lambda (_) (funcall fn))
               'follow-link t
               'face 'link))))))

    (+ start-index (length actions))))

(defun jsoa/git-summary (root)
  (let ((default-directory root))
    (when (file-directory-p (expand-file-name ".git" root))
      (let* ((status-lines
              (split-string
               (shell-command-to-string "git status --porcelain=v1")
               "\n" t))

             (unstaged
              (seq-filter
               (lambda (l)
                 (and (>= (length l) 2)
                      (not (string-prefix-p "??" l))
                      (not (eq (aref l 1) ?\s))))
               status-lines))

             (commits
              (split-string
               (shell-command-to-string
                "git log -5 --pretty=format:'%h %d %s'")
               "\n" t)))

        ;; Unstaged
        (when unstaged

          (jsoa/start-section (format "Unstaged changes (%d)" (length unstaged)))

          (dolist (l unstaged)
            (let* ((file (string-trim (substring l 3)))
                   (status (substring l 0 2))
                   (label
                    (cond
                     ((string-match "^ M" status) "modified")
                     ((string-match "^ D" status) "deleted")
                     ((string-match "^ A" status) "added")
                     ((string-match "^ R" status) "renamed")
                     (t "changed"))))
              (let ((start (point)))
                (insert (format "%-10s %s\n" label file))
                (make-text-button
                 (+ start 11) (point) ;; after label
                 'action (lambda (_)
                           (jsoa/open-file-other-window file root))
                 'follow-link t
                 'face 'link))
              ))
          (insert "\n")
          (jsoa/dashboard-separator)
          )

        ;; Commits
        (when commits
          (jsoa/start-section "Recent Commits")
          (dolist (c commits)
            (if (string-match "^\\([a-f0-9]+\\)\\(.*\\)$" c)
                (let ((hash (match-string 1 c))
                      (msg (string-trim (match-string 2 c))))

                  ;; clickable commit hash
                  (let ((start (point)))
                    (insert hash)
                    (make-text-button
                     start (point)
                     'action (lambda (_)
                               (let ((default-directory root))
                                 (magit-show-commit hash)))
                     'follow-link nil
                     'face 'link))

                  ;; rest of line (non-clickable)
                  (when (not (string-empty-p msg))
                    (insert " " msg)))

              ;; fallback
              (insert c))

            (insert "\n"))
          (insert "\n")
          )))))

(defun jsoa/todos-section (root)
  "Render grouped TODO section for ROOT."
  (let ((default-directory root))
    (let* ((output
            (shell-command-to-string
             "rg --no-heading --line-number --color never \
-e 'TODO:' -e 'FIXME:' -e 'HACK:' -e 'NOTE:'"))
           (lines (split-string output "\n" t)))

      (if (null lines)
          (insert (propertize "No TODOs found 🎉\n\n" 'face 'success))

        ;; =========================
        ;; Parse + Group
        ;; =========================
        (let ((groups (make-hash-table :test 'equal)))

          (dolist (line lines)
            (when (string-match "^\\([^:]+\\):\\([0-9]+\\):\\(.*\\)$" line)
              (let* ((file (match-string 1 line))
                     (linenum (string-to-number (match-string 2 line)))
                     (text (string-trim (match-string 3 line))))

                (when (string-match "\\(TODO\\|FIXME\\|HACK\\|NOTE\\):\\s-*\\(.*\\)" text)
                  (let* ((key (match-string 1 text))
                         (msg (match-string 2 text)))
                    (push (list file linenum key msg)
                          (gethash key groups))))))
            )

          ;; =========================
          ;; Config
          ;; =========================
          (let ((order '("FIXME" "TODO" "HACK" "NOTE"))
                (faces '(("FIXME" . error)
                         ("TODO"  . font-lock-warning-face)
                         ("HACK"  . font-lock-constant-face)
                         ("NOTE"  . shadow))))

            (jsoa/start-section
             (format "TODOs (%d)" (length lines)))

            ;; =========================
            ;; Render Groups
            ;; =========================
            (dolist (type order)
              (let ((items (reverse (gethash type groups))))
                (when items

                  ;; Header
                  (let* ((icon (jsoa/todo-icon type))
                         (count (length items))
                         (face (cdr (assoc type faces))))
                    (when icon
                      (insert (propertize icon 'face face))
                      (insert " "))
                    (insert
                     (propertize
                      (format "%s (%d)\n" type count)
                      'face face)))

                  ;; Alignment prep
                  (let* ((labels
                          (mapcar (lambda (it)
                                    (format "%s:%d"
                                            (jsoa/short-path (nth 0 it) root)
                                            (nth 1 it)))
                                  items))
                         (max-label (apply #'max (mapcar #'string-width labels)))
                         (msg-width
                          (max 20 (- jsoa/dashboard-width max-label 6))))

                    ;; Rows
                    (cl-loop
                     for (file line key msg) in items
                     for label in labels
                     do
                     (let ((start (point))
                           (msg (truncate-string-to-width msg msg-width nil nil t)))

                       ;; file:line button
                       (insert label)
                       (make-text-button
                        start (point)
                        'action (lambda (_)
                                  (jsoa/open-file-other-window file root line))
                        'follow-link t
                        'face 'link)

                       ;; padding
                       (insert (make-string
                                (max 0 (- max-label (string-width label)))
                                ?\s))

                       ;; message (dimmed slightly)
                       (insert "  ")
                       (let ((msg-start (point)))
                         (insert
                          (propertize
                           (concat key ": ")
                           'face (cdr (assoc type faces))))  ;; colored keyword

                         (insert
                          (propertize
                           msg
                           'face 'shadow))
                         )

                       (insert "\n")))
                    )

                  (insert "\n"))))))))))

;; =========================
;; Render Pipeline
;; =========================

(defun jsoa/render-project-dashboard (root)
  (let ((inhibit-read-only t)
        (default-directory root)
        (idx 1))

    (setq jsoa/dashboard-actions-map nil)
    (erase-buffer)

    (jsoa/project-info root)

    (jsoa/dashboard-separator)

    (setq idx (jsoa/git-recent-files-section root idx))

    (when (eq (jsoa/project-type root) 'python)
      (jsoa/dashboard-separator)
      (jsoa/python-diagnostics-section root))

    (jsoa/dashboard-separator)
    (jsoa/render-loc-section root)

    (jsoa/dashboard-separator)

    (setq idx (jsoa/dashboard-actions root idx))

    (jsoa/dashboard-separator)

    (jsoa/git-summary root)

    (jsoa/dashboard-separator)

    (jsoa/todos-section root)

    ;; Center everything once
    (indent-rigidly (point-min) (point)
                    (jsoa/dashboard-left-padding))

    (jsoa/dashboard-move-to-content)))

;; =========================
;; Commands / Mode
;; =========================

(defvar jsoa/dashboard-actions-map nil)

(defun jsoa/dashboard-run-action (n)
  (when-let ((fn (alist-get n jsoa/dashboard-actions-map)))
    (funcall fn)))

(define-derived-mode jsoa-dashboard-mode special-mode "Dashboard"
  "Major mode for project dashboard."

  (suppress-keymap jsoa-dashboard-mode-map t)

  ;; navigation
  (define-key jsoa-dashboard-mode-map (kbd "TAB") #'forward-button)
  (define-key jsoa-dashboard-mode-map (kbd "<backtab>") #'backward-button)
  (define-key jsoa-dashboard-mode-map (kbd "RET") #'push-button)

  ;; highlight active button
  (add-hook 'post-command-hook #'jsoa/dashboard-highlight-button nil t))

(map! :map jsoa-dashboard-mode-map
      :n "1" (cmd! (jsoa/dashboard-run-action 1))
      :n "2" (cmd! (jsoa/dashboard-run-action 2))
      :n "3" (cmd! (jsoa/dashboard-run-action 3))
      :n "4" (cmd! (jsoa/dashboard-run-action 4))
      :n "5" (cmd! (jsoa/dashboard-run-action 5))
      :n "6" (cmd! (jsoa/dashboard-run-action 6))
      :n "7" (cmd! (jsoa/dashboard-run-action 7))
      :n "8" (cmd! (jsoa/dashboard-run-action 8))
      :n "9" (cmd! (jsoa/dashboard-run-action 9)))

(map! :map jsoa-dashboard-mode-map
      :n "TAB" #'forward-button
      :n "S-TAB" #'backward-button
      :n "RET" #'push-button)

(defun jsoa/project-command-center (project-root)
  (let* ((name (file-name-nondirectory
                (directory-file-name project-root)))
         (buf (get-buffer-create (format "*dashboard:%s*" name)))
         (gitignore (expand-file-name ".gitignore" project-root)))

    ;; Anchor project
    (when (file-exists-p gitignore)
      (find-file-noselect gitignore))

    (delete-other-windows)
    (balance-windows)

    ;; Show buffer
    (switch-to-buffer buf)

    ;; Initial render
    (with-current-buffer buf
      (cd project-root)
      (jsoa-dashboard-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jsoa/render-project-dashboard project-root)))

    ))

(defun jsoa/project-dashboard ()
  "Open dashboard for current project."
  (interactive)
  (let ((root (projectile-project-root)))
    (unless root
      (user-error "Not in a project"))
    (jsoa/project-command-center root)))
