# Design A1: Generation-Cached Live Results

- **Status:** Proposed (alternative to plan item A "drop Collection, keyset-Sequence + explicit snapshot")
- **Date:** 2026-07-12
- **Baseline:** lattice `Sources/Lattice/Results/Results.swift`, `Results/TableResults.swift`; latticecore post-deferred-delivery (`src/db.cpp` `drain_if_settled`, `src/lattice.cpp` txn-settled hooks, `docs/design-deferred-memory-delivery.md`)

---

## 1. Problem

Today's live `Results` re-queries SQLite on **every** access:

- `TableResults.count` → `endIndex` → `backend.count(...)` = a fresh `COUNT(*)` per read (`TableResults.swift:152-170`).
- `Results.subscript(index:)` → `snapshot(limit: 1, offset: i)` — and **traps** (`fatalError("Index out of bounds")`) when the fetch comes back empty (`Results.swift:234-241`; same trap in `Slice.subscript`, `Results.swift:180-189`).
- The two are issued at different instants, so under a concurrent writer (sync applies remote chunks on background threads, `sync.cpp:2777-2948`) `count == 10` can be followed by `subscript(9)` seeing a post-delete database → **index-out-of-bounds crash in production**. The crash is not a bug in either query; it is the *pairing* of two live queries as if they were one snapshot.
- `OFFSET` is O(offset): `query_rows` builds `SELECT * … LIMIT n OFFSET k` (`lattice.hpp:2616-2626`), so a `List` scrolled to row *i* issues one O(i) scan **per visible row**; deep scroll is quadratic. Even the batch `Cursor` iterates by OFFSET batches (`Results.swift:144-154`), so full iteration is O(n²/100).

What is worth keeping: it **is** live, and `RandomAccessCollection` gives SwiftUI `List`/`ForEach` lazy row loading — only visible rows are ever materialized. Plan item A gives that up (Sequence-only live type; random access only via a materialized `snapshot()`), which forces every `ForEach` over 100k rows to materialize 100k elements up front. This design keeps `Collection` and removes the crash and the quadratic scroll instead.

## 2. Assets this design is built on (all landed)

1. **Post-commit, per-transaction, exactly-once same-process change batches.** File DBs deliver via the WAL hook (`lattice.cpp:187-196`); memory/Emscripten DBs via the transaction-settled drain — the update hook only buffers + marks dirty (`lattice.cpp:96-116, 168-186`), and `database::drain_if_settled` flushes after any statement that restores autocommit (`db.cpp:177-192`), with rollback discard (`db.cpp:160-175`). Contract: exactly-once, batch walked in commit order, delivered **synchronously on the writing thread before `add()`/`commit()` returns** (`Lattice.swift:1551-1565`; deferred-delivery doc §3.4 "promptness").
2. **`changedFieldsNames` per row change.** The C++ `change_event` carries `changed_fields` (populated from AuditLog at flush, `lattice.hpp:1616-1642`); the Swift **object**-observer path already parses it (`Model.swift:80-102`). The Swift **table**-observer trampoline currently drops it — it decodes only ops/rowIds/gids (`CxxBackend.swift:418-441`). Refinement work, not baseline.
3. **Query-materialized elements are LIVE registered instances.** Every `Element(dynamicObject:)` hydration registers in `ModelInstanceRegistry` with a C++ object observer (`Model.swift:287-296`, `:60-133`); field updates refresh rendered rows via `_objectWillChange_send`/`_triggerObservers_send` (`Model.swift:199-224`) **independently of the collection**. Row *content* freshness therefore does not need collection invalidation.
4. **We own the WAL checkpoint pacer** (`sync.cpp:597-644`): TRUNCATE when due+idle with a 250 ms busy budget and PASSIVE fallback when readers hold the WAL (`sync.cpp:625-635`).
5. **Cross-process notifier** for file DBs: shared per-path, best-effort wakeups (`lattice.cpp:37-64`); the documented contract already says cross-process delivery can drop a wakeup (`Lattice.swift:1555-1558`).

## 3. Design overview

`TableResults` keeps its public shape and its `Collection` conformance. Internally, all index-based reads are served from a **generation cache**:

- A *generation* is an integer `G` plus lazily-filled state: `count`, an LRU map of keyset-fetched **pages**, and a persistent map of **keyset anchors** (page boundary → `(sortValue, id)`).
- Post-commit table-change batches (asset 1) **advance the generation** — an O(1) marker bump done synchronously in the observer callback. Nothing is refetched at invalidation time; rebuild cost is paid lazily on next access.
- `count` and `subscript` always answer from the current generation's cached state; a cache miss triggers exactly one SQL statement (`COUNT(*)` or one page fetch) that then *belongs to* that generation.
- Pages are fetched by **keyset continuation** from the nearest anchor (`WHERE (sort > ?) OR (sort = ? AND id > ?) ORDER BY sort, id LIMIT pageSize`), composed as a WHERE-fragment through the existing neutral surface `backend.objects(table:where:orderBy:limit:offset:)` (`Backend.swift:293-303`) — no new backend requirement for the baseline. A cold random jump (scrollbar fling) falls back to one `LIMIT pageSize OFFSET k` — O(k) **once per jump**, not per row — and records anchors so the neighborhood is keyset from then on.
- Because `id INTEGER PRIMARY KEY AUTOINCREMENT` exists on every model table (`lattice.hpp:2941`), `(sortColumn, id)` is always a total, stable order. Unsorted queries get an explicit `ORDER BY id` (today their order is whatever SQLite emits; making it deterministic is required for stable anchors and is a small behavior improvement).

Row field freshness is **delegated to the object path** (asset 3): cached pages hold live registered instances, so a field update repaints the row without touching the cache. The cache only answers *membership, order, and count*.

## 4. API surface

No protocol signature changes. `Results` stays `Sequence & RandomAccessCollection` (`Results.swift:10`). Additions are semantic + a small explicit-control surface:

```swift
public protocol Results<Element>: Sequence, RandomAccessCollection where SubSequence == Slice<Element> {
    // ... unchanged chaining API: where / sortedBy / group / distinct /
    //     observe / snapshot(limit:offset:) / nearest / withinBounds ...
}

extension TableResults {
    /// Force the next access to rebuild from the database (drops count + pages).
    public func refresh()

    /// Tuning knobs (defaults: pageSize 100, maxCachedPages 16).
    public var cachePolicy: ResultsCachePolicy { get set }
}

public struct ResultsCachePolicy: Sendable {
    public var pageSize: Int
    public var maxCachedPages: Int          // LRU bound on hydrated rows
    public var crossProcessBeltInterval: Duration?  // data_version poll floor; nil = notifier only
}
```

Internal engine (new file `Results/GenerationCache.swift`):

```swift
final class GenerationCache<Element: Model> {   // one per query shape, shared (see §10 risk 2)
    private struct Generation {
        let id: UInt64
        var count: Int?                          // filled by first count access
        var pages: [Int: [Element]]              // LRU-evicted
    }
    private var anchors: [Int: (sortKey: SQLValue, id: Int64)]  // survives generations & eviction
    private var current: Generation
    private var previousPages: [Int: [Element]]  // last generation's pages, kept until superseded (§5)
    private let lock = NSLock()
    private var observerToken: UInt64?           // backend.addTableObserver, registered lazily
}
```

The cache subscribes via **`backend.addTableObserver` directly** (`CxxBackend.swift:418`), *not* via `Lattice.observe(T.self…)`: the latter hops through `Task.detached` (`Lattice.swift:1671`) and would forfeit the synchronous-before-`add()`-returns delivery that makes read-your-writes hold (§6). The callback does lock → bump generation → unlock; all SQL happens later, on reader threads, outside the lock.

## 5. Consistency contract and the never-trap argument

**Contract: consistent-within-generation.** `startIndex`, `endIndex`/`count`, and `subscript` answer from one generation. Generations advance only at commit-notification arrival (or `refresh()`, or the cross-process belt check) — never spontaneously mid-answer.

Why the trap disappears:

1. **Stale count + cached page (common case):** both come from generation G. The deleted row's element is still cached and still a valid Swift object (live property reads of a deleted row return column defaults, not a crash — the accessor's SELECT simply finds no row). No trap, one frame of stale content, corrected on the very next render because the deletion's notification already bumped G *before the deleting transaction's `add()`/`commit()` returned* (asset 1).
2. **Stale count + cold page (the hole):** the page fetch runs against the post-delete database and comes back short. Fallback ladder, in order: (a) serve the previous generation's retained page (`previousPages`); (b) clamp — return the nearest existing fetched element; (c) if the table is now empty and *nothing* is cached, `endIndex` is re-resolved first — but if a caller holds a stale index anyway, subscript returns the last element of page 0 after a forced synchronous re-count. Step (c) is reachable only if a reader raced the *first ever* access against a full-table wipe; it renders a wrong row for one frame instead of crashing.
3. **Mid-iteration advance:** `IndexingIterator` re-reads `endIndex` each step, so a shrinking count ends the loop early; a growing one iterates further; either way subscript resolves via the ladder above. A single SwiftUI render pass can therefore observe at most two adjacent generations' *content*, never an inconsistent (count, subscript) pair that traps.

All cache state sits behind one lock; page fetches and hydration run outside it with a double-checked generation id (a fetch that completes for a dead generation is discarded, its anchors kept). Observer callbacks arrive on writer/scheduler threads (`Lattice.swift:1577`, C++ delivery is on the writing thread) and touch only the marker — no SQL, no allocation beyond a struct copy, no re-entrancy into SQLite from the delivery frame.

**Explicitly out of contract:** an atomic multi-row read. Anyone needing "all rows as of one instant" uses the existing `snapshot()`/`materializedSnapshot()` (`Results.swift:226-228`, `RowCache.swift:86-89`) — unchanged.

## 6. Invalidation pipeline, staleness, read-your-writes

```
writer thread                                reader/main thread
─────────────                                ──────────────────
COMMIT
 └─ WAL hook / drain_if_settled (post-commit, locks released)
     └─ notify_changes_batched → C trampoline (CxxBackend.swift:426)
         └─ cache: lock; gen += 1; retain pages as previousPages; unlock   ← O(1), synchronous
         └─ objectWillChange fan-out (ResultsChangePublisher, Results.swift:319-353)
                                              └─ SwiftUI schedules re-render
                                                 next render tick: count miss → 1 COUNT(*)
                                                                   visible page miss → 1-2 page fetches
```

- **Same-process staleness:** zero at the data level — the generation is bumped before the writer's `add()`/`write{}` returns (deferred-delivery doc §3.4; `Lattice.swift:1551-1554`). A reader on another thread that queries between commit and bump sees the *old generation's cached* state, which is exactly the consistent-within-generation promise. UI staleness = one main-runloop hop, same as today's `@LatticeQuery` debounce (`SwiftUI.swift:57-65`).
- **Read-your-writes:** holds for same-thread write-then-read *without* any await: by the time `try lattice.add(x)` returns, the generation is already advanced, so the next `count` access recomputes. This is strictly better than item A's snapshot model, where a stale snapshot must be manually re-taken.
- **Cross-process (file DBs):** wakeups ride the shared notifier → `handle_cross_process_notification` → table observers — best-effort by contract (`Lattice.swift:1555-1558`, `lattice.cpp:52-58`). Belt: on cache read, at most once per `crossProcessBeltInterval` (default ~1 s), issue `PRAGMA data_version` on the read connection; a changed value means some *other connection* committed → bump generation. `data_version` is not used anywhere in core today (verified by grep) — this is a new, tiny surface (one pragma; same-connection writes never change it, which is fine because same-connection writes always fire the update hook). Worst case with a dropped wakeup: UI stale for one belt interval, never a crash.

## 7. SwiftUI story: `List`/`ForEach` over 100k rows

- `ForEach` requires `RandomAccessCollection` — **kept**, so nothing changes at call sites: `List(results) { row in … }` still lazily materializes only visible rows. Item A would have broken this (Sequence can't back `ForEach` without full materialization).
- Idle (no writes): a render tick issues **0 collection queries** — count and visible pages are cached. Row field reads are the object path's cost, unchanged from today (per-field SELECT for live instances; `materialize()` per row is the existing zero-SQL option, `RowCache.swift:22-55`).
- During a write burst: invalidations are O(1) bumps; rebuild cost is bounded by *render frequency*, not write frequency. SwiftUI coalesces `objectWillChange` per frame, so a 1,000-txn/s sync burst costs at most ~60 × (1 COUNT + visible-page fetches)/s, versus today's same COUNT-per-tick *plus* one O(offset) statement per visible row per tick.
- Deep scroll: sequential scroll from row 0 to row 100k is pure keyset — O(pageSize) per page, O(n) total (today O(n²)). A scrollbar fling to row 90k costs one `LIMIT 100 OFFSET 89 900` (O(offset), once), then the neighborhood is anchored and keyset. Anchors are ~24 bytes per page boundary — 1,000 entries for 100k rows — and are never evicted, so revisiting an evicted page is a keyset fetch, not an OFFSET scan.
- `@LatticeQuery` today rebuilds a fresh `TableResults` per fetch (`SwiftUI.swift:42-55`) and `@Relation` builds one per property access (`Results.swift:367-385`) — for the cache to warm, it must be **shared per (lattice identity, query shape)**, keyed by `(table, whereSQL, orderBySQL, groupBy, distinctBy)` and held in a per-Lattice registry with weak/idle eviction. This is the main structural change (§10, risk 1). With it, `@LatticeQuery`'s debounced refetch becomes a generation-cache read instead of a fresh full `snapshot()`.

## 8. Perf model

| Operation | Today | A1 |
|---|---|---|
| `count`, idle | 1 × `COUNT(*)` per access | 0 (cached) |
| `count`, after commit | 1 × `COUNT(*)` per access | 1 × `COUNT(*)` per generation, amortized per render tick |
| `subscript(i)`, warm | 1 × `LIMIT 1 OFFSET i` (O(i)) | 0 (cached page) |
| `subscript(i)`, cold sequential | 1 × O(i) per row | 1 × keyset `LIMIT 100` per page (O(pageSize + log n)) |
| `subscript(i)`, cold random jump | 1 × O(i) per row | 1 × `OFFSET i` (O(i)) per jump, then keyset |
| Full iteration (`for-in`) | OFFSET batches, O(n²/100) (`Results.swift:144-154`) | keyset pages, O(n) |
| Render tick, idle | 1 COUNT + ~20 × O(i) row fetches | **0 queries** |
| Render tick, during writes | same as idle, every tick | ≤ 1 COUNT + 1-2 page fetches, ≤ once per frame |
| Write burst 1k txn/s | reader queries race writers each tick | 1k × O(1) bumps + ≤60 rebuilds/s |

Statement budgets are pinnable in tests via `Lattice.totalSQLStatementCount` / `threadSQLStatementCount` (`RowCache.swift:100-109`).

**Memory bounds:** `maxCachedPages × pageSize` hydrated elements (default 16 × 100 = 1,600; each holds a full `SELECT *` row copy — `lattice.hpp:2598` — plus a registry entry and one C++ object observer) + retained `previousPages` (≤ same bound, dropped as the new generation supersedes them) + anchors (O(n/pageSize), ~16 KB at 100k rows) + O(1) metadata. Worst case ≈ 2 × 1,600 rows ≈ low single-digit MB for typical row widths. Compare item A's `ResultsSnapshot`: unbounded — the whole result set.

## 9. Interplay

- **Checkpoint pacer (asset 4):** the cache holds **no open read transactions** — every rebuild is a discrete short statement. It therefore never pins the WAL against TRUNCATE checkpoints (`sync.cpp:625-635`); no lifetime coordination is required (unlike snapshot designs that hold long-lived readers). Conversely the pacer helps the cache: passive checkpoints bound the O(WAL-frames) page-lookup cost that made re-query storms catastrophic (`RowCache.swift:8-13`).
- **Object observation path (asset 3):** row content freshness is entirely the object path's job; the cache never refetches a page because a field changed. The division of labor is: object path = cell content; generation cache = membership/order/count; `objectWillChange` on the Results = "structure may have changed, re-render".
- **Filtered/sorted UPDATE edge:** an UPDATE can move a row in/out of the predicate or reorder the sort. **Baseline handles this for free**: any commit touching the table bumps the generation, and the next rebuild's SQL (`WHERE … ORDER BY …`) recomputes membership and order authoritatively. The refinement (skip invalidation when `changedFields ∩ (predicateColumns ∪ sortColumns) = ∅`) needs (a) the C trampoline extended to carry `changed_fields` — the C++ `change_event` already has it (`lattice.hpp:1642`), the trampoline drops it (`CxxBackend.swift:426-434`) — and (b) column extraction from the built predicate SQL. INSERTs can additionally use the existing membership probe pattern (`rowMatchesNow`, `Lattice.swift:1701-1706`); DELETE membership-before-change is knowable only via the AuditLog OLD-values trick (`Lattice.swift:1720-1731`), so DELETEs always invalidate. The refinement is a stretch goal; ship the baseline first.
- **`group`/`distinct`/bbox queries:** no stable `(sortKey, id)` cursor exists over grouped rows, so those shapes keep OFFSET paging *within* the generation (still cached, still never trap; cold pages are O(offset)). `countWithinBBox`/`objectsWithinBBox` (`TableResults.swift:165-170, 51-54`) slot into the same generation mechanics unchanged.

## 10. Migration burden from today's API

**Source-compatible: zero signature changes.** `Collection` kept, `snapshot()` kept, chaining kept. Semantic diffs to document in `MIGRATION-1.0.md`:

1. `count`/`subscript` are generation-cached: cross-thread readers observe a commit after its notification (same-process: before the writer's call returns; effectively immediate). Same-thread read-your-writes preserved.
2. Out-of-bounds subscript **clamps/serves-stale instead of trapping** (today: `fatalError`, `Results.swift:238`). Code intentionally relying on the trap (none plausible) breaks.
3. Unsorted queries gain a deterministic `ORDER BY id`.
4. Baseline memory grows by the page cache (bounded, configurable).

## 11. Risks (what could sink it)

1. **Cache identity/lifecycle** — biggest engineering risk. `@LatticeQuery.fetch()` and `@Relation` construct fresh `TableResults` constantly (`SwiftUI.swift:48`, `Results.swift:378`); a per-instance cache never warms. Requires a per-Lattice registry keyed by query shape with sane eviction, and the key is a SQL string — two semantically identical predicates that stringify differently get separate caches (acceptable), but a bug here means either leaks or permanent cold misses.
2. **Never-trap ladder correctness under adversarial delete bursts.** Mixed-generation frames are by-design possible; if SwiftUI identity animations see a row appear in two places for one frame, that's a visual glitch to be soaked out with identity-stable element reuse (reuse the same registered instance per rowId across pages/generations — `ModelInstanceRegistry` already dedups observers per key).
3. **Object-observer registration churn.** 1,600 cached rows = 1,600 `add_object_observer` registrations (`Model.swift:76-108`); page eviction during fast scroll registers/deregisters hundreds per second through a single `NSLock` (`Model.swift:55`). May need batch registration or a per-table observer multiplexer in the registry.
4. **Cross-process staleness belt is new core-adjacent surface.** Without the `data_version` belt, a dropped xproc wakeup (documented possibility, `Lattice.swift:1555-1558`) leaves the UI stale indefinitely; with it, we ship a poll — tuning `crossProcessBeltInterval` badly either burns statements or shows stale counts.
5. **Keyset edge cases:** nullable sort columns need an explicit NULLs block in the continuation predicate; DESC flips comparisons; float sort keys with duplicates rely entirely on the `id` tiebreaker. All standard, all testable, all easy to get subtly wrong.
6. **Burst pathology:** generation churn faster than render means `previousPages` are superseded before serving — degrades to cold pages every frame (≈ today's per-tick cost, minus the per-row OFFSET). Not a regression, but the win evaporates during sustained maximal churn; the refinement (risk-free skips via `changedFields`) is the recovery lever.

## 12. Test plan (sketch)

- **Crash repro pin:** background writer deleting rows in a loop while main thread does `count` + `subscript(count-1)` — trap today, must pass 10k iterations.
- **Statement budgets** via `threadSQLStatementCount`: idle render = 0; post-commit tick ≤ 1 + pages; full iteration of 10k rows ≤ n/pageSize + 1 statements.
- **Read-your-writes:** `add` → immediate `count` on same thread reflects the insert (no await).
- **Deep-scroll cost:** cold jump to 90k = exactly 1 statement; subsequent adjacent pages keyset (assert no OFFSET in SQL via a statement-tap or budget).
- **UPDATE-moves-row:** predicate on `status`, update flips status → row leaves/enters results next tick; sort-key update reorders.
- **Cross-process:** second process commits; belt disabled → stale until notifier fires; belt enabled → fresh within interval. Reuse `ObservationOrderingTests` to confirm no contract regression.
