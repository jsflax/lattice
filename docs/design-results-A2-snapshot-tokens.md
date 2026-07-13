# Design A2: Generation-Pinned Results via WAL Snapshot Tokens

- **Status:** Proposed (alternative to plan item A's "drop Collection, keyset-Sequence-only")
- **Date:** 2026-07-12
- **Baseline:** lattice `Sources/Lattice/Results/*`, latticecore post-deferred-delivery (`database::drain_if_settled`, `src/db.cpp:177-191`)
- **One sentence:** live `Results` keeps `RandomAccessCollection` by pinning each *generation* to a `sqlite3_snapshot` token (anchored by a pooled keeper read-transaction); every `count`/`subscript`/page fetch runs a short read transaction *at that token*, so all indices within a generation are MVCC-consistent and the concurrent-writer index-out-of-bounds trap is structurally impossible; transaction-settled change notifications (F2) advance the generation.

---

## 1. Problem being replaced

Today every access re-queries head state independently:

- `TableResults.endIndex` runs `SELECT COUNT(*)` **now** (`Results/TableResults.swift:165-170`); `count` aliases it (`:153`).
- `subscript(index:)` runs `snapshot(limit: 1, offset: i)` **now** and `fatalError`s on empty (`Results/Results.swift:234-241`); `Slice.subscript` same (`:180-189`).
- `Cursor` iterates in OFFSET batches of 100 (`Results/Results.swift:130-155`) — O(offset) per batch in SQLite, quadratic over a deep scan.
- All of these funnel to `lattice_db::query_rows` (`latticecore .../lattice/lattice.hpp:2582-2626`, plain `LIMIT/OFFSET` on `read_db()`) and `lattice_db::count` (`:2151-2193`).

Under a background sync writer (chunked apply transactions, `src/sync.cpp:2777+`), a delete can land between the `COUNT(*)` and the `OFFSET i` fetch → empty result → production trap. OFFSET makes deep scroll quadratic. Plan item A fixed this by dropping `Collection`; this design fixes it by making the reads *coherent* instead.

## 2. Verified ground facts (read, not assumed)

**Snapshot API availability.** We link the **system** SQLite on Apple and Linux (`latticecore/Package.swift:48,65,84,110,138` — `.linkedLibrary("sqlite3")`; no amalgamation in the SwiftPM build). Verified on this machine: Apple's system SQLite is **3.51.0 compiled with `ENABLE_SNAPSHOT`** (probe: `PRAGMA compile_options` lists `ENABLE_SNAPSHOT`; `sqlite3_snapshot_get` links against `-lsqlite3`), and the SDK headers declare the full API with `API_AVAILABLE(macos(10.12), ios(10.0), watchos(3.0), tvos(10.0))` (`MacOSX.sdk/usr/include/sqlite3.h:10461-10650`; iPhoneOS.sdk declares the same 36 references). So on Apple platforms — where SwiftUI Results live — the flag question is settled: **available, no vendoring needed**. The Android CMake path bundles amalgamation 3.45.0 with only `SQLITE_ENABLE_FTS5/JSON1/RTREE` (`latticecore/CMakeLists.txt:12-24`) — we own it, add `SQLITE_ENABLE_SNAPSHOT` there. **Linux system sqlite3 is NOT guaranteed to have it** (distro-dependent) — see §10 fallback, which must exist anyway.

**Exact API contract** (from the SDK header, `sqlite3.h:10483-10589`):

- `sqlite3_snapshot_get(D,"main",&P)` requires: **not autocommit** (issue `BEGIN` first), WAL mode, no write txn, and ≥1 transaction written to the *current* WAL file — else `SQLITE_ERROR`. If it opens the read transaction itself, **"it is guaranteed that the returned snapshot object may not be invalidated by a database writer or checkpointer until after the read-transaction is closed"** (`:10498-10504`). That guarantee is the keel of this design.
- `sqlite3_snapshot_open(D,"main",P)` requires: not autocommit, no active statements; returns **`SQLITE_ERROR_SNAPSHOT` if the snapshot "has been overwritten by a checkpoint"** (`:10556-10558`) — in wal.c terms, if the WAL salts changed (RESTART/TRUNCATE) *or* `nBackfillAttempted` passed the token's mxFrame, i.e. **even a PASSIVE checkpoint kills unanchored tokens**. A fresh connection must "know" the DB is WAL (run `PRAGMA application_id` after open, `:10578-10585`).
- `sqlite3_snapshot` is a 48-byte opaque struct (`:10479-10481`), freed with `sqlite3_snapshot_free`.

**Consequence:** a bare token pins nothing. The unit of pinning in SQLite is an **open read transaction** (checkpointers only backfill up to the minimum reader mark; RESTART/TRUNCATE go busy against it — exactly what `maybe_checkpoint`'s TRUNCATE→PASSIVE fallback already handles, `src/sync.cpp:629-636`, 250 ms busy budget `db.cpp:673`). So a generation = **token + keeper read-transaction**, not token alone. The prompt's "token, not an open read txn" shape is unsound against the documented invalidation rule; the keeper is what makes `SQLITE_ERROR_SNAPSHOT` an edge case instead of the steady state.

**Assets in place:** post-commit exactly-once per-transaction batched delivery on the writing thread (`database::drain_if_settled`, `src/db.cpp:177-191`; design in `latticecore/docs/design-deferred-memory-delivery.md` §3); table observers with commit-ordered batches (`lattice.hpp:1929 notify_changes_batched`); Swift delivery contract pinned at `Lattice.swift:1551-1566`; per-row `changedFieldsNames` on the object path (`Model.swift:80-103`); live registered instances refresh rendered rows independently (`ModelInstanceRegistry.notifyChange`, `Model.swift:199-224`); the checkpoint pacer is ours (`sync.cpp:597-644`, defaults 60 s PASSIVE / 300 s TRUNCATE, `sync.hpp:214-215`); cross-process notifier is best-effort darwin notify (`src/cross_process_notifier_darwin.cpp`).

## 3. Type & API surface

### Swift (public — `Results` protocol keeps its shape)

```swift
public protocol Results<Element>: Sequence, RandomAccessCollection where SubSequence == Slice<Element> {
    // unchanged: where/sortedBy/group/distinct/observe/nearest/withinBounds/matching
    func snapshot(limit: Int64?, offset: Int64?) -> [Element]   // kept (now generation-consistent)
    func element(at index: Int) -> Element?                      // NEW: non-trapping access
    func refresh()                                               // NEW: force generation advance
    var generationID: UInt64 { get }                             // NEW: diagnostics / cache keys
}

extension Results {
    public subscript(index: Int) -> Element      // kept; reads AT the pinned generation
    public var count: Int                        // kept; cached per generation
    public func makeIterator() -> Cursor<Element> // kept; iterator pins its generation
}
```

### Swift (internal — `TableResults` becomes a facade over an atomic generation)

```swift
final class TableResults<Element: Model>: Results, ObservableObject, @unchecked Sendable {
    // Immutable-after-publish; swapped atomically. All reads load it ONCE per top-level access.
    final class Generation {
        let handle: ReadGenerationRef          // C++ FRT: token + keeper txn (nil → fallback modes, §10)
        let id: UInt64
        private lazy var cachedCount: Int      // 1 COUNT(*) at token, then free
        private lazy var ids: ContiguousArray<Int64>?  // materialized on first deep/random access
        private let pageCache: PageCache<Element>      // LRU, ~4 pages × 200 rows
        func count() -> Int
        func element(at i: Int) -> Element?    // ids[i] → hydrate by pk at token (page-batched)
        func page(_ range: Range<Int>) -> [Element]
        func keysetContinue(after cursorKey: (AnyHashable, Int64), batch: Int) -> [Element] // Cursor path
    }
    private let currentGen: ManagedAtomicLazyReference<Generation>
    private let staleFlag = ManagedAtomic<Bool>(false)   // set by table observer (writer thread, settled)
    // top-level access: if staleFlag { repin() }; iterators/slices capture `gen` once.
}
```

### C++ core (`lattice_db` + `database`)

```cpp
// db.hpp — class database (src/db.cpp)
int  snapshot_begin_get(sqlite3_snapshot** out);   // BEGIN; sqlite3_snapshot_get — keeper anchor
int  snapshot_begin_open(sqlite3_snapshot* tok);   // BEGIN; sqlite3_snapshot_open — per-fetch
void txn_end();                                     // COMMIT the read txn

// lattice.hpp — class lattice_db
class read_generation {                 // refcounted; bridged as an FRT (ReadGenerationRef)
    database* keeper_;                  // from a small pool (max 3, cache_size clamped, §8)
    sqlite3_snapshot* token_;           // may be null (fallback modes)
    uint64_t id_;
    std::chrono::steady_clock::time_point born_;
};
std::shared_ptr<read_generation> acquire_read_generation();   // BEGIN+get on pooled keeper
size_t read_generations_outstanding() const;                  // pacer consults
void   request_generation_advance();                          // pacer pressure → notifies observers
// query_rows / count / query_union_rows / objects_within_bbox / nearest overloads taking
// read_generation& — identical SQL, executed on a pool read connection inside
// snapshot_begin_open(token) … txn_end(), or serialized on the keeper when token==null.
```

Fetch protocol per call: pool connection → `BEGIN` → `snapshot_open(token)` → run the same SQL `query_rows`/`count` build today (`lattice.hpp:2582/2151`) → `COMMIT`. On `SQLITE_ERROR_SNAPSHOT`/`SQLITE_BUSY`: release, `acquire_read_generation()` fresh, mark the Swift facade stale, retry once at the new generation; on second failure return empty and schedule refresh — **never trap**.

## 4. Generation lifecycle & checkpoint-pacer protocol

**Advance triggers:** (1) table-observer fire for `Element` — exactly-once, transaction-settled, on the writer thread (`drain_if_settled` → `notify_changes_batched` → `Lattice.observe`, `Lattice.swift:1655-1748`) sets `staleFlag`; the swap executes at the next *top-level access* or on the lattice's isolation when `objectWillChange` is delivered; (2) explicit `refresh()`; (3) `SQLITE_ERROR_SNAPSHOT` recovery; (4) pacer pressure (below). Old generations are refcounted — an in-flight render finishes on gen N while gen N+1 exists; keeper txn closes and token frees when the last reference drops.

**Pacer coordination** (`synchronizer_base::maybe_checkpoint`, `src/sync.cpp:597-644`):

1. **PASSIVE:** unchanged. Keeper read-marks bound backfill automatically; PASSIVE can never invalidate an anchored generation (§2 guarantee). It still drains the WAL up to the oldest keeper — steady progress.
2. **TRUNCATE:** gate on `read_generations_outstanding() == 0`. Today a held reader makes TRUNCATE burn its 250 ms busy budget and fall back to PASSIVE (`sync.cpp:629-636`); the gate skips the futile writer stall. When gated, call `request_generation_advance()` — delivered like a change notification, so live facades re-pin, keepers close, and the *next* pacer cycle truncates. Generations advance on every settled write anyway, so in practice keepers are milliseconds old and the gate is rarely taken.
3. **TTL hard cap (WAL growth backstop):** if the oldest generation exceeds `generation_ttl` (default 30 s) *and* WAL frames exceed a threshold, core force-closes its keeper txn (token stays allocated; the next fetch on it hits `SQLITE_ERROR_SNAPSHOT` and recovers via §3). This bounds WAL retention even when a *cross-process* writer churns the WAL and our best-effort wakeup (`cross_process_notifier_darwin.cpp`) misses — the only case where a generation can grow old while the WAL grows.
4. `~database`'s close-time PASSIVE checkpoint (`src/db.cpp:139-141`) and `DEFAULT_WAL_AUTOCHECKPOINT=1000` (system build) both behave like (1) — safe against anchored generations, no special-casing.

## 5. SwiftUI story: lazy List/ForEach over 100k rows

`@LatticeQuery` keeps its exact structure (`SwiftUI.swift:42-95`): observe → debounced once-per-frame `fetch()` (`:58-65`) → new `TableResults` → `objectWillChange`. Two changes:

- `fetch()` no longer *re-queries*; it re-pins: the fresh `TableResults` binds the current generation at creation, so **each render tick reads one frozen generation**. `List(results)`/`ForEach(results)` use the `RandomAccessCollection` conformance exactly as today: SwiftUI reads `count` (1 cached COUNT(*) at the token) and subscripts **only visible rows** (~20 of 100k) — lazy row loading is preserved, which is the whole reason to keep `Collection`.
- Deep scroll (scrollbar drag to row 90 000): first random access past the warm window materializes the generation's id vector — one index-only `SELECT id FROM T WHERE p ORDER BY s, id` at the token (100k × 8 B = 800 KB, tens of ms, off-isolation with placeholder rows) — then `results[i]` = `ids[i]` + primary-key hydrate, O(log n) per row. No OFFSET anywhere on the random-access path. `Cursor` iteration uses keyset continuation `WHERE (s, id) > (:last_s, :last_id) ORDER BY s, id LIMIT 100` (plan asset e; valid because order is frozen at the token), replacing the O(offset)-per-batch creep at `Results/Results.swift:144-154`.

Rendered row *values* stay on the object path: hydrated elements are live registered instances (`Model.swift:286-296` registers on hydration), so a field update refreshes the row's Text via `ModelInstanceRegistry.notifyChange` + `changedFieldsNames` without touching the collection (asset c). Strict row-image consistency remains opt-in via `materialize()` (`RowCache.swift`).

## 6. Concurrency & crash-safety argument

1. **Within a generation:** count, id vector, pages, and row hydration all execute inside read transactions opened at the *same* snapshot token — one WAL frame set, plain MVCC. If `i < gen.count()`, the row exists in that snapshot; the `LIMIT 1 OFFSET i`-returns-empty trap (`Results/Results.swift:236-240`) is impossible, including while a background sync thread deletes rows at head.
2. **Across generations:** the swap is an atomic store of an immutable object, taken only at (a) top-level access after a stale mark, (b) isolation-delivered notification, (c) explicit `refresh()`. Iterators, slices, and each `@LatticeQuery` render tick capture the generation once. A background writer can therefore never move the world between a same-context `count` and `subscript`; only *your own* interleaved write can (classic live-collection semantics, and read-your-writes is exactly what you want then).
3. **Token death:** anchored tokens can't be invalidated (header guarantee, §2); the only paths to `SQLITE_ERROR_SNAPSHOT` are the TTL cull and keeper-pool exhaustion, both of which flow through re-pin-and-retry, degrading to an empty page + scheduled refresh — never a trap, never UB.
4. **Threading:** keeper and pool connections are `SQLITE_OPEN_FULLMUTEX` read-only connections (`src/db.cpp:29-46`); WAL readers don't block the writer; `drain_if_settled` already guarantees notifications arrive outside SQLite frames with locks released (`src/db.cpp:177-191`).

## 7. Staleness contract (1.0 wording)

- **Membership, order, count:** reflect the snapshot at the last delivered change notification for the element's table — same-process writers at most one transaction-settled delivery behind head (exactly-once, commit-ordered, `Lattice.swift:1551-1566`). Read-your-writes: a write through any handle in this process synchronously marks facades stale before `add()`/`write{}` returns; the writer's next top-level access re-pins.
- **Cross-process writers:** best-effort wakeup; guaranteed refresh points are any local write, `refresh()`, and the pacer heartbeat (≤60 s, `sync.cpp:661-663`). Data is durable and readable immediately — only the *push* is best-effort (matches the existing contract).
- **Row values:** live accessors read latest-committed per property (may be *newer* than collection membership for ≤1 frame — today's documented mixed-version behavior, asset c); `materialize()` opts a row into generation-image reads.

## 8. Memory bounds

Per live observed query: 1 pooled keeper connection (read-only, `PRAGMA cache_size` clamped to 2 000 pages for pool members — the default 50 000 at `src/db.cpp:87` is a writer-sized cap) + 48-byte token + cached count + page cache (~4×200 hydrated rows) + id vector **only after deep random access** (8 B/row; 800 KB at 100k). Keeper pool capped at 3 per `lattice_db`; exhaustion culls the oldest generation's keeper (recovery path §3). WAL retention: bounded by write volume within notification latency (ms) in-process; by `generation_ttl` (30 s) against cross-process churn.

## 9. Perf model

| Scenario | Today | A2 |
|---|---|---|
| Render tick, idle | `COUNT(*)` + `LIMIT 1 OFFSET i` × visible row, every tick | **0 queries** (count cached, pages cached in generation) |
| Render tick during write burst | same, × racing re-fetches | per frame (debounced, `SwiftUI.swift:58-65`): 1 token acquire (BEGIN+get, no SQL) + 1 `COUNT(*)` + 1 visible-page query ≈ **2–3 queries/frame** regardless of write rate |
| Deep scroll to row 90k | O(offset) per subscript ⇒ quadratic; traps under writers | one O(n) index-only id scan per generation + O(log n) pk hydrate per row |
| Full iteration (Sequence) | OFFSET batches ⇒ O(n²/100) | keyset batches ⇒ O(n) |
| Write amplification | none | keeper re-pin per settled txn (2 cheap statements), coalesced per frame |

## 10. Fallback modes (also the portability answer)

- **Empty WAL / no token available** (`snapshot_get` precondition 4, §2) or **Linux without `ENABLE_SNAPSHOT`:** *keeper-serialized mode* — the generation holds only the keeper's open read transaction and all generation reads execute on the keeper connection under a mutex. Same consistency contract, less read parallelism; empty-WAL is precisely the no-recent-writes case where serialization is free. Detected at runtime (`sqlite3_compileoption_used("ENABLE_SNAPSHOT")`).
- **In-memory DBs:** no WAL (`src/db.cpp:82-84` guards; memory stays `MEMORY` journal), and shared-cache read transactions hold table locks that block writers — keepers are forbidden. Fallback: *materialized-id generation* — on each settled notification, re-run the id query once and cache `[rowid]`; count = `ids.count`; subscript hydrates by pk. A row deleted after the swap hydrates as an **invalidated instance** (reads return defaults, `isInvalidated == true`) rather than trapping — rare (in-memory + delete racing a render) and documented.

## 11. The filtered/sorted UPDATE edge

An UPDATE that moves a row across the predicate boundary or reorders the sort: the table observer already fires **conservatively on every UPDATE** (`Lattice.swift:1734-1736`; membership rationale at `:1688-1699`, INSERT membership via `rowMatchesNow` `:1701-1706`, DELETE pre-membership via audit rows `:1716-1731`). Any such fire advances the generation, and the new generation re-evaluates membership, order, *and* count wholesale at one token — there is no incremental index to corrupt. Transient (≤1 frame) mixed rendering — a moved row showing its new field value at its old position via the object path before the collection re-pins — is inherited from today and accepted. Future optimization (not 1.0): use `CollectionChange` row-ids + `changedFieldsNames` (asset b) to patch the id vector in place when neither predicate nor sort columns changed.

## 12. Migration burden from today's API

Near zero source breakage: `Results` keeps `Sequence + RandomAccessCollection`, `snapshot(limit:offset:)`, `observe`, `where/sortedBy/group/distinct`, the nearest/geo/FTS surface, `@Relation` (`Results/Results.swift:356-398`), and `@LatticeQuery` verbatim. Additive: `element(at:)`, `refresh()`, `generationID`. Semantic deltas to document: (1) reads are notification-fresh, not statement-fresh (§7); (2) `count` is cached per generation; (3) out-of-range subscript from a *cross-generation* index misuse returns via `element(at:)`-style recovery instead of the old head-state luck; (4) unobserved, un-refreshed handles don't advance until touched. `NearestResults`/`VirtualResults` stay live-one-shot initially (LIMIT-k queries have no pagination trap) and can adopt generations later.

## 13. Implementation risks (what could sink it)

1. **WAL pinning vs. cross-process writers** — a missed best-effort wakeup leaves a keeper pinning another process's WAL growth. Mitigated by TTL cull + pacer pressure (§4); wrong tuning shows up as either WAL bloat or needless re-pins. Needs a dedicated stress test (sync agent process + pinned UI process).
2. **`snapshot_open` operational subtleties** — connection must have prior WAL awareness (`PRAGMA application_id` at pool-open), no active statements at open, `SQLITE_BUSY` during checkpointer races. Each is handled, but the retry state machine is the bug farm; it must be exhaustively unit-tested at the `database` level (forced checkpoints between get/open).
3. **Generation-swap discipline in Swift** — the crash-safety argument (§6.2) relies on "swap only at top-level access / isolation delivery". Any internal path that re-reads `currentGen` mid-sequence (e.g. `Slice` capturing the facade instead of the generation) reintroduces the race. Enforce by construction: only `Generation` executes queries; the facade never does.
4. **Keeper-pool starvation** — >3 concurrently retained generations (slow renders on multiple screens) trigger culls → visible refresh churn. Telemetry via `LatticePerf` counters before tuning.
5. **Platform variance** — Linux distros without `ENABLE_SNAPSHOT` silently run keeper-serialized mode (correct but serialized); Android needs the amalgamation define; Emscripten has no WAL at all (DELETE journal, `src/db.cpp:73-77`) → materialized-id mode. Three genuinely different execution modes behind one contract is the long-term maintenance tax of this design.
6. **sqlite-vec / R\*Tree / FTS5** — all store data in ordinary shadow b-trees in the same file; vec0 reads them via `sqlite3_blob_open` on the querying connection (`SqliteVec/src/sqlite-vec.c:4082,6763,7402`), so snapshot reads are consistent. Risk is only future vec0 in-memory caching; pin with a test (KNN at a token while a writer mutates vectors).

## 14. Decision ask

Approve A2 as the 1.0 live-Results design (supersedes plan item A's Collection drop), with keeper-anchored generations (not bare tokens), the pacer TRUNCATE gate + TTL cull, and the two fallback modes. Keyset iteration from item A is retained for the Sequence path — running inside a generation rather than replacing the Collection.
