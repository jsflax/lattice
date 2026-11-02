# Config-first background sync actor/compiler probe

November 1, 2026. Compiler prototype only: no production Lattice files changed, no SQLite work, and no real background-task execution.

## Result

The approved caller API can use ordinary configuration data and bind internally to the actual store on its existing actor. No public controller, session handle, provider, or manual lifecycle forwarding is required in the ordinary path.

The following passed with Xcode 27.1, Apple Swift 6.4, Swift language mode 6, complete concurrency checking, and warnings treated as errors:

- `ConfigActorProbe.swift`: full object compilation for `arm64-apple-ios15.0` using the installed iPhoneOS 27.1 SDK.
- The same source: full object compilation for `arm64-apple-ios15.0-simulator` using the installed iPhoneSimulator 27.1 SDK.
- `ActorRuntimeProbe.swift`: macOS executable compiled for deployment target macOS 14 and executed on this Mac. Two owning actors each received 1,000 concurrently submitted operations; every operation asserted its expected actor executor and exact final counts passed. A weak binding ran while its owner held the store, then rejected after the owner released it.

Empty compile logs represent successful exit status 0. Runtime output is in `actor-runtime-result.log`. This is not iOS device qualification, a Core safety proof, or an implementation of task expiration.

## Public shape

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

`backgroundSync` is optional policy data. The SDK binds automatically to the store actually created by that initializer. A new public `session` parameter is unnecessary.

An app whose store opens asynchronously or only later needs a synchronous early declaration:

```swift
try Lattice.registerBackgroundTasks(configuration: configuration)
```

That declaration registers the configured task identifier without opening or migrating the database. Normal Lattice initialization repeats the declaration idempotently before opening, then attaches the resulting store. The proposed method name is not frozen. Assignment to the existing `Lattice.defaultConfiguration` is not registration today.

Early declaration by itself cannot discover an app's schema, current account, token provider, or lazily created actor. If a background launch never opens an eligible store, the handler has no store to refresh; it must defer rather than invent another store or credentials. The app can use its normal launch path to initialize the store asynchronously after early registration. A protected-store open failure must leave the process-level handler registered so a later successful open can bind without registering twice.

## Internal actor bridge

The package already uses this technique in `Sources/Lattice/ObserverActorDelivery.swift`. The complete compiler probe verifies it with a deliberately non-Sendable store:

```swift
private struct Binding: Sendable {
    let operation: @Sendable @isolated(any) (Command) async throws -> Void

    init(@_inheritActorContext operation:
        @escaping @Sendable @isolated(any) (Command) async throws -> Void
    ) {
        self.operation = operation
    }
}

// Form this inside the existing initializer's isolated context.
let binding = Binding { [weak store] command in
    _ = isolation // the original isolated parameter, not a captured copy
    guard let store else { throw StoreError.closed }
    try await store.perform(command)
}
```

The private coordinator can be MainActor-isolated for UIKit observation while calling `try await binding.operation(...)` on the store's original actor. There is no unchecked Sendable wrapper around the facade. Weak capture prevents process-lifetime registration from pinning a discarded store. An executing operation may hold the store strongly until its cleanup completes.

Two rejected approaches matter:

1. An ordinary `@Sendable` closure capturing the non-Sendable store is rejected, including a closure typed `@isolated(any)` without inherited actor context. Explicitly capturing `[isolation]` also loses the original isolated-parameter proof. Preserve the original parameter and use the existing compiler-supported inheritance helper.
2. Sending the raw `BGTask` from a default arbitrary launch queue into `Task { @MainActor ... }` fails region-isolation checking during full compilation, even though `-typecheck` alone did not catch it. The working Apple bridge imports `BackgroundTasks` with `@preconcurrency`, registers delivery on `.main`, and enters the driver with `MainActor.assumeIsolated`. BGTask state then stays on that actor. This compatibility import does not make arbitrary raw-task transfer safe.

The iOS 27 `submitTaskRequest(_:)` async spelling compiles behind `#available(iOS 27, *)`. The probe creates and submits the request inside `Task.detached`, as current headers instruct avoiding the main thread. The legacy `submit(_:)` branch preserves the iOS 15 deployment target.

## Actual Lattice binding integration point

`Lattice` is a struct and cannot be weakly captured. The production binding should capture the class-bound backend weakly, along with its native identity and the original isolation parameter. `LatticeBackend` already inherits `AnyObject, Sendable`; `CxxBackend` owns the native reference. Factor the required per-backend operations/reader-coordinator lookups so the capsule does not need to retain the whole facade.

Weak lifetime alone is insufficient: explicit `Lattice.close()` can invalidate a native store while Swift references remain alive. Close/unbind must invalidate the binding generation and reject subsequent operations, and an operation admitted before close must settle according to the Core ownership contract. The probe's released-store check demonstrates weak lifetime, not explicit-native-close safety. Native identity must be checked so a reopened file cannot accidentally use an earlier binding.

## Contracts still required in implementation

The sample registry and driver show compilation, not the full ownership state machine. In particular they must not be copied as production scheduling code:

- Registration lifetime is per process/identifier. Store binding is a separate lifetime keyed by actual native identity, not only filesystem path.
- Duplicate compatible setup must reuse registration. A different live store cannot silently replace the existing binding; account replacement first cancels/settles/unbinds the previous owner, then attaches the new one without registering again.
- The sample `attach` writes a dictionary asynchronously. Production must define attachment/delivery ordering and reject conflicting bindings; a queued attach must not revive a closed or superseded store.
- `Lattice` query/reference facades and independent connections must not accidentally opt themselves into another controller through copied configuration.
- The example does not model expiration, app background assertions, failure versus partial progress, bounded cleanup, or settled foreground takeover. Those depend on the Core contract.
- Background scheduling policy should remain Sendable/Hashable data; arbitrary closure identity should not become part of Configuration hashing or native-store identity.
- The synchronous registration lock in the sample is a compiler convenience. Production should preserve the existing rule against user callbacks or final releases under internal locks and handle launch callbacks without lock reentrancy.

## Commands

Paths shown relative to this directory except SDKs. `TMPDIR` was set to this directory's `tmp`; module-cache and object/executable output are also here.

```sh
xcrun swiftc -c -parse-as-library -swift-version 6 \
  -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-ios15.0 \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk \
  -module-cache-path module-cache ConfigActorProbe.swift -o ConfigActorProbe-ios15.o

xcrun swiftc -c -parse-as-library -swift-version 6 \
  -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-ios15.0-simulator \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk \
  -module-cache-path module-cache ConfigActorProbe.swift -o ConfigActorProbe-ios15-simulator.o

xcrun swiftc -parse-as-library -swift-version 6 \
  -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos14.0 -module-cache-path module-cache \
  ActorRuntimeProbe.swift -o ActorRuntimeProbe
./ActorRuntimeProbe
```
