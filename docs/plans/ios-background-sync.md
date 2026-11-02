# iOS background sync implementation plan

Released and verified, November 2, 2026. **Lattice 2.6.1 and Core 2.5.1 are published and verified. PR/main CI, release checks, and caller-guide verification pass. Engram integration hardening, Orbital, and HUD notices were accepted after verification; downstream adoption remains unverified.** The SDK release source is `248b1864f866134dc0f167f6adfd79eac4c8be61`. [Checkpoint 008](evidence/ios-background-sync-008/README.md) records closure; [checkpoint 007](evidence/ios-background-sync-007/README.md) preserves qualification, historical failures, and explicit device-coverage limits.

## Goal and finish line

Ship opt-in iOS background sync through `Lattice.Configuration`: bind to the configured store, hide registration and lifecycle observation, make finite durable sync progress, settle owned work on expiration, and resume the same usable database.

Publish and verify the Lattice release and matching Core release if required. Notify `engram-integration-hardening`, Orbital, and HUD with versions and upgrade instructions. No direct or indirect shock-trooper contact. The [archived recovery goal](sync-performance-recovery.md) remains separate; its unfinished candidate is not a dependency.

## Approved caller direction

Initial implementation merged at `d0ca27e4c1b98501dec4215f11403f281962691a`; all four PR CI legs passed on an identical tree. Main CI concluded success overall with required macOS/stable Linux/iOS passed and optional nightly failed. SDK tag 2.6.0 is immutable at that source. Required macOS job 125079754321 failed in release workflow 41383687634, so no SDK 2.6.0 GitHub Release was created. The [published caller guide](https://jsflax.github.io/lattice/documentation/lattice/backgroundsync/) was verified then for that main commit; the repository guide remains [Background Sync on iOS](../../Sources/Lattice/Lattice.docc/BackgroundSync.md).

```swift
let lattice = try Lattice(
    Note.self,
    configuration: .init(
        fileURL: storeURL,
        authorizationToken: token,
        wssEndpoint: syncURL,
        backgroundSync: .appRefresh(
            identifier: "com.example.app.sync",
            minimumInterval: 15 * 60
        )
    )
)
```

The policy defaults off and remains Sendable/Equatable/Hashable data. The session defaults to this store on its existing actor. The normal caller owns no controller, session object, or provider closure. Lattice handles registration, rescheduling, expiration, completion, public UIKit notifications, and its own cleanup; no scene forwarding or swizzling.

The independent `try await lattice.syncOnce(maximumDuration: 20)` API registers no task. `Lattice.SyncOnceResult` distinguishes `completed`, `budgetExhausted`, `alreadyRunning`, and `unavailable`; failures and cancellation throw after owned work settles. The shared command queue lets a foreground transition cancel and join an admitted manual pass before resuming. A timer limits work; it does not define success. Preserve existing app-owned progress/error subscription slots.

## Registration and store lifetime

Register permitted identifiers once per process before launch finishes. Normal Lattice initialization registers before opening storage. Lazy/protected stores use synchronous `Lattice.registerBackgroundTasks(configuration:)` during launch with no database I/O. A delivered task that remains unbound cannot infer a schema or open the store by itself; it reports unsuccessful completion and requests another opportunity. `defaultConfiguration` only stores a value; assignment does not register. Constructing or copying config performs no registration.

Process-lifetime registration and the current store binding are separate. Repeated facades of the same native store reuse the binding. An independent store cannot silently take an identifier. Close/logout/account replacement must settle old work and retire that binding before replacement. Reconnect uses the immutable original token today: resolving the same store again is not credential rotation.

Derived connections share an internal lifecycle lineage with the retained original owner. TSR resolution, borrowed `LatticeActor` contexts, stream readers, and attached query clones retain local managed lifecycle while dropping transport credentials and task policy. Foreground/suspension reaches each distinct native member; only the original owner runs finite network sync. New members start suspended and trigger revision-based reconciliation without expiring a valid task. Closing a member leaves its siblings intact; closing or losing the original owner retires the lineage and closes its derived connections. Weak alias cleanup must permit native address reuse without letting a stale reference adopt a new allocation/account. Finite budgeting includes actor admission and required cohort cleanup.

Declare the identifier in `BGTaskSchedulerPermittedIdentifiers` and enable `fetch` in `UIBackgroundModes`. Adding permitted identifiers disables legacy background fetch on iOS 13+; document migration and test the host integration. Do not also register SwiftUI `.backgroundTask` for the SDK-owned identifier. Multiple registered identifiers are allowed, but only one pending app-refresh request is permitted app-wide. A requested interval is an earliest-time hint, never a fixed schedule. [Registration](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)), [setup and legacy fetch](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app), [submission](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:)).

## First implementation checkpoints

1. **Finite work.** Probe empty, single-upload, multi-window, and paged-download cases. Define the starting upload horizon and initial download boundary. Current in-flight count is not the entire backlog. Compare a clearly labeled idle heuristic with a small negotiated completion marker. Strict legacy clients must not receive unknown messages; old servers must not yield false completion. A marker from an old foreground connection cannot certify a fresh pull.
2. **Reversible suspension.** Reuse synchronizer destruction: pacer stop, observer removal, transport invalidation, and worker shutdown already exist. Factor WSS-only teardown; all-channel teardown also dismantles IPC. Probe queued applies, cancellation, SQL contention, maintenance stop/restart, lock release without handoff, and same-store/Results resumption. Preserve durable edits/cursors/ACKs and app callbacks. Measure cleanup rather than inventing timing guarantees.
3. **Actor-safe integration.** Compile the config-first shape under Swift 6/iOS 15. Keep the facade on its owning actor; UIKit observation belongs on MainActor. Reuse existing actor-bound callbacks where possible. Exercise early/lazy registration, failing initialization, cold launch, protected data, duplicate binding, logout, credentials, and independent manual sync.
4. **Driver and hosts.** Implement only the Core/server/SDK changes demonstrated necessary. Add deterministic scheduler/lifecycle tests and SwiftUI/UIKit host examples. Use aggregate UIApplication state, no custom per-scene machinery without evidence. Test transient inactivity, protected-data notifications, expiration races, and foreground takeover.
5. **Qualification and release.** Run affected tests/builds and required CI; publish coherent versions, verify artifacts, and deliver the three adoption notices. Record physical-device and naturally scheduled execution coverage accurately.

## Cleanup and lifecycle contract

Keep latest desired state, one active attempt, and settlement of prior transitions. Generation checks prevent late callbacks affecting successors. Initial inactive is not foreground ownership; protected-data availability alone must not reconnect. Foreground takeover joins required cleanup and resumes foreground sync without a stale task disconnecting it.

Acquire a short UIKit execution assertion before foreground-to-background cleanup and end it once. An OS-delivered background task already supplies runtime. Install expiration handling before starting the Swift task; exactly one completion owner reports after settlement. [Execution assertion](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)), [completion](https://developer.apple.com/documentation/backgroundtasks/bgtask/settaskcompleted(success:)).

Retire open transactions where that releases locks; destroying every idle connection is unnecessary. Demand independent lock acquisition only after full suspension, not while a foreground successor owns sync. A flock source fact alone does not prove an iOS termination rule. Unrelated app writes and other processes remain outside the SDK's ownership.

Ordinary `syncOnce` without a managed policy cleans up its private session and restores the parent store's prior maintenance state. It does not impose a new parent-reader latch; existing explicit `retireAllGenerations()` / `resumeGenerations()` contracts still apply to caller-managed suspension. Automatic policy requires an iOS host app, writable file store, endpoint, nonempty token, and no unmanaged IPC targets. `LatticeActor(for:configuration:)` is a temporary-context factory, so a retained store in the app's actor remains the background owner; a borrowed `LatticeActor(existingLattice)` does not register again.

Preserve earlier pending requests and distinguish registration from submission failures. Use a small availability shim for the iOS 27 submission API while retaining iOS 15. Begin with app refresh; processing/continued-processing modes are not prerequisites.

## Acceptance gates

| Gate | Evidence required |
| --- | --- |
| API | Config example compiles, actor store works, no public controller/session, manual work needs no registration. |
| Completion | Empty/multi-window/paged/old-server/continuous-write cases have truthful outcomes. |
| Data safety | Expiration during connect/upload/apply/ACK/contention preserves edits and never ACKs unapplied rows. |
| Lifetime | Same store/Results survive; close/logout/rebind cannot revive stale credentials or ownership. |
| Lifecycle | Cold launch, protected data, transient inactivity, multiple scenes, takeover, and exactly-once completion. |
| Compatibility | No stolen callbacks, unintended IPC teardown, duplicate registration, or unnegotiated legacy wire changes. |
| Resources | Measured contention cleanup and no owned work after full suspension. |
| Host/release | Real host coverage honestly recorded; required CI; clean versioned pins; changelog/migration docs; verified publication. |
| Adoption | Engram, Orbital, HUD receive exact versions and setup instructions; delivery receipts recorded. |

## Release record and remaining evidence

Between `edb48f3` and tagged main, the production Sources, package manifest, and lock are unchanged; those later changes isolate conformance/ordering tests without excluding them or extending their budgets. That historical comparison does not cover the subsequent native bootstrap correction. PR CI passed macOS, stable Linux, nightly, and iOS, including the supplemental strict cooperative-worker regression. Main CI run 41381739897 concluded success overall, but its optional nightly leg failed one two-second fake-backend refresh expectation. Source and subsequent postconditions are consistent with post-settlement budget exhaustion under load; this is an inference, because the returned enum and isolated refresh duration were not logged. Required main legs passed. Checkpoint 007 preserves this exception rather than claiming all main legs were green.

Physical evidence covers managed early expiration, actual system background entry, independent WAL cleanup, lazy unbound/later binding, and manual failure/pre-admission cancellation with durable 25-row reopen. After Local Network permission was accepted, foreground sync acknowledged 25 uploads, received 2,001 remote rows, and an ordinary callback read 2,026 rows including the 25 fixture rows. At that earlier stage, successful finite BGTask completion was unqualified: one debugger callback hit lacked its success BOOL and a second attempt had no observed hit. The extra debugger-owned UIKit assertion was ended and the managed app restored; that attempt added no post-network WAL checkpoint. The later candidate checks below qualify successful debugger-triggered BGTask completion and its independent post-completion WAL checkpoint. Expiration during active transfers, foreground takeover during active work, locked-phone behavior, natural scheduling, and true OS cold launch remain coverage gaps.

The native diagnostic reproduces the same WAL bootstrap lock failure in independently built Core 2.4.2 and Core 2.5.0; all initialized-file controls pass. The narrow candidate correction passes all 800 probe opens and 23 focused native tests. The SDK test-only diagnostic/isolation follow-up also passes full and strict local runs. These findings are preserved in [checkpoint 007](evidence/ios-background-sync-007/fresh-open-investigation.json); they do not prove the exact cause of the original opaque Swift CI error.

The reachable-relay public manual `syncOnce` phone pass now returns `.completed`, with acknowledged uploads, received rows, qualified independent WAL cleanup, and durable close/reopen. That pass uses the existing corrected binary and the managed plist in manual mode; that earlier pass does not qualify Apple BGTask completion, a successful network pass in the separate no-background-plist binary, or the native correction. A later candidate host built against Core `820f0ba` verifies public manual completion and actual debugger-triggered BGTask success while backgrounded, followed by independent WAL cleanup before foreground restore and durable reopen. The temporary host UIKit assertion is disclosed and ended. Natural scheduling, true cold launch, locked-phone behavior, active-transfer expiration, and foreground takeover during active work remain unqualified.

Core PR 79 passed all checks and merged as `d2241191c1a630e0aaf0d8a5a38b0520c9614c4c`, identical in tree to the tested candidate. Core exact-main/release CI passed, and Core 2.5.1 is published and verified. The SDK actual published pin is verified; an earlier optional desktop pass that instead used Core 2.5.0 is explicitly corrected in the evidence. The subsequent actual published-pin SDK full and strict suites pass, with separate frozen receipts. PR39 and exact-main CI have since passed all four legs. SDK 2.6.1 is tagged at the verified source, and all release jobs passed. **Completed:** SDK 2.6.1 publication and all 350 source files verified (30/30 checks); Engram, Orbital, and HUD notices accepted after verification. SDK tag 2.6.0 will not be retargeted. Core release/receipt, SDK source archive/local verification, and safe notice confirmations are recorded in checkpoint 008. The old SDK tag is not a publication receipt.
