;;; expose-popup-test.el --- Tests for expose-popup -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'expose-popup)

;;; ---------------------------------------------------------------------------
;;; Hover tips: a discovery mechanic reading the real installed keymap under
;;; `expose-key-prefix', not a second, hand-maintained list beside it -- the
;;; exact shape of drift already found once this session, in the README's
;;; own keybinding table falling behind the keymap it was documenting.
;;; ---------------------------------------------------------------------------

(defun jsoa-tip-explain () "Explain what this code does and why." (interactive))
(defun jsoa-tip-why () "Explain why this code exists, not merely what it does." (interactive))
(defun jsoa-tip-graph () "Graph what calls this, and what calls those, transitively out to a bound depth." (interactive))
(defun jsoa-tip-scroll () "Scroll the Expose popup down." (interactive))

(defun expose-popup-test-keymap ()
  "Return a keymap shaped like the real one: nested prefixes, one exclusion."

  (let ((h (make-sparse-keymap))
        (g (make-sparse-keymap))
        (top (make-sparse-keymap)))
    (define-key h "e" #'jsoa-tip-explain)
    (define-key h "y" #'jsoa-tip-why)
    (define-key g "r" #'jsoa-tip-graph)
    (define-key top "h" h)
    (define-key top "G" g)
    (define-key top "j" #'jsoa-tip-scroll)
    top))

(defmacro expose-popup-test-with-pool (keymap &rest body)
  "Run BODY with the tip pool reset and sourced from KEYMAP."

  (declare (indent 1))
  `(let ((expose-popup--tip-pool-computed nil)
         (expose-popup--tip-pool nil)
         (expose-popup-tip-exclude-commands '(jsoa-tip-scroll)))
     (cl-letf (((symbol-function 'expose-key-prefix-binding)
                (lambda () ,keymap)))
       ,@body)))

(ert-deftest expose-popup-test-collect-recurses-into-sub-keymaps ()
  ;; Exclusion is a different concern, tested separately below; bind it to
  ;; nothing here so this test is not at the mercy of whatever the real
  ;; default exclude list happens to contain.
  (let* ((expose-popup-tip-exclude-commands nil)
         (keymap (expose-popup-test-keymap))
         (pairs (expose-popup-tip-collect keymap [])))

    (should (= 4 (length pairs)))
    (should (equal "h e" (car (rassoc 'jsoa-tip-explain pairs))))
    (should (equal "h y" (car (rassoc 'jsoa-tip-why pairs))))
    (should (equal "G r" (car (rassoc 'jsoa-tip-graph pairs))))
    (should (equal "j" (car (rassoc 'jsoa-tip-scroll pairs))))))

(ert-deftest expose-popup-test-collect-excludes-configured-commands ()
  (let* ((expose-popup-tip-exclude-commands '(jsoa-tip-scroll))
         (pairs (expose-popup-tip-collect (expose-popup-test-keymap) [])))

    (should-not (rassoc 'jsoa-tip-scroll pairs))))

(ert-deftest expose-popup-test-pool-is-memoized ()
  (let ((calls 0))
    (expose-popup-test-with-pool (expose-popup-test-keymap)
      (cl-letf (((symbol-function 'expose-key-prefix-binding)
                 (lambda () (setq calls (1+ calls)) (expose-popup-test-keymap))))
        (expose-popup-tip-pool)
        (expose-popup-tip-pool)
        (expose-popup-tip-pool)
        (should (= 1 calls))))))

(ert-deftest expose-popup-test-pool-empty-is-not-an-error ()
  (expose-popup-test-with-pool nil
    (should-not (expose-popup-tip-pool))
    (should-not (expose-popup-random-tip))))

(ert-deftest expose-popup-test-description-is-first-docstring-line ()
  (should
   (equal "Explain what this code does and why."
          (expose-popup-tip-description 'jsoa-tip-explain))))

(ert-deftest expose-popup-test-description-truncates-long-lines ()
  (let ((expose-popup-tip-max-length 20))
    (let ((description (expose-popup-tip-description 'jsoa-tip-graph)))
      (should (= 21 (length description)))
      (should (string-suffix-p "…" description)))))

(ert-deftest expose-popup-test-random-tip-names-the-full-key-path ()
  (expose-popup-test-with-pool (expose-popup-test-keymap)
    (let ((tip (expose-popup-random-tip)))
      (should (string-match-p "\\`tip: SPC c h " tip)))))

;;; ---------------------------------------------------------------------------
;;; Regression: the tip must be picked once per hover, not once per
;;; mode-line redisplay.
;;;
;;; `expose-popup-mode-line-info' is the `:eval' form re-run on every
;;; mode-line refresh -- reading `expose-popup-random-tip' from inside it
;;; directly would re-randomize the tip for as long as one hover stayed on
;;; screen, flickering rather than holding still long enough to read.
;;; ---------------------------------------------------------------------------

(ert-deftest expose-popup-test-tip-is-stable-across-mode-line-refreshes ()
  (expose-popup-test-with-pool (expose-popup-test-keymap)
    (cl-letf (((symbol-function 'expose-popup-show-buffer) (lambda () nil)))
      (expose-popup-show-content "hover body")

      (let ((first (expose-popup-mode-line-info))
            (second (expose-popup-mode-line-info))
            (third (expose-popup-mode-line-info)))
        (should (equal first second))
        (should (equal second third))
        (should (string-match-p "tip:" first))))))

(ert-deftest expose-popup-test-hover-shows-a-tip ()
  (expose-popup-test-with-pool (expose-popup-test-keymap)
    (cl-letf (((symbol-function 'expose-popup-show-buffer) (lambda () nil)))
      (expose-popup-show-content "hover body")
      (should (string-match-p "tip:" (expose-popup-mode-line-info))))))

(ert-deftest expose-popup-test-action-result-does-not-show-a-tip ()
  "A result you asked for must not compete with a tip about something else."

  (expose-popup-test-with-pool (expose-popup-test-keymap)
    (cl-letf (((symbol-function 'expose-popup-show-buffer) (lambda () nil))
              ((symbol-function 'posframe-refresh) (lambda (&rest _) nil))
              ((symbol-function 'expose-history-add) (lambda (&rest _) nil)))

      ;; Even after a hover was showing a tip a moment ago.
      (expose-popup-show-content "hover body")
      (should (string-match-p "tip:" (expose-popup-mode-line-info)))

      (expose-popup-show-view
       (list :title "Explain" :body "the answer" :format 'plain))
      (should-not (string-match-p "tip:" (expose-popup-mode-line-info))))))
