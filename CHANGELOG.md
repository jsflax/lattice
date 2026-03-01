# Changelog

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
