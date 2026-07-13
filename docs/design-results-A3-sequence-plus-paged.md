# Design A3: Live `Results` as Sequence + explicit `snapshot()` / `paged()`

- **Status:** Proposed (1.0 replacement for live `Results` random access)
- **Date:** 2026-07-12
- **Baseline:** lattice `Sources/Lattice/Results/Results.swift`, `TableResults.swift`, `SwiftUI.swift`; latticecore post-deferred-delivery (`docs/design-deferred-memory-delivery.md`, `src/db.cpp drain_if_settled`, `src/sync.cpp maybe_checkpoint`)
- **Position:** steelman of the approved plan's item A, extended with `paged()` so lazy `List`/`ForEach` survives. The thesis: **make consistency explicit instead of simulating it** — no invalidation machinery, no stale-generation ambiguity, no traps.

---

## 1. Problem (grounded)

Today `Results` *is* a `RandomAccessCollection` (`Results.swift:10`) whose every
operation is a fresh SQL statement:

- `count`/`endIndex` → `SELECT COUNT(*)` **now** (`TableResults.swift:152–170`, via `backend.count`, `CxxBackend.swift:272–274`);
- `subscript(i)` → `SELECT * … LIMIT 1 OFFSET i` **now**, and traps on empty (`Results.swift:234–241`: `fatalError("Index out of bounds")`; same in `Slice`, `Results.swift:180–189`);
- the `Cursor` iterator batches by 100 but advances a raw `OFFSET` (`Results.swift:130–155`), and the C++ side appends literal `LIMIT`/`OFFSET` (`lattice.hpp:2616–2624`) — `OFFSET i` is O(i) in SQLite, so walking N rows by index is O(N²).

The trap is not theoretical: sync applies remote changes in background
transactions (`sync.cpp:2777+`), so `count` at t₀ and `subscript(i)` at t₁
observe different committed states. `Collection` *requires* that indices
obtained from the collection remain valid until mutation-you-control — a
contract a live view over a concurrently-written database **cannot** honor.
Every "fix" that keeps `Collection` on the live type either caches (and
inherits an invalidation problem, §8) or clamps silently (and lies to
`ForEach`'s differ mid-pass).

What we now have that the item-A design predates:

1. **Transaction-settled, exactly-once, per-transaction-batched change delivery** — file DBs via the WAL hook, memory DBs via the post-statement drain (`db.cpp:177–191 drain_if_settled`, hooks wired at `lattice.cpp:197–206`; contract documented at `Lattice.swift:1551–1565` and pinned by `ObservationOrderingTests`). Observers never fire mid-transaction anymore.
2. **`changedFieldsNames` per row change** on the Swift object path (`Model.swift:80–103` — the C++ object-observer callback delivers a JSON array of changed columns).
3. **Query-materialized models are live registered instances** (`Model.swift:286–296` registers each hydrated object in `ModelInstanceRegistry`; `notifyChange` at `Model.swift:199–224` fires `_objectWillChange_send()` + `_triggerObservers_send`). A rendered row refreshes its own fields without any collection work.
4. **We own the WAL checkpoint pacer** (`sync.cpp:597–644 maybe_checkpoint`; TRUNCATE falls back to PASSIVE when readers hold the WAL, `sync.cpp:630–635`).

---

## 2. Design overview

Three surfaces, one rule each:

| Surface | Conformance | Consistency rule |
|---|---|---|
| `Results` (live) | `Sequence` only | every call reads latest-committed **at call time**; one iteration is a keyset walk |
| `snapshot()` → `ResultsSnapshot` | `RandomAccessCollection` (immutable) | point-in-time copy; never changes |
| `paged()` → `PagedResults` | `RandomAccessCollection` (generation) | `count` pinned at creation; fills are lazy and **tolerant** — stale possible, traps impossible |

The live type stops pretending to be an array. Random access is a *choice*
with a named cost: `snapshot()` = O(k) copy, `paged()` = pinned-count window.

## 3. Exact API surface

```swift
// ── Live Results: Sequence, NOT Collection ─────────────────────────────
public protocol Results<Element>: Sequence {
    associatedtype Element
    associatedtype QueryType: _Query<Element>
    associatedtype UnderlyingElement

    // Unchanged query-builder / observation surface:
    func `where`(_ query: (QueryType) -> Query<Bool>) -> Self
    func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder) -> Self
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self
    func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self
    func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self
    func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable
    // …nearest/withinBounds/matching unchanged…

    // Point-in-time scalar reads (each = ONE statement, latest-committed):
    var count: Int { get }          // SELECT COUNT(*) — was endIndex
    var isEmpty: Bool { get }       // EXISTS probe (LIMIT 1)
    var first: Element? { get }     // LIMIT 1  (internal code already relies
                                    // on .first — Lattice.swift:1705,1724,1727)
    func makeIterator() -> KeysetCursor<Element>

    // Explicit random access:
    func snapshot() -> ResultsSnapshot<Element>                    // full copy
    func snapshot(limit: Int64?, offset: Int64?) -> [Element]      // raw, kept (backend primitive)
    func paged(pageSize: Int, maxCachedPages: Int) -> PagedResults<Element>
}

extension Results {
    public func paged() -> PagedResults<Element> { paged(pageSize: 100, maxCachedPages: 16) }

    // Source-break softeners — compile errors with a story, not silent removal:
    @available(*, unavailable, message: "live Results is not random-access; use paged() for lazy UI or snapshot() for a consistent copy")
    public subscript(index: Int) -> Element { fatalError() }
    @available(*, unavailable, message: "use paged() or snapshot()")
    public subscript(bounds: Range<Int>) -> [Element] { fatalError() }
}

// ── Immutable snapshot ────────────────────────────────────────────────
public struct ResultsSnapshot<Element>: RandomAccessCollection {
    private let elements: [Element]           // one SELECT — internally consistent
    public var startIndex: Int { 0 }
    public var endIndex: Int { elements.count }
    public subscript(position: Int) -> Element { elements[position] }
}

// ── Lazily-filled paged window ────────────────────────────────────────
public struct PagedResults<Element: Model>: RandomAccessCollection {
    // struct facade over a final-class storage box (page cache is shared
    // mutable state behind an NSLock; not Sendable — bind to creating isolation)
    public var startIndex: Int { 0 }
    public var endIndex: Int   // == count pinned by ONE COUNT(*) at creation
    public subscript(position: Int) -> Element   // tolerant fill — NEVER traps
    public var isStale: Bool   // set when a tolerant fill detected drift
    public let pageSize: Int
}
```

`KeysetCursor` replaces the OFFSET-advancing `Cursor` (`Results.swift:130–155`).
`Slice` (`Results.swift:157–223`) is deleted — its subscript has the same trap.
`@Relation` keeps returning `TableResults` (`Results.swift:356–398`) — relations
stay live; indexing into one now requires `.paged()`/`.snapshot()` like any other.

### 3.1 Keyset iteration (NULL-aware)

Deterministic total order is mandatory: the effective ORDER BY is always
`(sortColumn userDir, id ASC)`; unsorted queries get `ORDER BY id ASC` (a
behavior change — today `snapshot()` emits no ORDER BY when unsorted,
`TableResults.swift:47–48`, so order was arbitrary anyway).

Page fill after anchor `(v, k)` on ascending `sortCol` (SQLite sorts NULLs
first ASC):

```sql
-- anchor value NULL:      (sortCol IS NULL AND id > :k) OR sortCol IS NOT NULL
-- anchor value non-NULL:  (sortCol > :v) OR (sortCol = :v AND id > :k)
-- DESC mirror (NULLs last): (sortCol < :v) OR (sortCol = :v AND id > :k) OR sortCol IS NULL
```

ANDed into the existing predicate SQL (the predicate machinery already
composes raw SQL fragments — see the union CASE WHEN path,
`TableResults.swift:106–141`). Anchor comparisons must use the same collation
as the ORDER BY. With an index on the sort column (`@Indexed`,
`Model.swift:715–717`) each fill is an O(log N) seek + pageSize steps.

**Carve-out:** `group(by:)`/`distinct(by:)`/`withinBounds` queries have no
sound keyset anchor (grouped rows have no stable `(col, id)` identity;
R*Tree paths route through `objectsWithinBBox`, `TableResults.swift:51–54`).
These fall back to OFFSET page fills — same as today, minus the per-element
OFFSET.

### 3.2 `paged()` mechanics

- **Creation:** one `COUNT(*)` pins `endIndex`; store the query descriptor
  (predicate SQL, sort column/dir).
- **Sequential access** (the `List` scroll case): filling page p when page
  p−1's keyset anchor is known → keyset fill (§3.1). Anchors are recorded per
  filled page (two column values each — for 100k rows/100 per page that's
  1,000 anchors, negligible).
- **Random jump** (scrubber to row 90,000): ONE
  `LIMIT pageSize OFFSET page*pageSize` query for that page — O(offset) **once**,
  then the recorded anchor makes subsequent scrolling keyset again.
- **Tolerant fill:** a fill that returns fewer rows than expected (concurrent
  deletes shrank the table) never traps. The subscript serves, in order of
  preference: the requested row → the last row of the nearest earlier
  non-empty fill → the last element successfully returned by *any* fill (one
  element retained as a lifeboat; a `PagedResults` that was created with
  count > 0 has fetched at least one row before any index is served, because
  index 0's page fills first in every `ForEach`/`List` pass). Every clamp sets
  `isStale = true`. Clamped frames last until the next change-batch rebuild
  (≤ 1 frame in the SwiftUI wiring, §4).
- **Page cache:** LRU of `maxCachedPages` pages of strong `Element` refs.
  Eviction releases instances → `Model` deinit deregisters its C++ object
  observer (`Model.swift:391–394`). Live registered instances are therefore
  bounded at `maxCachedPages × pageSize` (default 1,600), regardless of table
  size.

## 4. SwiftUI story: lazy `List`/`ForEach` over 100k rows

`ForEach(liveResults)` stops compiling. That is the cost, and it is paid
**once per view**, visibly:

```swift
@LatticeQuery(sort: \.name) var people: TableResults<Person>

List($people.paged) { person in PersonRow(person) }   // preferred
// or, self-managed: List(people.paged()) { … }
```

`@LatticeQuery`'s wrapper already debounces observer fires to one fetch per
frame (`SwiftUI.swift:58–65`) and rebuilds `wrappedValue` on each change batch
(`SwiftUI.swift:42–55`, observation wired at `:89–93`). It gains a cached
projected `paged` value:

- **Idle body eval: 0 queries.** `endIndex` is the pinned count; visible rows
  hit the page cache. (Today: 1 `COUNT(*)` + one `LIMIT 1 OFFSET i` per
  visible row, *per body evaluation*.)
- **Change batch:** the table observer fires once per settled transaction
  (exactly-once, commit-ordered — `Lattice.swift:1551–1565`; memory DBs now
  batch per transaction too, `db.cpp:177–191`), the wrapper debounces to ≤1
  rebuild/frame, and rebuild = 1 `COUNT(*)` + refill of the currently visible
  page(s) on demand (~1–2 page queries). `List` diffs against the new
  generation; unchanged rows keep identity via `Model.id == primaryKey`
  (`Model.swift:419–425`).
- **Row-content updates ride the object path for free:** a field update on a
  visible row triggers that instance's `objectWillChange` via
  `ModelInstanceRegistry.notifyChange` (`Model.swift:199–224`) — the row
  re-renders even before (and independently of) the collection rebuild.
- **100k scroll:** creation = 1 COUNT; steady scrolling = one keyset fill per
  100 rows (O(log N) seek each with an indexed sort column, ~O(N) total for a
  full traversal vs O(N²) today); jump-to-bottom = one OFFSET-90k page query
  (single-digit ms for a b-tree skip), then keyset resumes. Memory stays at
  ≤1,600 hydrated rows.

`snapshot()` is the right tool below ~1k rows (pickers, settings lists):
one query, then a plain immutable collection — and it's what
`DetachedResults` already does per-row for the fine-grained value-type path
(`DetachedResults.swift:1–50`).

## 5. Concurrency & crash-safety argument

The production crash requires an API that does *count-then-offset against a
mutable view*. This design removes every such path **at compile time**:

- live `Results` has no subscript at all (unavailable, §3);
- `ResultsSnapshot` indexes an immutable Swift array populated by ONE
  `SELECT` — a single statement is one implicit read transaction, so the copy
  is internally consistent;
- `PagedResults.count` never changes after creation and its subscript is
  tolerant by construction (§3.2) — a fill racing a background sync apply
  returns short and clamps; no `fatalError` exists in the type.

No shared mutable iteration state crosses threads: `KeysetCursor` is a
single-owner iterator; `PagedResults`' page cache is lock-guarded and the type
is deliberately **not** `Sendable` (today's `TableResults` is
`@unchecked Sendable`, `TableResults.swift:7` — the paged window is bound to
its creating isolation; cross-actor hand-off goes through
`sendableReference`/`snapshot()` like everything else). Writers are unaffected:
all three surfaces only issue reads through `read_db()`.

## 6. Staleness contract (the whole contract, stated once)

- **Live `Results`:** every scalar (`count`, `first`, `isEmpty`) and every
  iteration *start* reads latest-committed at call time. Two consecutive calls
  may disagree — that is the definition of live. One iteration is a keyset
  walk: each key is visited at most once, in sort order; rows inserted behind
  the anchor mid-walk are missed, rows inserted ahead are seen; **no row is
  ever delivered twice, and iteration never traps** (a shrinking table just
  ends the walk early).
- **`ResultsSnapshot`:** frozen at the single SELECT. Never changes; per-row
  *field* reads are still live via the model handle unless the caller also
  `materialize()`s rows (`RowCache.swift`).
- **`PagedResults`:** a *generation*. `count` and page contents are as-of
  creation/fill time; drift shows up as `isStale` + clamped rows for at most
  one change-batch cycle before the wrapper mints a new generation. Nothing in
  a generation mutates while `ForEach` is diffing it — which is precisely the
  property `Collection` consumers assume and today's live type violates.

## 7. Perf model

| Scenario | Today | A3 |
|---|---|---|
| Idle render tick (List, V visible rows) | 1 COUNT + V `LIMIT 1 OFFSET` queries per body eval | **0 queries** (pinned count + page cache) |
| One write transaction committed | N per-row observer fires → debounced refetch; every body eval requeries | 1 batched fire (`Lattice.swift:1551–1565`) → ≤1 rebuild/frame: 1 COUNT + ~1–2 page fills |
| Sequential scroll of N rows | O(N²) (per-row OFFSET) | N/100 keyset fills; O(log N) each with indexed sort → ~O(N) |
| Jump to index i | O(i) *per body eval touching it* | O(i) **once**, then keyset |
| Full-table iteration (`for x in results`) | O(N²/100) via OFFSET batches (`Results.swift:144–154`) | O(N) keyset |
| Memory | unbounded only via `snapshot()` | iterator O(pageSize); paged ≤ pages×size elements (default 1,600 live instances + observers); snapshot O(k) |

Hydration cost note: each materialized `Element` registers a C++ object
observer (`Model.swift:293–295` → `add_object_observer`, `Model.swift:76`).
`paged()` bounds that; `snapshot()` of 100k rows would register 100k observers
— documented as the reason snapshot is for small k.

## 8. Why the simpler model beats caching (the steelman)

A cached live `Collection` ("keep `ForEach(results)` compiling, maintain an
in-memory ordered mirror, patch it from change events") must answer, per
UPDATE: *did this row enter/leave the predicate, and did it move in the sort?*
This codebase has already litigated that exact question and lost:
`Lattice.observe`'s filtered observers **abandoned** changedFields-vs-predicate
diffing because (1) member rows mutating non-predicate columns froze observing
UI and (2) membership-*before*-the-change is unknowable post-hoc — audit rows
carry new values only (`Lattice.swift:1687–1706`). The retreat was to
conservative fires + re-query. A caching collection would re-inherit the same
unsolvable inference or degrade to conservative re-query — i.e., to this
design, plus an invalidation engine, plus generation-identity questions
("which count is `ForEach` diffing against?"), plus a Swift-side reimplementation
of SQLite's ORDER BY (collations included) to splice rows into position.

Explicit generations make the answer boring: an UPDATE fires `.update`
unconditionally (`Lattice.swift:1734–1735`); the wrapper mints a new
`PagedResults`; SQLite — the only component that can evaluate the predicate
and the sort correctly — recomputes membership and order. `changedFieldsNames`
(asset b) stays available as a pure *optimization*: skip the rebuild when
`changedFields ∩ (predicate ∪ sort columns) = ∅` and let the object path
handle it — safe to add later because skipping is advisory, never
correctness-bearing.

**The ergonomic cost, honestly:** `ForEach(results)` and `results[i]` stop
compiling, in every consumer, forever. Each SwiftUI site makes a choice it
didn't have to make before, and the wrong easy choice (`snapshot()` on a huge
table) is a foot-gun we can only document and lint, not prevent. Muscle memory
from Realm/SwiftData (both hand out random-access live collections) works
against us. We judge the trade worth it because the alternative is an API that
compiles to a production trap — but the migration is a real, repo-wide cost
(`MIGRATION-1.0.md` gets three entries: subscript removal, `Sequence`-only
conformance, implicit `ORDER BY id`).

## 9. Interplay

- **Checkpoint pacer (asset d):** `maybe_checkpoint`'s TRUNCATE requires no
  readers holding the WAL (busy fallback, `sync.cpp:630–635`). All three
  surfaces issue short single statements and **never hold a read transaction
  across user code** — consistency is achieved by copying (`snapshot`,
  page fills), not by pinning a SQLite read snapshot. So collections cannot
  starve WAL truncation. This is a deliberate rejection of
  `sqlite3_snapshot`-style pinned readers: a pinned-snapshot `Results` would
  make every scrolled `List` an indefinite WAL-truncation blocker.
- **Object observation path (asset c):** unchanged and load-bearing — cached
  page rows self-refresh their fields (`Model.swift:199–224`), so most UPDATE
  traffic renders without any collection rebuild reaching steady state, and a
  clamped/stale generation still shows *live field values* while it lasts.
- **Filtered/sorted UPDATE edge:** a field update that moves a row across the
  predicate or reorders the sort cannot be handled by the object path (it
  refreshes fields, not positions). It is handled by the conservative `.update`
  dispatch (`Lattice.swift:1734–1735`) → generation rebuild → SQLite
  re-evaluates. Window of inconsistency: ≤1 frame, bounded by the existing
  debounce (`SwiftUI.swift:58–65`). DELETE membership uses the audit-row
  old-values check where available (`Lattice.swift:1720–1733`).
- **Cross-process (asset f):** file-DB wakeups are best-effort
  (`Lattice.swift:1555–1558`); a missed wakeup means a stale generation
  persists until the next local change or manual refresh — same failure class
  as today's `@LatticeQuery`, no regression.

## 10. Migration burden

| Today | 1.0 | Effort |
|---|---|---|
| `for x in results` / `Array(results)` / `map`/`filter` | unchanged (`Sequence`) | none |
| `results.count`, `.isEmpty`, `.first` | unchanged (explicit members) | none |
| `results[i]`, `results[a..<b]`, `Slice` | `paged()[i]` / `snapshot()[i]` | mechanical; compile-guided via unavailable subscript |
| `ForEach(results)` / `List(results)` | `List($query.paged)` / `List(results.snapshot())` | one decision per view |
| index-based `Collection` algorithms | operate on `snapshot()` | mechanical |
| unsorted iteration order | now pinned `ORDER BY id` | behavioral, almost always desired |
| internal: `observe`'s `.first` probes (`Lattice.swift:1705`) | keep working (`first` retained) | none |

## 11. Implementation risk (what could sink it)

1. **Ecosystem source break.** Every SwiftUI consumer edits every list view. If
   adoption pain pushes users to blanket `snapshot()`, we trade traps for
   memory/latency cliffs on big tables. Mitigation: `$query.paged` as the
   documented default; lint rule for `snapshot()` on unbounded queries.
2. **Keyset SQL correctness.** NULL ordering, collation-matched anchor
   comparisons, DESC mirrors, and the group/distinct/bounds carve-out are each
   a wrong-order/skipped-row bug waiting for a property test. This is the bulk
   of the test matrix.
3. **Tolerant-fill clamping can hand `ForEach` duplicate IDs** (clamped row =
   repeated element) for ≤1 frame — SwiftUI logs and may mis-animate. If it
   bites, the fallback is padding with the *nearest distinct earlier* element
   walk, at fill-time cost.
4. **Unindexed sort column** turns each keyset fill into a table scan —
   silently O(N) per page. Mitigation: debug-mode EXPLAIN check + log nudging
   `@Indexed`.
5. **Rebuild storms under sync churn:** heavy remote apply = 1 COUNT + page
   refills per frame. COUNT on a large table with a non-indexed predicate is
   the slow part; the changedFields∩columns skip (§8) is the escape valve if
   profiling demands it.
6. **Page-cache eviction churn** register/deregisters C++ object observers per
   row (`Model.swift:76`, `:184`); fast fling-scrolling 100k rows exercises
   this path ~2k times/s. Observer add/remove is a mutex + map op — believed
   fine, must be measured.

## 12. Test plan (pinning)

- `KeysetIterationTests`: NULL-first/last × ASC/DESC × collated TEXT ×
  duplicate sort values — walk equals `snapshot()` order; no dup, no trap under
  a concurrent deleter thread (the current repro for the OFFSET trap, inverted).
- `PagedResultsTests`: pinned count; tolerant fill under mid-scroll delete of
  the current page (asserts clamp + `isStale`, no trap); random jump then
  sequential (asserts exactly one OFFSET query via `LatticePerf` counters,
  `TableResults.swift:40`); LRU bound (≤ pages×size live registrations via
  `LatticePerf` registration counters, `Model.swift:61`).
- `LatticeQueryPagedTests`: 0 queries per idle body eval (perf counters);
  one rebuild per settled transaction batch; UPDATE-moves-row-across-predicate
  lands in ≤1 debounce cycle.
- Checkpoint interplay: fling-scroll a paged List while the pacer runs —
  assert TRUNCATE checkpoints still succeed (no persistent `busy`,
  `sync.cpp:629–635`).
