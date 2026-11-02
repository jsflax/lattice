# Derived managed-handle lineage checkpoint

Prepared November 1, 2026. Source is handed back to the root agent for full SDK/Core integration and device qualification. No physical-device behavior is claimed here.

## Correctness issue and implemented boundary

A TSR or borrowed LatticeActor resolved on another actor can create a distinct native identity. Keeping the native managed flag without attaching it to the lifecycle owner leaves that connection suspended indefinitely. Clearing the flag lets its automatic readers/maintenance run outside managed cleanup. The SDK now carries an internal lineage token through configuration copies, resolves local-only managed derived connections, and fans lifecycle commands across the original owner's native members. The token itself is excluded from public configuration value equality/hash. It retains the group; idle group candidates retain neither actor nor backend.

Only the original owner performs finite network work. Derived configurations remove the task policy, endpoint, token, and IPC targets. Their local managed Core support is supplied by the separate Core slice. A finite alreadyRunning result leaves existing foreground work alone. Suspended/cooled finite work confirms borrowed-member settlement too. The group uses a monotonic deadline across actor admission and borrowed cleanup and passes the remaining duration to the native owner just before native startup.

Owner close first publishes invalidation and cancels already-admitted operation permits, including those still waiting to hop onto an actor. It then closes borrowed native identities outside registry/group locks; ordinary owner close handles its own backend. Derived close removes only that member. Native close calls evict Swift trampoline/generation caches outside their locks. Stale lineages cannot reopen after close, and a derived attachment requires a retained original-owner capability rather than just an equal numeric native address.

Registry aliases keep weak candidate backends per native identity and prune them on attachment, probing weak references outside the registry lock. Closed allocations remain fenced while their registered wrappers are alive; expired allocations can reuse an address. Repeated wrappers are deduplicated. This avoids keeping every historical derived native ID for the lifetime of the original group.

New membership changes scheduler revision without changing its binding generation. The root-owned scheduler replays a required lifecycle state when membership changes, and does not expire a valid background task just because a local handle joined. A bounded member snapshot avoids an endless attach/drain loop; new native managed members start suspended.

## Evidence

- `lineage-binding-tests-compile.json/.log`: actual policy/scheduler/binding source and actual scheduler/binding tests compile under strict Swift 6 with enclosing Lattice types stubbed.
- `lineage-tests-run.json/.log`: **41 tests across two suites passed**. Ten new binding tests cover distinct members/owner-only refresh, preserving alreadyRunning work, derived/owner close, stale references, conflicting lineages, unconfirmed suspension, queued actor-hop cancellation, address reuse, dead-owner ABA, and cleanup-inclusive budgeting. The suite also retains existing cancellation and weak-binding tests.
- `lineage-binding-ios-extension.json/.log`: actual policy/scheduler/binding code emits an iOS 15 object under Swift 6 `-application-extension` with the installed iOS 27.1 SDK.
- `lineage-all-source-parse.json/.log`: every changed Swift source and associated test parses, including Lattice/TSR/actor wiring and the two additional full-SDK policy tests.
- `lineage-manifest.json`: source hashes captured at the handoff gate. Exact compiler argv is preserved in each receipt.

The portable scaffolding does not import the real C++ backend. Native connection behavior, full constructor wiring, policy tests that need the real Configuration, and actual cross-actor model observations must pass the root's full SDK run. `ManagedBackgroundBindingIntegrationTests.swift`, supplied by the finite-integration helper, exercises actual Core on distinct actors. No release claim follows from this standalone compile.

## Explicit lifetime limitation

The pre-existing `Lattice.WeakCacheEntry` stores a strong actor/observer-delivery reference while its backend reference is weak. An actor that owns its store may therefore be retained through that existing cache independently of this new scheduler's weak binding. The portable idle-owner test qualifies only the binding group; it does not prove full-SDK actor deallocation through the global cache. This slice preserves that older design and documents the limit rather than claiming it fixed.

## Prepared phone artifacts

`ios-host` now contains the config-first UIKit host, separate managed/manual schemes, a narrow UI-test target, fresh per-test fixture directories, and a source-only lab relay. The relay's normal/legacy/delayed modes use the public shipping route and the nonsecret `lattice-background-lab` fixture. Its read-only reuse-build plan selects dependency objects from one native SDK build; it has not been linked or started. Project/plist/XML/Swift syntax checks passed. A standalone simulator XCTest typecheck timed out at its 45-second bound without diagnostics; full Xcode build remains required. No install, device run, fake task delivery, lock/passcode change, or natural-delivery claim was made by this agent.
