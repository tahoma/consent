;;; Exercise both storage layouts through the source-library evaluator.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (stdlib comparator)
        (except (stdlib hash-table) string-hash string-ci-hash)
        (only (stdlib hash-table implementation)
              make-hash-table-storage
              hash-table-storage-policy
              hash-table-storage-layout))

(define comparator (make-comparator integer? = < number-hash))
(define policy
  (hash-table-storage-policy (make-hash-table comparator)))

(map
 (lambda (layout)
   (let ((table (make-hash-table-storage policy 0 #t layout)))
     (hash-table-set! table 7 70 2 20 9 90)
     (hash-table-prune! (lambda (key value) (= key 2)) table)
     (let ((copy (hash-table-copy table)))
       (list (hash-table-storage-layout copy)
             (hash-table-size copy)
             (hash-table-fold (lambda (key value sum) (+ sum value)) 0 copy)
             (or (eq? layout 'unordered)
                 (equal? (hash-table-keys copy) '(7 9)))))))
 '(unordered insertion-ordered))
