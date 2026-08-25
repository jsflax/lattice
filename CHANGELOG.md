# Changelog

## [1.7.0] - 2026-08-20

LatticeCore dependency floor unchanged (`from: "1.4.2"`); zero core changes.

### Added
- **Observer push** (`LatticeServerKit`): `configureSyncRelay` gains
  `observerPush: SyncObserverPush?` (default `nil` — pre-1.7 behavior
  byte-for-byte). On a push-enabled mount, every commit to a channel's
  database file — a relay-socket apply on any mount sharing the file, an
  in-process co-writer such as a projector actor, or (best-effort) another
  process — is pushed to that mount's sockets as ordinary
  `ServerSentEvent.auditLog` catch-up frames, exactly-once and
  commit-ordered per socket ("nudge + pump": a payload-free per-file commit
  observer nudges per-socket pumps that re-run the catch-up machinery from a
  monotone AuditLog-pk cursor, with awaited sends for slow-consumer
  isolation). Watch groups live on ONE process-wide manager, so push mounts
  over the same channel file share one watcher Lattice and one commit
  observer; every pump holds its own strong watcher reference, so
  last-subscriber teardown can never trap or dangle an in-flight pump.
  Clients apply pushed frames with zero changes; app-level redial loops
  become cheap no-op fallbacks. Push-enabled mounts no longer fan client
  frames (observer acks) to same-channel peers. `SyncObserverPush.pageSize`
  is validated at init (`precondition`) and clamped positive per
  subscription, so a zero/negative page can never make a pump spin without
  draining. The per-file watcher open runs OFF the process-wide manager
  actor (concurrent first subscribers dedupe onto one in-flight open), so a
  slow SQLite open on one channel cannot stall another channel's pumps,
  nudges or teardowns; and a connection whose connect-time catch-up throws
  releases its parked subscription and closes, so a failed catch-up can
  neither strand a watch group nor leave a permanently silent observer.
- `Lattice.observeCommits(_:)` — payload-free AuditLog commit signal (no
  per-row hydration, no delivery-worker hop; consumers re-query by cursor).
- `Lattice.eventsAfter(id:)` — `Int64` primary-key-cursor overload beside
  the existing `eventsAfter(globalId:)`.
- `SyncSchemaHandshake`: native `?schema=` query-parameter declaration
  (checked before the header — browser WebSockets cannot set headers) and
  `Mode.exact(Int)`, which refuses both older ("upgrade required") and
  newer ("server behind client") clients with distinct legible close
  reasons. Query-param admission is OPT-IN: the legacy `minimumVersion`
  init stays header-only (behavior-identical to pre-1.7 — an upgrade never
  silently widens a mount's admission surface); the exact-mode init
  defaults `queryParameterName` to `"schema"`, and minimum-mode mounts can
  set it explicitly. Consumers adopting exact mode can delete their
  query-lift middleware and app-level newer-schema checks.

## [1.2.0] - 2026-08-04

### Added
- `IPCSyncTarget.narrowingEmitsRemovals` — Swift surface for the Stage A4
  core flag. Default `true` (narrowing trims the peer's mirror, unchanged);
  `false` makes narrowing bookkeeping-only, which is required when the peer
  is a shared multi-writer database (a group spoke): un-sharing must stop
  future sharing without deleting rows other members already have.

## [1.0.0] - 2026-07-25

The 1.0 release. Every breaking change below is also ledgered, one line per
change, in `MIGRATION-1.0.md` — read that alongside this section when
upgrading from 0.10.x. Binary consumers: an xcframework built against 0.10.x
fails at link against 1.0 (symbols changed for the throwing `add` family, the
`changeStream` getter's new return type, and the removed
`init(isStoredInMemoryOnly:)`) — vendored binaries must be rebuilt from
migrated sources.

### Added
- `Lattice.detach(lattice:)` — drops a previously attached database's views,
  DETACHes it, and rebuilds the merged schema. Add it to teardown paths that
  `attach`.
- `Lattice.rollbackTransaction()` alongside the existing begin/commit pair.
- `Results.element(at:)` — returns `nil` for a missing index instead of a
  fabricated element (see the subscript behavior change below).
- `Configuration.resultsTuning` (`ResultsTuning`) — tuning knobs for the new
  live-results read model: page size, cached pages and shapes, generation
  TTL, WAL eviction threshold, cross-process freshness interval.
- `Lattice.retireAllGenerations()` — releases every pinned read generation;
  required before suspension in some host configurations (see the
  backgrounding note under Changed).
- Public `ColumnValue` (`.null` / `.int64` / `.real` / `.text` /
  `.blob(Data)`, one case per SQLite storage class, with
  `int64Value`/`doubleValue`/`stringValue`/`dataValue`/`isNull` accessors)
  and `MigrationContext.setValue(table:rowId:column:value:)` for staging
  per-row writes during migration enumeration.
- New `LatticeError` cases: `addFailed`, `alreadyManaged`, `attachFailed`,
  `detachFailed`.

### Changed

Live results and observation:
- **Live `Results` reads are generation-consistent.** On file (WAL)
  databases, every `count`, page fill, and `snapshot()` within one
  main-thread render batch executes at a single pinned MVCC snapshot, served
  by a small pool of read-only connections; on in-memory databases the
  equivalent is a per-query-shape materialized id vector captured under the
  store's write gate. Same-handle read-your-writes stays exact — `add`,
  `delete`, `transaction`, and managed-property setters advance the read
  epoch synchronously before returning. A commit from another same-process
  handle (a second `Lattice` instance, a sync-applied chunk) also advances
  the epoch synchronously on the writer's thread; a commit from another
  thread becomes visible at the next render-batch boundary, so a single
  frame always renders one generation. `Results.refresh()` forces an
  advance.
- **`count` and `subscript` are generation-cached** — resolved at most once
  per main-thread runloop tick instead of issuing a fresh statement per
  read, backed by a bounded per-query-shape page cache (`pageSize` ×
  `maxCachedPages` hydrated rows per shape, at most `maxCachedShapes` shapes
  per lattice, LRU-evicted). Baseline memory grows by the size of that
  cache; tune it via `Configuration.resultsTuning`.
- **Out-of-bounds and cross-generation subscripts no longer trap.** Instead
  of `fatalError("Index out of bounds")`, `Results` and `Slice` subscripts
  serve a tolerant ladder: the current fill, then a retained previous page,
  then a last-known-good element, and finally an unmanaged default-valued
  placeholder. Use `element(at:)` when you want `nil` for a missing index.
  Accessing a `@Relation` on a not-yet-inserted instance returns empty
  results instead of trapping.
- **Unsorted live queries are now deterministic**: results with no explicit
  sort carry an implicit `ORDER BY id ASC` (oldest-first) instead of SQLite
  scan order.
- **Iteration is stable under concurrent change.** On file databases,
  `for x in results` walks a captured generation and, if that generation is
  retired mid-walk, transparently re-pins and resumes from a keyset anchor —
  rows are visited at most once, in order. On in-memory databases, a row
  deleted concurrently with a render can hydrate as an invalidated
  (default-valued) placeholder for at most one frame; iteration skips such
  rows.
- **File databases trade some WAL growth for pinned reads**: the `-wal` file
  may grow up to `ResultsTuning.walKeeperEvictionThresholdBytes` (default
  16 MB) before pinned snapshots are evicted, and up to three extra
  read-only connections are opened per instance. Idle read generations
  self-retire after `ResultsTuning.generationTTLSeconds` (default 30 s) via
  a maintenance timer that runs for every configuration, including non-sync
  lattices.
- **Backgrounding retires all read generations.** This is automatic where
  UIKit is available (resign-active / protected-data notifications), and
  transparent — results re-pin lazily on the next access after
  foregrounding. App extensions and non-UIKit hosts using a shared app-group
  container MUST call `Lattice.retireAllGenerations()` before suspension: a
  suspended process holding WAL read marks in a shared container is killed
  by the system (`0xdead10cc`). SwiftUI hosts where those notifications do
  not fire should call it from a `ScenePhase` handler.
- **Cross-process freshness is a bounded-staleness contract**: another
  process's commit becomes visible within
  `ResultsTuning.crossProcessBeltIntervalMs` (default 500 ms) or on any
  same-process write or notification, whichever comes first — not
  instantaneously. Same-process writes remain read-your-writes exact.
- **`DynamicResults` is a documented exemption** from the generation-pinned
  read model: it keeps live `count` and LIMIT/OFFSET
  `snapshot(limit:offset:)` semantics, and is trap-free under concurrent
  shrink by construction. `count` and a subsequent `snapshot` are not
  mutually consistent under a concurrent writer — take one `snapshot()` and
  derive counts from it.

Throwing APIs (wrap call sites in `try`):
- **The `add` family now throws**: `add(_:)`, `add(_:preservingGlobalId:)`,
  `add(contentsOf:)`, and the `any VirtualModel` overload. Backend insert
  failures (constraint violation, closed handle, I/O error) surface as
  `LatticeError.addFailed` where `add(_:)` previously terminated the process
  and the `VirtualModel` overload silently swallowed them. Re-adding an
  already-managed object throws `LatticeError.alreadyManaged` instead of an
  unconditional message-less `fatalError()`, and `add(contentsOf:)` now
  pre-checks every element and throws before anything is inserted. The
  `throws` cascades through wrappers: helpers that wrap `add` must become
  `throws` themselves, and detached work that adds becomes
  `try await Task.detached { … }.value` so the failure reaches the caller.
- **`Lattice.attach(lattice:)` and `attaching(lattice:)` now throw**
  `LatticeError.attachFailed` on schema mismatch or alias collision instead
  of terminating the process; the new `detach(lattice:)` throws
  `LatticeError.detachFailed`. `attach` and `detach` are `mutating`
  (`Lattice` is a struct) — a handle that attaches must be bound `var`, not
  `let`; recommended teardown is `defer { try? handle.detach(lattice:) }`,
  and the non-mutating `attaching(lattice:)` returns a new merged handle.
- **`Lattice.transaction { }` now rolls back on a thrown error and rethrows
  it.** Previously a throw left the write transaction open, wedging the
  connection until the busy timeout killed the process.
- **`LatticeBackend` protocol requirements changed** (custom conformers
  only; none known outside this repo): `attach` now throws; `detach(_:)`,
  `rollback()`, and throwing `addPreservingGlobalId`/`addBulk` are new or
  updated requirements; and the read-generation machinery adds
  invalidation-hook, generation acquire/retain/release/retire,
  pool-maintenance, and generation-pinned query entry-point requirements.

Storage and memory:
- **`Configuration.isStoredInMemoryOnly` is replaced by
  `Configuration.storage`**: `.file(URL)`, `.memory()` for a fresh private
  in-memory database, or `.memory(named:)` for a shared one — handles opened
  with the same name in one process share the database and observe each
  other's writes. Migrate `.init(isStoredInMemoryOnly: true)` to
  `.init(storage: .memory())`; `.init(fileURL:)` spellings keep working, and
  `configuration.fileURL` remains as a computed accessor whose setter
  switches storage to `.file`. Boolean read sites migrate too:
  `if configuration.isStoredInMemoryOnly` becomes
  `if case .memory = configuration.storage` (file branch:
  `if case .file(let url) = configuration.storage`). Do not test the storage
  kind via `fileURL` — for memory stores it returns the legacy `:memory:`
  placeholder URL, not a real path.
- `.memory(named:)` names are percent-encoded into the backing SQLite URI:
  names no longer need to be URI-safe, and two names that differ only by
  URI-hostile characters (`?`, `#`, `%`, space) are distinct databases.
- **`EmbeddedModel` reads are tolerant**: reading a property from empty or
  undecodable stored JSON returns the type's default value (with an error
  log) instead of trapping. JSON encode failures on the write path still
  trap, now with a message naming the type.

Sync progress and change stream:
- **`Lattice.changeStream` is now
  `AsyncThrowingStream<[AnySendableReference<AuditLog>], any Error>`** (was
  `AsyncStream`) — iterate with `for try await`. Creating or iterating the
  stream no longer blocks the calling task on the background database open,
  so time limits and cancellation can fire; the AuditLog observer still
  registers synchronously at stream creation, so commits made after the
  stream exists are always captured (early batches buffer and flush in
  order). A failed background open surfaces as a thrown error at first
  iteration instead of crashing the process, and cancellation promptly ends
  iteration and removes the observer. In non-throwing observer contexts
  (view models, `.task` modifiers) the recommended policy is
  catch-and-end-observation — strictly gentler than the 0.10 trap:
  `do { for try await batch in lattice.changeStream { … } } catch { … }`,
  logging the error and re-creating the stream to resume.

Migrations:
- **`MigrationContext.enumerateObjects(table:callback:)` is
  reimplemented.** The old `(any Model, any Model) -> Void` callback was a
  never-functional stub — it compiled but did nothing. The callback now
  receives each row's `id` (`Int64`) plus the full old row as
  `[String: ColumnValue]`, and per-row writes are staged with the new
  `setValue(table:rowId:column:value:)`. The versioned `[Int: Migration]`
  dictionary remains the wired migration path in 1.0 — no public open
  invokes a `MigrationContext` block yet. The versioned row-transform path
  migrates BLOB-bearing tables byte-for-byte (now test-pinned).
- **`DynamicResults.sorted(by:ascending:)` is renamed
  `sortedBy(_:ascending:)`** — one sort spelling across the API surface,
  matching the typed `Results` family.

### Removed
- **`Lattice.onSyncProgress(_:)`** — `syncProgressStream` is the canonical
  progress API (`for await progress in lattice.syncProgressStream`), with
  `syncProgressPublisher` as the Combine adapter. The publisher is now
  stream-backed, and cancelling its subscription clears the underlying
  handler, where the old callback leaked for the backend's lifetime.
  Migration is a mechanical callback → `for await` conversion. If the loop
  lives in a `Task { … }` closure, capturing the `Lattice` struct trips
  Swift 6 region isolation ("sending … risks causing data races") — hoist
  the stream out first: `let stream = lattice.syncProgressStream;
  Task { for await progress in stream { … } }` (`AsyncStream` is `Sendable`;
  `Lattice` is not).
- **`Model.__globalId`** — the deprecated requirement is gone and the
  `@Model` macro no longer emits it; `globalId` is now the stored property
  itself (public get, setter internal to the model's module). Migration is a
  mechanical rename `.__globalId` → `.globalId` in reads and query key
  paths; to seed a specific `globalId` on insert use
  `add(_:preservingGlobalId:)`. Also removed: the macro-emitted
  `__GlobalIdName`/`__GlobalIdKey` helper structs and the orphaned public
  `StaticString`/`StaticInt32` protocols (Lattice's `StaticString` shadowed
  `Swift.StaticString` in any file importing Lattice).
- **`List`'s `Codable` conformance** — its `init(from:)` was an
  unconditional `fatalError()` stub, so decoding any model graph containing
  a `List` terminated the process, and the working encode half had no
  callers. Serialize via `@Detached` (lists mirror as plain arrays with
  their own synthesized `Codable`); a `@Codable` model with a `List`
  property is now a compile-time error — mark it `@CodableIgnored` or detach
  first.
- **Dead symbols**: the public no-op `enum Deprecated`, the duplicate
  `typealias CxxManagedLatticeObject` (use `CxxManagedModel`), the
  long-commented-out `LatticeExampleServer` executable target, and the
  orphaned `fluent`/`fluent-sqlite-driver` package dependencies.
- **Twelve underscored support symbols are no longer `public`** — they were
  not referenced by macro expansions and had zero external users
  (`Query._constructForTesting`/`_constructPredicate`/`_unionSubquery`/
  `_caseWhen`/`_unionAccessTracker`/`_unionOverrides`, `Lattice._isolation`,
  `Model._registerIfNeeded`, `_ModelStorage`, `_defaultCxxLatticeObject`,
  `_pushDefaultToStorage`; `_UncheckedSendable` moves behind
  `@_spi(LatticeInternals)`). Macro-referenced underscored plumbing stays
  public and is exempt from semver — consumers must not call it directly.
  The full audit is in `docs/spi-audit-1.0.md`; the policy is in
  `VERSIONING.md`.

### Fixed
- **Read-your-writes inside explicit transactions on file stores**: inside
  `lattice.transaction { … }` on a file-backed store, collection reads
  (`objects()` snapshots, counts, indexed access and iteration),
  `Lattice.count`, and `object(primaryKey:)` now see the transaction's own
  uncommitted writes — previously they served the pre-transaction state
  because they routed through read/keeper connections that cannot observe
  the writer connection's open transaction (managed-property reads were
  always correct). In-transaction reads now execute on the writer
  connection, never mint read generations, and never publish into the shape
  caches, so a rollback leaves no trace of the discarded writes. Memory
  stores already behaved correctly; the cross-SDK conformance scenario
  `transactions/own-writes-visible-inside` now passes.
- **Bulk-update notification coalescing**: cross-instance notifications are
  coalesced per (instance, property) and delivered by a single drain task in
  commit order, fixing a multi-minute UI hang under bulk writes (issue #4).
  Also released separately as 0.10.12.
- `syncProgressStream` no longer crashes the process if its background query
  database fails to open (cross-process path) — it logs and finishes the
  stream. Its non-sync-agent path now rides the cross-process idle hint
  instead of opening a second database handle and AuditLog observer — one
  fewer failure mode, same yields.
- `Configuration.init` no longer traps when no documents directory exists
  (headless Linux daemons, some sandboxed utility processes): the default
  database location falls back to the current working directory with a
  warning log.

## [0.10.8] - 2026-07-10

(0.10.7 was tagged but never published — its release gate hung on a relay
frame-drop race this version fixes; rolled forward per policy.)

### Fixed
- **Relay connect-window frame drop**: LatticeServerKit registered its
  frame handlers only after the per-user lattice open plus an event-loop
  hop; WebSocketKit silently drops frames with no handler registered, so a
  client that uploaded within that window lost the frame and its entries
  sat unACKed until resend/reconnect. Handlers now go live synchronously
  first; frames arriving during the open buffer in order and replay when
  the lattice is ready. `test_NIORelayCatchUp` (quarantined for exactly
  this) is re-enabled.
- **Linux**: first green Linux test suite since 0.9.x — an interop
  segfault feeding a returned `std.vector` temporary straight into
  `Data.init(Sequence)` (production read path for Data/Vector fields), the
  Linux geo shim ported across two refactors it slept through, an
  unguarded Combine import, and a strict-concurrency capture.
- CI reliability: hang-catcher time limits sized for 25x-slower runners;
  the cooperative-pool-starvation tests (semaphore-blocking observer
  orchestration) and the D1b/D2 relay set are gated off macOS CI
  specifically — full coverage remains locally and on Linux CI, where
  hangs surface as interruptible failures; a 20-minute watchdog samples
  the test process so any future hang leaves stacks in the job log.
- CI: containers to swift:6.3-noble (6.2 refused the 6.3 manifest at parse
  time); 30-minute job timeouts so a hang fails fast instead of zombieing.

## [0.10.7] - 2026-07-10

### Added
- **Materialized reads API**: opt-in row-cache reads for read-heavy code paths. A live model handle issues one `SELECT` per property read (right for observation, catastrophic for bulk formatting); a materialized model serves reads from the row snapshot its originating query already hydrated — zero further SQL — falling through to the live path on any miss (slower, never wrong). Writes remain write-through.
  - `Model.materialize()` / `dematerialize()` / `isMaterialized` / `refreshMaterialized()`
  - `withMaterializedReads {}` / `withDetachSnapshot {}` scoped variants that restore the prior mode
  - `TableResults.materializedSnapshot()` — `snapshot()` with every element flipped to materialized reads
- **`Model.increment(_:by:)`**: atomic SQL-side field increment (`SET c = c + delta` under the write lock) — no read-modify-write race, and half the statements of `+= 1`
- **`Lattice.totalSQLStatementCount`** and **`Lattice.threadSQLStatementCount`**: statement-count primitives for statement-budget regression tests (thread-local twin for parallel in-process test suites)

### Changed
- **`@Detached`**: generated `detached()` routes through a snapshot — an explicitly materialized object detaches with zero SQL statements; a live object refreshes once (refresh-by-default preserved for existing callers) instead of paying one statement per field
- LatticeCore minimum version bumped to 0.10.4 (row-cache support floor)
- In-memory test configurations migrated to temp-file databases
- Five pre-existing failing/hanging tests quarantined with owner annotations (3 relay delivery hangs, 2 cross-instance observation failures) — tracked for 1.0

### Fixed
- **`@Union` compile break for class-payload unions** (present since 0.10.0): the macro emitted `Codable`/`Sendable`/`DetachableLeaf` unconditionally, so unions with model-class payloads (e.g. `case article(Article?)`) failed to compile ("associated value contains non-Sendable type"). The leaf conformances are now emitted only when every payload is a known value-leaf type (String, Int family, Double, Float, Bool, Date, UUID, Data — optionals included) or the author explicitly declares `Codable & Sendable` on the enum. Value-payload unions keep zero-boilerplate `@Detached` support; class-payload unions get `LatticeUnion` + `Equatable` and compile again

## [0.10.6] - 2026-07-05

### Fixed
- **Linux relay crash**: replaced C++ container protocol-conformance operations with index-based loops in the sync data path

## [0.10.5] - 2026-07-04

### Fixed
- **WSS transport**: stale-session URLSession delegate events are now ignored, preventing a dead connection's callbacks from corrupting the state of its replacement

## [0.10.4] - 2026-07-04

### Fixed
- **WSS transport**: each connect attempt uses a fresh ephemeral `URLSession`, so a poisoned session can no longer break every subsequent reconnect

## [0.10.3] - 2026-07-04

### Fixed
- **Sync relay**: one `Lattice` instance per connection — concurrent upload bursts previously segfaulted the server

## [0.10.2] - 2026-07-04

### Fixed
- **Linux build**: use `FileHandle.standardError` instead of `fputs(stderr)`

## [0.10.1] - 2026-07-04

### Added
- `pendingSyncEntryCount` — number of local changes not yet uploaded

### Fixed
- **Sync relay**: WS frame handlers registered before catch-up begins, closing a window where early client frames were dropped
- Sync tests no longer depend on leaked object lifetimes

## [0.10.0] - 2026-07-04

### Added
- **iOS 15 deployment floor**: minimum iOS version lowered from 16 to 15
  - Storage flipped to a pluggable boxed `any LatticeBackend`; backend selection centralized in `BackendFactory`
  - Parameterized-existential usage eliminated (witness dispatch, snapshot closures, concrete `TableResults` projections)
  - `os_unfair_lock` back-deployed below the `OSAllocatedUnfairLock` iOS 16 floor
  - Geo subsystem and `LatticeUnion` field accessors gated `@available(iOS 16.4, *)`
- **`@Union` macro**: sum types as model fields, with `switch`/`case let` query syntax and schema-evolution support
- **`@Detached` value-mirror macro**: generates a `Sendable` value-type mirror of a model plus `detached()`, with `DetachedResults` and a public memberwise initializer
- **Lattice MCP server** (`lattice-mcp`): dynamic schema-from-file API, generic query tool with per-call database routing, and `lattice_search` (FTS), `lattice_nearest` (vector), `lattice_geo` search tools
- **LatticePerf**: performance counters
- **IVF vector search**: public training API, reconcile and collection-map safety coverage
- Regression suites: close-guard (use-after-delete), observer/close races, cascade link cleanup, compound `@Unique` on link-kind fields, URL-change sync handover

### Changed
- **Cascade audits**: a single batched observer fire per WAL commit instead of one per cascaded row
- `AuditLog` uses hand-rolled `Codable` to lowercase wire UUIDs
- LatticeCore dependency resolved by version (`from: "0.10.0"`) instead of branch pin

### Fixed
- **LatticeServerKit**: WS frame handlers registered before any `await`, fixing dropped first-upload frames
- URL values were unquoted in SQL predicates
- Bare `@Unique` macro (no arguments) now works; unique-constraint auto-dedup fixed
- `.count` on `NearestResults` issues a count-only query and no longer materializes results
- `@LatticeQuery` rebinds when the lattice identity changes and no longer resurrects a deleted database
- `@Model` no longer shadows the `lattice` computed property
- Log file handling and `didSet`/`willSet` macro detection

## [0.9.1] - 2026-03-26

### Added
- `AnyProperty` decodes raw flat JSON values from SQLite audit-log triggers in addition to the typed `{"kind","value"}` format
- `_vacuumVec0` API and `setLogFile(URL)` convenience overload
- Combined geo + vector query tests

### Changed
- **`eventsAfter` is now lazy**: returns `TableResults<AuditLog>` for paginated access instead of loading all entries through the C++ bridge; `ServerSentEvent.auditLog` accepts any `Sequence<AuditLog>`, and LatticeServerKit paginates event catch-up in strides
- LatticeCore bumped to 0.9.1, swift-syntax to 603.0.0, swift-tools to 6.3

## [0.9.0] - 2026-03-16

### Added
- **Polymorphic relationships**: `VirtualList<any Protocol>` collections and `VirtualLink` (`(any Protocol)?`) single links backed by discriminated link tables, with the `@VirtualLinkProperty` macro
- **Observation infrastructure**: `ResultsChangePublisher` and `ObservableObject` conformance on `TableResults` and virtual results for SwiftUI reactivity; `List.observe()` and `VirtualList.observe()` for link-table mutation tracking; `observeLinkTable()`
- `globalId` public computed property (replaces `__globalId`, which remains as a deprecated shim); `object(globalId:)` is now public
- `add(any VirtualModel)` / `delete(any VirtualModel)` existential overloads
- IPC `socketPath` configuration for cross-platform sync
- `setLogFile()` API for file-based debug logging
- vec0 IPC sync and multi-connection lock-storm regression tests

### Changed
- Virtual results changed from struct to class for reference-semantic observation
- LatticeCore bumped to 0.9.0; NIO to 2.96.0 (Swift 6.2 Linux)

### Fixed
- Linux test compatibility (stderr concurrency safety, SQLite3 import)

## [0.8.8] - 2026-03-08

### Changed
- **LatticeServerKit**: `configureSyncRelay` takes a `storageURL: URL` instead of a `storagePath` string. The old API prepended `applicationSupportDirectory`, which on Linux resolves to an ephemeral overlay filesystem; a URL lets the caller target a persistent volume

### Fixed
- Cross-process tests hanging on CI: uncancellable `withCheckedContinuation` and polling patterns replaced with cancellation-aware `AsyncStream`

## [0.8.7] - 2026-03-07

### Fixed
- **Linux release builds**: worked around a swift-foundation type-metadata bug — `SortDescriptor` storage changed to an `(any SortComparator)?` existential so type metadata resolves at runtime via witness tables instead of failing at link time

## [0.8.6] - 2026-03-07

### Fixed
- **Linux**: link `FoundationInternationalization` explicitly — Swift 6.2 on Linux splits Foundation into sub-modules and `SortDescriptor.AllowedComparison` isn't auto-linked for downstream executables in release mode

## [0.8.5] - 2026-03-06

### Added
- Cross-process AuditLog UPDATE observer test: validates the passive sync-progress observer fires when a cross-process write only updates existing AuditLog rows

### Changed
- LatticeCore bumped to 0.8.5

## [0.8.4] - 2026-03-05

### Changed
- LatticeCore bumped to 0.8.4 (unlimited reconnect backoff — sync clients retry indefinitely instead of giving up)

## [0.8.3] - 2026-03-05

### Added
- `LatticeError.syncReceiveFailed`: `Lattice.receive()` checks the C++ `last_receive_error()` and throws instead of crashing the process — LatticeServerKit's catch block now fires on bad sync payloads

### Changed
- LatticeCore bumped to 0.8.3 (`last_receive_error` surface + deadlock fix)

## [0.8.2] - 2026-03-05

### Changed
- LatticeCore bumped to 0.8.2 (fixes a migration lookup crash)

## [0.8.1] - 2026-03-05

### Fixed
- **AuditLog `globalId` dropped during the C++ → Swift → JSON round-trip**: `JSONEncoder` emitted `"globalId": null`, which the C++ parser treated as an empty string. On multi-batch sync (>1000 events) the dedup query matched all empty-globalId rows from batch 1, silently skipping every subsequent batch
- **Linux build**: `import os` moved inside the `#if canImport(SwiftUI)` guard
- Flaky stale-slot eviction test on Linux CI

## [0.8.0] - 2026-03-04

### Added
- **Replication slots**: slot-aware `compactHistory()` (safe — respects unsynced peers) and `forceCompactHistory()` (nuclear), with stale-slot eviction
- **Sync observability**: `onSyncError()` and `onSyncStateChange()` callbacks
- **Cross-process sync progress**: passive AuditLog observation drives `onSyncProgress` when the process is not the sync agent
- `.distinct(by:)` on `TableResults`, `NearestResults`, and virtual results
- `@LatticeQuery` debounced fetch to coalesce rapid observer fires, and a fetchLimit-only initializer

### Changed
- LatticeCore bumped to 0.8.1

### Fixed
- `ModelInstanceRegistry` deadlock: the registry no longer holds its lock while accessing weak references, preventing a recursive deregister deadlock on deinit

## [0.7.0] - 2026-03-03

### Added
- **Sync Progress API**: Real-time upload/download progress tracking
  - `Lattice.SyncProgress` struct with `pendingUpload`, `totalUpload`, `acked`, `received`, `uploadFraction`, `isUploading`
  - `lattice.syncProgress` polling property
  - `lattice.onSyncProgress { progress in }` callback (fires on synchronizer background thread)
  - `lattice.syncProgressStream` — `AsyncStream<SyncProgress>` for async iteration
  - `lattice.syncProgressPublisher` — Combine `AnyPublisher<SyncProgress, Never>` (macOS/iOS)
- **Subquery Filtering with Predicate**: `Query.in(_:where:)` for filtered subqueries
  - `$0.field.in(\.otherField, where: { $0.condition == true })` generates `IN (SELECT col FROM table WHERE ...)`
- **Log Level Control**: `Lattice.setLogLevel(.debug)` to control C++ log output
- **`@LatticeEnum` default value**: Macro now generates `static var defaultValue` (first case), enabling graceful handling of unknown raw values during schema evolution
- IPC reconnection, multi-channel, filtered sync, blob round-trip, subquery-filtered link, cloud relay, and reverse cloud relay tests
- Sync progress tests (upload tracking, download tracking, ACK tracking, callback, owned-DB background thread)
- `Results.subquery` filtered links test
- Enum auto-migration test for unknown raw value deserialization

### Changed
- **LatticeServerKit simplified**: Removed built-in OAuth/JWT auth layer (`AuthController`, `OAuthAccount`, `JWKSFetcher`, `Token`, `User`). Server kit now provides sync relay only — auth is the application's responsibility.
- **`AuditLog` visibility**: Properties (`tableName`, `rowId`, `globalRowId`, `changedFields`, `changedFieldsNames`, `timestamp`, `isFromRemote`, `isSynchronized`) changed from `package`/`internal` to `public package(set)` for read access outside the module
- **`changeStream` performance**: Reuses a single query `Lattice` instance instead of creating one per AuditLog notification. Previous behavior ran `ensure_tables()` (WAL write lock) on every notification, causing `SQLITE_BUSY` under load.
- **WebSocket message size**: `maximumMessageSize` increased to 128 MB (from default 1 MB) to handle large sync batches
- **Enum deserialization**: Returns `defaultValue` instead of `fatalError` for unknown raw values
- LatticeCore dependency bumped to 0.7.0
- JWT dependency bumped to 5.0.0
- Added `fluent-sqlite-driver` dependency for `LatticeExampleServer`
- Added `LatticeExampleServer` executable target
- IPC sync tests: removed all `Task.sleep` calls (16 tests), replaced with deterministic `waitForChange` helper pattern
- Cross-platform test compatibility: replaced Darwin-only `OSAllocatedUnfairLock` with `NIOLockedValueBox`

### Fixed
- **IPC tests hanging in parallel**: `test_IPCSync_BlobColumnRoundTrip` and other tests hung when run in parallel due to race conditions from `Task.sleep`-based synchronization. Replaced all sleeps with `waitForChange` continuations.
- **IPC probe misidentifying live server**: Fixed in LatticeCore 0.7.0 — the root cause of `test_IPCSync_DeletedRowSkippedOnCatchup` hanging
- **MultipleChannels test flake**: Sequential `source.add()` calls triggered separate upload batches; `waitForChange` only caught the first. Fixed by adding notes sequentially with separate `waitForChange` calls per insert.
- **Linux build failure**: `OSAllocatedUnfairLock` (Darwin-only) replaced with `NIOLockedValueBox` from SwiftNIO (already a transitive dependency via Vapor)

## [0.6.0] - 2026-02-28

### Added
- **IPC Sync**: Cross-process database synchronization via Unix domain sockets
  - `IPCSyncTarget` configuration with `.server`/`.client` roles
  - Channel-based naming with auto-derived platform-specific socket paths
  - Bidirectional sync — changes flow both directions
  - Composable with WSS for cloud relay (`source →IPC→ target →WSS→ server`)
- **Filtered Sync**: Per-table upload filtering with predicate support
  - `SyncFilter` with `.include(Model.self, where:)` API
  - Only matching rows uploaded; incoming remote changes always applied
- **Per-Synchronizer Sync State**: Independent sync tracking per transport
  - `_lattice_sync_state` table tracks sync status per `sync_id`
  - Enables automatic cloud relay without loop prevention logic
- IPC + WSS integration tests including full Engram architecture end-to-end test
- Linux compatibility fixes for test suite

### Changed
- `websocket_client` renamed to `sync_transport` (C++ interface)
- LatticeCore minimum version bumped to 0.6.0

## [0.5.1] - 2026-02-27

### Added
- `preservingGlobalId` API for object insertion
- Profile picture support
- Migration moved into `Configuration` struct
- Attach tests and cache eviction regression test

## [0.5.0] - 2026-02-26

### Added
- `@Indexed` attribute for non-unique column indexes
