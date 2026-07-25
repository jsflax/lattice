# Syncing Across Devices

Real-time WebSocket synchronization: configuration, filtered upload,
progress observation, and history compaction.

## Enabling sync

Point a configuration at a sync relay and every local commit uploads
automatically; remote changes apply in the background and surface through
the same live results and observers as local writes:

```swift
let config = Lattice.Configuration(
    fileURL: URL(fileURLWithPath: "/path/to/db.sqlite"),
    authorizationToken: "your-auth-token",
    wssEndpoint: URL(string: "wss://your-server.com/sync")
)

let lattice = try Lattice(Person.self, configuration: config)
// Changes are automatically synced via WebSocket
```

## How it works

Consumer-level contract (the transport and conflict machinery live in the
LatticeCore engine):

- Every local write is captured by SQL triggers into an append-only audit
  log inside the same database — capture is transactional with the write,
  so nothing is lost if the process dies before upload.
- A background synchronizer uploads pending entries in chunks and marks
  them synchronized when the server acknowledges them. Uploads retry with
  backoff across reconnects; sync state is durable, so a relaunch resumes
  where it left off.
- Remote changes are applied idempotently and do not re-trigger capture, so
  changes never echo back to their origin.
- Sync state is tracked *per transport*: one database can serve a WebSocket
  channel and IPC channels (see <doc:IPC>) simultaneously, and an entry
  received from one is still pending for the others — that is what makes
  automatic relay work without loop prevention.

## Filtered sync

Control which rows are uploaded per table with `SyncFilter`. Only matching
rows are uploaded; incoming remote changes are always applied regardless of
filter.

```swift
var filter = Lattice.SyncFilter()
filter.include(Person.self, where: { $0.age >= 18 })
filter.include(Pet.self) // all pets

let config = Lattice.Configuration(
    fileURL: url,
    authorizationToken: token,
    wssEndpoint: wssURL,
    syncFilter: filter
)
```

## Observing progress

`syncProgressStream` is an `AsyncStream` of `SyncProgress` values:
`pendingUpload`, `totalUpload`, `acked`, `received`, plus the derived
`uploadFraction` and `isUploading`. Iterate it from an async context (hoist
the stream out of any `Task { … }` closure — see
<doc:ObservationAndSwiftUI>), or use `syncProgressPublisher` for Combine.

```swift
let stream = lattice.syncProgressStream
Task {
    for await progress in stream {
        print("uploaded \(progress.acked)/\(progress.totalUpload)")
    }
}
```

Related observability surface:

- `pendingSyncEntryCount` — entries not yet synchronized across every
  registered sync channel; `0` means fully relayed and acknowledged.
- `onSyncError { message in … }` — transport and apply errors.
- `onSyncStateChange { connected in … }` — connection state transitions.

## Tuning

`Configuration.syncTuning` forwards transport knobs (chunk size, reconnect
backoff, coalescing windows, …) into every synchronizer the database
creates — WSS and IPC alike. Every field is optional: `nil` keeps the
engine default, and values that would break the synchronizer are ignored.

## Compacting history

The audit log grows with every write. `compactHistory()` prunes
synchronized entries while respecting replication slots — entries a known
peer has not yet received are kept. `forceCompactHistory()` prunes
unconditionally; use it only when no peer will ever need catch-up again.

## Server side

The `LatticeServerKit` library product provides the sync relay for Vapor
servers. It is relay-only by design: authentication is the application's
responsibility — validate the client's `authorizationToken` in your own
middleware before the socket reaches the relay.
