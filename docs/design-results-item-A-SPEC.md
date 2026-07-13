# Item A — Live Results 1.0: Consolidated Implementation Spec

- **Status:** APPROVED PLAN OF RECORD (consolidates panel designs A1/A2/A3 per the
  user + design-panel decisions of Jul 12–13 2026; supersedes the original plan
  item A "drop Collection, keyset-Sequence + explicit snapshot")
- **Revision:** Rev 2, 2026-07-13 — revised in place after adversarial review.
  Every fatal/major finding is addressed in the body (invalidation is now a new
  synchronous core hook, not the scheduler-dispatched trampoline; §3 is rebuilt
  around WAL log-rewind starvation and a threshold eviction bound; §4.1 is
  rebuilt around real shared-cache concurrency; a process-lifecycle contract is
  added). Disposition map in §9. No findings were rejected.
- **Date:** 2026-07-13
- **Repos:** lattice (Swift ORM), latticecore (C++ core)
- **Baseline ground truth:** lattice `Sources/Lattice/Results/Results.swift`,
  `Results/TableResults.swift`, `SwiftUI.swift`, `Backend/CxxBackend.swift`,
  `Model.swift`, `ThreadSafeReference.swift`; latticecore
  `include/lattice/lattice.hpp`, `include/lattice/db.hpp`, `src/db.cpp`,
  `src/lattice.cpp`, `src/sync.cpp`, and the landed transaction-settled
  delivery substrate (`docs/design-deferred-memory-delivery.md`;
  `database::set_txn_hooks`/`mark_txn_dirty` at `db.hpp:129-140`, wired at
  `lattice.cpp:197-206`)
- **Inputs consolidated:** `design-results-A2-snapshot-tokens.md` (generation +
  keeper machinery, adapted), `design-results-A1-generation-cache.md`
  (invalidation + anchor designs), `design-results-A3-sequence-plus-paged.md`
  (keyset SQL + tolerant fill)

**One sentence:** live `Results` keeps `RandomAccessCollection`; consistency
comes from **A2-LITE generations** — a *generation* is a plain held read
transaction (`BEGIN` on a pooled, dedicated read-only connection owned by the
generation), so every `count`/`subscript`/page-fill for that generation reads
one SQLite MVCC snapshot with **zero special SQLite APIs**; generations advance
via a new **synchronous core invalidation hook** (inline on the writer's
thread, before any scheduler dispatch — read-your-writes by construction),
generation resolution is **pinned per render batch** (one frame reads one
generation), pages fill by keyset with persistent anchors (never
O(offset)-per-frame), WAL growth is bounded by threshold keeper eviction, and
no `fatalError` — and no cross-bridge C++ exception — path survives.

---

## 0. Binding decisions (fixed inputs to this spec)

1. **Live `Results` KEEPS `RandomAccessCollection`.** `ForEach(results)` /
   `List(results)` compile unchanged with lazy row loading. The approved plan's
   drop-Collection shape (item A as written; steelmanned as A3) is SUPERSEDED.
2. **Consistency mechanism = A2-LITE.** A generation is a plain held read
   transaction on a pooled dedicated read connection owned by the generation.
   NO `sqlite3_snapshot` tokens (§8.1), NO SQLite vendoring prerequisite
   (§8.2 — explicitly out of item A's scope).
3. **Freshness = "no staleness":** generation advances via the
   observation→invalidation path, delivered **synchronously on the writer's
   thread before `add()`/`transaction()` returns**. Neither `Lattice.observe`'s
   `Task.detached` hop (`Lattice.swift:1671`) **nor the existing
   `backend.addTableObserver` trampoline** is an acceptable invalidation path —
   the trampoline is scheduler-dispatched (`notify_changes_batched` routes every
   callback through `scheduler_->invoke`, `lattice.hpp:1987`, and a Lattice
   opened in an isolated context installs a `Task`-hopping scheduler,
   `Lattice.swift:378-391`, `:665-674`), so its delivery lands *after* the write
   call returns in the canonical MainActor case. A new synchronous core hook is
   therefore part of this item (§2.3). Cross-process belt: `PRAGMA
   data_version`, amortized once per top-level access batch. Within an access =
   snapshot isolation, which is consistency, not staleness.
4. **Panel grafts (all required):** persistent keyset page anchors surviving
   generations (~24 B/page); identity-stable rows across generations (`Model`
   is already `Identifiable` by primaryKey — verified §1.6, pinned by test);
   pacer coordination for keeper-txn WAL retention (§3).
5. **`snapshot()` stays** as the explicit point-in-time copy API;
   `NearestResults` stays single-shot materializing; the plan's keyset iterator
   work (NULL-aware resume predicates etc.) is retained as the page-fill
   mechanism (§2.4).

---

## 1. Semantics & contracts

### 1.1 The generation model

A **generation** is an immutable value `(epoch, snapshotHandle)`:

- `epoch: UInt64` — a per-lattice monotone counter, bumped by invalidation
  (§2.3). ONE shared generation exists per `(lattice identity, epoch)` — not
  per-`Results`. All live `Results` facades over the same `Lattice` read
  through the same generation.
- `snapshotHandle` — storage-dependent:
  - **File (WAL) DBs:** a *keeper*: one pooled read-only connection
    (`database::open_mode::read_only`, `db.cpp:26-50` — WAL-joining,
    `SQLITE_OPEN_FULLMUTEX | READONLY | URI`) holding an open read transaction.
    Acquisition = `BEGIN` + one pin statement (`SELECT 1 FROM sqlite_schema
    LIMIT 1`) — `BEGIN DEFERRED` does not take a snapshot until the first read,
    so the pin makes acquisition a fence. Every read for the generation
    (count, subscript hydration, page fill, `snapshot()`) executes **on that
    connection**, giving SQLite WAL MVCC snapshot isolation. No API beyond
    `BEGIN`/`COMMIT` is used.
  - **Memory DBs (private `:memory:`, named shared-cache) and Emscripten:**
    *materialized-id generation* — no held transaction at all (§4.1). The
    generation's snapshot is a per-query-shape id vector captured inside a
    short **capture transaction** under the per-store serialization rules of
    §4.1 (the capture is *not* naked single-statement — see §4.1 for why).

Consumers never see generations directly (diagnostics excepted, §1.7). They
are the internal unit of consistency.

### 1.2 Collection conformance contract

`Results` keeps `Sequence & RandomAccessCollection where SubSequence ==
Slice<Element>` (`Results.swift:10`). The contract is
**consistent-within-generation**:

- `startIndex`, `endIndex`/`count`, and `subscript` answer from one
  generation. Generations advance only at invalidation delivery (taking
  effect at the next render-batch boundary, §1.3), `refresh()`, the
  cross-process belt check, TTL retirement, or threshold/lifecycle eviction
  (§3) — never spontaneously mid-answer, and never mid-render-batch for
  cross-thread commits (§1.3 batch pin).
- Within a generation on a file DB, `count` and every page fill execute at one
  MVCC snapshot: **if `i < generation.count`, row `i` exists in that snapshot
  and its fetch cannot come back short.** Consistency is structural, not
  clamped, on the common path. *One carve-out:* across a **force-retire**
  (threshold eviction §3.4, lifecycle retire §3.6, pool exhaustion §2.2) a
  read can lose the race with the keeper's `COMMIT`; the facade re-validates
  generation liveness before each statement (§3.4 protocol) and any read that
  still loses serves through the tolerant ladder below. Rung 1 is therefore
  "structurally cannot be short, *except across force-retire, where the
  ladder applies*."
- An atomic multi-row copy is *explicitly out of contract* — that is
  `snapshot()` / `materializedSnapshot()` (`RowCache.swift:86-89`), unchanged.

**Trap-free: why no `fatalError` path survives.** Today's traps are
`Results.subscript(index:)` (`Results.swift:234-241`) and `Slice.subscript`
(`Results.swift:180-189`), both `snapshot(limit: 1, offset: i)` against head
state, both deleted by this design. Enumerated exhaustively:

1. **In-generation index (`i < gen.count`), file DB:** the page fill runs at
   the same snapshot that produced `count` — structurally cannot be short
   (force-retire carve-out above). No trap possible; no clamp needed.
2. **In-generation index, memory DB:** `count == ids.count`; `subscript(i)`
   hydrates `ids[i]` by primary key. The id vector is captured inside a
   capture transaction serialized against writers (§4.1), so it is always a
   committed state. If the row was deleted *after* the vector was captured
   (the vector can be at most one settled delivery behind), the hydrate-by-pk
   returns an **invalidated instance** — live property reads of a missing row
   return column defaults (the accessor's `SELECT` finds no row), never a
   crash. Corrected at the next epoch.
3. **Cross-generation index** (an `Int` index crosses an epoch bump; count
   shrank): the tolerant ladder from A1 §5 / A3 §3.2 serves, in order: (a) the
   current generation's fill result; (b) the *retained previous generation's*
   page for that index (kept until superseded by the next successful access);
   (c) the lifeboat — the last element any fill returned for this query
   shape; (d) a freshly hydrated **invalidated placeholder instance**
   (defaults, `isInvalidated`-style semantics — the same shape as rung 2).
   **This rung is normal operation, not misuse:** SwiftUI's lazy `List` diffs
   at count N and realizes rows later, so under write bursts stale-index
   subscripts are the *expected* path (the batch pin in §1.3 makes them
   impossible within one frame, but indices legitimately survive across
   frames in caller code and in UIKit adapters). Rung (d) is reachable only
   by indexing an empty-at-current-generation collection with a fabricated
   index — and now renders a blank row for one frame instead of aborting the
   process.
4. **`Slice`** is reworked to capture `(generation, bounds)` at creation; its
   subscript and iterator go through the same page machinery — same ladder,
   no independent trap.
5. **Bridge-level containment:** no C++ exception may cross the Swift interop
   boundary (that is `std::terminate`, i.e. a process abort — the same class
   of failure as a trap). Every generation-read bridge entry point is wrapped
   in a catch-all that converts any `db_error`/exception into an empty result
   plus a stale flag (§4.1, Commit 4); the Swift side treats that as a ladder
   trigger. CI pins both: a grep gate asserts no `fatalError(` remains under
   `Sources/Lattice/Results/` (`@available(*, unavailable)` stubs excepted:
   none planned), and a fault-injection test asserts a thrown core read
   surfaces as an empty result, not a crash.

### 1.3 Freshness contract

**Read-your-writes (same process), by construction — two layers:**

- **Layer 1, Swift write path (same handle):** `Lattice.add()` /
  `Lattice.transaction()` bump the coordinator epoch directly, synchronously,
  after the backend write returns. This gives exact same-handle
  read-your-writes with zero core dependency and ships in Commit 1.
- **Layer 2, core synchronous invalidation hook (cross-handle):** a new
  `lattice_db::add_invalidation_hook` (§2.3) runs **inline in
  `flush_changes` on the writer's thread** — file DBs inside the WAL hook's
  post-commit frame (write lock released; `lattice.cpp:187-195`), memory DBs
  in the transaction-settled drain (`db.hpp:129-151`, `lattice.cpp:197-206`,
  deferred-delivery doc §3.4) — **before** `notify_changes_batched`'s
  `scheduler_->invoke` dispatch (`lattice.hpp:1987`), and is fanned out
  inline to **every alive same-path instance** via
  `instance_registry::for_each_alive` (`lattice.hpp:99`, `:145`; the same
  fan-out pattern already used for cross-instance events at
  `lattice.hpp:1737`). This covers writes arriving through *other* handles to
  the same store: the synchronizer's dedicated `lattice_db`
  (`sync.cpp:2317-2331`), a second app-side `Lattice`, TSR-resolved handles.
  The epoch is already bumped when the write call returns; the writer's next
  access acquires a fresh generation whose pinned snapshot post-dates its own
  commit. No `await`, no hop, no debounce in the invalidation path.

  **Explicitly:** the existing `backend.addTableObserver` trampoline is *not*
  this path — `notify_changes_batched` routes all table-observer callbacks
  through `scheduler_->invoke` (`lattice.hpp:1987`), and every `Lattice`
  created in an isolated context (the canonical SwiftUI `@MainActor` case)
  installs a scheduler whose `invoke` is an unstructured `Task` hop
  (`Lattice.swift:378-391`, `:665-674`; documented at
  `Lattice.swift:1559-1561`). That trampoline remains the *UI repaint*
  signal only (§1.5). Only nonisolated-created lattices get inline delivery
  from it, which is exactly why a naive T2 would pass in unit tests and fail
  in real apps — T2 is parameterized over isolation contexts (§7).

**Render-batch generation pin (frame coherence):** a SwiftUI render pass is
many top-level accesses (count/ID diff, then lazy per-row subscript fills).
With truly synchronous invalidation, a background commit landing mid-body
would otherwise advance the generation *between* those accesses and tear the
frame (identity diffed at N, rows hydrated at N+1). Therefore generation
resolution is **batch-pinned**:

- The coordinator resolves `current` **at most once per top-level access
  batch** and every access in the batch serves that pinned generation. On the
  main thread the batch boundary is the runloop tick (a `CFRunLoopObserver`
  on `.beforeWaiting` clears the pin — the same batch boundary the
  `data_version` belt uses); on other threads each top-level `Results` access
  is its own batch.
- An epoch bump arriving from **another thread** mid-batch takes effect at
  the next batch boundary — one frame is single-generation by construction.
- An epoch bump performed by the **batch's own thread** (the reader is the
  writer) clears the pin immediately — same-thread read-your-writes stays
  exact: `add()` → same-thread `count` reflects the write with no await.
- This intentionally reproduces the one good property of today's scheduler
  hop (no mid-frame advance) without its staleness (delivery after return).

**Cross-process (file DBs):** wakeups ride the shared best-effort notifier
(`lattice.cpp:37-64`; documented droppable, `Lattice.swift:1551-1566`).
Belt: `PRAGMA data_version` on a **non-transaction** connection — the
dedicated `xproc_read_db_` already exists for exactly this role
(`lattice.hpp:822`, `:2765`); inside a held read txn the value is frozen at
the snapshot, so the belt must never run on a keeper. Issued at most once per
top-level access batch with a floor interval
(`ResultsTuning.crossProcessBeltIntervalMs`, default 500 ms; `nil` disables).
`data_version` changes exactly when another connection committed — new value
⇒ bump epoch. Worst case after a dropped wakeup with an idle UI: stale until
the next access (belt) or generation TTL — never a crash.

**Within an access:** snapshot isolation. Two accesses in different batches
may straddle an epoch (that is what "live" means); one access — and one
render batch — never mixes snapshots.

**Row *values*** stay on the object path: hydrated elements are live
registered instances (`Model.swift:287-296` registers;
`ModelInstanceRegistry.notifyChange` `Model.swift:199-224` repaints), so a
field update refreshes a rendered row independently of — and possibly one
frame ahead of — collection membership. Inherited, documented behavior;
`materialize()` opts a row into a fixed image (`RowCache.swift`).

### 1.4 Iteration, Slice, TSR

- **Iteration:** `makeIterator()` returns a `KeysetCursor` that captures the
  current generation (refcounted) and walks **keyset batches** on the
  generation's connection: `WHERE (sort, id) > (:v, :k) ORDER BY sort dir, id
  LIMIT batch` — O(n) total, each key visited at most once, replacing the
  OFFSET-advancing `Cursor` (`Results.swift:130-155`, O(n²/100)). A shrinking
  table ends the walk early; never a trap. If the generation is force-retired
  mid-iteration (TTL, threshold eviction, lifecycle — §3), the iterator
  transparently re-pins at the current head and **resumes by keyset anchor**
  — the resume predicate is position-free, so generation-hopping is safe
  (rows inserted behind the cursor at the hop are missed, ahead are seen; no
  duplicates — same contract as A3's live walk, documented).
- **`Slice`:** captures `(generation, startIndex, endIndex)`; batch iterator
  fetches the range in one statement at the generation; subscript via §1.2.
- **`ResultsThreadSafeReference`:** unchanged
  (`ThreadSafeReference.swift:106-117`) — it captures the query *shape* and
  rebuilds on `resolve(on:)`. The resolved facade binds to the target
  lattice's shared cache registry (§2.2), so a TSR resolve lands warm if that
  shape is already live.

### 1.5 `@LatticeQuery` and `@Relation`

- `@LatticeQuery` keeps its structure verbatim (`SwiftUI.swift:42-95`):
  observe → debounced `fetch()` → fresh `TableResults` → `objectWillChange`.
  Because caches are shared per (lattice, query shape) in the registry (§2.2),
  the fresh `TableResults` is a thin facade over the already-warm cache —
  `fetch()` becomes a re-bind, not a re-query. Its internal `observe` wiring
  stays on `Lattice.observe` (UI-repaint signal, hop tolerable); the *cache
  invalidation* signal is the coordinator's synchronous core hook (§2.3) —
  two consumers, two mechanisms, different latency requirements.
- `@Relation` builds a `TableResults` per property access
  (`Results.swift:367-385`); same registry sharing. Note: its predicate
  embeds the parent primaryKey literal, so each parent row is a distinct
  shape — bounded by the registry's LRU/idle eviction (§2.2).

### 1.6 Identity stability across generations (graft, pinned)

`Model.id` already resolves to `AnyHashable(primaryKey)` for managed objects
(`Model.swift:419-425`) and `==` compares primaryKeys (`Model.swift:432-438`),
so SwiftUI diffing keys rows by database identity across generations — a row
that survives an epoch bump keeps its `ForEach` identity even though a new
element instance may be hydrated. Two obligations:

1. **Pin it:** a test asserts `Model.id == primaryKey` semantics and stable
   `ForEach` diff identity across an epoch bump (no delete+insert animation
   for unchanged rows).
2. **Prefer instance reuse:** page refills consult `ModelInstanceRegistry`
   (already keyed by `(dbPath, table, primaryKey)`, `Model.swift:21-25`) and
   reuse the live registered instance for a rowId when one exists, rather
   than hydrating a duplicate — bounding observer-registration churn
   (A1 risk 3) and making identity stability instance-level, not just
   id-level. (Registry gains a `lookup(key:) -> Model?`; reuse is best-effort
   — a missing weak ref hydrates fresh as today.)

### 1.7 Additive public API

```swift
extension Results {
    /// Force the next access to advance the generation and drop caches.
    public func refresh()
    /// Non-trapping indexed access (nil instead of ladder rung (d)).
    public func element(at index: Int) -> Element?
}

extension TableResults {
    /// Diagnostics/tests: the epoch this facade last served from.
    public var generationID: UInt64 { get }
}

extension Lattice {
    /// Retire every open read generation now (COMMIT keeper transactions,
    /// return pooled connections). Facades re-pin lazily at next access;
    /// caches keyed by epoch survive if no invalidation arrived meanwhile.
    /// Called automatically on app backgrounding where UIKit is available
    /// (§3.6); REQUIRED manually from app extensions and non-UIKit hosts
    /// that share an app-group container.
    public func retireAllGenerations()
}

public struct ResultsTuning: Sendable {   // per-Lattice, on Configuration
    public var pageSize: Int = 100
    public var maxCachedPages: Int = 16                // LRU bound, per shape
    public var crossProcessBeltIntervalMs: Int? = 500  // nil disables
    public var generationTTLSeconds: TimeInterval = 30 // idle self-retire
    public var keeperPoolSize: Int = 3
    public var maxCachedShapes: Int = 64               // registry LRU bound
    /// WAL size at which ALL keepers are force-retired to open a reader gap
    /// so the log can rewind/truncate (§3.4). The hard WAL bound.
    public var walKeeperEvictionThresholdBytes: Int = 16 << 20   // 16 MB
}
```

The package floor is iOS 15 / macOS 14 (`Package.swift:8`), so `ResultsTuning`
uses back-deployable types only — `Int` milliseconds and `TimeInterval`
seconds, **not** `Duration` (iOS 16+; stored properties cannot be
availability-gated). This matches existing back-deployment scar tissue
(`Results.swift:130-134`, `:356-365`, `ThreadSafeReference.swift:86-92`).

Everything else — protocol shape, chaining, `observe`, `snapshot(limit:offset:)`,
nearest/geo/FTS, `sendableReference` — is signature-identical.

---

## 2. Architecture

### 2.1 Components

```
Swift (lattice)                          C++ (latticecore)
──────────────                           ─────────────────
GenerationCoordinator  ── per Lattice ── lattice_db::read_generation pool
  epoch: atomic UInt64                     acquire_read_generation() → gen id
  current generation (lazy mint,           release_read_generation(id)
    batch-pinned per §1.3)                 read_generations_outstanding()
  belt clock (data_version)                  [AGGREGATED per path across
  maintenance timer (TTL/eviction,            instance_registry::for_each_alive]
    all storage configs, §3.2)             invalidation hook (synchronous,
  lifecycle observers (§3.6)                 inline in flush_changes, §2.3)
QueryShapeCache (registry, LRU)            WAL-threshold eviction flag
  key: (identityHash, table, whereSQL,       (frame count from the WAL hook)
        orderBySQL, groupBy, distinctBy)   pacer TRUNCATE + advance request
  count?, pages LRU, anchors (persistent),   (sync.cpp; per-path fan-out)
  previousPages (one generation retained), generation-scoped reads:
  lifeboat element                           objects_at(gen,…) / count_at(gen,…)
TableResults facade  → registry lookup,      query_ids_at(gen,…)  [id vectors]
  executes reads at the batch-pinned       data_version() on xproc_read_db_
  coordinator.current                      per-store write gate (shared-cache)
```

### 2.2 Generation lifecycle — who mints, shares, retires

- **Mints:** the `GenerationCoordinator` (one per Lattice identity, held in a
  process-global registry keyed by `backend.identityHash`, created lazily on
  first live-Results access, torn down on `close()`/registry eviction). A
  generation is minted lazily at the first top-level access batch whose
  facade observes `epoch != current.epoch` (or `current == nil`) — **not**
  inside the invalidation callback (no SQL in the hook frame, §2.3), and
  batch-pinned thereafter (§1.3).
- **Shares:** all query shapes on the lattice read the current generation.
  On a file DB the generation's reads all run on its one keeper connection —
  serialized by `SQLITE_OPEN_FULLMUTEX`; acceptable because generation reads
  are short discrete statements. The pool (default 3) exists so an in-flight
  render on generation N drains while N+1 serves, not for read parallelism.
- **Retires:** (a) a newer generation exists and the old refcount drops to 0
  → `COMMIT` the keeper txn, return the connection to the pool. When an epoch
  bump finds the superseded generation already at refcount 0, the `COMMIT` is
  scheduled immediately on a reader/utility thread — **never executed in the
  invalidation hook frame** (§2.3 rules); this is what makes §3's "natural
  lifetime" real rather than access-dependent. (b) **idle TTL** — a
  generation older than `generationTTLSeconds` with no active reads
  self-retires, enforced by the coordinator's maintenance timer (§3.2 — this
  actor exists for every storage/config, including non-sync lattices, which
  have no pacer thread at all: `setup_sync_if_configured` is the only
  synchronizer creation, `lattice.hpp:839-843`). "**Active reads**" is
  defined as *in-flight statements on the keeper connection* (a core
  counter), NOT logical accesses — a visible-but-warm screen issuing zero SQL
  does not hold a keeper alive (safe: re-pin is two cheap statements and
  epoch-keyed caches survive). (c) **WAL-threshold eviction** (§3.4) and
  **pacer advance requests** (§3.3). (d) **process lifecycle** — all
  generations retire on backgrounding (§3.6). (e) pool exhaustion — acquiring
  a fourth concurrent generation force-retires the oldest (protocol §3.4);
  facades on it re-resolve at next access.
- **Cache carry-over across epochs:** an epoch bump does not wipe everything.
  Every settled commit bumps the epoch (§2.3 — this is load-bearing for §3's
  WAL bounds), but the invalidation batch names the changed table(s); only
  shapes over those tables drop `count`/pages (whole-table baseline, §2.3).
  Shapes over untouched tables keep their caches — sound because those
  tables' content is identical in the old and new snapshots (exactly-once,
  per-table batched delivery, `Lattice.swift:1551-1566`). Anchors are never
  dropped on epoch bumps (§2.4).

### 2.3 Invalidation wiring — synchronous core hook

**The mechanism is a NEW core hook, not the existing trampoline.** The
existing table-observer path (`backend.addTableObserver`,
`CxxBackend.swift:418-441` → bridge → `lattice_db::add_table_observer`)
delivers through `notify_changes_batched`, which collects callbacks and runs
them via `scheduler_->invoke(...)` unconditionally (`lattice.hpp:1987`). For
any Lattice created in an isolated context — the canonical SwiftUI MainActor
app — that scheduler's `invoke` is an unstructured `Task` hop
(`Lattice.swift:378-391`; isolation captured per-init at
`Lattice.swift:665-674`). Epoch bumps through that path land *after* the
write returns: not read-your-writes. It remains the UI-repaint signal only.

**New surface (Commit 3, bridged in Commit 4):**

- `lattice_db::add_invalidation_hook(hook) → token` /
  `remove_invalidation_hook(token)`: hooks are invoked **inline in
  `flush_changes`**, on the writer's thread, after the commit is settled
  (file DBs: inside the WAL hook's post-commit C frame,
  `lattice.cpp:187-195`; memory DBs: the settled drain,
  `lattice.cpp:197-206`) and **before** the `notify_changes_batched`
  scheduler dispatch. Payload: the batch's changed table names (and, from the
  Commit-4 additive overload, `changed_fields` for v1.1).
- **Cross-instance fan-out:** `flush_changes` invokes not only its own
  instance's hooks but every alive same-path instance's hooks, via
  `instance_registry::for_each_alive(config_.path)` (`lattice.hpp:99`,
  `:145`) — the registry already keys the app handle and the synchronizer's
  dedicated handle identically (`resolve_path`, `lattice.hpp:806-812`;
  registration at `:846`), and the pattern is precedented at
  `lattice.hpp:1737`. This is what makes sync-applied chunks and second-handle
  writes bump the app coordinator's epoch synchronously.
- **Rollback also signals:** the rollback txn-hook (`discard_change_buffer`,
  `lattice.cpp:197-206`) additionally bumps the epoch (a relaxed atomic store
  — legal in the C hook frame). A rolled-back transaction delivers no change
  batch by design (deferred-delivery §3.4), so without this a memory-family
  capture that raced the transaction could serve a poisoned id vector forever
  (§4.1); the rollback bump guarantees the next access re-captures.
- **Swift bridging:** `swift_lattice_ref.add_invalidation_hook(context,
  c_fn)` using the existing C-trampoline pattern (bridge
  `lattice.hpp:1066-1093`). The Swift callback body is restricted exactly as
  the C++ hooks are (below) — atomics only.
- **Epoch semantics:** the hook fires for **every settled commit on the
  store, regardless of which tables are observed** — the epoch bump is
  table-agnostic; the changed-table payload only refines *which shapes drop
  caches*. This is deliberate: keeper retirement (§3) must be driven by
  *every* commit (each commit grows the WAL that the keeper pins), while
  per-table lazy subscription would let commits to unobserved tables grow the
  WAL forever behind a pinned keeper. Cheap by construction: an unobserved
  table's commit costs one atomic increment and a re-pin at next access;
  untouched shapes keep their caches (§2.2 carry-over).

The hook callback runs on the writer's thread — for file DBs inside the WAL
hook's C frame. It is therefore restricted to: **atomic epoch increment +
per-shape dirty-flag stores + (memory DBs) marking id vectors stale + setting
the eviction/advance request flags (§3). No SQL, no allocation-heavy work, no
locks that anyone holds across SQL, nothing that can throw.** Generation
minting, `COUNT(*)`, page refills, and keeper `COMMIT`s all happen later, on
reader/utility threads.

**Normative system-wide lock invariant (not just a callback rule):** every
lock the invalidation hook can take is a **leaf lock** that NO thread in the
process may hold across any SQL statement, backend call, or operation that
can block on a connection mutex. The hazard is reader-side: for file DBs the
hook frame runs with the writer connection's FULLMUTEX held; if the hook
takes lock L and any reader thread ever holds L while issuing SQL on that
connection, the result is an ABBA hang — and this repo has already shipped
exactly that deadlock once (`sync.cpp:668-676` documents the observed
pacer_mutex_/connection-mutex hang and the release-before-DB-work rule that
fixed it). Until Commit 5 lands, sync-enabled file lattices read through the
write connection (`read_db_` gated on `!is_sync_enabled()`,
`lattice.hpp:820-821`; fallback `:2762`), so Commit 1's registry code is
exposed on day one. Concretely enforced as:

- per-shape dirty flags and the epoch are plain atomics — no lock at all;
- `QueryShapeCache` registry lookups use a **two-phase pattern**: snapshot
  the shape ref under the registry lock, *release it*, run SQL, re-validate
  the epoch before publishing the result. The registry lock is never held
  across a query;
- a Commit-1 pin test (T10): sync-enabled file lattice, tight writer loop vs
  a reader thread populating cold shapes, bounded watchdog.

**v1 baseline — whole-table:** any batch for table T invalidates every
shape keyed on T. UPDATEs that can't affect membership still invalidate;
the rebuild is one `COUNT(*)` + visible-page refill per epoch, ≤ once per
frame after SwiftUI coalescing — cheap and always correct. This sidesteps
the membership-inference tarpit the codebase already litigated and lost
(`Lattice.swift:1687-1706`; A3 §8).

**v1.1 refinement — `changedFieldsNames`-aware:** the C++ `change_event`
already carries `changed_fields` (`lattice.hpp:1830-1834`, populated at
flush `lattice.hpp:1596-1642`); the invalidation hook's Commit-4 overload
carries it. Extract predicate+sort columns from the built SQL, and **skip
shape invalidation for UPDATE-only batches whose changed fields are disjoint
from (predicateColumns ∪ sortColumns)** — the object path repaints the row
contents. The *epoch still bumps* (WAL policy, above); only the cache drop is
skipped. INSERT and DELETE always invalidate (pre-change membership is
unknowable post-hoc). Advisory-only optimization: skipping wrongly is a
correctness bug, so it ships behind a default-on flag with a soak test,
after v1.

### 2.4 Page cache + keyset anchors

Per query shape (`QueryShapeCache`):

- **Deterministic total order is mandatory:** effective ORDER BY is always
  `(sortColumn userDir, id ASC)`; unsorted queries get `ORDER BY id ASC`.
  (`id INTEGER PRIMARY KEY AUTOINCREMENT` exists on every model table.)
  Behavior change: unsorted order becomes deterministic — almost always
  desired; MIGRATION line §6.
- **Pages:** LRU of `maxCachedPages` pages × `pageSize` hydrated elements
  (default 16 × 100). Eviction releases instances → `Model` deinit
  deregisters its C++ object observer. `previousPages` retains the last
  generation's pages until superseded (ladder rung (b), §1.2).
- **Keyset fill (NULL-aware, from A3 §3.1):** filling after anchor `(v, k)` on
  ascending `sortCol` (SQLite sorts NULLs first ASC):

  ```sql
  -- anchor value NULL:      (sortCol IS NULL AND id > :k) OR sortCol IS NOT NULL
  -- anchor value non-NULL:  (sortCol > :v) OR (sortCol = :v AND id > :k)
  -- DESC mirror (NULLs last): (sortCol < :v) OR (sortCol = :v AND id > :k) OR sortCol IS NULL
  ```

  ANDed into the predicate as a raw fragment through the existing neutral
  surface `backend.objects(table:where:orderBy:limit:offset:)` — the
  generation variant adds only the connection routing. Anchor comparisons use
  the ORDER BY's collation. With `@Indexed` sort columns each fill is an
  O(log n) seek + pageSize steps; unindexed sort columns degrade to scans —
  debug-mode EXPLAIN check logs a nudge.
- **Anchors are persistent (the graft):** `pageIndex → (sortValue, id)`,
  ~24 B/page, recorded on every fill, surviving LRU eviction **and epoch
  bumps**. ~1,000 entries / 100k rows ≈ 24 KB; never evicted while the shape
  lives.
- **Cold random jump** (scrollbar fling to row 90k): one
  `LIMIT pageSize OFFSET k` at the generation — O(k) **once per jump**, not
  per row, not per frame — then the neighborhood is anchored and keyset.
- **Write-burst deep scroll (why anchors must survive generations):** UI
  scrolled to row ~90k while commits churn. Each epoch's visible-page refill
  uses the retained anchor → **keyset, O(pageSize) per frame**, never
  O(offset)-per-frame. A stale-generation anchor is *rank-approximate* (net
  churn above it shifts its rank); v1 refills **content-anchored** — the new
  page starts at the same content position, which keeps the user's visible
  window stable under churn (better UX than index-exact) — and records fresh
  exact anchors as scrolling continues. v1.1 may add an async exact-rank
  reconciliation (one index-range count off the render path). Trap-freedom is
  unaffected either way (§1.2); only scrollbar-proportion exactness drifts
  transiently.
- **Grouped/distinct shapes:** no sound keyset anchor exists (grouped rows
  lack stable `(col, id)` identity). They page by OFFSET *within* the
  generation — still MVCC-consistent on file DBs (the OFFSET scan runs at the
  keeper snapshot, so it cannot race a deleter), still never trap; cold pages
  are O(offset). Same for bbox (`objectsWithinBBox`) shapes.

### 2.5 Keeper connection pool (file DBs)

- **Bounds:** `keeperPoolSize` (default 3) read-only connections per
  `lattice_db`, opened lazily with the config's `busy_timeout_ms` and
  `PRAGMA cache_size` clamped to 2,000 pages (the default 50,000 at
  `db.cpp:87` is writer-sized; three keepers at the default would reserve
  ~600 MB of page-cache headroom). Note: the *pool* is per-instance, but all
  retention *policy* (outstanding counts, TTL, eviction, advance requests)
  aggregates per **path** across `instance_registry::for_each_alive` — the
  synchronizer's handle and any second app handle are separate instances on
  the same store (§3.3), and multiple app-side instances per path are normal
  (TSR resolves).
- **Reuse:** retire → `COMMIT` → connection back to the pool; acquire →
  `BEGIN` + pin. No open/close churn in steady state.
- **Interaction with existing `read_db_`:** additive. `read_db()`
  (`lattice.hpp:2762`) keeps serving one-shot paths (legacy `snapshot()`
  fallback, NearestResults, DynamicResults, internal queries). Notably,
  sync-enabled file lattices have **no** `read_db_` today
  (`lattice.hpp:820-821` gates it on `!is_sync_enabled()`) and read through
  the write connection — the keeper pool gives exactly the lattices most
  exposed to sync-writer races their first parallel read path.
- **TEMP-view caveat:** attach/union TEMP views exist only on `db_`/`read_db_`
  (`view_handles()`, `lattice.hpp:4042-4047`). Pool connections do not carry
  them — which is why attached/union shapes stay off keepers in 1.0 (§4.2).

---

## 3. WAL-retention policy

A keeper's open read transaction pins WAL frames at its snapshot — exactly the
Part-I 1.1 GB-WAL reader class.

### 3.1 The retention model, stated honestly

SQLite reuses (rewinds) the WAL only at a write-transaction start when the log
is **fully backfilled AND no reader is using it**; RESTART/TRUNCATE
checkpoints additionally block until every reader reads from the database file
only. Under this design's own steady state — an active screen rendering
during a write burst — a WAL-using reader exists at every instant: generation
N+1's keeper `BEGIN`s before N retires (pool overlap, §2.2), and each re-pin
mid-burst takes a read-mark inside the growing log. **The writer can therefore
never rewind during the burst, and the -wal file grows by the burst's frames —
"retention ≈ one transaction" is false in that regime.** A sync catch-up burst
would otherwise grow the WAL to the size of the entire dataset (the Part-I
class, caused by a treadmill of always-fresh readers instead of one old one).

The real bound is imposed deliberately: **threshold keeper eviction (§3.4)**
periodically opens a coordinated reader gap so the log can rewind/truncate,
making burst-time WAL growth a sawtooth capped near
`walKeeperEvictionThresholdBytes` instead of unbounded. The bounds below are
ordered by expected engagement; every one has a named enforcement actor that
exists in every storage/config combination.

### 3.2 Natural lifetime, idle TTL, and the enforcement actors

- **Natural lifetime — next commit:** every settled commit — *any* table,
  observed or not (§2.3 epoch semantics) — bumps the epoch synchronously.
  A superseded generation at refcount 0 has its keeper `COMMIT`ted
  immediately (scheduled on a reader/utility thread, never the hook frame,
  §2.2); with an active UI the replacement pin is ≤ one frame later. Keeper
  *age* during a burst ≈ one frame — but note §3.1: young keepers still
  starve the rewind; age alone bounds nothing. This bound's job is releasing
  *snapshot pins* fast so PASSIVE backfill keeps pace.
- **Idle TTL:** a generation older than `generationTTLSeconds` (default
  30 s) with **no active reads** (= no in-flight statements on the keeper —
  §2.2's definition; logical "visibility" of a warm screen does not count)
  self-retires. **Enforcement actor:** the coordinator's **maintenance
  timer** — a Swift-owned low-frequency timer (utility QoS, armed only while
  generations are outstanding), present for **every** lattice including
  non-sync file lattices, which have no pacer thread (`synchronizer_` exists
  only via `setup_sync_if_configured`, `lattice.hpp:839-843`). The timer
  drives a core maintenance entry (`run_read_pool_maintenance()`) that (a)
  TTL-retires refcount-0/idle generations, (b) force-re-pins generations
  older than an absolute age cap even when actively read (safe: per-table
  exactly-once delivery keeps untouched shapes' caches valid across the
  re-pin, §2.2), and (c) executes pending threshold evictions (§3.4). The
  sync pacer *additionally* calls the same maintenance for sync lattices —
  but it is a second caller, not the actor of record. This closes the
  view-model-resident case: a hidden retained `Results` on a non-sync
  lattice under hours of local writes is retired by the timer, not by a
  render that never comes (test T5-b).

### 3.3 Pacer/TRUNCATE interplay

`synchronizer_base::maybe_checkpoint` (`sync.cpp:597-644`): PASSIVE is
untouched — keeper read-marks bound backfill automatically and PASSIVE never
blocks on them; it keeps draining the WAL up to the oldest keeper. TRUNCATE
keeps today's attempt-with-250 ms-budget + PASSIVE fallback
(`sync.cpp:627-643`) — a pre-gate on "generations outstanding" is **not**
used: it would be both mis-scoped (see below) and stricter than necessary.
What changes: when a TRUNCATE attempt is beaten by keepers (`res.busy != 0`
on the truncate pass), the pacer issues `request_generation_advance()` so
facades re-pin at next access and the *next* cycle truncates behind them.

**Instance scoping (normative):** the synchronizer owns its own `lattice_db`
(`owned_db_`, `sync.cpp:2317-2331`; `sync.hpp:324-325`) — a *different
instance* from the app handle(s) holding the keepers, and multiple app-side
instances per path are normal (TSR resolves). Every policy read and every
signal in §3 therefore aggregates/fans out per **path** via
`instance_registry::for_each_alive(config_.path)` (`lattice.hpp:99`, `:145`):
`read_generations_outstanding()` sums across instances;
`request_generation_advance()` and eviction flags reach every same-path
coordinator. A C++ test pins the second-instance case (T11).

### 3.4 Hard bound — WAL-threshold keeper eviction (replaces any age-gated cap)

The WAL hook already receives the log's frame count on every commit
(`sqlite3_wal_hook`'s `int` parameter, `lattice.cpp:188-195` — currently
unused). When `frames × page_size > walKeeperEvictionThresholdBytes`, the
hook sets a per-path `eviction_pending` flag (atomic — hook-frame legal) and
requests a generation advance. Then, on reader/maintenance threads: **ALL
keepers on ALL same-path instances are force-retired — regardless of
generation age or active reads** (an age precondition would defeat the cap in
exactly the burst case it exists for: mid-treadmill no generation ever grows
old). The next generation acquisition (or the maintenance tick, if no access
comes) first checks aggregate outstanding == 0, runs one bounded
TRUNCATE-else-PASSIVE checkpoint — the **coordinated reader gap** — and only
then re-pins. Result under a sync catch-up burst: grow to threshold → gap →
rewind/truncate → re-pin → repeat; disk high-water ≈ threshold + one
detection window, not dataset-sized.

**Force-retire protocol** (used here, by pool exhaustion §2.2(e), and by
lifecycle §3.6): SQLite refuses `COMMIT` while statements are in progress on
the connection (SQLITE_BUSY "SQL statements in progress"), so the cull
(i) sets a `retiring` flag under the pool lock — new reads on the generation
are refused there and re-resolve to current; (ii) calls `sqlite3_interrupt`
on the keeper connection for wedged in-flight statements; (iii) `COMMIT`s
with a bounded retry. Facade reads re-validate the generation's live flag
under the pool lock before each statement; a read that still loses the race
serves via the tolerant ladder — the §1.2 rung-1 carve-out.

### 3.5 Close-time and autocheckpoint

`~database`'s close-time PASSIVE and `wal_autocheckpoint=1000` behave like
§3.3's PASSIVE — safe against keepers, no special-casing.

### 3.6 Process lifecycle (iOS suspension, 0xdead10cc)

A keeper holds WAL read-mark locks on the `-shm` file for the life of its read
transaction. iOS terminates suspended apps holding SQLite/file locks in
**shared (app-group) containers** with `0xdead10cc` — precisely the app +
extension / app + agent deployments where cross-process file lattices are
used. And every in-process retirement mechanism above is frozen while the
process is suspended, so a cross-process writer's WAL would otherwise grow for
the entire suspension against the suspended app's pinned snapshot. Today's
design holds no read transactions between statements; this spec must not
introduce that regression. Contract:

- The coordinator observes `UIApplication.willResignActiveNotification` /
  `ScenePhase.background` and
  `protectedDataWillBecomeUnavailableNotification` (where UIKit is available)
  and calls `retireAllGenerations()` — every keeper txn `COMMIT`s (force-
  retire protocol §3.4), every pooled connection is returned. Suspended
  processes hold **zero** read transactions and zero WAL read-marks.
- Re-pin is lazy on the next access after foregrounding: `BEGIN` + pin, two
  cheap statements; epoch-keyed caches survive if no invalidation arrived
  while backgrounded (the belt/notifier catches cross-process commits on
  resume).
- `Lattice.retireAllGenerations()` is public (§1.7) and REQUIRED from app
  extensions and non-UIKit hosts sharing an app-group container; documented
  in the API docs and MIGRATION notes.
- T5-c simulates a suspend/resume cycle (retire-all → cross-process writes →
  TRUNCATE succeeds → resume → re-pin, caches correct).

**Soak pin:** generation churn (write burst + scrolling UI, hours-scale
compressed) must keep the -wal at an **absolute bound**: `≤ 2 ×
walKeeperEvictionThresholdBytes` at all times, including bursts much larger
than the threshold (the factor 2 covers one detection window); TRUNCATE must
succeed within two pacer cycles of the burst ending (§7 test T5, plus the
T5-b non-sync/hidden-Results and T5-c suspend/resume variants).

---

## 4. The hard edges

### 4.1 In-memory and named shared-cache databases — DECIDED: materialized-id generations, no keeper

**Why keepers are forbidden here:** a held read transaction on a shared-cache
connection takes **table read locks** that make same-name writers fail
immediately with `SQLITE_LOCKED` (busy timeout does not apply to shared-cache
table locks — deferred-delivery doc §1.1; `db.cpp` `db_error`). That is the
exact defect class the transaction-settled delivery work just eliminated;
reintroducing it via keepers is unacceptable. Private `:memory:` is worse:
there is only the single write connection (`read_db_ == nullptr`,
`lattice.hpp:785`, fallback at `:2762`), and a held read txn on it would wedge
all writes on the same connection.

**Decision:** memory-family generations are **materialized-id snapshots** —
but their capture and hydration have real concurrency obligations that differ
between the two memory sub-families. Stated precisely:

**The concurrency truth (replaces Rev-1's "single shared connection" claim):**

- **Private `:memory:`** really is one connection — but
  `SQLITE_OPEN_FULLMUTEX` serializes individual `sqlite3_*` *calls*, not
  transactions (`db.cpp:26-29`), and same-connection reads have **no
  isolation from that connection's own open transaction**. A naked capture
  `SELECT` issued between two statements of another thread's explicit write
  transaction reads *uncommitted* rows; if that transaction then rolls back,
  no delivery ever corrects the vector (rollback discards the buffer,
  deferred-delivery §3.4).
- **Named shared-cache** (`file:<name>?cache=shared` — which is exactly what
  sync-enabled `:memory:` becomes, `resolve_path` at `lattice.hpp:806-812`)
  has **≥ 2 connections**: the app handle's write connection and the
  synchronizer's dedicated handle (`sync.cpp:2317-2331`), plus any additional
  same-name handles. FULLMUTEX serializes nothing across them. A capture,
  count, or hydration on one connection issued while another holds a write
  transaction (e.g. a 50-entry sync chunk apply,
  `apply_remote_changes_impl`, `sync.cpp:2786-2799`) fails **immediately**
  with `SQLITE_LOCKED`; in the reverse direction the capture's
  statement-scope table read locks fail the writer's *in-transaction*
  statements with `SQLITE_LOCKED` mid-chunk (writers retry LOCKED only at
  `BEGIN`, `db.cpp:717-743`, not per-statement). The landed settled-delivery
  work fixed *observer-callback-time* reads only; arbitrarily-timed UI reads
  get nothing from it.

**Mechanisms (all three ship; belt-and-braces):**

1. **Capture transaction (fixes private-`:memory:` dirty reads):** the id
   capture on memory DBs always runs inside
   `database::begin_transaction()` … `commit()`. `begin_transaction`'s retry
   loop already waits out a concurrent same-connection transaction —
   including the "cannot start a transaction within a transaction" path
   (`db.cpp:717-743`, `is_in_transaction()` at `:774`) — so the capture can
   never interleave another thread's open write txn on the shared
   connection, and the vector is always a committed state. The rollback-hook
   epoch bump (§2.3) is the second belt: any capture that races a
   transaction cannot outlive it.
2. **Per-store write gate (fixes shared-cache SQLITE_LOCKED, both
   directions):** `instance_registry`'s per-path entry publishes a shared
   mutex; on shared-cache stores it is taken (a) by every lattice-level
   write-transaction entry point (`lattice_db::transaction`/`add`/the sync
   chunk apply in `apply_remote_changes_impl`) for the duration of the
   transaction, and (b) by every generation capture/hydration batch. Captures
   and cross-connection write transactions therefore never overlap — no
   LOCKED in either direction on the lattice-managed paths. (Writers already
   serialize against each other at the SQLite level; the gate adds
   capture-vs-writer exclusion. It is never held across a scheduler hop, and
   it is subordinate to the §2.3 leaf-lock rule: nothing takes it inside a
   hook frame.)
3. **Bounded LOCKED retry + bridge catch-all (for anything that slips —
   raw-SQL users, future call sites):** core-side `query_ids_at` /
   `count_at` / hydration on memory DBs catch `SQLITE_LOCKED`/`db_error` and
   retry with a short sleep-backoff (LOCKED is immediate-fail; a retry loop
   is mandatory — `sqlite3_unlock_notify` is not compiled uniformly),
   degrading after a ~250 ms budget to the tolerant ladder (previous vector,
   else empty + stale flag). **Every bridge generation-read entry point gets
   a catch-all** (Commit 4): no C++ exception may cross into Swift — the
   current read paths have none (`objects()`/`count()`, bridge
   `lattice.hpp:717-797`), and a `db_error` crossing the interop boundary is
   `std::terminate`, i.e. the process abort this whole spec exists to
   forbid. Caught ⇒ empty result + stale flag ⇒ Swift ladder.

**The materialized-id design itself:**

- On first access at a new epoch, one capture (per the rules above):
  `SELECT id FROM T [WHERE …] [GROUP BY …] ORDER BY sort dir, id`
  → `ContiguousArray<Int64>` per shape. `count = ids.count`;
  `subscript(i)` = hydrate `ids[i]` by primary key (page-batched
  `WHERE id IN (…)`, input order preserved, same gate/retry rules).
- **Justification:** (a) zero *held-lock* footprint — no held txn between
  accesses, no LOCKED regression from pinning (§7 test T6 pins containment);
  (b) the capture is atomic w.r.t. writers **by the capture transaction plus
  the per-store gate** — *not* by any single-connection property (Rev 1's
  claim to that effect was wrong for shared-cache and wrong about FULLMUTEX
  transaction semantics, and is withdrawn); (c) memory DBs deliver
  **transaction-settled** batches synchronously (the landed drain), so the
  epoch bump — and thus vector refresh — is prompt and the vector is never
  more than one delivery behind; (d) cost is bounded and proportionate:
  8 B/row on a database that is already RAM-resident (800 KB per 100k rows);
  (e) consistency is structural: `count` and membership come from the same
  captured vector, so rung-1 of the trap argument holds exactly, with rung-2
  (invalidated-instance hydration) covering deletes that land between capture
  and hydration.
- **Rejected alternative** (serve from the shared connection with no captured
  state): leaves the A1 cold-fetch hole (stale count + head-state page fill)
  as the *steady state* on memory DBs, downgrading the whole contract to
  clamping. The id vector costs one cheap RAM-local scan per epoch per active
  shape and buys the same within-generation guarantee file DBs get.
- Grouped/distinct shapes materialize representative ids via the same
  `SELECT id … GROUP BY …` (SQLite's bare-column representative-row
  semantics, stable in practice; documented).
- **Emscripten** (DELETE journal, no WAL, single connection,
  `db.cpp:73-77`): same materialized-id mode. Single-threaded WASM makes the
  capture trivially atomic (the capture transaction is still used, for
  uniformity; the gate is a no-op).

### 4.2 Attached / union results (`view_handles`, `_source`)

Attach exposes overlapping tables as per-connection TEMP views on
`db_`/`read_db_` only (`view_handles()`, `lattice.hpp:4030-4047`), and
same-model UNION rows carry a `_source` column that qualifies lazy accessors
(`lattice.hpp:5450-5461`). Replaying `ATTACH` + view DDL (and rebuilds on
`rebuild_attached_views()`) across three pool connections is real surface with
real teardown ordering hazards.

**1.0 decision:** union/attached shapes (`_VirtualResults`,
`_VirtualResultsCompat`, attach-view-backed `TableResults`) do **not** use
keeper generations. They get **logical-epoch caching only**: shared shape
cache, cached count per epoch, synchronous-hook invalidation over every member
table, OFFSET page fills on `read_db()`, tolerant ladder for shortfalls. They
keep every never-trap and freshness property; they lack within-access MVCC
exactness (their today-status, minus the traps and re-query storms). Row
hydration (`_source` qualification) is untouched. Extending attach DDL replay
to pool connections is a tracked follow-up, not 1.0.

### 4.3 NearestResults

Stays **single-shot materializing** (binding decision 5): LIMIT-k
`combinedNearestQuery` (`NearestResults.swift:434-521`) has no
count-then-offset pairing and no pagination trap. It keeps reading
latest-committed via `read_db()`. Note for the future: vec0 reads its shadow
b-trees through the querying connection (verified in A2 §13.6), so KNN *would*
be generation-consistent on a keeper if ever wanted; a pin test (KNN under
concurrent vector mutation) guards the status quo.

### 4.4 DynamicResults (LatticeMCP)

Already snapshot-shaped: `count` + `snapshot(limit:offset:)` + `first`, no
`Collection` conformance, no subscript, no trap path
(`Dynamic/DynamicResults.swift:10-58`). **Alignment:** none required for
safety. It keeps `read_db()` semantics ("every call reads latest-committed"),
which is right for MCP's one-shot request/response usage. Optional later:
route through a generation when the owning provider holds one, purely for
cross-statement report consistency. Not 1.0.

### 4.5 Grouped / distinct results

Covered in §2.4: generation-scoped OFFSET paging (consistent on file DBs
because the scan runs at the keeper snapshot; id-vector on memory DBs), no
keyset anchors, never trap. `countWithinBBox`/`objectsWithinBBox` shapes
follow the same rule.

### 4.6 `Lattice.close()` / `delete()` while generations live

`Lattice.close()` → `backend.close()` → `lattice_db::close()`. Ordering
additions: retire all generations (COMMIT keeper txns) and close pool
connections **before** `db_`/`read_db_` teardown; `database::close()` is
already the logical-close pattern (ops short-circuit to empty; the `sqlite3*`
is freed only in single-threaded `~database`, `db.hpp:35-40`), and pool
connections adopt it. In-flight generation reads hold a `shared_ptr` to their
`database` wrapper — post-close they return empty rows → tolerant ladder →
placeholder/lifeboat, no trap, no UAF. `Lattice.delete(for:)` already closes
cached backends before unlinking (`Lattice.swift:1082-1110`); generations ride
that same close. The coordinator registry evicts on close (keyed by
`identityHash`, which changes on reopen — `SwiftUI.swift:70-95` already relies
on this identity swap).

### 4.7 `busy_timeout` and lock interplay

- WAL readers never block the writer and vice versa: keeper acquisition
  (`BEGIN` + pin SELECT) does not contend with an active writer; the
  config's `busy_timeout_ms` (default 30 s, `db.hpp:17`) stays on pool
  connections for pathological recovery windows only.
- File DBs have **two** real keeper↔writer interactions, both owned by §3:
  TRUNCATE-vs-keeper (attempt + fallback + advance request, §3.3) and
  **log-rewind starvation** under continuous keeper coverage (threshold
  eviction, §3.4).
- Memory family: no *held* transactions and no new busy paths beyond the
  bounded LOCKED retry on shared-cache captures (§4.1). Shared-cache stores
  are **not** single-connection (app handle + sync handle + any same-name
  handles), and no part of this design relies on single-connection
  serialization there — capture atomicity comes from the capture transaction
  and the per-store write gate (§4.1). Private `:memory:` is
  single-connection, and its capture atomicity comes from the capture
  transaction, not from FULLMUTEX (which serializes calls, not transactions).

### 4.8 Linux / CI

Identical by construction: the design uses only `BEGIN`/`COMMIT`, WAL MVCC,
`PRAGMA data_version` — core SQLite on every platform and every distro build.
No compile-option probing, no `ENABLE_SNAPSHOT`, no vendoring (§8.1, §8.2),
no `sqlite3_unlock_notify` dependency (§4.1 uses retry-backoff instead).
The full test inventory (§7) runs unmodified on Linux CI; WAL + read-only
connections behave identically (POSIX shm; the read-only heap wal-index
fallback already handled at `db.cpp:33-40`).

---

## 5. Performance model

| Operation | Today | This design |
|---|---|---|
| `count`, idle | 1 × `COUNT(*)` per access (`TableResults.swift:165-170`) | 0 (cached per generation) |
| Render tick, idle | 1 COUNT + one O(i) `LIMIT 1 OFFSET i` per visible row, per body eval | **0 queries** beyond the amortized `data_version` pragma (≤ 1 per belt interval) |
| Render tick, write burst | same as idle, racing the writer, every tick | per epoch, coalesced ≤ 1/frame: keeper re-pin (BEGIN + pin, no data SQL) + 1 `COUNT(*)` + visible-page keyset refill (1–2 fills) |
| `subscript(i)`, warm | O(i) statement per access | 0 (page cache) |
| Sequential scroll of N rows | O(N²) (per-row OFFSET) | N/pageSize keyset fills, O(log N + pageSize) each with `@Indexed` sort → ~O(N) |
| Cold random jump to row k | O(k) per body eval touching it | O(k) **once per jump**, then anchored keyset |
| Deep scroll during write burst | O(offset) × visible rows × every frame | keyset refill from persisted anchor: O(pageSize)/frame |
| Full iteration | OFFSET batches, O(n²/100) (`Results.swift:144-155`) | keyset batches, O(n) |
| Write amplification | none | O(1) atomic epoch bump per settled txn (inline hook); refcount-0 keeper COMMIT scheduled off-thread; re-pin ≤ once/frame |

The render-batch pin (§1.3) costs one thread-local read per access and one
runloop-observer callback per main-thread tick — no SQL, no locks. Memory-DB
captures add `BEGIN`/`COMMIT` around the id scan (two cheap statements on a
RAM-resident store) plus per-store gate acquisition on shared-cache stores.

**Memory bounds (per shape):** `maxCachedPages × pageSize` hydrated elements
(default 1,600; each a full-row copy + registry entry + one C++ object
observer) + `previousPages` (≤ same, dropped on supersession) + anchors
(~24 B/page, ~24 KB per 100k rows, never evicted) + lifeboat (1 element).
Per lattice: registry ≤ `maxCachedShapes` shapes (LRU + idle eviction);
keeper pool ≤ 3 read-only connections at clamped 2,000-page cache; memory DBs
add id vectors (8 B/row per active shape). **Disk:** -wal bounded by
`walKeeperEvictionThresholdBytes` sawtooth (§3.4), absolute, independent of
burst size. Statement budgets are pinnable via
`Lattice.totalSQLStatementCount` / `threadSQLStatementCount`
(`RowCache.swift:100-109`, backed by `db.cpp` counters).

---

## 6. Migration & compatibility

**Compiles unchanged: everything.** `Results` keeps
`Sequence + RandomAccessCollection`, `subscript`, `Slice`, `snapshot()`,
`observe`, chaining, nearest/geo/FTS, `@LatticeQuery`, `@Relation`,
`ForEach(results)` / `List(results)`, `sendableReference`. Additive API only
(§1.7). No `MIGRATION-1.0.md` *source-break* entries from this item.

**Semantic changes (each gets a MIGRATION-1.0.md line):**

1. Live `Results` reads are **generation-consistent** (snapshot at the last
   delivered invalidation, resolved once per render batch) instead of
   statement-fresh; same-thread read-your-writes preserved; cross-thread
   readers observe a commit no later than the next batch boundary after its
   synchronous notification.
2. Out-of-bounds / cross-generation `subscript` **clamps or serves an
   invalidated placeholder instead of trapping** (previously
   `fatalError("Index out of bounds")`, `Results.swift:238`, `:185`).
3. Unsorted queries gain a deterministic implicit `ORDER BY id ASC`; sorted
   queries gain the `id` tiebreaker.
4. `for x in results` iterates by keyset: rows are visited at most once in
   total order; mid-iteration shrinkage ends early rather than trapping; the
   O(n²) OFFSET creep is gone.
5. Baseline memory grows by the bounded page cache + anchors (configurable
   via `ResultsTuning`); memory DBs additionally hold per-shape id vectors;
   file DBs accept a -wal sawtooth up to `walKeeperEvictionThresholdBytes`.
6. Memory-family DBs: a row deleted concurrently with a render can hydrate as
   an invalidated (default-valued) instance for ≤ 1 frame.
7. `count` on an unobserved, untouched handle does not advance until the next
   access (belt/TTL bound it when cross-process writers are involved).
8. Backgrounding retires all read generations (transparent — lazy re-pin on
   next access after foregrounding). **App extensions and non-UIKit hosts on
   shared app-group containers must call `retireAllGenerations()` before
   suspension** (0xdead10cc, §3.6).

---

## 7. Implementation plan

Core work **is** required: holding a read transaction needs a connection the
Swift layer can route reads through, and today's bridge exposes none —
`swift_lattice_ref.begin_transaction/commit/rollback` (bridge
`lattice.hpp:1021-1033`) drive the **write** connection via
`lattice_db::begin_transaction`, `query_rows`/`count` are hardwired to
`read_db()` (`lattice.hpp:2625`, `:2762`), there is no id-only query surface,
and — decisive for sequencing — **no synchronous invalidation delivery exists**
(`notify_changes_batched` is scheduler-dispatched, `lattice.hpp:1987`; §2.3).
Commits in dependency order, each compile-gated with its pin tests:

**Commit 1 (lattice) — shared shape cache + epochs + never-trap
(Swift-only).**
`GenerationCoordinator` (logical epochs only, all storages; render-batch pin
§1.3), `QueryShapeCache` registry (two-phase lock pattern, §2.3),
**write-path epoch bumps** — `Lattice.add()`/`transaction()` bump the
coordinator directly after the backend returns (same-handle RYW with zero
core work; the scheduler-hopped `Lattice.observe` remains an interim
cross-handle freshness signal until Commit 5), tolerant ladder replacing both
`fatalError`s, lifeboat + `previousPages`, `refresh()`/`element(at:)`, facade
wiring for `TableResults`/`@LatticeQuery`/`@Relation`/TSR.
*Tests:* **T1 trap-impossibility watchdog** (the A4 pattern: background
deleter loop vs main-thread `count` + `subscript(count-1)`, 10k iterations,
bounded watchdog — run on file, `:memory:`, named shared-cache);
**T2a same-handle read-your-writes** (`add` → same-thread `count` reflects,
no await — **parameterized over isolation contexts: MainActor-created AND
nonisolated-created lattices**; the cross-handle form is T2b, Commit 5);
**T10 leaf-lock ABBA watchdog** (sync-enabled file lattice, tight writer loop
vs reader thread populating cold shapes through the registry, bounded
watchdog — pins the §2.3 two-phase pattern on the read-through-write-
connection topology that shipped the `sync.cpp:668-676` deadlock);
statement-budget partials (idle tick 0 collection queries); no-`fatalError`
grep gate; registry eviction bounds.

**Commit 2 (lattice) — keyset fills + persistent anchors.**
NULL-aware/DESC/collation keyset predicates, deterministic `ORDER BY id`,
`KeysetCursor` replacing `Cursor`, anchor map + content-anchored burst refill,
grouped/distinct OFFSET carve-out.
*Tests:* keyset property matrix (NULL-first/last × ASC/DESC × collated TEXT ×
duplicate keys — walk ≡ `snapshot()` order, no dup, no trap under a
concurrent deleter); deep-scroll budget (jump to 90k = exactly 1 OFFSET
statement, then keyset — via `threadSQLStatementCount`); anchor survival
across epoch bumps.

**Commit 3 (latticecore) — synchronous invalidation hook + read-generation
pool + WAL policy.**
`lattice_db::add_invalidation_hook`/`remove` (inline in `flush_changes`,
before the `notify_changes_batched` dispatch, fanned per-path via
`instance_registry::for_each_alive`; rollback-hook epoch signal),
`lattice_db::read_generation` (refcounted; keeper `database` from a new
`read_pool_`; `BEGIN`+pin on acquire, `COMMIT` on release; force-retire
protocol §3.4 with `retiring` flag + `sqlite3_interrupt` + bounded COMMIT
retry), `acquire_read_generation()/release`,
`read_generations_outstanding()` **aggregated per path across
`for_each_alive`**, `run_read_pool_maintenance()` (TTL retire, absolute age
re-pin, pending evictions — callable without a synchronizer),
WAL-threshold eviction flag from the WAL hook's frame count,
`request_generation_advance()` (delivered through the invalidation-hook
path, fanned per-path), `maybe_checkpoint`: TRUNCATE attempt unchanged +
advance request when beaten (§3.3 — **no** outstanding-gate), per-store
write gate for shared-cache stores (§4.1), close-ordering (retire pool
before `db_`/`read_db_`).
*Tests (C++):* invalidation hook fires inline on the writer's thread before
any scheduler dispatch (thread-id + ordering assert), including from the
sync handle to the app handle (cross-instance); rollback bumps;
**T11 cross-instance policing** (keeper held by a *second* same-path
`lattice_db` — synchronizer topology: outstanding counts aggregate; advance
request reaches the holder; TRUNCATE succeeds next cycle); TTL retire with
in-flight-statement "active reads" definition; force-retire vs in-flight
statement (interrupt + bounded COMMIT retry, reader re-resolves, no
SQLITE_BUSY leak); WAL-threshold eviction opens a reader gap and the log
rewinds (frame count sawtooth ≤ threshold + one window under a synthetic
burst); shared-cache gate: chunked sync apply vs concurrent captures — no
surfaced SQLITE_LOCKED either direction; generation reads post-`close()`
return empty (no UAF, TSAN/ASAN lanes).

**Commit 4 (latticecore bridge) — generation + hook surface, exception
containment.**
`swift_lattice_ref`: `add_invalidation_hook(context, c_fn)`/`remove` (C
trampoline, §2.3 restrictions), `acquire_read_generation() → uint64`,
`release_read_generation(id)`, generation-scoped `objects_at` / `count_at` /
`objects_within_bbox_at` (same SQL builders, keeper-routed),
`query_ids_at(table, where, orderBy) → std::vector<int64_t>` (id vectors —
capture-transaction + gate + LOCKED-retry semantics per §4.1),
`data_version() → int64` on `xproc_read_db_`, `retire_all_generations()`.
**Every one of these read entry points is wrapped in a catch-all** — any
`db_error`/exception becomes an empty result + stale flag; no C++ exception
can reach Swift interop (§1.2 rung 5). Additive trampoline overload carrying
`changed_fields` (delivered but unused until Commit 8).
*Tests:* bridge round-trips; hook delivery is same-thread/inline from a
MainActor-created lattice (the T2 failure mode of the old trampoline,
pinned); fault injection — a throwing core read surfaces as empty + stale,
process alive; id-vector order ≡ row query order; data_version changes on
foreign-connection commit only.

**Commit 5 (lattice) — keeper generations wired end-to-end + lifecycle.**
Swift coordinator consumes the Commit-4 hook (replacing the interim
`Lattice.observe` cross-handle signal), routes file-DB generation reads
through the bridge surface; `snapshot()` on a live facade executes at the
current generation; memory DBs upgrade to materialized-id generations via
`query_ids_at`; maintenance timer (§3.2) wired for all configs; lifecycle
observers + `retireAllGenerations()` (§3.6).
*Tests:* **T2b cross-handle read-your-writes** (write on handle B / sync
apply → handle A's next batch reflects, MainActor-parameterized);
**T3 within-generation MVCC exactness** (count at gen N, delete via writer,
subscript still serves gen N rows until re-pin); **T5 WAL-bound soak**
(write burst + scrolling UI: -wal ≤ 2 × threshold **absolute**, TRUNCATE
recovers ≤ 2 pacer cycles post-burst); **T5-b non-sync + hidden Results**
(no pacer; view-model-retained facade, zero accesses, hours-compressed local
writes → timer-driven retire keeps -wal bounded); **T5-c suspend/resume**
(retire-all on background simulation → cross-process writes → TRUNCATE
succeeds while suspended-state → resume re-pins, caches correct);
**T6 shared-cache memory containment** (named memory, two handles: writer
loop + generation-reading UI loop — zero *surfaced* errors, zero deadlock,
zero `std::terminate`, bounded watchdog; internal LOCKED retries permitted,
steady-state ≈ 0 with the gate); **T8 render-batch frame coherence**
(background insert-at-head during a List render pass must not displace
visible row contents relative to their diffed IDs within one frame — pin the
batch pin); close/delete-while-generations-live; iterator generation-hop
resume.

**Commit 6 (lattice) — data_version belt.**
Amortized belt check on top-level access batches (`xproc_read_db_`);
`crossProcessBeltIntervalMs` tuning.
*Tests:* **T4 cross-process data_version** (second process commits: belt off
→ stale until notifier/TTL; belt on → fresh within interval; assert ≤ 1
pragma per interval). Reuse `ObservationOrderingTests` to pin no
delivery-contract regression.

**Commit 7 (lattice) — identity stability + instance reuse.**
Registry `lookup(key:)`, page refill reuse of live instances.
*Tests:* **T7 identity stability across epochs** (`Model.id == primaryKey`
pinned; `ForEach` diff produces no delete+insert for surviving rows across an
epoch bump; reused instance identity where the weak ref is live); observer
registration-churn budget under fling-scroll (LatticePerf counters).

**Commit 8 (both, v1.1) — changedFields skip.**
Consume the Commit-4 trampoline fields; predicate/sort column extraction;
skip disjoint UPDATE-only *shape* invalidation (epoch still bumps, §2.3)
behind a default-on flag.
*Tests:* member-row unrelated-column update ⇒ no rebuild, row repaints via
object path; predicate/sort-column update ⇒ rebuild ≤ 1 debounce cycle;
long-soak equivalence vs baseline (flag on vs off, identical final frames).

**Test inventory cross-reference (required by this spec):**
T1 trap-impossibility under concurrent delete bursts (A4 watchdog) — Commit 1;
T2a same-handle read-your-writes (isolation-parameterized) — Commit 1;
T2b cross-handle read-your-writes — Commit 5; T3 within-generation MVCC —
Commit 5; T4 cross-process data_version — Commit 6; T5 WAL-bound soak
(absolute bound) + T5-b (non-sync, hidden Results) + T5-c (suspend/resume) —
Commit 5; T6 shared-cache containment — Commit 5; T7 identity stability
across epochs — Commit 7; T8 render-batch frame coherence — Commit 5;
T10 leaf-lock ABBA watchdog — Commit 1; T11 cross-instance WAL policing —
Commit 3.

---

## 8. Explicitly resolved questions

1. **Why not `sqlite3_snapshot` (A2 as written)?** The API is a compile-time
   option (`SQLITE_ENABLE_SNAPSHOT`) that our *linked system* SQLite does not
   uniformly have: the design-discussion probe (Jul 12–13 2026) verified that
   **Ubuntu noble's system `libsqlite3` 3.45.1 does NOT export
   `sqlite3_snapshot_get/open/free/cmp/recover`** — the symbols are absent
   from the shared object, so the A2 build would not even link on our Linux
   CI/servers. (Apple's dylib exports them — A2 §2 verified 3.51.0 with
   `ENABLE_SNAPSHOT`; Android/wasm bundle their own amalgamation.) A2 §2 also
   established the deeper point: a bare token pins nothing — the real unit of
   pinning is the **open read transaction** (keeper). A2-LITE keeps exactly
   that keeper and drops the token, and with one connection per generation
   executing all of that generation's reads, the token adds nothing: the
   connection's own read transaction *is* the snapshot. Same guarantee, zero
   platform variance, zero fallback-mode matrix (A2 risk 5's "three execution
   modes" collapses to two: keeper and materialized-id).
2. **Why no SQLite vendoring prerequisite?** Nothing in this design is gated
   on a compile option — `BEGIN`, WAL MVCC, and `PRAGMA data_version` are
   unconditional core SQLite. Vendoring remains a *separable* future decision
   for preupdate-hook/session flags and is explicitly out of item A's scope.
3. **Why not drop `Collection` (the original item A / A3)?** User decision,
   on ergonomics: `ForEach(results)`/`results[i]` keep compiling with lazy row
   loading, and Realm/SwiftData muscle memory keeps working. A3's own §8
   costs it honestly — a repo-wide, every-list-view source break whose easy
   wrong choice (`snapshot()` on a big table) is a memory cliff we could only
   lint. A2-LITE delivers the same trap-freedom *with* the ergonomics; A3's
   real contributions — keyset SQL, tolerant fill, the "generations make
   UPDATE-membership boring" argument — are absorbed (§2.4, §1.2, §2.3).
4. **Why was A1's pure generation-cache rejected?** The **cold-fetch hole**
   (A1 §5.2): with no pinned snapshot, a stale cached count paired with a
   *cold* page fetch executes against the post-delete head database and comes
   back short — A1 can only clamp (serve previous pages / nearest element),
   i.e. knowingly render wrong rows for a frame, and its ladder is the
   *primary* mechanism rather than a rare fallback. Under A2-LITE the common
   path is structurally consistent (count and fill share one MVCC snapshot);
   A1's ladder survives only as the cross-generation fallback (§1.2 rung 3)
   and its two strongest ideas — trampoline-synchronous invalidation
   (realized here as the §2.3 core hook) and persistent keyset anchors — are
   load-bearing grafts here (§2.3, §2.4). A1's "no held read txns → no WAL
   coordination" advantage is neutralized by §3 (threshold eviction, TTL,
   maintenance timer, lifecycle).
5. **Why does *every* commit bump the epoch, when subscription is
   per-shape?** Because the epoch drives two consumers with different needs:
   cache invalidation (per-table, refined by the changed-table payload) and
   **keeper retirement** (per-commit — every commit grows the WAL a keeper
   pins, including commits to tables no shape observes). Lazily-scoped epoch
   bumps would silently exempt unobserved-table write workloads from §3.2's
   natural-lifetime bound. The cost of the broader bump is one atomic
   increment plus a
   two-statement re-pin at next access; untouched shapes keep caches (§2.2).
6. **Why batch-pinned generation resolution instead of resolve-per-access?**
   Truly synchronous invalidation (binding decision 3) means a background
   commit can land *between* a render pass's count/ID-diff and its lazy
   subscript fills; resolving per-access would mix generations inside one
   frame (identity at N, rows at N+1 — visible row displacement after a
   head-insert). Pinning per batch makes a frame single-generation by
   construction while keeping same-thread RYW exact (a same-thread bump
   clears the pin immediately, §1.3). This deliberately keeps the one good
   property of today's scheduler hop (frame coherence) while fixing its
   staleness.

---

## 9. Adversarial-review disposition (Rev 2)

All eleven findings of the Jul 2026 adversarial review were **accepted**; none
rejected. Where each landed:

| # | Finding (abbrev.) | Resolution |
|---|---|---|
| 1 | Named shared-cache: "single shared connection" premise false; SQLITE_LOCKED races; db_error → `std::terminate` across bridge | §4.1 rebuilt: capture txn + per-store write gate + bounded LOCKED retry + bridge catch-alls (§1.2 rung 5); §4.7 rewritten; T6 re-scoped to containment; Commit 3/4 items |
| 2 | WAL log-rewind starvation; TRUNCATE embargoed by outstanding-gate; unbounded burst WAL | §3.1 corrected model; §3.4 threshold keeper eviction (age precondition removed); §3.3 gate replaced by attempt+advance-request; T5 acceptance now absolute (≤ 2× threshold) |
| 3 | Private `:memory:` FULLMUTEX serializes statements, not txns — dirty-read capture; rollback silence poisons vector | §4.1 mechanism 1 (capture transaction via `db.cpp:717-743` retry loop); §2.3 rollback-hook epoch bump |
| 4 | Pacer consults the wrong `lattice_db` instance — outstanding() always 0 | §3.3 normative per-path aggregation via `instance_registry::for_each_alive`; Commit 3; test T11 |
| 5 | No retirement actor without sync; epoch bump ≠ release; lazy per-table subscription starves the bound | §3.2 maintenance timer (all configs) + off-hook refcount-0 COMMIT (§2.2); §2.3 per-commit epoch semantics; "active reads" defined; T5-b |
| 6 | iOS suspension: 0xdead10cc + frozen retirement | §3.6 lifecycle contract; `retireAllGenerations()` public (§1.7); migration line 8; T5-c |
| 7 | ABBA: callback-lock rule must be a system-wide reader-side invariant | §2.3 normative leaf-lock rule + two-phase registry pattern; T10 in Commit 1 |
| 8 | Force-retire: COMMIT vs in-flight statements (SQLITE_BUSY); retire/read race serves head state | §3.4 force-retire protocol (retiring flag, interrupt, bounded retry, per-statement liveness re-validation); §1.2 rung-1 carve-out |
| 9 | RYW headline false: `addTableObserver` is scheduler-dispatched | §0.3 + §1.3 + §2.3 rebuilt around the new synchronous core hook; Commit 1 re-scoped to Swift write-path bumps; T2 split (T2a/T2b) and isolation-parameterized |
| 10 | Mid-render epoch advance tears a frame | §1.3 render-batch generation pin; §8.6; T8 |
| 11 | `ResultsTuning` uses `Duration` on an iOS-15-floor package | §1.7: `crossProcessBeltIntervalMs: Int?`, `generationTTLSeconds: TimeInterval` |
