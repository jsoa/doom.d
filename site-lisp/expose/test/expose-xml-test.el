;;; expose-xml-test.el --- Tests for expose-xml -*- lexical-binding: t; -*-

(require 'ert)
(require 'expose-xml)

(ert-deftest expose-xml-test-escape-entities ()
  (should
   (equal
    (expose-renderer-xml-escape "a & b < c > d \"e\" 'f'")
    "a &amp; b &lt; c &gt; d &quot;e&quot; &apos;f&apos;")))

(ert-deftest expose-xml-test-escape-nil-is-empty ()
  (should
   (equal
    (expose-renderer-xml-escape nil)
    "")))

(ert-deftest expose-xml-test-empty-p-nil-and-blank-string ()
  (should (expose-renderer-xml-empty-p nil))
  (should (expose-renderer-xml-empty-p ""))
  (should-not (expose-renderer-xml-empty-p "x"))
  (should-not (expose-renderer-xml-empty-p 0)))

(ert-deftest expose-xml-test-plist-empty-p-all-blank ()
  (should
   (expose-renderer-xml-plist-empty-p
    '(:a nil :b "")))
  (should-not
   (expose-renderer-xml-plist-empty-p
    '(:a nil :b "value"))))

(ert-deftest expose-xml-test-render-plist-omits-empty-values ()
  (let ((result
         (expose-renderer-xml
          '(:file "app.py" :language nil :focus ""))))

    (should
     (string-match-p "<file>app\\.py</file>" result))
    (should-not
     (string-match-p "<language>" result))
    (should-not
     (string-match-p "<focus>" result))))

(ert-deftest expose-xml-test-render-plist-escapes-value ()
  (let ((result
         (expose-renderer-xml
          '(:code "if a < b && c > d"))))

    (should
     (string-match-p "&lt;" result))
    (should
     (string-match-p "&gt;" result))
    (should
     (string-match-p "&amp;" result))
    (should-not
     (string-match-p "if a < b" result))))

(ert-deftest expose-xml-test-render-nested-list ()
  (let ((result
         (expose-renderer-xml
          '(:imports ("os" "sys")))))

    (should
     (string-match-p "<imports>" result))
    (should
     (string-match-p "<item>os</item>" result))
    (should
     (string-match-p "<item>sys</item>" result))))

(ert-deftest expose-xml-test-render-symbol-value ()
  (let ((result
         (expose-renderer-xml
          '(:type review))))

    (should
     (string-match-p "<type>review</type>" result))))

(ert-deftest expose-xml-test-tag-name-strips-keyword-colon ()
  (should
   (equal
    (expose-renderer-xml-tag-name :file)
    "file")))

(provide 'expose-xml-test)

;;; expose-xml-test.el ends here
