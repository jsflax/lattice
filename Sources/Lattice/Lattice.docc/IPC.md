# Cross-Process Sync (IPC)

Synchronize databases across processes on one machine via Unix domain
sockets, and compose IPC with WebSocket sync for cloud relay.

## Channels

Both sides reference a shared *channel name* — the socket path is
auto-derived per platform, and roles are negotiated at runtime: the first
process to open a channel becomes the server, later ones connect as
clients. There is no role to configure (earlier releases' explicit
`.server`/`.client` role API no longer exists). Set `ipcTargets` on the
configuration before opening the database:

```swift
// Hub process: opens the channel and serves filtered data
var filter = Lattice.SyncFilter()
filter.include(Person.self, where: { $0.age >= 18 })

var sourceConfig = Lattice.Configuration(fileURL: sourceURL)
sourceConfig.ipcTargets = [.init(channel: "adults", syncFilter: filter)]
let source = try Lattice(Person.self, configuration: sourceConfig)

// Spoke process: same channel name — connects and receives the filtered data
var targetConfig = Lattice.Configuration(fileURL: targetURL)
targetConfig.ipcTargets = [.init(channel: "adults")]
let target = try Lattice(Person.self, configuration: targetConfig)
// Sync is bidirectional — changes flow both ways
```

A per-channel `syncFilter` restricts what that channel *uploads*; incoming
changes are always applied. Multiple targets in `ipcTargets` open multiple
independent channels from one database.

## Explicit socket paths

The derived socket path assumes both processes share a HOME directory. When
they don't (e.g. a macOS app talking to an iOS simulator), pass an explicit
`socketPath:` to `Lattice/IPCSyncTarget`:

```swift
config.ipcTargets = [.init(channel: "adults", socketPath: "/tmp/adults.sock")]
```

## Cloud relay

IPC and WSS compose — a database can receive changes via IPC and
automatically forward them to the cloud via WSS:

```swift
// Relay process: receives from IPC, relays to cloud
var relayConfig = Lattice.Configuration(
    fileURL: relayURL,
    authorizationToken: token,
    wssEndpoint: URL(string: "wss://your-server.com/sync")
)
relayConfig.ipcTargets = [.init(channel: "adults")]
```

Per-synchronizer state (the `_lattice_sync_state` table) tracks sync status
independently per transport: an entry received over IPC is marked
synchronized for the IPC channel but remains pending for WSS, which is what
makes automatic relay work — no loop-prevention logic, and changes never
echo back to their origin.

## Progress and tuning

The observability and tuning surface is shared with device sync:
`syncProgressStream`, `pendingSyncEntryCount`, `onSyncError`,
`onSyncStateChange`, and `Configuration.syncTuning` all apply to IPC
channels. See <doc:Sync>.
