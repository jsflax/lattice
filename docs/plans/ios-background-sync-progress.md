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

Initial probes are in [checkpoint 001](evidence/ios-background-sync-001/README.md), the outbox/relay slice in [checkpoint 002](evidence/ios-background-sync-002/README.md), SDK integration qualification in [checkpoint 003](evidence/ios-background-sync-003/README.md), and the iOS platform fix/build/first-launch evidence in [checkpoint 004](evidence/ios-background-sync-004/README.md). **Core 2.5.0 is published; the SDK integration is not yet released.**

- Native finite sync and managed suspension/resumption are implemented. All 185 affected native tests passed at `aa4407c`; a test-only retention follow-up then passed all 24 lifecycle cases, bringing distinct native coverage to 186. Core PR 77 passed final branch CI and is merged at `62fc557`. The full Swift bridge consumption probe also passed. The later platform fix and release status are recorded below.
- SDK config-first registration, lifecycle handling, weak actor binding, serialized manual/automatic work, `syncOnce`, and public docs are implemented. The first full selected SDK run passed 69 tests and exposed a UUID-ACK timing bug now fixed in Core. Copied-handle lifecycle integration is complete; the updated selected suite passed 87 tests, including native cross-actor checks. The seven-row upload case dropped from 10.049s to 0.359s in individual local runs.
- The first full iOS 15 host build found a platform bridge-layout mismatch. Core PR 78 (`8d0c86d`) makes iOS value-handle selection consistent and preserves C API ownership. The native C API suite passed 37 tests in 1.481s; a separate consistently rebuilt value-layout runtime passed the same 37 cases in 1.547s. The latter runs on macOS, not the phone. PR 78 is merged at `c3fcb7d`; all required CI is green for that exact main commit.
- The disposable relay is built/running, and Xcode resolved both candidate local packages. The signed iOS 15 managed and manual builds, including the corrected WAL probe, pass; both apps are installed, with manual runtime still pending. Exported managed events show a 25-row write, fresh-process persistence, and an ordinary callback close/open/snapshot retaining 25 rows. Offline and early-expiration debugger deliveries complete with `success=false`; the early-expiration task has one observed completion hit and a qualified independent WAL truncate checkpoint (mode `wal`, return 0, frames 0/0). The initial `-1/-1` probe remains unqualified. Two UI runner attempts timed out enabling automation (exit 65) before any product test body; no further retry until the cause changes. The local-network prompt awaits a response. Successful network background sync, remaining lifecycle/manual/lazy qualification, and natural delivery remain pending.
- [Core 2.5.0](https://github.com/jsflax/LatticeCore/releases/tag/2.5.0) is published by successful workflow [41373486648](https://github.com/jsflax/LatticeCore/actions/runs/41373486648). Its tag, source commit `c3fcb7dd24f75740b6559ec84fe0d5086f4569f1`, and downloaded release-receipt digest match. SDK 2.6.0 remains intended. The temporary Core edit override is removed; the manifest, complete lock, and verified source-binding record now use published Core 2.5.0. No other dependency pin changed.
- The later lazy-host debug delivery completed unsuccessfully while leaving the fixture directory empty. Opening the store afterward succeeded and wrote 25 rows; a settled pending-request read confirmed another refresh opportunity. This is developer-triggered delivery, not natural scheduling or an OS-initiated cold launch. Network success still awaits the phone's local-network permission.
- SDK local tests use SwiftPM's native backend because default SwiftBuild failed dependency scanning in the existing test graph. Full release CI, device runtime qualification, published artifact verification, and consumer notices remain outstanding.
