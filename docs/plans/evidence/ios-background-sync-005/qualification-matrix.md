# Background sync qualification matrix

November 1, 2026. “Verified” means the bounded case in that row, not every related lifecycle or network scenario. Physical-device calls were driven through the lab host and debugger; XCTest test bodies have not run.

| Area | Status | Evidence and boundary |
| --- | --- | --- |
| Native finite sync, outbox, cancellation, managed lifecycle | Verified selected suites | 186 distinct affected native cases across the checkpoint 003 runs; this is not full device coverage. |
| SDK/relay/actor integration | Final complete local suite passed | After failed CI and an intermediate two-issue fixture run: four XCTest cases and 840 Swift Testing cases in 126 suites pass, without exclusions. New exact-commit CI remains pending. |
| Binding worker starvation counterfactual | Verified controlled comparison | Same async fixtures and two-second deadlines: old detached worker's 18-test run fails with 2 issues; new dispatch worker passes all 18 under strict cooperative scheduling. Stub-enclosed probe, not a replacement for the full SDK suite. |
| Final actual-SDK strict regression | Verified | Two serial ordering XCTest cases plus 16 Swift Testing cases pass with one cooperative worker; original deadlines/native timeouts retained. Added after full tests in macOS CI. |
| Native C API ownership layouts | Verified on macOS | Same 37 cases under native and forced value layouts; checkpoint 004. No phone C API runtime claim. |
| iOS 15 managed/manual host build | Verified | Signed managed/manual builds, including corrected WAL probe, pass and install; checkpoint 004 and built manual plist in checkpoint 005. |
| Managed offline task | Verified failure path | Actual BGAppRefreshTask completes false; independent initialized WAL truncate succeeds. No successful relay communication. |
| Early expiration | Verified on original and corrected binaries | Final dispatch-worker build: actual false completion hit count remains 1 after WAL cleanup and callback reopen/snapshot of 25 rows. Late expiration remains open. |
| Lazy unbound delivery | Verified bounded path | Early registration with store closed; zero fixture files before/after; false completion hit count 1. App state inactive, not a cold-background proof. |
| Lazy later binding/rescheduling | Verified locally | Later open/write/snapshot of 25 rows; settled read confirms a future pending request. No delivery-time guarantee or successful sync. |
| Manual failure without BG declarations | Verified | Separate built plist has no task identifiers or background modes; unreachable relay throws after cleanup. |
| Manual cancellation | Verified pre-admission case | Cancellation-after-settlement event; no active-transfer cancellation claim. |
| Manual cleanup and durability | Verified locally | Qualified WAL checkpoint with frames 0/0, ordinary callback close/open/snapshot retaining 25 rows after failure/cancellation. |
| Managed durability/reopen | Verified locally | Fresh process and callback close/open preserve 25 rows; checkpoint 004. |
| Successful phone empty/upload/paged sync | Outstanding | Desktop shipping-relay coverage exists; phone network success awaits local-network permission and a reachable relay. |
| Late expiration during active work | Outstanding on phone | Native/SDK tests do not substitute for this physical-device path. |
| Actual system background entry and cleanup | Verified bounded path | System scene-background event, actual UIApplication state 2, and qualified independent WAL checkpoint with return code 0 and frames 0/0. |
| Foreground resumption/takeover, complete Home roundtrip, multiple scenes | Outstanding on phone | Background entry and prior callbacks do not establish these later transitions. |
| Protected-data transitions | Scheduler test passed; phone lock/unlock outstanding | New protected-data loss/availability scheduler test passes in full suite. No locked-phone behavior claimed. |
| Natural OS scheduling / true OS cold launch | Unqualified | Debug selectors and no-activate requests do not establish either. |
| Physical XCTest UI suite | Tooling failure before tests | Two automation-mode initialization timeouts, exit 65; zero product test bodies. No retry without a changed cause. |
| Core publication | Verified | Core 2.5.0 tag/source/release receipt digest match; checkpoint 005 release files. |
| SDK CI/publication | Local correction validated; fresh CI pending | Original PR 38 `ffebdbb` CI failed. Final local complete suite, actual-SDK strict regression, actionlint, and corrected iOS host build pass. Source update/final exact-commit CI/publication remain; SDK 2.6.0 not published. |
| Consumer adoption | Not sent | Engram, Orbital, HUD draft only. Coordinator sends after verified SDK publication; no shock-trooper contact. |
