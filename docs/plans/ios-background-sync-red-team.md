# Background sync adversarial review

November 1, 2026. Reviewed plan revision `52af5f2` against SDK `751950358f49b934dfa8af1dcfd493b683cd9d0a`, Core `6afbe41b6ea4de63b27bb40e042ad9e455ba72ed`, Apple documentation, and the installed iPhoneOS 27.1 headers. Two fresh reviews challenged the integration and the simplest alternative; the author independently traced the relevant source.

**Verdict: needs revision before implementation.** The earlier implementation-ready characterization is withdrawn. This was a source/platform-contract review, not a runtime or physical-device qualification. The plan remains visible so the findings can be evaluated against what it actually proposed.

## High priority findings

### Define useful completion before the timer and result enum

The plan explicitly allows a connected session to consume its whole 20-second window and report `attempted`. That does not define when useful refresh work is finished. It could waste time on an empty store or stop midway through an initial download. These are consequences of the proposed policy, not measured product failures. A maximum duration should be a safety limit.

Core's [drain](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L1155) covers upload/ACK progress, not complete initial downloads. The server already has a [local end to its initial catch-up pass](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/LatticeServerKit/LatticeServerKit.swift#L1434): it sends the pages and then activates live observation at their boundary.

Compare a clearly labeled best-effort idle rule with a small optional catch-up-complete message. A large global watermark protocol is unnecessary, but categorically forbidding any protocol addition could make the overall design more complicated. Select the finite work contract before choosing success, timeout, or partial-progress results. Apple's [completion API](https://developer.apple.com/documentation/backgroundtasks/bgtask/settaskcompleted(success:)) does not select that product contract for us.

### Separate permanent registration from account and store lifetime

The registered handler lasts for the process, while login credentials and the eligible store can change. The plan provides no disable, logout, or rebinding contract. The SDK's [configuration is immutable](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L838), and [Core reconnect uses its stored token](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L1093). Calling a memoized provider again does not itself update that token.

Define how logout disables pending/active work and releases the old binding without unregistering and re-registering the Apple handler. Resolve current account eligibility, credentials, and store deliberately for each opportunity. This requires a normal app-lifetime contract, not a general account-management framework.

## Medium priority findings

### Make refresh work independently callable

The current manual `refresh()` escape hatch requires constructing a controller that also registers and schedules a competing task. That is unsuitable for an app that already has a background-refresh handler. Apple's [one pending refresh-request limit](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:)) is not a limit of one permitted or registered identifier.

Keep the actual sync operation usable independently, and make hidden scheduling the convenient opt-in wrapper. The default can remain simple without forcing every consumer to transfer its entire refresh policy to Lattice.

### Do not require the database to live on MainActor without a demonstrated reason

UIKit observation belongs on MainActor; the sync operation can run on the store's existing actor. The SDK already [captures caller isolation in its scheduler](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L776). A provider returning only a MainActor-created Lattice excludes existing store actors and encourages synchronous opening/migration on the UI executor.

Evaluate an async operation that hops to the app's store actor, or an internal actor-safe capability. Do not transfer a non-Sendable Lattice facade merely to satisfy an OS callback. This is an API design choice to validate with a small compiler prototype, not an Apple restriction.

### Include the legacy background-fetch migration consequence

Apple documents that adding `BGTaskSchedulerPermittedIdentifiers` disables the legacy fetch delegate method and minimum-fetch-interval API on iOS 13 and later. Existing app behavior can therefore change just by following the plist instructions. Add a migration/coexistence note and host test. [Apple setup guide](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)

### Distinguish skipped work, failure, and foreground takeover

The plan maps every deferred result to unsuccessful task completion, including legitimate foreground activity or an already-running refresh. Those are not inherently the same as failed work. Define `notNeeded`, unavailable, failed, and cancelled from the chosen work contract.

Likewise, independent lock acquisition is an acceptance condition after full suspension. A refresh returning during foreground takeover may legitimately leave foreground sync holding that lock. Split these test expectations.

## Corrections and assumptions that survived

- Automatic public lifecycle notifications are appropriate. Aggregate UIApplication state is already available; do not add a custom per-scene state machine without demonstrating a compatibility need. Keep cold-launch, transient inactivity, and multi-window tests.
- Hidden early registration is appropriate. The initializer's store provider does not make construction of `AppStore` itself lazy; the host example must avoid opening/migrating storage before registration.
- The iOS 27 submission API is real and present in the installed 27.1 headers. Supporting it is a small availability shim, not a design workstream.
- Reader retirement exists and is Swift-exposed. `disconnectSync()` alone leaves real work behind, but [synchronizer destruction already stops the pacer, removes its observer, disconnects, and drains its scheduler](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L1006). First factor/reuse that path and measure the gap before designing a new resource-admission system.
- Holding `.sync.lock` after disconnect is a source fact. Its iOS termination consequences across different storage layouts are not established by that fact alone. Separate lock-ownership tests from OS-termination claims.
- The earlier protocol census was incomplete: the C++ enum has four kinds, while Swift [ServerSentEvent](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Sync.swift#L145) also includes `rejected` and `floorReset`. Neither inspected side supplies the proposed initial-catch-up-complete contract, but the whole wire surface must be considered before declaring a protocol change necessary or unnecessary.

## Smallest next investigations

1. Trace and prototype a finite sync operation: empty store, one upload, and a paged initial download. Compare a local idle policy with the smallest completion signal. A deadline remains a fallback, not the definition of work.
2. Exercise reuse of existing WSS teardown under queued apply and SQL contention, followed by resumption on the same store. Add only the missing cancellation/settlement behavior demonstrated by that probe.
3. Compile a minimal actor-local work API and optional scheduling wrapper. Walk it through fresh launch, locked data, credential rotation, logout, and an app with an existing refresh handler before freezing public names.

These investigations precede another claim that the API is ready. No implementation or runtime acceptance is implied by this review.
