# Background sync checkpoint 005 — release pins and device follow-up

November 1, 2026. Core is published; SDK 2.6.0 is not yet published. This checkpoint adds bounded physical-device evidence to the [earlier build, expiration, and WAL results](../ios-background-sync-004/README.md).

## Release and CI

Core 2.5.0 is published and verified at `c3fcb7dd24f75740b6559ec84fe0d5086f4569f1`. The downloaded release receipt matches GitHub's asset digest; the source tag matches the receipt. The SDK manifest and complete SwiftPM lock now use that published version, with no other dependency pin changes and no Core edit override.

SDK [PR 38](https://github.com/jsflax/lattice/pull/38), commit `ffebdbb9697163966bb1e65699db68c165dd98c5`, **failed** [CI run 41374530832](https://github.com/jsflax/lattice/actions/runs/41374530832). The iOS build passed. The macOS, stable Linux, and nightly test runs reported **39, 37, and 39 issues**, respectively; these are issue counts, not counts of distinct failing tests. Their named failing cases are in `BackgroundSyncBindingTests`.

Full-suite load exposed starvation from blocking native work scheduled through detached Swift tasks, compounded by test observers blocking while awaiting native entry. The candidate correction moves native blocking work onto a dedicated concurrent utility dispatch queue and gives the tests asynchronous entry receipts, preserving their two-second deadlines. The production `Lattice` target compiled successfully in **58.97 seconds**. Compilation alone does not validate the full correction.

A strict cooperative-pool counterfactual now isolates the worker change. Both variants compile and use **identical updated asynchronous fixtures**, with only `BackgroundSyncBinding.swift` differing. Under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, the old detached worker's **18-test run fails with 2 issues in 4.058 seconds**: cancellation did not reach native work, and foreground startup preceded manual settlement. The dispatch worker passes **all 18 tests in 0.190 seconds**. The harness's two `true` results mean the old variant failed as expected and the new variant passed; they do not mean both variants passed.

This portable probe compiles actual policy/scheduler/binding code with an enclosing-Lattice stub. Its frozen 18-test evidence is retained unchanged; it does not replace actual SDK tests. [ci-validation-summary.json](ci-validation-summary.json) records CI failures, compile receipts, source hashes/snapshots, and the subsequent full SDK results below. [binding-counterfactual](binding-counterfactual) contains the archived harness and logs. That harness read the old implementation from HEAD at execution time (`ffebdbb`); use the frozen source hashes or explicitly pin that revision when reproducing it.

### Final complete-suite validation

The first full run after the dispatch correction built in **173.22 seconds**, then failed its **841-test / 126-suite Swift Testing phase with two issues in 73.959 seconds**. Both were the ordering fixtures' `didEnter` setup assertions: their asynchronous entry wait still competed with hundreds of parallel SQL tests. This intermediate failure is preserved, not replaced by the final result.

The two ordering cases now run in `BackgroundSyncBindingTestsOrdering`, a serial XCTest phase included in the **default complete suite** before Swift Testing. Their original two-second deadlines and native timeouts remain intact; no tests are excluded. A new protected-data scheduler regression was also added.

The final complete SDK run exits **0** after a **61.31-second build**:

- **XCTest: four cases passed** — both ordering cases (0.003s and 0.001s; 0.004s for their suite), plus two existing child-runner entry cases.
- **Swift Testing: 840 tests in 126 suites passed in 78.449 seconds**, with no issues. The binding suite took 13.851s under full parallel load; `protectedDataLossCancelsRefreshAndAvailabilityWaitsForForeground` passed in 11.785s.

A separate strict run of the **actual SDK** also exits **0** with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`: both ordering XCTest cases pass in 0.002s, followed by all **16 binding Swift Testing cases in 0.190s**. This supplements the unfiltered full run and is distinct from the historical portable 18-test comparison. macOS CI now runs this strict check after its unchanged complete test invocation; `actionlint` passes.

The final source has not yet been pushed to PR 38 at this checkpoint. **Fresh exact-commit CI remains a release gate. SDK 2.6.0 is not yet published.**

## Lazy registration and later binding

On the physical phone, early config-only registration returned with the store closed. The fixture directory contained **zero files before and after** a debugger-triggered delivery. The real `BGAppRefreshTask` completed with **`success=false` and one completion breakpoint hit**, through the SDK's unbound branch at `BackgroundTaskScheduler.swift:526`. No schema or database was invented to service the unbound task.

Opening the same lazy host afterward returned zero rows, then a write and snapshot recorded **25 rows**. A later pending-request read confirmed another refresh opportunity. The earlier empty pending list was read before the completion path settled; it was not evidence that rescheduling had failed. A pending request is not a promise of delivery.

Despite the launch request's `--no-activate` option, the observed application state was **inactive (1)**. This proves the tested lazy/unbound path in an already-running debug host, not background cold launch, natural scheduling, or successful network sync.

## Manual failure, cancellation, and cleanup

The separate manual app's built plist contains neither `BGTaskSchedulerPermittedIdentifiers` nor `UIBackgroundModes`; its minimum target is iOS 15. It opened the deferred store, wrote 25 local rows, and called public `syncOnce` against an unreachable loopback relay. The operation **threw `databaseError` after cleanup**. That is an error path, not a successful pass or the `unavailable` result case.

A separate cancellation requested before admission returned the host's cancellation-after-settlement event. This tests pre-admission cancellation, not interruption during an active upload/download. After those attempts, the independent checkpoint recorded **`qualified=true`, WAL mode, return code 0, and frame counts 0/0**. An ordinary callback then closed the store, reopened it, and read **all 25 rows** without a debugger exception interruption.

The managed lazy app was restored by a normal system launch with its 25 rows retained; no synthetic lifecycle notifications were used. The original local-network permission response remains pending. No successful phone network sync is claimed.

## Actual system background entry

A later system transition records `scene-background`, and the debugger reads **UIApplication state 2 (background)** with the store still open and 25 cached rows. After that transition, an independent checkpoint records **`qualified=true`, WAL mode, return code 0, and frame counts 0/0**. This adds real background-entry and WAL cleanup evidence to the earlier inactive-state lazy test. It does not establish successful network sync, foreground takeover, a complete Home/foreground roundtrip, natural BGTask delivery, or OS cold launch.

## Rebuilt dispatch-worker iOS binary

The managed iOS 15 host rebuilt successfully with the dispatch correction, was reinstalled, and reopened the existing **25-row fixture**. A new debugger-triggered early expiration reached the actual Apple completion callback with **`success=false` and one hit**. After the independent WAL probe qualified with return code 0 and frames 0/0, an ordinary callback closed, reopened, and snapshotted **25 rows**. A final breakpoint inspection still showed exactly one completion hit for that tested task.

The build log, installed build's launcher/debug dylib/plist, install/launch receipts, exported event log, and debugger transcript are frozen separately from the earlier host evidence. This validates the tested early-expiration/cleanup/reopen path on the corrected binary. The phone's permission prompt remains pending, so no successful network sync is claimed.

## Evidence and limits

[device-follow-up-summary.json](device-follow-up-summary.json) and [ci-validation-summary.json](ci-validation-summary.json) contain sanitized results and hashes of frozen raw receipts under `/Users/jason/localdev/lattice-bg-sync-evidence-20261101/checkpoint005-receipts`. Later transcript saves cannot change these snapshots. Raw device/network metadata and screenshots are not copied into the repository. The [qualification matrix](qualification-matrix.md) separates completed cases from outstanding coverage.

The two earlier XCTest attempts failed during runner initialization, before any product test body; no new retry is justified until that cause changes. Tooling limitations and interrupted debugger expressions are not classified as production Lattice bugs.

Successful physical-device network sync, active-work expiration, foreground resumption/takeover, locked-phone protected-data behavior, natural delivery, and true OS cold launch remain documented coverage limits. The new portable protected-data test is not a locked-phone test. Final exact-commit CI, SDK publication/artifact verification, and consumer notices remain required. Earlier checkpoints retain their time-specific qualification limits. The consumer upgrade draft remains unsent until the SDK release is verified; notices belong to the coordinator, and no direct or indirect shock-trooper contact is allowed.
