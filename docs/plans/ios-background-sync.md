# iOS background sync integration plan

Revised November 1, 2026 after source review and API discussion. This is a **planning deliverable; the proposed API is not implemented**. The previous performance/recovery goal was cleared after its [unfinished handoff](sync-performance-recovery.md) was saved. Its recovery candidate is not a dependency of this feature.

## Goal and chosen approach

Provide an opt-in iOS background-refresh controller that periodically requests execution time, uses the app's existing Lattice store to make durable sync progress, and suspends its activity safely when the opportunity ends. Keep the caller API small. Reuse existing reader retirement, WSS ownership, teardown/setup, durable cursors, and ACK behavior.

The user wants the SDK to hide task registration code. The app still declares its permitted task identifier and Background Mode; Lattice handles the runtime registration, submission, rescheduling, expiration, and completion. A bounded sync attempt is sufficient for v1. It does not claim that every server change has arrived, nor that iOS will run at a fixed interval.

V1 targets **BGAppRefreshTask for one app-owned WSS store/controller**, on iOS 15 and later. Add processing-task policy only after this path works; it should reuse the same session engine. Arbitrary cross-process ownership coordination, IPC suspension, custom-actor UI adapters, a new server protocol, and the old automatic-recovery redesign are outside v1.

## Proposed public API

Expose this type from the existing `Lattice` product on iOS, with BackgroundTasks/UIKit imports guarded from other platforms. The first adapter is `@MainActor`, matching the common UI-owned store. Validate that the supplied Lattice was created on that actor rather than moving a non-Sendable facade across executors.

```swift
@available(iOSApplicationExtension, unavailable)
@MainActor
public final class LatticeBackgroundSync {
    public struct RefreshPolicy: Sendable {
        public init(
            identifier: String,
            minimumInterval: TimeInterval = 15 * 60,
            maxDuration: TimeInterval = 20
        )
    }

    public init(
        refresh: RefreshPolicy,
        lattice: @escaping @MainActor () async throws -> Lattice,
        onError: (@MainActor (any Error) -> Void)? = nil
    ) throws

    public func setForegroundActive(_ active: Bool)

    @discardableResult
    public func refresh(maxDuration: TimeInterval? = nil)
        async throws -> RefreshResult
}
```

This is a proposed declaration, not compiled API. The compiler check in milestone 1 must retain the iOS 15 minimum and Swift concurrency rules. An omitted manual duration uses the registered policy's budget. The adapter is app-only; existing Lattice support for extensions remains unchanged.

The initializer stores the provider and registers the launch handler **without opening the database**. The provider resolves the same app-owned store lazily, on foreground activation or task delivery. That permits a cold background launch to register even when protected data is unavailable, and avoids migrations/network startup before registration. An unresolved controller does not open a store just to suspend it. Use deferred WSS startup when creating the store for this controller. Measure cold-open/provider time too; defer unavailable protected stores or migration work that cannot fit the background opportunity rather than assuming constructor work is free or instantly cancellable.

`setForegroundActive` synchronously records the latest desired state, then a serial internal driver performs asynchronous transitions. Returning from this setter means the request was recorded, not that all locks have already been released. It avoids creating a separate untracked Task for each UI lifecycle event. Transition failures go to `onError` after state is stable; refresh failures also propagate to their caller. The callback must not run while an internal state lock is held.

`RefreshResult` should have a small outcome enum: `attempted`, or `deferred` with a reason such as foreground activity or another sync owner. `attempted` means the bounded operation ran and its owned cleanup completed, not full remote catch-up. A never-established connection, fatal transport/apply failure, or failed cleanup must not be relabeled as a successful attempt. Expiration and caller cancellation throw `CancellationError` only after owned cleanup is settled. Detailed progress counters are not required for v1.

`maxDuration` is a cooperative attempt budget, including a cleanup reserve selected after measurement. It is not a real-time return guarantee or a promise that iOS grants that much runtime. A request for zero, negative, or nonfinite duration/interval is rejected. The first implementation measures cancellation under contention before documenting a tighter latency promise.

## What the app writes

At early application initialization, create and retain one controller. `AppStore.openLattice()` below is the app's memoized accessor, not a fresh temporary database per task. This example assumes the AppStore holds a MainActor-created store with deferred WSS startup.

```swift
let store = AppStore()
let sync = try LatticeBackgroundSync(
    refresh: .init(
        identifier: "com.example.app.sync-refresh",
        minimumInterval: 15 * 60
    ),
    lattice: { try store.openLattice() },
    onError: { error in
        store.reportSyncError(error)
    }
)
```

For SwiftUI, construct this eagerly in the `App` initializer, retain it for the process lifetime, and forward the **App-level aggregate** scene phase. Do not delay registration until `onAppear`, a `.task` view modifier, or a lazy store accessor. Initialize the desired state from the current app lifecycle as well as observing changes.

```swift
// App-level scenePhase, not one window's view-level scenePhase.
.onChange(of: scenePhase) { phase in
    switch phase {
    case .active:
        sync.setForegroundActive(true)
    case .background:
        sync.setForegroundActive(false)
    case .inactive:
        break
    @unknown default:
        break
    }
}
```

UIKit uses the same controller: create it during launch before `didFinishLaunching` returns, and forward active/background transitions. No caller writes `BGTaskScheduler.register`, an expiration handler, resubmission code, or `setTaskCompleted`. The adapter owns that identifier exclusively: **do not also attach SwiftUI `.backgroundTask` or another framework's handler for it**. The app can invoke `try await sync.refresh()` manually when it needs the same bounded operation.

The app's target must contain:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.example.app.sync-refresh</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
```

Merge these entries into the target's existing configuration; Xcode may generate the plist from build settings. Enable Background Fetch in Background Modes for refresh. A future BGProcessingTask policy also needs the `processing` mode. These are build-time application requirements, not configuration a runtime package can create. [Permitted identifiers](https://developer.apple.com/documentation/bundleresources/information-property-list/bgtaskschedulerpermittedidentifiers), [registration](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)).

## Responsibilities inside the adapter

### Registration and scheduling

Register once, early, on every process launch, including background launches. Validate identifier syntax, the permitted identifier, required mode, and SDK-owned duplicate registrations before calling Apple. Reject a second conflicting SDK controller deterministically. Internal repeated setup by the same controller must not register twice. Pending requests do not reveal another library's registered handlers, so the SDK cannot guarantee detection of foreign duplicate registration.

Registration succeeds or throws synchronously. Submission happens asynchronously; failures are reported through `onError` and are not confused with registration success. Ensure an initial request exists, schedule the next opportunity when a task is delivered, and ensure pending work when the app backgrounds. Preserve an earlier pending request instead of repeatedly moving it later on every lifecycle event. Apple has an app-wide refresh-request limit, so one refresh identifier should own this app's refresh policy; do not submit one per store/window.

`minimumInterval` maps to the next request's `earliestBeginDate`. iOS may run later or not grant an opportunity. The policy uses one coalesced submission path, without tight retry loops. Handle disabled Background App Refresh, restricted scheduling, authentication/protected-data availability, and offline delivery as explicit outcomes. [Scheduling semantics](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [submission behavior](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:)).

Apple's current documentation introduces `submitTaskRequest(_:completionHandler:)` in iOS 27 and deprecates synchronous `submit(_:)` there. Use an availability-gated submission shim, with the legacy route for older supported systems. Run submission away from MainActor as instructed by the new API, passing immutable request data to that worker. Check the build SDK before choosing the exact Swift async spelling; do not drop iOS 15 support. [New submission API](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submittaskrequest(_:completionhandler:)).

### Task delivery and lifecycle

The handler installs expiration handling before starting work, retains a handle to the Swift Task, and handles expiration racing Task creation. Expiration requests cancellation; it does not immediately report completion while database work still runs. A single completion owner calls `setTaskCompleted` once after the refresh and its cleanup end. V1 maps a healthy `attempted` result to success without claiming global catch-up; deferred outcomes, cancellation, failed cleanup, and failed work map to failure. Cover that exact mapping in tests. The normal attempt may use its configured window without an idle heuristic or server-completion barrier; ending that window preserves unfinished durable work for a later opportunity. [Task completion](https://developer.apple.com/documentation/backgroundtasks/bgtask/settaskcompleted(success:)), [expiration](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler).

Keep only the necessary controller state: latest foreground intent, one current background attempt, transition generation, and any cleanup in flight. Reject or coalesce duplicate refresh calls without overlapping native owners; v1 can return a deferred/already-running outcome. Late callbacks carry the generation and cannot finish or disconnect a successor.

If foreground activity arrives during refresh, release the background attempt's ownership and keep or resume foreground sync. If cleanup already started, join it before reconnecting the same store. When no foreground or refresh owner remains, suspend. Never close the app's store as routine refresh cleanup. Direct app calls to connect/disconnect must not compete with this controller after lifecycle ownership is delegated.

A normal foreground-to-background transition needs its own short UIKit execution assertion to protect asynchronous cleanup; BGTaskScheduler is not a substitute for finishing work already in flight. Acquire that assertion before starting cleanup, handle refusal/expiration, and end it once. Do not create a second assertion just because an OS background task is already providing runtime. Never block MainActor waiting for native work that may call back onto MainActor. [UIKit execution assertion](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)).

## Smallest necessary Core and Swift changes

Existing reader release is real and already exposed. Open idle SQLite connections need not all be physically destroyed to release transaction locks. The missing operation is **reversible suspension of owned sync and maintenance activity** while the app's database remains usable.

The [source audit](ios-background-sync-source-audit.md) identifies concrete gaps in simply calling `disconnectSync()` plus `retireAllGenerations()`:

- Disconnect leaves the WSS ownership flock held and the pacer capable of database maintenance.
- Already queued remote applies can execute after disconnect returns.
- Optional audit maintenance and queued Swift generation-maintenance ticks need settlement.
- Default SQL busy waits can outlast a refresh cleanup opportunity.

Implement an internal async suspension/acknowledgment path by reusing the existing WSS teardown/setup and read-retirement machinery. Stop new sync work, settle or cancel admitted work without ACKing unapplied rows, release this owner's WSS lock without sibling handoff, settle its maintenance, and retire its reader keepers. Keep the main store identity alive. Resume through existing setup and durable cursors. A failed/unfinished cleanup must remain an error, not a successful suspension receipt.

Do not call all-channel `teardown_sync(false)` as though it were WSS-only: it also tears down IPC. V1 should validate unsupported IPC/independent same-process owner arrangements before starting, without silently changing them. Another process owning WSS is a deferred result, not a reason to invent a global broker. Same native-identity facades may share the single controller; independent owners require an explicit later design.

Fix and test the automatic foreground/protected-data resume mismatch. Protected data becoming available is not foreground activation: it must not clear suppression or reconnect while the controller still intends suspension. Gate resumption on current lifecycle ownership and test unlock notifications racing cleanup. Keep existing retirement behavior and test new coordinators/racing accesses during suppression. Do not implement refresh by consuming `syncProgressStream` or replacing public state/error handlers: those are app-owned single slots. Reuse internal state or add a private observation seam only when needed.

## Implementation sequence

1. **Validate the small contract.** Compile the proposed caller API under Swift 6/iOS 15, test lazy provider isolation, and write deterministic regressions for queued apply after disconnect, reader retirement/resume, and retained ownership lock. Measure cleanup under SQL contention. Choose a cleanup reserve from these results; do not carry forward the draft's arbitrary one-second target.
2. **Add reversible suspension.** Factor only the required WSS and maintenance pieces; bridge asynchronous completion without blocking the app actor. Preserve durable upload/replay and ACK rules. Test same-store reuse, no sibling handoff, and failure/cancellation paths before adding scheduling.
3. **Build the thin controller.** Implement the desired-state driver, generation checks, lazy store provider, typed outcomes, execution-assertion lifetime, and hidden BGTaskScheduler plumbing. Preserve existing app progress/error subscribers.
4. **Demonstrate the caller experience.** Add small SwiftUI and UIKit host examples, plist/capability instructions, clear registration errors, and a protected-data cold-launch case. Document minimum interval as a hint and the exclusive identifier/store ownership contract.
5. **Qualify and ship.** Run focused lifecycle tests and existing affected Core/Swift tests/builds. Exercise a real iOS host, distinguishing debug-injected launches from naturally scheduled execution. Release coherent SDK/Core versions only if Core changes require them, and report actual limitations. Engram/Orbital notices follow a release if relevant; no direct or indirect shock-trooper contact.

## Focused acceptance criteria

| Scenario | Required observation |
| --- | --- |
| App integration | Early registration without opening a protected store; valid plist works; invalid/missing configuration produces a useful error; no double registration from SDK setup. |
| Submission policy | Initial/next requests, earlier-pending preservation, app-wide request contention, and failure reporting behave deterministically under a scheduler fake. |
| Data safety | Expiration before connect, during upload/apply/ACK, and during contention loses no durable edits and never advances ACK/cursor state past unapplied changes. |
| Cancellation | Task-creation/expiration and expiration/completion races invoke completion exactly once, after owned cleanup. Measure elapsed cleanup; document the validated budget and workload. |
| Actual settlement | In a controlled fixture, an independent process can acquire the released `.sync.lock` and complete a checked TRUNCATE/RESTART checkpoint with expected WAL state. Writer access or PASSIVE checkpoint alone is insufficient evidence. |
| Foreground takeover | An expired refresh cannot disconnect its foreground successor; the same Lattice/Results remain usable; rapid phase changes preserve the latest intent. |
| Other producers | Audit-retention and queued generation-maintenance controls show no owned DB work after successful suspension. Unrelated process locks are distinguished from this controller's responsibility. |
| App compatibility | Existing progress/error observers remain installed. No unexpected IPC teardown, separate owner takeover, temporary-handle close, or actor hop. |
| Device behavior | Physical-device cold background launch, expiration, protected-data handling, and foreground return work. Record natural scheduling separately; it is not a deterministic CI or calendar guarantee. |

The app still owns unrelated writes and other background subsystems; this adapter cannot make arbitrary application activity safe for suspension. The documented ownership boundary and tests must state which producers it controls.

## Corrections to the first draft

The first draft put too much weight on remote catch-up boundaries and broad ownership coordination, and proposed timing/cycle counts without measurements. The audit also clarifies that physical destruction of every database connection is unnecessary. Useful opportunistic refresh needs a small caller-facing controller plus targeted suspension correctness in the existing implementation.

Apple's SwiftUI `.backgroundTask` could otherwise provide registration/cancellation/completion for iOS 16+, but the user's chosen API hides that boilerplate. The SDK therefore uses BGTaskScheduler directly and supports iOS 15; callers must not register a second SwiftUI handler for its identifier. A later BGProcessingTask policy can share the same engine without changing the store-ownership design.
