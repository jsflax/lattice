# Background sync source audit

November 1, 2026. Read-only inspection of SDK `751950358f49b934dfa8af1dcfd493b683cd9d0a` and Core `6afbe41b6ea4de63b27bb40e042ad9e455ba72ed`, with separate reviews of the smallest caller API and actual lifetime behavior. No product code, native execution, or device qualification was performed. These findings support the [revised plan](ios-background-sync.md).

## Reuse before adding APIs

- Swift already exposes [`retireAllGenerations()` and `resumeGenerations()`](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L1696). They reach Core through CxxBackend and the Swift-C++ bridge. This is not a missing basic bridge.
- [Core retirement](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/include/lattice/lattice.hpp#L2714) commits/settles retained readers and can return idle connections to a pool. Releasing transaction locks does not require destroying every connection. Active statements and failed settlement still require explicit handling.
- [WSS setup](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/lattice.cpp#L520) already creates the synchronizer with its own database/scheduler and establishes exclusive ownership. No new storage broker is needed.
- [Core drain](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L1155) already attempts upload/ACK progress. Its synchronous `void` interface and polling deadline do not establish a whole-operation cancellation bound.

## Concrete gaps

| Finding | Source and consequence |
| --- | --- |
| Transport disconnect is narrower than suspension | [`disconnect_sync`](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/include/lattice/lattice.hpp#L9059) clears start intent and disconnects WSS, but does not destroy its synchronizer. |
| Ownership lock survives disconnect | [WSS lock release](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/include/lattice/lattice.hpp#L8807) occurs in teardown. Suspension must release this owner's `.sync.lock` and avoid automatic same-process sibling handoff. |
| Disconnected maintenance continues | [Pacer loop](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L886) explicitly drives WAL maintenance while idle/disconnected. |
| Queued apply survives disconnect | [Scheduled apply closure](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/src/sync.cpp#L1322) checks destruction, not the disconnected transport state. A reversible suspension must settle or cancel admitted work without falsely ACKing it. |
| Other owned maintenance can outlive reader retirement | [Core optional audit maintenance](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/include/lattice/lattice.hpp#L3876) and [Swift queued maintenance ticks](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Results/GenerationCoordinator.swift#L1020) need lifecycle coverage. |
| Generic teardown is not WSS-only | [IPC teardown](https://github.com/jsflax/LatticeCore/blob/6afbe41b6ea4de63b27bb40e042ad9e455ba72ed/Sources/LatticeCore/include/lattice/lattice.hpp#L8790) precedes WSS teardown. Factor the needed path or reject unsupported IPC configurations; never silently stop them. |
| Public progress observation is single-slot | [`syncProgressStream`](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L1822) replaces a previous subscriber. Background sync cannot appropriate it, or replace the app's state/error handler slots. |
| Documented automatic resume has no matching observer | [`GenerationLifecycleObserver`](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Results/GenerationCoordinator.swift#L1452) installs retirement notifications only, while the public methods document automatic foreground/protected-data resumption. Add the missing regression before claiming that path works. |

The SDK's default SQL busy timeout is 30 seconds; measure and bound the specific sync/cleanup contention paths before promising a shorter expiration response. A general deadline rewrite across unrelated Core features is not justified by this integration. Protected-data availability is not equivalent to foreground activity: a resume-notification fix must preserve the controller's suspension intent, including when unlock races cleanup.

## Why the existing store is the simpler default

[Deferred startup](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L570) affects WSS only. Ordinary same-configuration opens can share native identity; independent opens may instead lose sync ownership to an existing handle. Closing a temporary handle can invalidate shared state or hand sync to a sibling. Preserve the app's store and add the small reversible suspension operation.

The store's actor is part of its [scheduler/cache identity](https://github.com/jsflax/lattice/blob/751950358f49b934dfa8af1dcfd493b683cd9d0a/Sources/Lattice/Lattice.swift#L776). The first UI adapter explicitly uses MainActor; an arbitrary `Task.detached` or unchecked Sendable wrapper is not an actor-isolation solution. Registration can occur before resolving the store through a lazy provider.

## Scope removed from the first draft

The wire protocol has audit changes, ACKs, replay requests, and NACKs, with no end-of-snapshot message. That does not block a bounded refresh attempt. Do not add a remote catch-up watermark merely to return from a background operation; do not label progress as complete server convergence.

Remove the arbitrary 100-cycle, p95 one-second, and absolute two-second acceptance numbers from the initial draft. Start with deterministic lifecycle/lock tests and measured cleanup under a declared workload. Natural iOS scheduling is useful device evidence, not a deterministic CI timer or guaranteed release-date gate.

The resulting scope is one app-facing controller, thin Apple scheduling plumbing, and targeted suspension fixes. It does not require importing the old recovery candidate.

## Automatic lifecycle observation

The caller does not need to forward state or permit swizzling. Existing `GenerationLifecycleObserver` already uses public UIKit notifications. The controller can use the same supported mechanism, with [UIApplication applicationState](https://developer.apple.com/documentation/uikit/uiapplication/applicationstate) providing aggregate state across scenes. Initial inactivity, transient focus loss, and a background scene beside an active scene must be tested separately. Observe before taking the initial state snapshot and keep lifecycle delivery on MainActor. Automatic observation changes the caller surface; it does not replace the required native suspension work.
