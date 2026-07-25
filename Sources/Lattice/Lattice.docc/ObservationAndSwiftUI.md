# Observation and SwiftUI

Live results, collection observation, the `@LatticeQuery` property wrapper,
and the async change and sync-progress streams.

## Live results

Query results are live collections. Reads are generation-consistent: every
`count`, element access, and `snapshot()` within one main-thread render
batch comes from a single database snapshot, and same-handle writes are
visible immediately after `add`/`delete`/`transaction` return. Tune the
read model (page cache, generation TTL, cross-process freshness) via
`Configuration.resultsTuning`.

App extensions and non-UIKit hosts on shared app-group containers must call
`Lattice.retireAllGenerations()` before suspension — a suspended process
holding WAL read marks in a shared container is killed by the system. Where
UIKit is available this happens automatically on resign-active.

## Observing a collection

`observe` on any results collection delivers ``CollectionChange`` values —
one per inserted, updated, or deleted row matching the query:

```swift
let cancellable = lattice.objects(Person.self).observe { change in
    switch change {
    case .insert(let id):
        print("New person added with id: \(id)")
    case .update(let id):
        print("Person updated: \(id)")
    case .delete(let id):
        print("Person deleted: \(id)")
    }
}
```

The returned `AnyCancellable` ends observation when cancelled or released.
Individual model instances also conform to `ObservableObject`, and
``TableResults`` publishes `objectWillChange` for SwiftUI.

## SwiftUI: @LatticeQuery

``LatticeQuery`` binds a live, filtered, sorted query into a view. The view
re-renders when matching rows change:

```swift
import SwiftUI
import Lattice

struct PersonListView: View {
    @LatticeQuery(
        predicate: { $0.age >= 18 },
        sort: \Person.name,
        order: .forward
    ) var adults: TableResults<Person>

    var body: some View {
        List(adults) { person in
            Text(person.name)
        }
    }
}
```

Rapid observer fires are debounced into coalesced fetches, and the query
rebinds automatically when the underlying lattice identity changes.

## The change stream

`Lattice.changeStream` is an
`AsyncThrowingStream<[AnySendableReference<AuditLog>], any Error>` —
batches of audit-log references, one batch per commit. Iterate with
`for try await`. The stream is throwing: a failed background open surfaces
as an error at the first iteration instead of crashing the process, and
cancellation promptly ends iteration and removes the observer.

In a non-throwing observer context (a view model, a `.task` modifier), the
recommended policy is catch-and-end-observation:

```swift
do {
    for try await batch in lattice.changeStream {
        handle(batch)
    }
} catch {
    log(error)   // observation ends; re-create the stream to resume
}
```

## Sync progress

`syncProgressStream` is an `AsyncStream` of `SyncProgress` values —
pending/total upload counts, acknowledgements, and received counts (see
<doc:Sync>). When the loop lives in a `Task { … }` closure, hoist the
stream out first: `AsyncStream` is `Sendable`, but the `Lattice` handle is
not, and capturing it in the closure trips Swift 6 region isolation.

```swift
let stream = lattice.syncProgressStream
Task {
    for await progress in stream {
        updateUI(progress)
    }
}
```

`syncProgressPublisher` is the Combine adapter over the same stream;
cancelling the subscription clears the underlying handler.

## Crossing threads

Managed objects and `Lattice` handles are confined to the context that
created them. To cross threads, capture `sendableReference`s and resolve
them on the other side:

```swift
let personRef = person.sendableReference
let latticeRef = lattice.sendableReference

Task.detached {
    guard let lattice = latticeRef.resolve(),
          let person = personRef.resolve(on: lattice) else { return }
    person.name = "Updated Name"
}
```
