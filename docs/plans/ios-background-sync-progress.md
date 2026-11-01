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

Initial probes are in [checkpoint 001](evidence/ios-background-sync-001/README.md). The completed correctness and relay slice is in [checkpoint 002](evidence/ios-background-sync-002/README.md). No background-sync implementation is released.

- Core `c6194c3`: all 137 affected native tests passed, including 19 filtered-delivery durability cases and 14 cancellation cases. A channel-private durable outbox now preserves synthetic transitions across full windows, lost ACKs, filter changes, restart, and source-history compaction. Pending outbox data requires a coherent Core upgrade; downgrade safety is not promised.
- Core `b9bffbc`: fixed a pre-existing observer-destruction hang caused by duplicated callback-depth state in SwiftBuild's aggregate library. The released baseline reproduced it; the fixed source passes both raw and aggregate package boundaries.
- SDK `860d043`: config policy, strict catch-up marker codec, and ordered negotiated server marker implemented; 13 focused tests passed, including the shipping relay's 2,001-record replay and legacy negotiation behavior.
- SQLite busy cancellation is supported on owned private connections and strict shared-writer scopes. These tests do not yet qualify complete sync expiration or long SQL. Actual native lifecycle integration remains in progress.
- Actor/extension compiler probes passed. A further weak-actor hop probe verifies that idle task registration need not retain the store actor. Production weak binding, early registration, finite API, and Apple lifecycle integration are in progress.
- Native finite-cycle receipt and fixed-horizon implementation now has deterministic tests prepared; coordinated execution remains pending integration.
- The lab iPhone 13 Pro is connected and available for later real-host checks. Device task execution and naturally scheduled delivery have not yet been tested.
- SDK tests required SwiftPM's native backend because default SwiftBuild failed dependency scanning in the existing test graph. Full release CI and published artifact verification remain outstanding.
