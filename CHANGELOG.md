# Changelog

## [0.10.12]

### Fixed
- **Bulk row updates no longer hang the UI** (issue #4): cross-instance
  change notifications were dispatched as one unstructured `Task` per
  (property-change × live observer), so a routine bulk refresh piled tens of
  thousands of Tasks onto SwiftUI's process-global Observation lock —
  observed as a multi-minute freeze. Notifications are now coalesced per
  (instance, property) within a burst and delivered by a single drain task
  in commit order, hopping isolation once per run. A bulk write costs one
  drain task regardless of size. Also hardens the notify path against two
  Swift exclusivity violations the old dispatch masked (delivery from
  inside the commit hook; reading model storage on the notify path).
  Reported by Diana Perez Afanador.

## [0.10.9] - 2026-07-12

### Fixed
- **attach failure semantics under LatticeCore >= 0.10.5**: the core's
  exception-safe attach (bool + `last_attach_error()`) silently turned a
  schema-mismatch/alias-collision attach into a NO-OP for this release line
  (the historical behavior was a crash from the C++ exception; the bool
  result was ignored). `attach` now fails fast with the actual reason.
  LatticeCore floor raised to 0.10.8, which also delivers the URI-capable
  connections, path-exact detach, and attach SQL-escaping fixes to 0.10.x
  consumers.

## [Unreleased]

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
