;;; ~/.doom.d/modes/pass.el -*- lexical-binding: t; -*-

;;
;; pass
;;

(after! pass
  (set-popup-rule! "^\\*Password-Store" :side 'left :size 0.35 :quit nil))
