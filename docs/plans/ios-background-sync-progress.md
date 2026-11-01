# iOS background sync progress

## Active goal

Started November 1, 2026. Implement and release the [config-first integration](ios-background-sync.md), verify publication, then notify `engram-integration-hardening`, Orbital, and HUD. No direct or indirect shock-trooper contact. Earlier recovery work remains archived.

## Source and work locations

- SDK baseline: `751950358f49b934dfa8af1dcfd493b683cd9d0a` (2.5.0).
- Core baseline: `6afbe41b6ea4de63b27bb40e042ad9e455ba72ed` (2.4.2).
- SDK: `/Users/jason/localdev/lattice-sync-handoff-bgtasks-20261101`.
- Core: `/Users/jason/localdev/lattice-core-background-sync-20261101`.
- Evidence: `/Users/jason/localdev/lattice-bg-sync-evidence-20261101`.
- Xcode 27.1 / Apple Swift 6.4. Explicitly configured outputs stay under `~/localdev`.

## Milestones

- [x] User approved config-first API, implementation, release, and consumer notifications.
- [x] Refreshed baselines and isolated Core work from existing changes.
- [ ] Finite completion and compatibility probe.
- [ ] Teardown/resumption and contention probe.
- [x] Actor-safe API and registration compiler probe (not production scheduler qualification).
- [ ] Core/server/SDK integration.
- [ ] Lifecycle, lifetime, and host qualification.
- [ ] CI, release, and artifact verification.
- [ ] Engram, Orbital, and HUD notification receipts.

## Current checkpoint

Initial evidence is saved in [checkpoint 001](evidence/ios-background-sync-001/README.md). No background-sync implementation is released. The config-first direction replaces the earlier public controller/session proposal.

- Native baseline built successfully; all three suspension characterizations passed (52ms test execution). Disconnect alone retains work/ownership; destructor settlement cancels queued apply without ACK/cursor progress and preserves the parent store; close releases the independent flock.
- iOS 15 device/simulator object compilation passed with Swift 6 strict concurrency. A macOS runtime probe verified 2,000 calls on two owning actors plus weak-binding lifetime. This is not physical-device task execution.
- SQLite interrupt did not shorten a busy wait (1,993ms after interruption against a 2,000ms budget). A scoped cancellation mechanism probe settled in 7ms and preserved a same-connection unrelated writer; native integration is in progress.
- Filtered-window regression: the ordinary UPDATE control passed, while leaving/reentering a filter lost a synthetic transition and left the peer stale through reconnect. The failing receipts are retained. Capacity admission and lost-ACK durability are being corrected before finite sync can rely on the path.
- The policy value/Configuration option is implemented with 17 standalone validation cases. Scheduling/binding is not wired yet. The server's opt-in initial-replay marker is implemented; shipping-relay tests and the SDK build are in progress.
- Finite completion is now specified as a fixed starting upload horizon plus a negotiated initial-replay marker and settled cleanup. Core operation integration and end-to-end qualification remain outstanding; a zero in-flight window is insufficient.
