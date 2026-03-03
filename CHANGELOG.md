# Changelog

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
