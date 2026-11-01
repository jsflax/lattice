# iOS background sync integration plan

Prepared November 1, 2026. **Proposed next goal; implementation has not started.** The [performance and recovery goal](sync-performance-recovery.md) remains paused and incomplete.

## Goal

Let an iOS app use BGTaskScheduler to make durable sync progress while it is in the background, stop safely on cancellation or expiration, and resume on the next opportunity without losing or acknowledging unapplied changes. Reuse Lattice's existing read-retirement, shutdown, deferred-connect, and sync-progress machinery. Add the smallest missing Core/Swift contracts needed to make completion truthful and testable.

For an app's user, the benefit is fresher data on reopening and less foreground catch-up. This is opportunistic refresh: it does not promise a fixed interval or continuous background WebSocket service.

## Existing support and the actual gap

Source baseline inspected: SDK [`751950358f49b934dfa8af1dcfd493b683cd9d0a`](https://github.com/jsflax/lattice/tree/751950358f49b934dfa8af1dcfd493b683cd9d0a), Core [`6afbe41b6ea4de63b27bb40e042ad9e455ba72ed`](https://github.com/jsflax/LatticeCore/tree/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed). These are fetched main revisions, not the paused recovery candidate. The SDK declares iOS 15 support; the integration should preserve that minimum and non-iOS builds.

**Database lock release is already supported and exposed to Swift.** The earlier suggestion that it might simply need exposing from Core was too broad. The distinction is between the existing mechanisms and a verified completion boundary for the entire background session.

| Existing capability | What it supplies | What remains to establish |
| --- | --- | --- |
| [`retireAllGenerations()` and `resumeGenerations()`](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L1696) | Retires retained reader generations, suppresses repinning in the existing coordinator, and supports lazy resumption. Already connected through the Swift backend/bridge to Core. | Settlement of active statements, writes, new/sibling owners, and deferred cleanup before suspension. Retirement alone is not whole-session quiescence. |
| [`close()`](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L1669) | Evicts generation caches and tears down storage/sync ownership. | Overall deadline/cancellation behavior and actual lock release. A sibling may inherit sync ownership; closing one facade is not necessarily process-wide shutdown. |
| `Configuration.syncStartup` and `connectSync()` | Opens a store with deferred network startup, then connects intentionally. | A background-session coordinator that owns admission, lifecycle, and completion. `disconnectSync()` explicitly does not establish a suspension boundary. |
| [Core `synchronizer_base::drain(deadline)`](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L1155) | Upload/ACK draining; close already shares a two-second drain budget. | Structured completion, cancellation propagation, and bounded underlying SQL/scheduler work. It returns `void` and is not exposed as a Swift background session. |
| `SyncProgress`, pending counts, ACK tracking, durable download cursor | Progress and resumability foundations. | A defined end-to-end completion watermark. Socket connection, zero pending uploads, or the per-ACK `on_sync_complete` callback does not prove remote catch-up. |

[Core database close is logical](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/db.cpp#L201); physical destruction can wait for remaining owners. Read retirement also has a bounded retry and deferred-cleanup fallback. Tests must therefore observe actual transaction/lock settlement, rather than infer it from a `void` API returning.

There is one concrete lifecycle discrepancy to resolve early: the public Swift docs promise automatic resumption on foreground/protected-data availability, but the inspected [`GenerationLifecycleObserver`](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Results/GenerationCoordinator.swift#L1452) registers only the two retirement notifications. Verify and fix the observer/doc mismatch with a regression test. Existing manual retire/resume tests are useful foundations, not evidence that the automatic path works.

No BackgroundTasks scheduler integration was found in the inspected SDK Sources, Examples, or Tests. This is a source audit; no new runtime qualification was performed for this plan.

## Platform strategy

Use **BGAppRefreshTask** for short incremental catch-up. Offer **BGProcessingTask** for larger backlogs, requesting network connectivity and making power policy explicit. An app owns task identifiers, Info.plist/background-mode configuration, and launch-time registration; the library provides the reusable sync-session adapter. Register each identifier once and early enough for launch delivery. [Apple strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app), [registration contract](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)).

Treat the requested interval as a freshness preference. `earliestBeginDate` is a lower bound, not a promised start time. Refresh runtime is limited, and expiration may occur before the nominal allowance. Resubmit according to policy, handle scheduler refusal/restriction, and keep foreground catch-up as the reliable fallback. [Scheduling semantics](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [expiration handling](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler).

BGContinuedProcessingTask is for work submitted from the foreground as a result of a person's action; it is not the periodic-sync mechanism. Silent pushes and background URLSession transfers are possible later triggers/transports, not requirements for this initial integration. [Continued-processing contract](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest).

## Session contract to design first

1. **Own a sync window.** Deduplicate overlapping refresh, processing, manual-sync, and foreground requests per store. Give each launch a session/configuration generation so late callbacks from an expired or replaced session cannot finish or re-arm its successor. Define how same-process handles share ownership and how extensions/IPC participate. Do not close an app's active shared handle unexpectedly or claim control over another process.
2. **Establish a meaningful target.** Capture a finite local upload boundary and, where the protocol supports it, a remote catch-up boundary. Confirm existing protocol capabilities before adding a barrier. Keep progress-only outcomes distinct if a remote boundary cannot be established; partial progress must never be presented as full catch-up.
3. **Do bounded work.** Carry cancellation and a monotonic deadline through connection setup, upload, apply, ACK waits, SQLite contention, and cleanup. Audit the existing drain/close joins and callback reentrancy before promising a bound. Cancellation may skip an optional drain, but must preserve durable replay state and ACK correctness.
4. **Prove suspension readiness.** Stop new session work, settle or cancel admitted work, retire readers, prevent racing repins, and confirm relevant writer/reader locks are gone. Keep logical close and physical resource settlement distinct. Reuse existing retirement/close mechanisms before inventing replacements.
5. **Return an honest outcome.** Distinguish completed-to-boundary, partial durable progress, expired/cancelled, unavailable credentials/protected data, and failure. Define how each maps to `setTaskCompleted(success:)`; invoke completion exactly once, after cleanup. Expose enough diagnostics to explain partial progress without recording credentials or row contents.
6. **Resume predictably.** Preserve progress across process death and reopen, handle authentication refresh and protected-data transitions, and clear reader suppression on the appropriate foreground path. Avoid creating permanent unpinned behavior or resuming background keepers prematurely.

The API names and whether this is a separate Swift product are design decisions for the first milestone. Keep BackgroundTasks/UIKit dependencies out of Core and guard the adapter for supported Apple platforms.

## Milestones and acceptance

### 1 Verify and specify the existing contracts

- Trace retire/resume/close/drain from Swift to physical resources; document ownership, completion, and reentrancy.
- Add the automatic lifecycle regression and resolve the documented-resume mismatch.
- Specify the completion boundary and proposed public result. Reuse the existing server protocol where possible; identify a minimal protocol addition only if required.
- Decide a shared-store ownership policy and a cancellation path that does not rely on unbounded `close()` execution in an expiration handler.

### 2 Implement a scheduler-independent bounded sync session

- Add only the missing Core/bridge/Swift result and cancellation hooks demonstrated by milestone 1.
- Cover expiration before connect, during upload/apply/ACK, SQL contention, offline operation, auth failure, protected-data loss, sibling-owner handoff, and reopen after termination.
- Preserve existing foreground sync, deferred startup, read caches, and supported platform behavior.

### 3 Add the app-owned BGTaskScheduler adapter

- Provide opt-in registration/submission, refresh/processing handlers, rescheduling, overlap coalescing, and exactly-once task completion.
- Supply a small iOS host example with required identifiers/background modes and foreground/manual fallback. Include integration guidance for UIKit/SwiftUI and app-group stores.
- Report requested versus actual launch, progress, outcome, cleanup duration, and retry eligibility. Do not describe OS scheduling delays as Core sync failures.

### 4 Qualify and release

Use these initial engineering targets as the new goal's measurable acceptance criteria:

| Measure | Acceptance target |
| --- | --- |
| Data correctness | Zero lost durable edits, duplicate visible applications, or ACK/cursor advances past unapplied work across the failure matrix. |
| Lifecycle repetition | At least 100 controlled background-session/expiration/resume cycles with exactly one completion per issued task, no overlapping owner, and no owned DB work after successful cleanup. |
| Expiration cleanup | In the defined controlled device workload, cancellation-to-quiescence p95 at most 1 second and every observed case at most 2 seconds. Report failures; do not widen targets after seeing results without revisiting the design. |
| Actual lock release | An independent process can acquire the expected write access and complete a TRUNCATE/RESTART WAL checkpoint after cleanup, checking SQLite return/busy results and the expected WAL state. Exercise retained Results, active reads/writes, and sibling handles. A writer succeeding or a PASSIVE checkpoint alone does not prove retained reader locks are gone; distinguish unrelated owners from this session's locks. |
| Short refresh work | Start with a configurable 20-second work deadline and stop early enough for cleanup; handle immediate OS expiration at every stage. This is an app budget, not a guaranteed iOS runtime allocation. |
| Real iOS behavior | Demonstrate launch, expiry handling, foreground return, and reopen on a physical device. Record at least one naturally OS-scheduled launch separately from simulated/debug launches. No promised cadence or maximum wait. |
| Compatibility | Existing applicable Core/Swift suites and supported builds pass; changes to bridge contracts raise the SDK dependency floor coherently. |

Record device/OS, store size, batch sizes, network conditions, samples, and exact test populations before measuring. Use deterministic scheduler/clock tests for races and real SQLite processes for lock assertions; simulated BGTask launches alone cannot establish actual scheduling behavior. A device or naturally scheduled launch that is unavailable stays an open acceptance item.

Publish only after the agreed gates pass, with release notes separating scheduling opportunity, progress, and completion guarantees. Notify Engram and Orbital when relevant; never contact shock trooper directly or indirectly. No deployment or release is part of preparing this plan.

## Scope boundaries

This goal does not inherit the old eight-writer 50% latency target, complete its automatic-recovery redesign, or import its unqualified source bundle wholesale. If a shared lifetime bug blocks safe background sync, isolate the smallest fix and qualify it on current main. Fixed background intervals, always-on sockets, a general storage broker, and a new conflict-resolution model are outside this goal.

The existing goal remains paused. This document defines the next objective and acceptance criteria; it does not mark the old goal complete or claim that a new active goal has already been created.
