;;; Benchmark the portable standard hash-table engine.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; Run this program through tools/run-portable-tests.sh on the same host and
;;; target roots being compared.  Raw jiffy samples are evidence, not test
;;; assertions; hash-table conformance never depends on elapsed wall time.

(import (scheme base)
        (scheme process-context)
        (scheme time)
        (scheme write)
        (stdlib comparator)
        (rename (except (stdlib hash-table) string-hash string-ci-hash)
                (make-hash-table make-public-hash-table))
        (only (stdlib hash-table implementation)
              make-hash-table-storage
              hash-table-storage-policy
              hash-table-storage-buckets))

(define benchmark-size 50000)
(define lookup-rounds 10)
(define traversal-rounds 10)
(define benchmark-attempts 3)
(define benchmark-sink 0)

;; The ordered option exercises the same facade and workloads on ordered
;; storage.  Public construction remains the unordered path being measured.
(define benchmark-layout
  (if (member "--ordered" (command-line))
      'insertion-ordered 'unordered))

(define (make-hash-table comparator . capacity)
  "Construct the selected layout with COMPARATOR and optional CAPACITY."
  (let ((table (apply make-public-hash-table comparator capacity)))
    (if (eq? benchmark-layout 'unordered)
        table
        (make-hash-table-storage
         (hash-table-storage-policy table)
         (if (null? capacity) 0 (car capacity)) #t benchmark-layout))))

(define integer-comparator
  (make-comparator integer? = < number-hash))

(define collision-comparator
  (make-comparator integer? = < (lambda (key) 0)))

(define (elapsed-jiffies thunk)
  "Run THUNK and return its elapsed jiffies."
  (let ((started (current-jiffy)))
    (thunk)
    (- (current-jiffy) started)))

(define (fill-table! table size)
  "Associate every integer below SIZE with itself in TABLE."
  (let loop ((index 0))
    (if (< index size)
        (begin
          (hash-table-set! table index index)
          (loop (+ index 1))))))

(define (measure-lookups table start rounds)
  "Measure ROUNDS complete lookup passes beginning at START."
  (elapsed-jiffies
   (lambda ()
     (let repeat ((remaining rounds) (total 0))
       (if (= remaining 0)
           (set! benchmark-sink total)
           (let lookup ((offset 0) (subtotal total))
             (if (= offset benchmark-size)
                 (repeat (- remaining 1) subtotal)
                 (lookup
                  (+ offset 1)
                  (+ subtotal
                     (hash-table-ref/default
                      table (+ start offset) 1))))))))))

(define (measure-attempt attempt)
  "Return one ordinary-workload measurement for ATTEMPT."
  (let ((table (make-hash-table integer-comparator))
        (reserved (make-hash-table integer-comparator benchmark-size)))
    (let ((insert-grow
           (elapsed-jiffies
            (lambda () (fill-table! table benchmark-size))))
          (insert-reserved
           (elapsed-jiffies
            (lambda () (fill-table! reserved benchmark-size)))))
      (let ((lookup-hit (measure-lookups table 0 lookup-rounds))
            (lookup-miss
             (measure-lookups table benchmark-size lookup-rounds))
            (traverse
             (elapsed-jiffies
              (lambda ()
                (let repeat ((remaining traversal-rounds) (total 0))
                  (if (= remaining 0)
                      (set! benchmark-sink total)
                      (begin
                        (hash-table-for-each
                         (lambda (key value)
                           (set! total (+ total value)))
                         table)
                        (repeat (- remaining 1) total))))))))
        (list
         'attempt attempt
         (list 'insert-grow insert-grow)
         (list 'insert-reserved insert-reserved)
         (list 'lookup-hit lookup-hit)
         (list 'lookup-miss lookup-miss)
         (list 'traverse traverse))))))

(define (measure-collision-size size)
  "Return insertion and lookup jiffies for SIZE colliding keys."
  (let ((table (make-hash-table collision-comparator)))
    (let ((insert
           (elapsed-jiffies (lambda () (fill-table! table size)))))
      (let ((lookup
             (elapsed-jiffies
              (lambda ()
                (let loop ((index 0) (total 0))
                  (if (= index size)
                      (set! benchmark-sink total)
                      (loop (+ index 1)
                            (+ total (hash-table-ref table index)))))))))
        (list size (list 'insert insert) (list 'lookup lookup))))))

(define (measure-attempts)
  "Return the configured ordinary-workload attempts."
  (let loop ((attempt 1) (result '()))
    (if (> attempt benchmark-attempts)
        (reverse result)
        (loop (+ attempt 1)
              (cons (measure-attempt attempt) result)))))

(define (measure-mutation-and-sparse)
  "Measure update, deletion, and scans after deleting most associations."
  (let ((table (make-hash-table integer-comparator benchmark-size)))
    (fill-table! table benchmark-size)
    (let* ((update
            (elapsed-jiffies
             (lambda ()
               (do ((key 0 (+ key 1))) ((= key benchmark-size))
                 (hash-table-set! table key (+ key 1))))))
           (delete
            (elapsed-jiffies
             (lambda ()
               (do ((key 0 (+ key 1))) ((= key (- benchmark-size 100)))
                 (hash-table-delete! table key)))))
           (sparse
            (elapsed-jiffies
             (lambda ()
               (do ((round 0 (+ round 1))) ((= round traversal-rounds))
                 (hash-table-for-each
                  (lambda (key value)
                    (set! benchmark-sink (+ benchmark-sink value)))
                  table))))))
      (list (list 'update update) (list 'delete delete)
            (list 'sparse-traverse sparse)
            (list 'live (hash-table-size table))
            (list 'buckets
                  (vector-length (hash-table-storage-buckets table)))))))

(define (storage-shape size)
  "Report logical payload fields for SIZE immediate-key associations."
  (let* ((table (make-hash-table integer-comparator size))
         (buckets (vector-length (hash-table-storage-buckets table)))
         (entry-fields (if (eq? benchmark-layout 'unordered) 5 7)))
    (list size
          (list 'buckets buckets)
          (list 'entry-fields entry-fields)
          (list 'total-payload-fields (+ 9 5 buckets (* entry-fields size)))
          (list 'retained-objects (+ 3 size)))))

(write
 (list
  'stdlib-hash-table-benchmark
  '(schema 2)
  (list 'layout benchmark-layout)
  (list 'size benchmark-size)
  (list 'lookup-rounds lookup-rounds)
  (list 'traversal-rounds traversal-rounds)
  (list 'attempts (measure-attempts))
  (list 'mutation-and-sparse
        (map (lambda (attempt) (measure-mutation-and-sparse)) '(1 2 3)))
  (list 'storage-shapes (map storage-shape '(0 1 6 7 1000 50000)))
  (list 'collision-measurements
        (map measure-collision-size '(500 1000 2000)))
  (list 'jiffies-per-second (jiffies-per-second))
  (list 'sink benchmark-sink)))
(newline)
