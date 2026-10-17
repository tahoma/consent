;;; Provider-neutral mutable hash-table storage.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This internal library owns the shared storage model for the mutable hash
;;; table family.  Public SRFI and R7RS-large libraries remain separate
;;; facades because their constructors, introspection, traversal results, and
;;; mutation contracts differ.  Unordered entries omit insertion links;
;;; ordered entries keep a doubly linked chain for the future SRFI 250 facade.

(define-library (stdlib hash-table implementation)
  (export make-hash-table-policy
          hash-table-policy?
          hash-table-policy-type-test
          hash-table-policy-equivalence
          hash-table-policy-hash
          hash-table-policy-token
          hash-table-policy-comparator
          make-hash-table-storage
          hash-table-storage?
          hash-table-storage-policy
          hash-table-storage-layout
          hash-table-storage-mutable?
          hash-table-storage-size
          hash-table-storage-capacity
          hash-table-storage-mutation-version
          hash-table-storage-structural-version
          hash-table-storage-compatible?
          hash-table-storage-ref-entry
          hash-table-storage-set!
          hash-table-storage-delete!
          hash-table-storage-clear!
          hash-table-storage-reserve!
          hash-table-storage-copy
          hash-table-storage-entries
          hash-table-storage-loop
          ;; Expansion support for the internal traversal syntax.
          hash-table-storage-buckets
          unordered-entry-key
          unordered-entry-value
          unordered-entry-bucket-next
          ordered-entry-key
          ordered-entry-value
          hash-table-storage-first-entry
          hash-table-storage-last-entry
          hash-table-entry?
          hash-table-entry-key
          hash-table-entry-value
          hash-table-entry-set-value!
          hash-table-entry-next
          hash-table-entry-previous)
  (import (scheme base))
  (begin
    ;; A policy keeps key semantics independent from every public API facade.
    (define-record-type <hash-table-policy>
      (%make-hash-table-policy type-test equivalence hash token comparator)
      hash-table-policy?
      (type-test hash-table-policy-type-test)
      (equivalence hash-table-policy-equivalence)
      (hash hash-table-policy-hash)
      (token hash-table-policy-token)
      (comparator hash-table-policy-comparator))

    (define (make-hash-table-policy
             type-test equivalence hash token comparator)
      "Return a hash-table key policy from the supplied procedures."
      #((parameters
         (type-test (type procedure) (description "Key type predicate."))
         (equivalence (type procedure) (description "Key equivalence."))
         (hash (type procedure) (description "Key hash procedure."))
         (token (type any) (description "Compatibility identity token."))
         (comparator (type any) (description "Source comparator or #f.")))
        (returns (type hash-table-policy)
         (description "Reusable hash-table key policy."))
        (effects allocation error))
      (if (and (procedure? type-test)
               (procedure? equivalence)
               (procedure? hash))
          (%make-hash-table-policy
           type-test equivalence hash token comparator)
          (error "hash-table policy requires procedures"
                 type-test equivalence hash)))

    ;; Distinct records save two fields per unordered entry.  Neither layout
    ;; allocates bucket-list pairs or optional per-entry sidecars.  A false
    ;; owner marks a removed entry in either layout.
    (define-record-type <unordered-entry>
      (make-unordered-entry owner key value hash bucket-next)
      unordered-entry?
      (owner unordered-entry-owner set-unordered-entry-owner!)
      (key unordered-entry-key)
      (value unordered-entry-value set-unordered-entry-value!)
      (hash unordered-entry-hash)
      (bucket-next unordered-entry-bucket-next
                   set-unordered-entry-bucket-next!))

    ;; Ordered entries add only the two insertion-chain links.
    (define-record-type <ordered-entry>
      (make-ordered-entry
       owner key value hash previous next bucket-next)
      ordered-entry?
      (owner ordered-entry-owner set-ordered-entry-owner!)
      (key ordered-entry-key)
      (value ordered-entry-value set-ordered-entry-value!)
      (hash ordered-entry-hash)
      (previous hash-table-entry-previous
                %set-hash-table-entry-previous!)
      (next hash-table-entry-next %set-hash-table-entry-next!)
      (bucket-next ordered-entry-bucket-next
                   set-ordered-entry-bucket-next!))

    (define (hash-table-entry? object)
      "Return whether OBJECT is an entry in either storage layout."
      #((parameters (object (type any) (description "Possible entry.")))
        (returns (type boolean) (description "Whether OBJECT is an entry."))
        (effects pure))
      (or (unordered-entry? object) (ordered-entry? object)))

    (define (hash-table-entry-key entry)
      "Return ENTRY's key, independent of its layout."
      #((parameters (entry (type hash-table-entry) (description "Entry.")))
        (returns (type any) (description "Association key."))
        (effects error))
      (if (unordered-entry? entry)
          (unordered-entry-key entry)
          (ordered-entry-key entry)))

    (define (hash-table-entry-value entry)
      "Return ENTRY's value, independent of its layout."
      #((parameters (entry (type hash-table-entry) (description "Entry.")))
        (returns (type any) (description "Association value."))
        (effects error))
      (if (unordered-entry? entry)
          (unordered-entry-value entry)
          (ordered-entry-value entry)))

    (define (hash-table-entry-owner entry)
      "Return ENTRY's owner, or #f after removal."
      (if (unordered-entry? entry)
          (unordered-entry-owner entry)
          (ordered-entry-owner entry)))

    (define (%set-hash-table-entry-value! entry value)
      "Replace ENTRY's value in its concrete layout."
      (if (unordered-entry? entry)
          (set-unordered-entry-value! entry value)
          (set-ordered-entry-value! entry value)))

    ;; Structural and value-sensitive revisions serve different later APIs.
    (define-record-type <hash-table-storage>
      (%make-hash-table-storage
       policy buckets size mutable? mutation structural first last layout)
      hash-table-storage?
      (policy hash-table-storage-policy)
      (layout hash-table-storage-layout)
      (buckets hash-table-storage-buckets %set-hash-table-storage-buckets!)
      (size hash-table-storage-size %set-hash-table-storage-size!)
      (mutable? hash-table-storage-mutable? %set-hash-table-storage-mutable?!)
      (mutation hash-table-storage-mutation-version
                %set-hash-table-storage-mutation-version!)
      (structural hash-table-storage-structural-version
                  %set-hash-table-storage-structural-version!)
      (first hash-table-storage-first-entry
             %set-hash-table-storage-first-entry!)
      (last hash-table-storage-last-entry
            %set-hash-table-storage-last-entry!))

    ;; Smallest bucket vector allocated by the portable provider.
    (define minimum-bucket-count 8)

    (define (capacity->bucket-count capacity)
      "Return a power-of-two bucket count suitable for CAPACITY entries."
      ;; Automatic growth permits three live entries per four buckets.  Round
      ;; 4 * CAPACITY / 3 upward so an explicit capacity request receives the
      ;; same guarantee without reserving twice as many buckets.
      (let ((target
             (max minimum-bucket-count
                  (quotient (+ (* 4 capacity) 2) 3))))
        (let loop ((count minimum-bucket-count))
          (if (>= count target) count (loop (* 2 count))))))

    (define (make-hash-table-storage policy capacity mutable? . layout)
      "Return empty storage, defaulting to the unordered LAYOUT."
      #((parameters
         (policy (type hash-table-policy) (description "Key policy."))
         (capacity (type exact-non-negative-integer)
          (description "Requested association capacity."))
         (mutable? (type boolean) (description "Whether mutations work."))
         (layout (type list)
          (description "Optional unordered or insertion-ordered tag.")))
        (returns (type hash-table-storage)
         (description "Empty shared hash-table storage."))
        (effects allocation error))
      (if (not (hash-table-policy? policy))
          (error "invalid hash-table policy" policy))
      (if (not (and (exact-integer? capacity) (>= capacity 0)))
          (error "invalid hash-table capacity" capacity))
      (if (not (or (null? layout)
                   (and (null? (cdr layout))
                        (memq (car layout)
                              '(unordered insertion-ordered)))))
          (error "invalid hash-table layout" layout))
      (%make-hash-table-storage
       policy
       (make-vector (capacity->bucket-count capacity) #f)
       0
       (if mutable? #t #f)
       0
       0
       #f
       #f
       (if (null? layout) 'unordered (car layout))))

    ;; A named traversal loop has no iterator object or per-entry closure.
    ;; ENTRY is #f at the end.  Call LOOP with NEXT, POSITION, and new state.
    ;; Save the successor before BODY so deleting the current entry is safe.
    ;; Other structural mutations during traversal are not supported.
    (define-syntax hash-table-storage-loop
      (syntax-rules ()
        ((_ storage (entry next position loop) ((state initial) ...) body ...)
         (hash-table-storage-loop storage
          (entry next position loop key-of value-of)
          ((state initial) ...) body ...))
        ((_ storage (entry next position loop key-of value-of)
            ((state initial) ...) body ...)
         (let ((table storage))
           (if (eq? (hash-table-storage-layout table) 'insertion-ordered)
               (let ((key-of ordered-entry-key)
                     (value-of ordered-entry-value))
                 ;; Callers may need only one accessor, or neither.  These
                 ;; references keep both optional bindings warning-free.
                 key-of value-of
                 (let loop ((entry (hash-table-storage-first-entry table))
                            (position 0) (state initial) ...)
                   (let ((next (and entry (hash-table-entry-next entry))))
                     body ...)))
               (let* ((buckets (hash-table-storage-buckets table))
                      (limit (vector-length buckets))
                      (key-of unordered-entry-key)
                      (value-of unordered-entry-value))
                 key-of value-of
                 (let loop ((entry #f)
                            (position (if (= (hash-table-storage-size table) 0)
                                         limit 0))
                            (state initial) ...)
                   (if (and (not entry) (< position limit))
                       (loop (vector-ref buckets position)
                             (+ position 1) state ...)
                       (let ((next
                              (and entry
                                   (unordered-entry-bucket-next entry))))
                         body ...)))))))))

    (define (hash-table-storage-capacity storage)
      "Return the current association capacity of STORAGE."
      #((parameters
         (storage (type hash-table-storage) (description "Storage.")))
        (returns (type exact-positive-integer)
         (description "Capacity before the next automatic resize."))
        (effects error))
      (quotient
       (* 3 (vector-length (hash-table-storage-buckets storage))) 4))

    (define (hash-table-storage-compatible? left right)
      "Return whether LEFT and RIGHT use the same key policy identity."
      #((parameters
         (left (type hash-table-storage) (description "First storage."))
         (right (type hash-table-storage) (description "Second storage.")))
        (returns (type boolean) (description "Whether policies agree."))
        (effects error))
      (eq? (hash-table-policy-token (hash-table-storage-policy left))
           (hash-table-policy-token (hash-table-storage-policy right))))

    (define (check-mutable storage operation)
      "Signal an error unless STORAGE is mutable."
      (if (not (hash-table-storage-mutable? storage))
          (error "immutable hash table" operation storage)))

    (define (checked-key-hash storage key)
      "Return KEY's checked hash under STORAGE's policy."
      (let* ((policy (hash-table-storage-policy storage))
             (type-test (hash-table-policy-type-test policy)))
        (if (not (type-test key))
            (error "key rejected by hash-table comparator" key))
        (let ((hash ((hash-table-policy-hash policy) key)))
          (if (and (exact-integer? hash) (>= hash 0))
              hash
              (error "hash function returned invalid hash" hash key)))))

    (define (hash-index buckets hash)
      "Return HASH's index into BUCKETS."
      (modulo hash (vector-length buckets)))

    ;; Concrete bucket loops are generated from one body per operation.
    ;; Definitions stay explicit for source loaders that classify definitions
    ;; before expanding macros.
    (define-syntax bucket-find
      (syntax-rules ()
        ((_ policy entry key hash key-of hash-of next-of)
         (let ((equivalence (hash-table-policy-equivalence policy)))
           (let loop ((current entry))
             (cond
              ((not current) #f)
              ((and (= hash (hash-of current))
                    (equivalence key (key-of current)))
               current)
              (else (loop (next-of current)))))))))

    ;; Unlink from a concrete collision chain without rebuilding its prefix.
    (define-syntax bucket-delete!
      (syntax-rules ()
        ((_ policy buckets index key hash key-of hash-of next-of set-next!)
         (let ((equivalence (hash-table-policy-equivalence policy)))
           (let loop ((entry (vector-ref buckets index)) (previous #f))
             (cond
              ((not entry) #f)
              ((and (= hash (hash-of entry))
                    (equivalence key (key-of entry)))
               (let ((next (next-of entry)))
                 (if previous
                     (set-next! previous next)
                     (vector-set! buckets index next))
                 (set-next! entry #f)
                 entry))
              (else (loop (next-of entry) entry))))))))

    ;; Walk the old chains while relinking the same entries into new buckets.
    (define-syntax bucket-rehash!
      (syntax-rules ()
        ((_ storage bucket-count hash-of next-of set-next!)
         (let ((old (hash-table-storage-buckets storage))
               (buckets (make-vector bucket-count #f)))
           (do ((index 0 (+ index 1)))
               ((= index (vector-length old)))
             (let loop ((entry (vector-ref old index)))
               (if entry
                   (let ((next (next-of entry))
                         (index (hash-index buckets (hash-of entry))))
                     (set-next! entry (vector-ref buckets index))
                     (vector-set! buckets index entry)
                     (loop next)))))
           (%set-hash-table-storage-buckets! storage buckets)))))

    (define (find-unordered-entry policy entry key hash)
      "Find KEY in a compact bucket without per-probe layout dispatch."
      (bucket-find policy entry key hash
                   unordered-entry-key unordered-entry-hash
                   unordered-entry-bucket-next))

    (define (find-ordered-entry policy entry key hash)
      "Find KEY in an ordered bucket without per-probe layout dispatch."
      (bucket-find policy entry key hash
                   ordered-entry-key ordered-entry-hash
                   ordered-entry-bucket-next))

    (define (delete-unordered-entry! policy buckets index key hash)
      "Unlink KEY's compact entry from BUCKETS."
      (bucket-delete! policy buckets index key hash
                      unordered-entry-key unordered-entry-hash
                      unordered-entry-bucket-next
                      set-unordered-entry-bucket-next!))

    (define (delete-ordered-entry! policy buckets index key hash)
      "Unlink KEY's ordered entry from BUCKETS."
      (bucket-delete! policy buckets index key hash
                      ordered-entry-key ordered-entry-hash
                      ordered-entry-bucket-next
                      set-ordered-entry-bucket-next!))

    (define (rehash-unordered! storage bucket-count)
      "Relink compact entries into BUCKET-COUNT buckets."
      (bucket-rehash! storage bucket-count unordered-entry-hash
                      unordered-entry-bucket-next
                      set-unordered-entry-bucket-next!))

    (define (rehash-ordered! storage bucket-count)
      "Relink ordered entries without altering their insertion chain."
      (bucket-rehash! storage bucket-count ordered-entry-hash
                      ordered-entry-bucket-next
                      set-ordered-entry-bucket-next!))

    ;; Expand the outer dispatch to avoid an extra procedure call per lookup.
    (define-syntax find-entry-in-bucket
      (syntax-rules ()
        ((_ storage entry key hash)
         ((if (eq? (hash-table-storage-layout storage) 'unordered)
              find-unordered-entry find-ordered-entry)
          (hash-table-storage-policy storage) entry key hash))))

    (define (hash-table-storage-ref-entry storage key)
      "Return STORAGE's entry for KEY, or #f when absent."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (key (type any) (description "Key to look up.")))
        (returns (type (or hash-table-entry boolean))
         (description "Matching entry, or #f."))
        (effects error procedure-call))
      (let* ((hash (checked-key-hash storage key))
             (buckets (hash-table-storage-buckets storage))
             (bucket (vector-ref buckets (hash-index buckets hash))))
        (find-entry-in-bucket
         storage bucket key hash)))

    (define (increment-mutation! storage structural?)
      "Advance STORAGE's mutation revisions."
      (%set-hash-table-storage-mutation-version!
       storage
       (+ 1 (hash-table-storage-mutation-version storage)))
      (if structural?
          (%set-hash-table-storage-structural-version!
           storage
           (+ 1 (hash-table-storage-structural-version storage)))))

    (define (append-entry! storage entry)
      "Append ENTRY to STORAGE's insertion-order chain."
      (let ((last (hash-table-storage-last-entry storage)))
        (if last
            (begin
              (%set-hash-table-entry-next! last entry)
              (%set-hash-table-entry-previous! entry last))
            (%set-hash-table-storage-first-entry! storage entry))
        (%set-hash-table-storage-last-entry! storage entry)))

    (define (unlink-entry! storage entry)
      "Remove ENTRY from STORAGE's insertion-order chain."
      (let ((previous (hash-table-entry-previous entry))
            (next (hash-table-entry-next entry)))
        (if previous
            (%set-hash-table-entry-next! previous next)
            (%set-hash-table-storage-first-entry! storage next))
        (if next
            (%set-hash-table-entry-previous! next previous)
            (%set-hash-table-storage-last-entry! storage previous))
        (%set-hash-table-entry-previous! entry #f)
        (%set-hash-table-entry-next! entry #f)
        (set-ordered-entry-owner! entry #f)))

    (define (rehash! storage bucket-count)
      "Replace STORAGE's buckets with BUCKET-COUNT buckets."
      ((if (eq? (hash-table-storage-layout storage) 'unordered)
           rehash-unordered! rehash-ordered!)
       storage bucket-count))

    (define (hash-table-storage-reserve! storage capacity)
      "Ensure STORAGE can hold CAPACITY associations without growing."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (capacity (type exact-non-negative-integer)
          (description "Requested capacity.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error))
      (check-mutable storage 'hash-table-storage-reserve!)
      (if (not (and (exact-integer? capacity) (>= capacity 0)))
          (error "invalid hash-table capacity" capacity))
      (let ((bucket-count (capacity->bucket-count capacity)))
        (if (> bucket-count
               (vector-length (hash-table-storage-buckets storage)))
            (rehash! storage bucket-count))))

    (define (maybe-grow! storage)
      "Grow STORAGE before an insertion would exceed its load limit."
      (let ((buckets (hash-table-storage-buckets storage)))
        (if (> (* 4 (+ 1 (hash-table-storage-size storage)))
               (* 3 (vector-length buckets)))
            (rehash! storage (* 2 (vector-length buckets))))))

    (define (hash-table-storage-set! storage key value)
      "Associate KEY with VALUE in STORAGE and return its entry."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (key (type any) (description "Association key."))
         (value (type any) (description "Association value.")))
        (returns (type hash-table-entry)
         (description "Inserted or updated entry."))
        (effects mutation allocation error procedure-call))
      (check-mutable storage 'hash-table-storage-set!)
      (let* ((hash (checked-key-hash storage key))
             (buckets (hash-table-storage-buckets storage))
             (index (hash-index buckets hash))
             (entry
              (find-entry-in-bucket
               storage
               (vector-ref buckets index)
               key
               hash)))
        (if entry
            (begin
              (%set-hash-table-entry-value! entry value)
              (increment-mutation! storage #f)
              entry)
            (begin
              (maybe-grow! storage)
              (let* ((buckets (hash-table-storage-buckets storage))
                     (index (hash-index buckets hash))
                     (entry
                      (if (eq? (hash-table-storage-layout storage)
                               'unordered)
                          (make-unordered-entry
                           storage key value hash (vector-ref buckets index))
                          (make-ordered-entry
                           storage key value hash #f #f
                           (vector-ref buckets index)))))
                (vector-set! buckets index entry)
                (if (ordered-entry? entry) (append-entry! storage entry))
                (%set-hash-table-storage-size!
                 storage (+ 1 (hash-table-storage-size storage)))
                (increment-mutation! storage #t)
                entry)))))

    (define (hash-table-entry-set-value! entry value)
      "Set active ENTRY's VALUE without changing insertion order."
      #((parameters
         (entry (type hash-table-entry) (description "Entry to update."))
         (value (type any) (description "Replacement value.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation error))
      (if (not (hash-table-entry-owner entry))
          (error "inactive hash-table entry" entry))
      (let ((storage (hash-table-entry-owner entry)))
        (check-mutable storage 'hash-table-entry-set-value!)
        (%set-hash-table-entry-value! entry value)
        (increment-mutation! storage #f)))

    (define (hash-table-storage-delete! storage key)
      "Delete KEY from STORAGE and return whether it was present."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (key (type any) (description "Key to delete.")))
        (returns (type boolean) (description "Whether KEY was present."))
        (effects mutation allocation error procedure-call))
      (check-mutable storage 'hash-table-storage-delete!)
      (let* ((hash (checked-key-hash storage key))
             (buckets (hash-table-storage-buckets storage))
             (index (hash-index buckets hash))
             (entry
              ((if (eq? (hash-table-storage-layout storage) 'unordered)
                   delete-unordered-entry! delete-ordered-entry!)
               (hash-table-storage-policy storage)
               buckets
               index
               key
               hash)))
        (if (not entry)
            #f
            (begin
              (if (unordered-entry? entry)
                  (set-unordered-entry-owner! entry #f)
                  (unlink-entry! storage entry))
              (%set-hash-table-storage-size!
               storage (- (hash-table-storage-size storage) 1))
              (increment-mutation! storage #t)
              #t))))

    (define (hash-table-storage-clear! storage)
      "Delete every association from STORAGE."
      #((parameters
         (storage (type hash-table-storage) (description "Storage.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error))
      (check-mutable storage 'hash-table-storage-clear!)
      (if (> (hash-table-storage-size storage) 0)
          (begin
            (hash-table-storage-loop storage (entry next position advance) ()
              (if entry
                  (begin
                    (if (unordered-entry? entry)
                        (begin
                          (set-unordered-entry-bucket-next! entry #f)
                          (set-unordered-entry-owner! entry #f))
                        (begin
                          (%set-hash-table-entry-previous! entry #f)
                          (%set-hash-table-entry-next! entry #f)
                          (set-ordered-entry-bucket-next! entry #f)
                          (set-ordered-entry-owner! entry #f)))
                    (advance next position))))
            (%set-hash-table-storage-buckets!
             storage (make-vector minimum-bucket-count #f))
            (%set-hash-table-storage-size! storage 0)
            (%set-hash-table-storage-first-entry! storage #f)
            (%set-hash-table-storage-last-entry! storage #f)
            (increment-mutation! storage #t))))

    (define (hash-table-storage-entries storage)
      "Return a fresh list of entries in STORAGE's traversal order."
      #((parameters
         (storage (type hash-table-storage) (description "Storage.")))
        (returns (type list) (description "Fresh entry list."))
        (effects allocation error))
      (hash-table-storage-loop storage (entry next position advance)
          ((head '()) (tail #f))
        (if (not entry)
            head
            (let ((cell (list entry)))
              (if tail (set-cdr! tail cell))
              (advance next position (if tail head cell) cell)))))

    (define (hash-table-storage-copy storage mutable?)
      "Return a copy of STORAGE whose mutability is MUTABLE?."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (mutable? (type boolean) (description "Copy mutability.")))
        (returns (type hash-table-storage) (description "Storage copy."))
        (effects allocation error procedure-call))
      (let ((copy
             (make-hash-table-storage
              (hash-table-storage-policy storage)
              (hash-table-storage-size storage)
              #t
              (hash-table-storage-layout storage))))
        (hash-table-storage-loop storage (entry next position advance) ()
          (if entry
              (begin
                (hash-table-storage-set!
                 copy
                 (hash-table-entry-key entry)
                 (hash-table-entry-value entry))
                (advance next position))))
        (if (not mutable?)
            (%set-hash-table-storage-mutable?! copy #f))
        copy))))
