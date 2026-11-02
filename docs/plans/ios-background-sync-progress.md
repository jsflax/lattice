# iOS background sync progress

## Current status

Candidate release record, November 1, 2026 local time (November 2 UTC). **Core 2.5.1 is published and verified. SDK 2.6.1 is not yet published; full and strict tests against its verified published Core pin pass, with candidate CI, publication, and notices pending.** SDK tag 2.6.0 remains immutable and unpublished after its required release job failed. Core PR/main/release checks and native/candidate phone qualification pass. This is a progress record, not a completion receipt.

The goal remains to publish and verify the config-first background-sync release, then notify `engram-integration-hardening`, Orbital, and HUD with coherent versions and upgrade instructions. No direct or indirect shock-trooper contact. The earlier recovery goal remains separate.

## Milestones

- [x] User-approved config-first API and implementation.
- [x] Finite completion, durable outbox, actor binding, suspension/resumption, and caller documentation.
- [x] Published and verified Core 2.5.0, followed by the Core 2.5.1 bootstrap correction.
- [x] Complete local suite and strict cooperative-worker regression.
- [x] All four PR CI legs passed on the identical tree merged to main.
- [x] Published caller guide verified for exact main source.
- [x] Recorded physical-device evidence and its explicit limits.
- [x] Exact-main CI receipt: overall success, with optional nightly failure recorded explicitly.
- [x] SDK 2.6.0 tag pushed at qualified main source.
- [x] Reproduced the native WAL bootstrap race in old/current Core; focused candidate tests and all 800 probe opens pass.
- [x] Core correction merged after all PR checks passed; candidate phone manual sync and debugger-triggered BGTask success/settlement/reopen verified.
- [x] Core 2.5.1 exact-main/release CI, publication, and source/tag/archive/receipt verification.
- [x] SDK published Core 2.5.1 pin verified; all other dependency pins unchanged and no edit override.
- [x] Actual published Core 2.5.1 SDK full and strict test suites pass.
- [ ] Finish candidate CI; publish SDK 2.6.1 and verify artifacts.
- [ ] Safe Engram, Orbital, and HUD delivery receipts.

## Source and validation

[PR 38](https://github.com/jsflax/lattice/pull/38) merged at `2026-11-02T03:11:46Z` as `d0ca27e4c1b98501dec4215f11403f281962691a`. The tree exactly matches passing PR source `009edebcc146d185af2a898ea0c882ad02015a1d`. Production `Sources`, package manifest, and lock are unchanged between `edb48f3` and tagged main; those later changes isolate tests without extending budgets or excluding cases. This historical source comparison does not cover the subsequent native bootstrap correction.

[PR CI 41380305623](https://github.com/jsflax/lattice/actions/runs/41380305623) passed macOS, stable Linux, nightly, and iOS. macOS passed 12 XCTest cases and 832 Swift Testing cases in 125 suites; stable Linux passed 12 and 810/122; nightly passed 12 and 803/119, with its auxiliary runs recorded separately. The macOS strict pass covers 10 XCTest and 15 Swift Testing cases. Exact durations and frozen receipts are in [checkpoint 007](evidence/ios-background-sync-007/README.md); they are observations, not performance guarantees.

[Main CI 41381739897](https://github.com/jsflax/lattice/actions/runs/41381739897) concluded success overall. Required macOS, stable Linux, and iOS passed; optional nightly failed one two-second fake-backend refresh expectation (803 tests/119 suites, 99.261s). The later command and cleanup postconditions passed. Source/postcondition analysis is consistent with post-settlement budget exhaustion under parallel load, but the actual enum and isolated refresh duration were not logged. This is explicitly an inference, and not an all-legs-green or demonstrated network-failure claim. The [published caller guide](https://jsflax.github.io/lattice/documentation/lattice/backgroundsync/) remains verified from successful [docs workflow 41381739885](https://github.com/jsflax/lattice/actions/runs/41381739885) at exact main source.

The implementation provides opt-in `.appRefresh` configuration, early lazy registration, automatic public lifecycle observation, actor-owned store binding, finite `syncOnce` receipts, expiration settlement, and shared lifecycle for derived connections. It preserves app callbacks and distinguishes unconfirmed old-relay progress from completion. The earlier local seven-row upload observation changed from 10.049s to 0.359s after UUID ACK normalization; this remains a single-case observation.

## Device evidence and honest limits

Corrected managed and manual iOS 15 hosts demonstrate early expiration, actual system background entry, independent WAL cleanup, lazy unbound/later binding, manual failure/pre-admission cancellation, and durable 25-row reopen. The latest rebuilt binaries repeat cleanup/reopen evidence. A false completion during offline/expired work is not successful network sync.

The user accepted Local Network permission. Foreground network progress is verified: the corrected managed app connected at 03:45:14 UTC, acknowledged 25 uploads with zero pending, received 2,001 rows by 03:45:19, and an ordinary callback snapshotted 2,026 rows including 25 fixture rows at 03:47:52. Actual system background entry followed at 03:47:54, with cached application state 2; later foreground/active/connected events are also recorded.

The earlier debugger attempts did not qualify successful finite BGTask completion: one callback hit lacked its success BOOL, and a second attempt produced no observed completion hit. The later candidate run below supplies a successful debug-delivery receipt. A snapshot expression stalled until foreground. The temporary debugger-owned UIKit assertion was explicitly ended; the debugger detached/quit and the managed app was restored. That earlier attempt adds no post-network WAL checkpoint; later manual/candidate passes have independent receipts. Expiration during active transfer, foreground takeover during active work, locked-phone behavior, natural scheduling, and true OS cold launch remain unqualified. The portable protected-data test does not prove locked-phone behavior. UI automation failed before product test bodies; debugger-driven receipts are labeled explicitly.

A subsequent public manual `syncOnce` on the reachable relay returned `.completed` in 1.967s observed, with 25 uploads acknowledged and 2,026 received rows. An independent WAL checkpoint qualified at 0/0 frames, and ordinary callback close/open preserved 2,051 rows including 25 fixture rows. This used the existing Core 2.5.0 / corrected SDK managed binary in manual mode, with its declared background identifier unbound. It qualifies manual finite sync, not Apple BGTask success, the separate no-background-plist binary's network path, or the pending bootstrap candidate.

A freshly built candidate host against Core `820f0ba` repeats public manual success in 1.738s observed, with 25 ACKs, 2,051 received rows, WAL 0/0, and 2,076-row close/reopen. It then records a successful **debugger-triggered** `BGAppRefreshTask` while the app is in background state 2: the actual completion argument is true, both SDK completion frames show success, and the final selector hit count is one. Independent WAL cleanup qualifies after completion and before actual foreground/active return. Ordinary callback close/open again preserves 2,076 rows and 25 fixture rows.

The host used an additional temporary UIKit assertion for debugger setup and explicitly ended it. This verifies debug delivery and settlement, not natural scheduling, cold/locked launch, active-transfer expiration, or takeover during active work. The candidate manual pass still uses a managed plist with an unbound declared identifier. [The candidate phone receipt](evidence/ios-background-sync-007/phone-candidate-success.json) preserves exact scope and source/build hashes.

## Remaining release records

[Core 2.5.1](https://github.com/jsflax/LatticeCore/releases/tag/2.5.1) is now published with matching source, tag, workflow, archive, and receipt verification. The earlier Core 2.5.0 release remains historical evidence. **SDK tag 2.6.0 is immutable at `d0ca27e4c1b98501dec4215f11403f281962691a`.** Required [release macOS job 125079754321](https://github.com/jsflax/lattice/actions/runs/41383687634/job/125079754321) failed: 12 XCTest cases passed (8.404s), but 832 Swift Testing cases/125 suites reported one issue (92.388s). `pushAndCatchupComposeExactlyOnceAcrossRedial` caught an opaque native `lattice::cxx_error`; the exact cause is unproven. Other release legs were still running at the update; SDK 2.6.0 remains unpublished.

The native investigation reproduces the same fresh-file `PRAGMA journal_mode = WAL` lock failure in independently compiled Core 2.4.2 (24/200 raw and 12/200 store opens) and Core 2.5.0 (22/200 and 18/200). All initialized-file controls pass. This establishes an existing failure class in the same toolchain/SQLite environment; the opaque original Swift CI error still prevents exact attribution. The narrow bootstrap candidate passes all 800 probe opens and 23 focused native tests in 0.767s.

The test-only SDK diagnostic/isolation follow-up passes 14 XCTest cases in 5.830s plus 830 Swift Testing cases / 125 suites in 84.831s (build 125.22s). Strict testing passes 12 XCTest cases in 5.807s plus 13 Swift Testing cases in 0.110s. These passes precede the pending native pin and do not qualify the complete successor. Frozen receipts and limitations are in [checkpoint 007's investigation](evidence/ios-background-sync-007/fresh-open-investigation.json).

[Core PR 79](https://github.com/jsflax/LatticeCore/pull/79) passed all four checks and merged as `d2241191c1a630e0aaf0d8a5a38b0520c9614c4c`, with an identical tree to tested candidate `820f0ba`. Exact-main and release CI passed; Core 2.5.1 is published and verified, including 911 archived files and release-receipt SHA-256 `98387165dccb7ff40286c4e5713389d0bdc7dbe04542f09689e201ae757eccde`. The SDK manifest/actual checkout now use published Core 2.5.1, with 34 pins, other pins unchanged, and no edit override. The real new-pin full suite passes 14 XCTest cases in 6.225s (outer suite 6.228s), plus 830 Swift Testing cases / 125 suites in 72.437s after a 162.11s build. Strict testing passes 12 XCTest cases in 6.078s (outer suite 6.080s), plus 13 Swift Testing cases / one suite in 0.162s. Candidate CI, SDK 2.6.1 publication/artifact verification, and Engram/Orbital/HUD delivery remain pending in [checkpoint 007's status record](evidence/ios-background-sync-007/release-and-delivery-status.json). SDK tag 2.6.0 will not be retargeted. The coordinator owns release and notices. Do not mark the goal complete from this candidate record.

**Desktop provenance correction:** the optional `sdk-wal-core-integration-*` runs passed against Core 2.5.0, not the intended fix, because SwiftPM restored its published resolved state. Those passes do not qualify Core 2.5.1. The correction and verified actual new pin are retained in [checkpoint 007](evidence/ios-background-sync-007/source-and-pin-verification.json); the subsequent real new-pin full and strict passes have their own frozen receipts and rechecked pin/checkout hashes. Native and candidate-phone source proofs remain valid.

Earlier evidence remains intact: [001 probes](evidence/ios-background-sync-001/README.md), [002 outbox/relay](evidence/ios-background-sync-002/README.md), [003 integration](evidence/ios-background-sync-003/README.md), [004 iOS ABI/device](evidence/ios-background-sync-004/README.md), [005 dispatch correction](evidence/ios-background-sync-005/README.md), and [006 second CI failure/test isolation](evidence/ios-background-sync-006/README.md). The previously unlogged macOS result's cause is not retroactively claimed from later passing CI.
