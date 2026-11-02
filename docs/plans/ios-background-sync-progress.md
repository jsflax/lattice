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
- [x] Finite completion and compatibility probe (native plus negotiated relay tests).
- [x] Teardown/resumption and contention probe (173 native tests; review follow-up pending).
- [x] Actor-safe API and registration compiler probe (not production scheduler qualification).
- [x] Core/server/SDK integration (87 selected SDK tests passed).
- [ ] Lifecycle, lifetime, and host qualification.
- [ ] CI, release, and artifact verification.
- [ ] Engram, Orbital, and HUD notification receipts.

## Current checkpoint

Initial probes are in [checkpoint 001](evidence/ios-background-sync-001/README.md), the outbox/relay slice in [checkpoint 002](evidence/ios-background-sync-002/README.md), and current integration qualification in [checkpoint 003](evidence/ios-background-sync-003/README.md). **No background-sync implementation is released.**

- Native finite sync and managed suspension/resumption are implemented. All 185 affected native tests passed at `aa4407c`; a test-only retention follow-up then passed all 24 lifecycle cases, bringing distinct native coverage to 186. Core PR 77 passed final branch CI and is merged at `62fc557`; main/release CI and publication remain. The full Swift bridge consumption probe also passed.
- SDK config-first registration, lifecycle handling, weak actor binding, serialized manual/automatic work, `syncOnce`, and public docs are implemented. The first full selected SDK run passed 69 tests and exposed a UUID-ACK timing bug now fixed in Core. Copied-handle lifecycle integration is complete; the updated selected suite passed 87 tests, including native cross-actor checks. The seven-row upload case dropped from 10.049s to 0.359s in individual local runs.
- The lab phone is connected; the private host, UI tests, and disposable relay are prepared, and Xcode resolved both candidate local packages. The disposable relay is built/running and the Xcode phone build is underway. Installation, actual iOS lifecycle/task execution, and natural delivery have not yet been qualified.
- Intended releases are Core 2.5.0 and SDK 2.6.0. The temporary Core edit override must be removed and replaced by the published version before SDK release.
- SDK local tests use SwiftPM's native backend because default SwiftBuild failed dependency scanning in the existing test graph. Full release CI, phone host build, published artifact verification, and consumer notices remain outstanding.
