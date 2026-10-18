# Standard Hash-Table Family

Consent Scheme treats the standard mutable hash-table APIs as one family with
several public facades. The family shares portable storage where its semantics
agree, but it does not force incompatible standards into one public procedure
set.

## Ownership

| Layer | Responsibility |
| --- | --- |
| `(stdlib hash-table implementation)` | Portable buckets, key policy, mutability, insertion links, copies, and mutation revisions; internal only. |
| `(stdlib hash-table)` | SRFI 125 behavior and the `(scheme hash-table)`, `(srfi 125)`, and `(srfi srfi-125)` imports. |
| `(stdlib hash-table basic)` | Planned SRFI 69 compatibility facade for `(srfi 69)`, `(srfi srfi-69)`, `(srfi :69)`, and `(srfi :69 basic-hash-tables)`. |
| `(stdlib hash-table r6rs)` | Planned SRFI 126 facade for `(srfi 126)` and `(srfi srfi-126)`, with R6RS-style constructors, vectors, capacity, and introspection. |
| `(stdlib hash-table insertion-ordered)` | Planned SRFI 250 facade for `(srfi 250)` and `(srfi srfi-250)`, with cursors and order-sensitive traversal. |

The internal engine uses intrusive separate chaining and a per-table layout
tag. Default SRFI 125 tables use compact unordered entries. The ordered layout
adds a doubly linked insertion chain for the future SRFI 250 facade. Each entry
carries its bucket link directly, so neither layout allocates bucket-list
pairs or per-entry sidecars.

| Layout | Entry payload fields | Whole-table traversal |
| --- | ---: | --- |
| `unordered` | 5: owner, key, value, hash, bucket-next | Bucket scan |
| `insertion-ordered` | 7: the common fields plus previous and next | Insertion chain |

The private constructor accepts an optional layout tag; the tag cannot change
after construction. Copies and empty copies retain it. Set operations accept
either source layout and preserve the destination layout. The SRFI 125 facade
accepts either layout while continuing to promise unspecified traversal order.
The future SRFI 250 facade will construct and require ordered storage. Its
first, last, next, previous, and cursor operations must not accept unordered
entries. Updating an ordered association preserves its position; deleting and
reinserting it appends a new entry. Public names and aliases do not change.

Lookup, bucket deletion, and rehashing select concrete entry accessors once per
operation. The internal traversal syntax selects bucket scanning or insertion
links once, carries iterator state in tail-call arguments, and saves the next
entry before the body runs. This permits pruning the current entry without
allocating a snapshot, iterator record, or per-entry closure. The traversal's
accessor support exports belong only to the internal library, not any public
hash-table facade.

The source-owning `(stdlib hash-table ...)` hierarchy makes the shared family
visible without merging incompatible standards. No umbrella library exports a
union of every facade. The chunk does not add an `(rnrs hashtables (6))` alias
or another `(scheme ...)` spelling; those names require their own explicit
library-surface decision.

The engine records two revisions. Its structural revision changes when entries
are inserted or removed, which is the invalidation boundary needed by future
cursors. Its mutation revision also changes when an existing value is replaced,
which lets SRFI 125 reject callbacks that mutate a table being traversed. A
removed entry clears its owner reference; that owner also serves as the stale
entry marker instead of retaining a separate liveness field.

## Primitive Runtime Boundary

The standard family does not reuse the representation of `(consent
identity-table)` or import `(consent identity-table primitive)`. Those private
runtime libraries have a deliberately different contract: fixed identity
policies, no user callbacks, explicit lifetime and release, bounded fallback
behavior when host identity hashing is unavailable, runtime accounting, and
separate owned and host namespaces. Their primitive overlay exposes only the
irreducible host identity operations.

The two layers share Consent Scheme's owned `eq?`, `eqv?`, and `equal?`
semantics. Standard hash tables package those semantics through SRFI 128
comparators and portable hash procedures. Comparator type tests, equivalence,
and hash callbacks remain above the primitive boundary. A future native
provider may accelerate the stdlib engine only if it preserves the same public
policy, order, mutability, and revision contracts; it must not expose bridge
identity or private table lifetime through a standard import.

This separation also prevents a dependency cycle. A direct R7RS host may use
SRFI 69 to supply private host identity hashing, while Consent's SRFI 69 surface
is itself a later facade over the standard hash-table engine.

## SRFI 125 Surface

`(stdlib hash-table)` is the source-owning library. `(scheme hash-table)` is the
canonical R7RS-large spelling and `(srfi 125)` is the secondary SRFI spelling.
The library supports comparator-based construction, the deprecated SRFI 69
constructor form, immutable literals and copies, mutation, traversal, copying,
conversion, and destructive set operations.

The implementation follows the official SRFI 125 specification directly. The
official sample source is recorded but not vendored because it is implemented
on top of SRFI 126, which is scheduled after SRFI 125 in Consent's facade
sequence. The complete upstream test program is vendored verbatim under
`fixtures/srfi-125/` and retains its MIT license. Its executable adaptation
retains all 88 upstream test forms. The executable adaptation replaces
unavailable import helpers, spells three bytevector-containing data forms with
R7RS constructors for the configured Racket reader, and replaces the test-runner
epilogue. The local portable implementation remains Apache-2.0.

## SRFI 125 Test Coverage

Coverage is split deliberately between upstream compatibility and independent
conformance tests. The upstream program exercises 44 of the 46 exported
identifiers; it does not call `hash-table-values` or `hash-table-entries`. The
local suite covers both, so every public export is exercised by at least one
portable test.

| Contract | Upstream | Independent | Combined |
| --- | ---: | ---: | ---: |
| Public exported identifiers | 44/46 | 46/46 | 46/46 |
| Traversal callbacks forbidden to mutate their table | 0/8 | 8/8 | 8/8 |
| Public mutators rejected by immutable tables | 0/14 | 14/14 | 14/14 |
| Upstream test forms retained by the executable port | 88/88 | n/a | 88/88 |

The independent suite also covers adversarial collisions and growth, fresh
entry result lists, comparator type rejection, unsupported weak-table options,
empty-pop and arity errors, cross-policy set behavior, capacity/load bounds,
stale-entry liveness, destructive self-set operations, and the shared engine's
insertion links and revision boundaries. All 18 original local cases run on
both layouts; nine additional cases cover default construction, layout
validation, copies, reserve/rehash, sparse collision pruning, and all four
source/destination layout combinations. Order-independent SRFI assertions
compare sets or key/value correspondence, including arbitrary `pop!` results.
The 45-case suite also covers callback and immutable-mutator guards on both
layouts. Emacs-hosted tests separately cover both layouts through the source
evaluator, resolver aliases, missing-export diagnostics, and provenance.

Weak or ephemeral storage, thread safety, and hash-distribution performance are
not claimed as conformance coverage. The portable provider rejects those
optional storage requests, and timing or statistical hash-quality tests would
not establish SRFI semantics. Public traversal order also remains unspecified;
stable order is tested only as an internal engine contract for the future SRFI
250 facade.

Expected lookup, insertion, update, and deletion cost is amortized constant time
when the supplied hash function distributes keys satisfactorily. Ordered
whole-table operations cost O(n); unordered traversal costs O(n + b), where b
is the bucket count. Immediately after ordinary growth, b is between roughly
4n/3 and 8n/3. Explicit over-reservation and heavy deletion can leave a much
sparser table; deletion retains capacity and does not implicitly rehash.
Procedures returning lists
allocate their required result lists; callback-only traversals do not first
allocate an entry snapshot or per-callback argument lists.

The provider grows before its occupied load exceeds three quarters. An explicit
capacity request reserves the smallest power-of-two bucket vector that admits
that many associations at the same load, rather than reserving two buckets per
requested association. Growth allocates only the replacement bucket vector and
relinks the existing entries.

## Storage Cost and Layout Tradeoff

For n associations and b buckets, unordered storage retains `5n + b + 14`
logical payload fields; ordered storage retains `7n + b + 14`. The fixed 14
fields comprise the nine-field table and five-field policy. Both layouts have
`n + 3` storage objects: n entry records, one table, one policy, and one bucket
vector. These counts exclude shared comparator objects, keys, values, cached
hash bignums, and host record/header/alignment costs. Resize temporarily retains
the old and new bucket vectors but does not duplicate entries.

Thus unordered storage saves two words per association and adds one fixed
table tag word relative to the former ordered-only engine. On a 64-bit host
that is about 16 bytes per entry, or 0.8 MB at 50,000 entries. The local Gambit
record inspection reports six structure slots for an unordered entry versus
eight for an ordered entry, including each record's type slot. Physical bytes
still depend on the host's headers and allocator; logical field counts are
not a portable heap-byte measurement.

Same-machine, three-run Guile medians at 50,000 integer associations compare
the former engine with the split's default unordered layout:

| Workload | Former engine | Unordered layout |
| --- | ---: | ---: |
| Growing insertion, 50,000 entries | 0.461s | 0.544s |
| Pre-sized insertion, 50,000 entries | 0.396s | 0.358s |
| Successful lookup, 500,000 calls | 1.714s | 1.871s |
| Missing lookup, 500,000 calls | 1.440s | 1.552s |
| Callback traversal, 500,000 visits | 0.548s | 0.801s |

The split trades some dispatch and bucket-scanning time for smaller entries;
it is not a general speed improvement. The ordered layout traversed the same
500,000 entries in 0.604s. After deleting 49,900 entries without shrinking the
131,072 buckets, ten traversals cost 0.205s unordered versus 0.0012s ordered.
Applications dominated by sparse scans should choose ordered storage when its
public facade is available, or rebuild a smaller unordered table explicitly.
These timings are evidence from one host and workload, not API guarantees.

Arbitrary user hash procedures can deliberately return the same value for every
key, so no generic provider can promise constant time for that case without
changing its equality contract. Such a table degrades to linear lookup and
quadratic bulk construction. The local stress suite retains a constant-hash
comparator to cover correctness through that path; hash-flood resistance is not
claimed for attacker-selected user hash procedures.

`tools/benchmark-hash-table.scm` reports raw same-host jiffy samples for growing
and pre-sized insertion, successful and missing lookup, callback traversal,
updates, deletion, sparse scans, logical storage shape, and constant-hash
scaling. It defaults to unordered storage; passing `--ordered` directly to the
Scheme program repeats the workloads with ordered storage. Run it through
`tools/run-portable-tests.sh` with
`CONSENT_PORTABLE_PROGRAM` set to that file. Compare three-run medians from the
same machine and host; the benchmark is intentionally not a correctness gate.
