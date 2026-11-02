# Background Sync on iOS

Request background refresh opportunities through the store's configuration,
while keeping the same database usable when the app returns to the foreground.

## Enable background refresh

Background scheduling is off by default. Add `backgroundSync` when opening the
store during app launch, before launch finishes:

```swift
import Foundation
import Lattice

@Model final class Note {
    var text: String = ""
}

@MainActor
func openNotes(storeURL: URL, relayURL: URL, token: String) throws -> Lattice {
    try Lattice(
        Note.self,
        configuration: .init(
            fileURL: storeURL,
            authorizationToken: token,
            wssEndpoint: relayURL,
            backgroundSync: .appRefresh(
                identifier: "com.example.notes.sync",
                minimumInterval: 15 * 60
            )
        )
    )
}
```

Retain the returned store on its owning actor. Lattice binds background work to
that configured store; the caller does not create a controller, session, or
provider closure. Your app remains responsible for retaining and closing that
original store.

In the **app target**, enable the **Background fetch** capability and add these
entries to `Info.plist`. The identifier must match the configuration exactly:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.example.notes.sync</string>
</array>
```

Lattice registers the launch handler, submits refresh requests, handles
expiration, and reports completion after its work has settled. It observes
public UIKit lifecycle notifications. No `ScenePhase` forwarding, app-delegate
replacement, or swizzling is required. Do not also register this identifier
with `BGTaskScheduler` or SwiftUI's `.backgroundTask` modifier.

Adding `BGTaskSchedulerPermittedIdentifiers` changes an app's legacy background
fetch integration: migrate any existing `performFetchWithCompletionHandler`
setup instead of expecting both mechanisms to keep scheduling independently.

`minimumInterval` is an **earliest-time hint**, not a repeating timer. Its default
is 15 minutes, and it must be finite and greater than zero. iOS decides whether
and when an opportunity runs. The system allows one pending app-refresh request
per app. Lattice preserves an earlier pending request and does not cancel
another identifier's request to take its place. If the app already owns its
refresh handler, consider using `syncOnce` from that handler instead.

## Register early when storage opens later

An app may need to wait for protected data, authentication, or its store actor
before opening the database. Register synchronously during launch using the
configuration alone:

```swift
@MainActor
func registerForLazyOpen(configuration: Lattice.Configuration) throws {
    try Lattice.registerBackgroundTasks(configuration: configuration)
}

actor NotesStore {
    private var lattice: Lattice?

    func open(configuration: Lattice.Configuration) throws {
        guard lattice == nil else { return }
        lattice = try Lattice(Note.self, configuration: configuration)
    }

    func close() {
        lattice?.close()
        lattice = nil
    }
}
```

Call `registerForLazyOpen` before the launch callback returns; schedule the
actor's `open` separately when storage is available. A SwiftUI app can perform
the same early registration during app initialization. Creating or copying a
configuration, or assigning `Lattice.defaultConfiguration`, does not register
anything. A nil `backgroundSync` policy makes explicit registration a no-op.

Early registration opens no database and supplies no model schema. If iOS
delivers a task while the store is still unbound, Lattice reports unsuccessful
completion and requests another opportunity. The app remains responsible for
opening its store when it can. Registration remains valid if a later database
open fails; retrying the open does not register a second handler. Protected-data
availability alone does not claim foreground sync ownership.

Keep the policy for a registered identifier consistent for the process's
lifetime. An identifier cannot silently switch between different live stores,
and one live store cannot acquire two task identifiers. Repeated facades of the
same native store reuse its binding.

`LatticeActor(for:configuration:)` creates temporary contexts for individual
calls and cannot be the persistent owner of a background-managed store. Open
and retain the `Lattice` in your app's own actor, as above. A
`LatticeActor(existingLattice)` can provide derived contexts, but it does not
replace that retained owner or register another background task.

References resolved on another actor, borrowed `LatticeActor` contexts, and
Lattice's internal query connections follow the original store's managed
lifecycle. These derived handles use local connections; the original owner
syncs the file. Keep that owner alive while the derived contexts are in use.
Closing a derived connection leaves its owner and siblings available. Closing
the original owner retires its derived connections too. References captured
before that close cannot reopen the retired store; obtain new references from
the newly opened owner.

## Foreground, background, and expiration

In the foreground, the managed store resumes continuous sync. When the app
enters the background, Lattice suspends its owned sync work and retires its
managed read generations. A delivered background task runs a finite pass and
settles its owned work before completing. Expiration requests cancellation;
requesting cancellation is not itself completion.

The database stays open for subsequent use, and durable edits, sync cursors,
and acknowledgements survive these transitions. Existing Results and public
sync progress/state/error subscriptions can continue to be used. A transient
inactive state, such as an interruption, is not treated as a completed move to
the background. Returning to the foreground joins necessary cleanup before
resuming, so an older task's expiration cannot stop its successor.

This lifecycle manages Lattice's owned work. It does not settle transactions,
writes, or database access owned by unrelated app code or other processes.

## Use an app-owned execution opportunity

`syncOnce(maximumDuration:)` performs finite sync without registering an Apple
task. Open a deferred store when the app owns when sync starts:

```swift
@MainActor
func openManualNotes(storeURL: URL, relayURL: URL, token: String) throws -> Lattice {
    try Lattice(
        Note.self,
        configuration: .init(
            fileURL: storeURL,
            authorizationToken: token,
            wssEndpoint: relayURL,
            syncStartup: .deferred
        )
    )
}

@MainActor
func runManualPass(on lattice: Lattice) async throws -> Lattice.SyncOnceResult {
    try await lattice.syncOnce(maximumDuration: 20)
}
```

The default budget is 20 seconds and must be finite and greater than zero. The
budget includes setup and requests cancellation when it expires; cleanup can
continue past that work budget. An app-owned background handler must forward
expiration by cancelling its Swift task and await settlement before reporting
completion to the system. This method does not acquire a UIKit execution
assertion for the caller.

| Result | Meaning |
| --- | --- |
| `completed` | The pass confirmed its starting upload prefix and the server's initial replay boundary. Newer changes can remain for a later pass. |
| `budgetExhausted` | The pass or its required cleanup exceeded the budget, or the completion boundary was not confirmed. Useful changes may already have committed. |
| `alreadyRunning` | Another sync operation or foreground session already owns the work; this call leaves it running. |
| `unavailable` | This call could not use or retain the configured store's sync ownership. |

Failures throw. Cancellation throws `CancellationError` after owned work has
settled. A timer, an idle connection, or `pendingSyncEntryCount == 0` does not
prove that the server's replay has finished.

On an ordinary store without a background policy, a finite pass cleans up its
private sync session and restores the parent store's prior maintenance state.
It does not automatically retire unrelated parent read generations. Existing
manual host contracts still apply: where the host must release parent readers
before suspension, call `retireAllGenerations()` and later `resumeGenerations()`
when that host can resume. Those methods address read generations; the caller
also owns any other live database work. See <doc:ObservationAndSwiftUI>.

## Supported stores and account changes

Automatic scheduling requires an iOS 15 or later **host app**, a writable file
store, a WebSocket endpoint, and a nonempty authorization token. In-memory and
read-only stores, or stores with unmanaged IPC targets, cannot opt in. The
ordinary IPC features remain separate; see <doc:IPC>.

App extensions cannot opt into the automatic scheduler. Ordinary Lattice use
remains available to extensions; their execution time and explicit reader
lifetime responsibilities remain with the extension's host contract.

Use `close()` to retire the old binding before logout or account replacement,
then open a new store with the intended account configuration. Decide how the
app preserves that account's unsent local data and which file the new account
uses. The original endpoint and token belong to the opened store. Re-resolving
a facade or calling `connectSync()` or `reconnectSync()` is not credential
rotation. Process-level task registration remains after the old store closes.

## Upgrade the client and relay together

Use the matching LatticeCore dependency supplied by the Lattice release and
update the `LatticeServerKit` relay for confirmed finite completion. Native
durable outbox tracking and the relay's negotiated completion marker work
together; forcing an older Core version omits part of that contract.

Lattice 2.6.1 requires Core 2.5.1. Upgrade and restart all processes that own
the store's sync channels together. Rebuild native iOS bridge objects and Swift
consumers together; Core 2.5.0 and later use shared-pointer-backed value
handles on iOS, so previously compiled iOS foreign-reference objects cannot be
mixed with the new bridge.

An older relay may still transfer changes, but it cannot provide the new
completion boundary. A finite pass can therefore exhaust its budget even when
its upload count reaches zero. Treat that as unconfirmed progress. The marker
is negotiated so clients that do not request it do not receive a new frame.

Persisted outbox state is part of the store's sync bookkeeping. This feature
does not promise that an older binary can safely reopen an upgraded store;
follow the release's compatibility requirements when choosing versions.
