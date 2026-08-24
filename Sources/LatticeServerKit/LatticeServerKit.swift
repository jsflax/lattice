import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

// MARK: - SyncChannel

/// One relay partition: connections sharing a channel id share a server
/// database and fan out frames to each other. The personal topology maps a
/// user to their own channel (`id == userId.uuidString`); group topologies
/// map many users onto one channel.
public struct SyncChannel: Sendable {
    /// Fan-out + storage key. Connections with equal ids relay to each other.
    public let id: String
    /// The authenticated user on THIS connection (revocation kicks target
    /// a specific user's sockets on a channel).
    public let userId: UUID
    /// On-disk database filename under the relay's storage directory.
    /// Defaults to `"<id>.sqlite"` — for the personal wrapper that yields
    /// the historical `<userId>.sqlite`; group mounts using ids like
    /// `"group-<uuid>"` get collision-free names for free.
    public let databaseFileName: String

    public init(id: String, userId: UUID, databaseFileName: String? = nil) {
        self.id = id
        self.userId = userId
        self.databaseFileName = databaseFileName ?? "\(id).sqlite"
    }
}

// MARK: - Write policy

/// Per-channel allowlist of audit operations, enforced server-side before a
/// frame is applied or fanned out. Mechanical frame validation, not relay
/// intelligence: the relay already decodes every frame to apply it.
///
/// A violating frame is answered with `ServerSentEvent.rejected(reason:)`
/// and dropped whole — nothing applied, nothing fanned out, entries left
/// unACKed.
///
/// **Fails CLOSED.** This inspector reads the frame with a different parser
/// (Foundation) than the applier (nlohmann in LatticeCore), so anything the
/// inspector cannot fully understand — an unparsable frame, a non-object
/// array element, a missing/odd `tableName` or `operation` — is treated as
/// a violation rather than waved through. An earlier fail-open version was
/// defeated by prefixing the entry array with a single `0`: the Swift cast
/// to `[[String: Any]]` yielded nil (no violation) while the C++ parser
/// skipped the junk element and applied every real DELETE behind it.
public struct SyncWritePolicy: Sendable {
    public enum Operation: String, Sendable, CaseIterable {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }

    /// How to treat a table with no entry in `allowedOperations`.
    public enum UnlistedTablePolicy: Sendable {
        /// Unrestricted (back-compat default for single-tenant mounts).
        case allow
        /// Rejected. Correct for shared/multi-tenant channels: the schema
        /// is fixed and known, so anything else is forged.
        case deny
    }

    /// tableName → operations allowed on that table. Matched
    /// case-insensitively: SQLite identifiers are case-insensitive, so a
    /// `"memory"` entry reaches the same table as `"Memory"` and must not
    /// slip past an exact-match lookup.
    public var allowedOperations: [String: Set<Operation>]
    /// Optional cap on DELETE entries per frame across ALL tables — a
    /// mass-deletion brake that still admits legitimate single-row
    /// retractions on tables whose policy allows deletes.
    public var maxDeletesPerFrame: Int?
    /// Treatment of tables absent from `allowedOperations`.
    public var unlistedTables: UnlistedTablePolicy

    /// Lattice-internal tables a client may never write through the relay,
    /// whatever the policy says. `AuditLog` is the dangerous one: the relay
    /// serves it verbatim to catching-up peers (`eventsAfter`), so a forged
    /// INSERT into it launders arbitrary operations — including ones this
    /// policy forbids — into every member's next catch-up.
    static let internalTables: Set<String> = ["auditlog"]

    public init(
        allowedOperations: [String: Set<Operation>],
        maxDeletesPerFrame: Int? = nil,
        unlistedTables: UnlistedTablePolicy = .allow
    ) {
        self.allowedOperations = allowedOperations
        self.maxDeletesPerFrame = maxDeletesPerFrame
        self.unlistedTables = unlistedTables
    }

    /// Case-insensitive lookup over `allowedOperations`.
    private func allowed(forTable table: String) -> Set<Operation>? {
        let key = table.lowercased()
        if let exact = allowedOperations[table] { return exact }
        for (name, ops) in allowedOperations where name.lowercased() == key {
            return ops
        }
        return nil
    }

    /// First violation in the frame, or nil when the frame passes.
    func violation(inFrame data: Data) -> String? {
        violation(inFrame: RelayFrame(data))
    }

    /// Parse-once form: the relay inspects every frame anyway (to know which
    /// globalIds an upload asked it to store, so a shortfall can be nacked),
    /// so the policy reads that same parse instead of re-running its own.
    func violation(inFrame frame: RelayFrame) -> String? {
        guard let parsed = frame.json else {
            // The applier's parser is more permissive than Foundation's
            // (nesting depth, number forms). Anything we cannot read, we
            // cannot vet — refuse it.
            return "frame is not readable JSON"
        }
        guard let root = parsed as? [String: Any] else {
            return "frame is not a JSON object"
        }
        // Not an upload (ack/replayRequest/etc.): nothing to enforce.
        guard let rawEntries = root["auditLog"] else { return nil }
        guard let entries = rawEntries as? [Any] else {
            return "auditLog is not an array"
        }

        var deleteCount = 0
        for element in entries {
            guard let entry = element as? [String: Any] else {
                return "malformed audit entry (not an object)"
            }
            guard let table = entry["tableName"] as? String, !table.isEmpty else {
                return "audit entry is missing a tableName"
            }
            guard let opRaw = entry["operation"] as? String,
                  let op = Operation(rawValue: opRaw.uppercased()) else {
                return "audit entry has an unrecognized operation"
            }
            guard !Self.internalTables.contains(table.lowercased()) else {
                return "writes to the internal table \(table) are never permitted"
            }
            if op == .delete {
                deleteCount += 1
                if let cap = maxDeletesPerFrame, deleteCount > cap {
                    return "frame exceeds the \(cap)-delete limit for this channel"
                }
            }
            if let allowed = allowed(forTable: table) {
                guard allowed.contains(op) else {
                    return "operation \(opRaw) not permitted on \(table) for this channel"
                }
            } else if case .deny = unlistedTables {
                return "table \(table) is not part of this channel's schema"
            }
        }
        return nil
    }
}

// MARK: - Schema handshake

/// Declared-version gate at connect time. When configured, a client whose
/// declared schema version is missing (if required), unparsable, or outside
/// the mount's `mode` is answered with a human-readable text frame and a
/// policy-violation close — a visible, attributable error instead of a
/// silent apply-wedge when wire schemas drift (the W1.0 failure class).
///
/// The declaration is read from the `queryParameterName` query parameter
/// FIRST (browser WebSockets cannot set request headers, so `?schema=` is
/// the only channel a wasm client has — previously every consumer needed a
/// pre-upgrade middleware to lift it into the header), then from the
/// `headerName` header. Query-param admission is OPT-IN: legacy
/// `minimumVersion` mounts stay header-only on upgrade (their admission
/// surface must not silently widen); only mounts that set
/// `queryParameterName` — the exact-mode init does so by default, since its
/// purpose is browser clients — honor the query channel.
public struct SyncSchemaHandshake: Sendable {
    /// How the declared version is matched.
    public enum Mode: Sendable {
        /// Admit any client at or above the version (the historical
        /// semantics): old clients are refused, newer ones trusted.
        case minimum(Int)
        /// Admit ONLY the exact version: refuses below ("upgrade required")
        /// AND above ("server behind client") with distinct legible close
        /// reasons. Correct for wire schemas where the server cannot
        /// interpret frames minted by a newer client.
        case exact(Int)
    }

    public var headerName: String
    /// Query parameter consulted BEFORE the header. OPT-IN: `nil` (the
    /// legacy `minimumVersion` init's value) disables the query channel
    /// entirely — an upgraded header-only mount must not silently start
    /// admitting via `?schema=`. The exact-mode init defaults it to
    /// `"schema"` (its raison d'être is browser clients, which cannot set
    /// headers); a minimum-mode mount can opt in by setting it explicitly.
    public var queryParameterName: String?
    public var mode: Mode
    /// When false, clients that send no declaration at all are admitted
    /// (legacy tolerance); a declaration that is present but unparsable or
    /// out of range still closes.
    public var requireDeclaration: Bool

    /// Legacy accessor (pre-1.7 this struct was minimum-only). Reads the
    /// version out of either mode; setting forces `.minimum`.
    public var minimumVersion: Int {
        get {
            switch mode {
            case .minimum(let v), .exact(let v): return v
            }
        }
        set { mode = .minimum(newValue) }
    }

    /// Legacy alias for `requireDeclaration` (pre-1.7 name, when the header
    /// was the only declaration channel).
    public var requireHeader: Bool {
        get { requireDeclaration }
        set { requireDeclaration = newValue }
    }

    /// Minimum-version gate (source- AND behavior-compatible with pre-1.7:
    /// header-only — no query-param admission unless the mount opts in by
    /// setting `queryParameterName` afterwards).
    public init(headerName: String = "X-Lattice-Schema", minimumVersion: Int, requireHeader: Bool = true) {
        self.headerName = headerName
        self.queryParameterName = nil
        self.mode = .minimum(minimumVersion)
        self.requireDeclaration = requireHeader
    }

    /// Exact-version gate: refuses both older and newer clients.
    public init(exactVersion: Int, queryParameter: String? = "schema",
                headerName: String = "X-Lattice-Schema",
                requireDeclaration: Bool = true) {
        self.headerName = headerName
        self.queryParameterName = queryParameter
        self.mode = .exact(exactVersion)
        self.requireDeclaration = requireDeclaration
    }

    /// Reason to refuse this request, or nil to admit.
    func refusal(for req: Request) -> String? {
        // Query parameter first: it is the only declaration channel a
        // browser client has, and a client that sends both means the same
        // value anyway (skew between them is a client bug — the query wins
        // deterministically rather than silently).
        let declared: (raw: String, source: String)?
        if let name = queryParameterName, let value = req.query[String.self, at: name] {
            declared = (value, "?\(name)")
        } else if let value = req.headers.first(name: headerName) {
            declared = (value, "\(headerName) header")
        } else {
            declared = nil
        }
        let requirement: String
        switch mode {
        case .minimum(let v): requirement = ">= \(v)"
        case .exact(let v): requirement = "== \(v)"
        }
        guard let declared else {
            let channels = queryParameterName
                .map { "send ?\($0)= or the \(headerName) header" }
                ?? "send the \(headerName) header"
            return requireDeclaration
                ? "missing schema declaration (server requires schema \(requirement); \(channels))"
                : nil
        }
        guard let version = Int(declared.raw) else {
            return "unparsable schema declaration in \(declared.source): '\(declared.raw)'"
        }
        switch mode {
        case .minimum(let minimum):
            guard version >= minimum else {
                return "client schema \(version) below server minimum \(minimum) — upgrade required"
            }
        case .exact(let exact):
            if version < exact {
                return "client schema \(version) below server schema \(exact) — upgrade required"
            }
            if version > exact {
                return "client schema \(version) ahead of server schema \(exact) — server behind client, refusing to admit a newer schema"
            }
        }
        return nil
    }
}

// MARK: - Socket registry

/// One-way flag a connection consults before doing any work. Revocation
/// MUST NOT depend on the peer completing the WebSocket close handshake:
/// `close(code:)` only *sends* a close frame, and a hostile client that
/// never replies keeps `isClosed == false` (Vapor sets no server-side ping
/// timeout), so a "kicked" socket would otherwise keep applying frames to
/// the shared database and fanning them out to the members who remain.
final class RevocationFlag: @unchecked Sendable {
    private let lock = NIOLock()
    private var revoked = false
    var isRevoked: Bool { lock.withLock { revoked } }
    func revoke() { lock.withLock { revoked = true } }
}

actor SocketManager {
    struct Entry {
        let socket: WebSocket
        let userId: UUID
        let revocation: RevocationFlag
    }

    private var channels: [String: [Entry]] = [:]

    func sockets(channelId: String) -> [WebSocket] {
        // Revoked entries are excluded from fan-out immediately, even while
        // their transport lingers.
        channels[channelId, default: []]
            .filter { !$0.revocation.isRevoked }
            .map(\.socket)
    }

    func connectionCount(channelId: String) -> Int {
        reap(channelId: channelId)
        return channels[channelId, default: []].count
    }

    /// Every live (channelId, userId) pair, for periodic re-authorization
    /// sweeps. Reaps dead transports first so the sweep never wastes an
    /// auth check on a socket that already went away.
    func activeConnections() -> [(channelId: String, userId: UUID)] {
        for channelId in channels.keys { reap(channelId: channelId) }
        return channels.flatMap { channelId, entries in
            entries.filter { !$0.revocation.isRevoked }
                .map { (channelId: channelId, userId: $0.userId) }
        }
    }

    func add(socket: WebSocket, channelId: String, userId: UUID, revocation: RevocationFlag) {
        reap(channelId: channelId)
        channels[channelId, default: []].append(
            Entry(socket: socket, userId: userId, revocation: revocation))
    }

    func remove(socket: WebSocket, channelId: String) {
        channels[channelId]?.removeAll { $0.socket === socket }
        if channels[channelId]?.isEmpty == true { channels[channelId] = nil }
    }

    private func reap(channelId: String) {
        channels[channelId]?.removeAll { $0.socket.isClosed }
        if channels[channelId]?.isEmpty == true { channels[channelId] = nil }
    }

    /// Revoke + close one user's connections on a channel (membership
    /// removal). The revocation flag is the authoritative part — the close
    /// frame and the ping-timeout are best-effort transport cleanup. Entries
    /// stay registered until their `onClose` fires so a lingering hostile
    /// socket remains visible to `connectionCount` and to later kicks.
    func disconnect(channelId: String, userId: UUID) {
        for entry in channels[channelId, default: []] where entry.userId == userId {
            entry.revocation.revoke()
            forceClose(entry.socket)
        }
    }

    /// Revoke + close every connection on a channel (channel deletion; also
    /// the post-purge nudge that forces reconnect-and-catch-up).
    func disconnectAll(channelId: String) {
        for entry in channels[channelId, default: []] {
            entry.revocation.revoke()
            forceClose(entry.socket)
        }
    }

    /// Politely close, then drop the transport if the peer never answers:
    /// `pingInterval` starts server-side pings whose unanswered-pong path
    /// closes the channel outright.
    private func forceClose(_ socket: WebSocket) {
        socket.pingInterval = .seconds(5)
        _ = socket.close(code: .goingAway)
    }
}

/// Operational handle over a configured relay: revocation kicks and
/// visibility. Returned by `configureSyncRelay`; safe to hold anywhere.
public struct SyncRelayHandle: Sendable {
    let manager: SocketManager
    /// Present on observer-push mounts (`observerPush != nil`): the
    /// PROCESS-WIDE watch-group owner (`FileWatchManager.shared` — every
    /// push mount shares it, so mounts over one file share one watcher).
    /// Internal — exposed for key-scoped teardown observability in tests
    /// (`hasGroup(forFile:)` / `subscriberCount(forFile:)`), not part of the
    /// public surface.
    let pushManager: FileWatchManager?

    init(manager: SocketManager, pushManager: FileWatchManager? = nil) {
        self.manager = manager
        self.pushManager = pushManager
    }

    /// Kick one user's live connections on a channel (membership removal).
    public func disconnect(channelId: String, userId: UUID) async {
        await manager.disconnect(channelId: channelId, userId: userId)
    }

    /// Kick every connection on a channel (channel deletion / post-purge).
    public func disconnectAll(channelId: String) async {
        await manager.disconnectAll(channelId: channelId)
    }

    public func connectionCount(channelId: String) async -> Int {
        await manager.connectionCount(channelId: channelId)
    }

    /// Every live (channelId, userId) pair across the relay — the input to
    /// a periodic re-authorization sweep. Tokens are typically checked only
    /// at the WebSocket handshake, so without a sweep an admin revoking a
    /// token (or a membership) leaves the live socket connected until it
    /// happens to reconnect.
    public func activeConnections() async -> [(channelId: String, userId: UUID)] {
        await manager.activeConnections()
    }
}

// MARK: - Relay

extension Lattice {
    /// Configures the sync relay WebSocket endpoint on the given route group.
    ///
    /// This is the only thing LatticeServerKit provides — auth, migrations,
    /// and route protection are the consuming application's responsibility.
    /// The `channelExtractor` is the relay's authorization boundary: it maps
    /// an upgraded request to the channel it may join (throw to refuse).
    ///
    /// - Parameters:
    ///   - routes: A `RoutesBuilder` (typically already behind auth middleware)
    ///   - path: Route path for the WebSocket endpoint (e.g. `["sync"]` or
    ///     `["sync", "group", ":groupID"]`)
    ///   - schema: The Lattice model types to sync on this mount
    ///   - storageURL: Directory for per-channel databases (created if needed)
    ///   - writePolicy: Optional per-table operation allowlist for uploads
    ///   - handshake: Optional declared-schema gate at connect
    ///   - storeConfiguration: Optional per-mount factory for the
    ///     `Lattice.Configuration` used to open each channel's database,
    ///     given that channel's file URL. `nil` (the default) opens with
    ///     `.init(fileURL:)` — target schema version 1, which is correct
    ///     for files the relay itself created. A mount whose files are
    ///     produced/migrated by another opener (e.g. a projector writing at
    ///     a versioned schema) MUST supply the same `migration:` dictionary
    ///     here, or the raw open refuses the file's higher `user_version`.
    ///     The returned configuration must keep `fileURL` at the given URL.
    ///   - observerPush: Opt-in live push of committed changes to this
    ///     mount's sockets (see `SyncObserverPush`). Any commit to a
    ///     channel's file — a relay apply on any mount sharing the file, an
    ///     in-process co-writer, or (best-effort) another process — is
    ///     pushed as ordinary `ServerSentEvent.auditLog` catch-up frames,
    ///     exactly-once and commit-ordered per socket. Intended for deny-all
    ///     watch mounts; `nil` (the default) keeps pre-1.7 behavior exactly.
    ///     Watch groups live on ONE process-wide manager: push mounts over
    ///     the same channel file share one watcher `Lattice` and one commit
    ///     observer (the group's watcher open + reconcile tick come from the
    ///     first subscriber's mount; `pageSize` follows each socket's own
    ///     mount).
    ///     Note: a push-enabled mount does NOT fan client frames to
    ///     same-channel peers (delivery is the pump's job; on a watch mount
    ///     the only client frames are acks, and echoing every observer's ack
    ///     to every other observer is N² frames per commit).
    ///   - channelExtractor: Maps the request to its `SyncChannel`
    @discardableResult
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        path: [PathComponent] = ["sync"],
        for schema: [any Lattice.Model.Type],
        storageURL: URL,
        writePolicy: SyncWritePolicy? = nil,
        handshake: SyncSchemaHandshake? = nil,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil,
        observerPush: SyncObserverPush? = nil,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel
    ) -> SyncRelayHandle {
        let sockets = SocketManager()
        nonisolated(unsafe) let schema = schema
        // ONE watch manager per PROCESS: push-enabled mounts share
        // `FileWatchManager.shared`, so two push mounts over the same
        // channel file share one watcher Lattice and one commit observer.
        // Mount-specific configuration rides each subscribe call in the
        // context below; `nil` on legacy mounts (zero new work anywhere).
        let watchManager: FileWatchManager? = observerPush != nil ? .shared : nil
        let pushContext = observerPush.map {
            MountPushContext(schema: schema, storeConfiguration: storeConfiguration, options: $0)
        }
        routes.webSocket(path, maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 300 * 1024 * 1024)) { req, ws in
            // Per-connection state, confined to the socket's event loop.
            // Frames that arrive before the (slow — schema ensure, epoch
            // migrations) per-channel lattice open finishes are BUFFERED and
            // replayed in arrival order the moment it's live. Previously the
            // open ran before handler registration, and WebSocketKit silently
            // drops frames with no onBinary registered — a client that
            // uploaded within the open window lost that frame, its entries
            // sat unACKed until the resend/reconnect, and the relay tests
            // that await that first delivery hung (the intermittent CI hang
            // class). ONE `Lattice` REFERENCE per connection, held for the
            // socket's lifetime (a fresh Lattice per frame raced the weak
            // instance cache and segfaulted under real bursts — exit 139).
            //
            // NOT one SQLite connection per socket: every relay-shaped open of
            // the same file+schema aliases ONE cached `swift_lattice`
            // (LatticeCache::get_or_create) and therefore ONE
            // FULLMUTEX-serialized SQLite connection — leaked per-connection
            // Lattices retain that shared instance rather than adding
            // connections. That is why concurrent applies on a channel
            // contend inside `begin_transaction` (they are siblings on one
            // connection, not rivals for a file lock) and why 1.7.1
            // serializes them per file instead. The instance cache does NOT
            // key on `busyTimeoutMs`, so the first open of a file installs the
            // budget every later aliased handle runs with.
            let state = ConnectionRelayState()

            // Handlers go live IMMEDIATELY — synchronously on the socket's
            // event loop, BEFORE any await (handshake, extractor, open). The
            // old userIdExtractor was synchronous, so upgrade→registration
            // had no suspension point; the async channelExtractor would
            // otherwise reopen the frame-drop window. Until go-live, frames
            // only buffer. `state.channelId` is late-bound: nil means this
            // connection never registered with the SocketManager, so onClose
            // has nothing to deregister; `state.process` is installed at
            // go-live alongside the lattice.
            ws.eventLoop.execute {
                ws.onText { ws, str in
                    print("🧦", "Received String Event", str)
                }
                ws.onBinary { ws, bb in
                    // Revoked or refused: consume and discard. Never apply,
                    // never ack, never fan out, never buffer.
                    guard !state.revocation.isRevoked, !state.isRefused else { return }
                    if state.lattice != nil, let cont = state.applyContinuation {
                        // Post-go-live: hand the frame to this connection's
                        // serial applier. The queued-bytes cap bounds server
                        // memory against a client that outruns apply — same
                        // policy (and same cap) as the pre-open buffer.
                        if state.queuedApplyBytes + bb.readableBytes > maxBufferedFrameBytes {
                            print(">>> Apply queue cap exceeded; closing connection")
                            state.isRefused = true
                            cont.finish()
                            ws.pingInterval = .seconds(5)
                            _ = ws.close(code: .policyViolation)
                        } else {
                            state.queuedApplyBytes += bb.readableBytes
                            cont.yield(bb)
                        }
                    } else if state.bufferedBytes + bb.readableBytes <= maxBufferedFrameBytes {
                        state.bufferedBytes += bb.readableBytes
                        state.buffered.append(bb)
                    } else {
                        print(">>> Pre-open buffer cap exceeded; closing connection")
                        state.isRefused = true
                        state.buffered.removeAll()
                        state.bufferedBytes = 0
                        ws.pingInterval = .seconds(5)
                        _ = ws.close(code: .policyViolation)
                    }
                }
                ws.onClose.whenComplete { _ in
                    Task {
                        if let channelId = state.channelId {
                            await sockets.remove(socket: ws, channelId: channelId)
                        }
                        // Observer push: drop this socket's subscription
                        // (idempotent — the pump's send-failure path may have
                        // beaten us here). Group teardown when the last
                        // subscriber leaves happens inside the manager, with
                        // the watcher released off-loop.
                        if let sub = state.pushSubscription {
                            await watchManager?.unsubscribe(sub)
                        }
                        // Detach the per-connection lattice ON the loop (state
                        // is loop-confined) but RELEASE it OFF the loop:
                        // ~lattice_db tears down sync threads, and running
                        // that inline in `execute` stalls the shared event
                        // loop for every other connection (observed as
                        // time-limit storms in the in-process relay tests).
                        ws.eventLoop.execute {
                            // Stop the apply pipeline: finish drains the
                            // stream; the consumer exits after the in-flight
                            // apply (revocation gates any queued remainder).
                            state.applyContinuation?.finish()
                            state.applyContinuation = nil
                            state.applyConsumer = nil
                            let box = state.lattice.map(UnsafeSendableBox.init)
                            state.lattice = nil
                            state.process = nil
                            state.buffered.removeAll()
                            state.bufferedBytes = 0
                            if let box {
                                Task.detached { box.clear() }
                            }
                        }
                    }
                }
            }

            // Schema handshake: version skew closes with an explicit,
            // attributable reason instead of the silent apply-wedge class.
            if let refusal = handshake?.refusal(for: req) {
                print(">>> Sync handshake refused: \(refusal)")
                state.isRefused = true
                try? await ws.send("schema-handshake: \(refusal)")
                ws.pingInterval = .seconds(5)   // drop a peer that ignores the close
                try? await ws.close(code: .policyViolation)
                return
            }

            let channel: SyncChannel
            do {
                channel = try await channelExtractor(req)
            } catch {
                print(">>> Could not authorize sync connection: \(error)")
                state.isRefused = true
                ws.pingInterval = .seconds(5)
                try? await ws.close()
                return
            }

            // Defense in depth against path traversal: channel ids commonly
            // embed request-controlled path parameters (Vapor percent-decodes
            // them, so an encoded `../` can reach here past an extractor that
            // forgot to validate). The database name must be a single path
            // component inside storageURL.
            guard !channel.databaseFileName.isEmpty,
                  !channel.databaseFileName.contains("/"),
                  !channel.databaseFileName.contains("\\"),
                  !channel.databaseFileName.hasPrefix(".") else {
                print(">>> Refusing unsafe database filename for channel \(channel.id)")
                state.isRefused = true
                ws.pingInterval = .seconds(5)
                try? await ws.close(code: .policyViolation)
                return
            }

            try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

            let latticeURL: URL? = storageURL
                .appending(path: channel.databaseFileName)
            // Apply-serialization key: the SAME canonical channel-file key
            // the observer-push watch groups use, so two mounts over one file
            // (writer + watch, or two writer mounts) share one apply queue
            // rather than inventing a second path normalization. The
            // channel-id fallback is unreachable in practice (the URL is
            // always built above) and only exists so the key is never empty.
            let applyKey = latticeURL.map { FileWatchManager.canonicalKey(for: $0) }
                ?? "channel:\(channel.id)"

            @Sendable func processFrame(_ ws: WebSocket, _ bb: ByteBuffer, _ lattice: Lattice) async {
                // Authoritative revocation: a kicked connection stops
                // affecting the channel immediately, even if its transport
                // lingers because the peer never answered the close frame.
                guard !state.revocation.isRevoked else { return }
                let data = Data(buffer: bb)
                // ONE parse for the whole path: the write-policy gate reads
                // it, and so does the shortfall diff below (which globalIds
                // did this frame ask us to store?).
                let frame = RelayFrame(data)
                // Write-policy gate: a violating frame is refused whole —
                // not applied, not fanned out, its entries left unACKed.
                if let policy = writePolicy, let reason = policy.violation(inFrame: frame) {
                    print(">>> Sync frame rejected on \(channel.id): \(reason)")
                    if let encoded = try? JSONEncoder().encode(ServerSentEvent.rejected(reason: reason)) {
                        ws.send(ByteBuffer(data: encoded))
                    }
                    return
                }

                // Per-FILE serialization + bounded busy retry. Every write
                // through this relay — uploads AND the catch-up ack
                // bookkeeping, which is also a BEGIN + UPDATE burst
                // (`mark_audit_entries_synced`) — queues on the channel
                // file's apply slot, so concurrent connections take turns
                // instead of burning each other's busy budget inside
                // `begin_transaction` on the ONE shared, serialized SQLite
                // connection they all alias.
                let outcome = await withApplyLock(applyKey) {
                    applyWithRetry(lattice: lattice, data: data, frame: frame,
                                   channelId: channel.id, userId: channel.userId)
                }

                // B3.8: never ack an empty apply — in particular incoming
                // ACK frames used to be re-acked (ack-of-ack ping-pong, one
                // empty bookkeeping round trip per client download ack,
                // forever).
                if !outcome.applied.isEmpty,
                   let encoded = try? JSONEncoder().encode(ServerSentEvent.ack(outcome.applied)) {
                    ws.send(ByteBuffer(data: encoded))
                }

                // The silent-drop hole, closed. Before 1.7.1 a frame whose
                // apply came back short produced NOTHING: no ack (the id list
                // was empty), no nack (there was no nack), and no log line
                // (nothing threw, so the print-only catch never ran). Now the
                // shortfall is loud and the client is told exactly which
                // entries to resend.
                if !outcome.unapplied.isEmpty {
                    relayLog.error("""
                        relay apply INCOMPLETE: channel=\(channel.id) user=\(channel.userId) \
                        sqlite=\(outcome.errorClass.rawValue) frameBytes=\(frame.byteCount) \
                        requested=\(frame.requestedIds.count) applied=\(outcome.applied.count) \
                        unapplied=\(outcome.unapplied.count) attempts=\(outcome.attempts) \
                        elapsedMs=\(Int(outcome.elapsedMs)) — nacking\
                        \(outcome.lastError.map { " error=\($0)" } ?? "")
                        """)
                    if let encoded = try? JSONEncoder().encode(
                        ServerSentEvent.nack(ids: outcome.unapplied, reason: outcome.nackReason)) {
                        ws.send(ByteBuffer(data: encoded))
                    }
                } else if let error = outcome.lastError {
                    if frame.root == nil || frame.claimsUpload {
                        // An UPLOAD this relay could not parse (or whose
                        // entries yielded no extractable globalIds) failed
                        // terminally. There is nothing to nack BY ID — and
                        // this used to log as bookkeeping noise while the
                        // sender's entries were LOST. Be loud and CLOSE: a
                        // native writer redials and resends; a browser
                        // writer at least sees the break instead of a
                        // healthy socket over a dropped frame.
                        relayLog.error("""
                            relay apply failed on a frame it could not parse as an upload: \
                            channel=\(channel.id) user=\(channel.userId) \
                            sqlite=\(outcome.errorClass.rawValue) frameBytes=\(frame.byteCount) \
                            attempts=\(outcome.attempts) elapsedMs=\(Int(outcome.elapsedMs)) \
                            — closing so the client redials error=\(error)
                            """)
                        try? await ws.close(code: .unexpectedServerError)
                    } else {
                        // A non-upload frame (an ack's bookkeeping write) that
                        // failed: nothing to nack — the client's entries are
                        // already durable — but never silent.
                        relayLog.warning("""
                            relay bookkeeping apply failed: channel=\(channel.id) \
                            user=\(channel.userId) sqlite=\(outcome.errorClass.rawValue) \
                            frameBytes=\(frame.byteCount) attempts=\(outcome.attempts) \
                            elapsedMs=\(Int(outcome.elapsedMs)) error=\(error)
                            """)
                    }
                }

                // Legacy same-channel fan-out — unchanged on mounts without
                // observer push (writer mounts keep verbatim fan-out
                // byte-for-byte on the healthy path). On push-enabled mounts
                // it is skipped entirely: delivery is the pump's job
                // (commit-ordered, cursor-deduped), uploads are policy-refused
                // anyway, and fanning every frame would echo each observer's
                // ack to every other observer — N² frames per commit.
                //
                // Fan out ONLY what the channel database actually holds. A
                // frame that failed to apply used to be fanned out anyway:
                // live peers applied entries the relay store never got, so
                // catch-up replay could never deliver them to anyone who
                // reconnected or joined later — permanent divergence between
                // live observers and the channel of record (program-plan
                // sync-M7, reproduced during this incident). A PARTIAL apply
                // fans the applied subset; a total failure fans nothing.
                guard watchManager == nil else { return }
                let fanOut: ByteBuffer?
                if outcome.isComplete {
                    fanOut = bb
                } else if !outcome.applied.isEmpty,
                          let reduced = frame.reencoded(keeping: Set(outcome.applied)) {
                    fanOut = ByteBuffer(data: reduced)
                } else {
                    fanOut = nil
                }
                guard let fanOut else { return }
                for socket in await sockets.sockets(channelId: channel.id) where socket !== ws {
                    socket.send(fanOut)
                }
            }

            // Register BEFORE the slow lattice open (kick-race fix): a
            // revocation during the open window can now see — and close —
            // this socket. Fan-out frames sent to a pre-open socket are fine
            // (the client applies them independently of our open state).
            // channelId publishes to the loop first so a kick-triggered
            // onClose can always deregister.
            state.channelId = channel.id
            await sockets.add(socket: ws, channelId: channel.id,
                              userId: channel.userId, revocation: state.revocation)
            // A socket that closed while the extractor was awaiting ran its
            // onClose with channelId still nil and deregistered nothing —
            // without this it would sit in the registry for the process
            // lifetime, retaining a dead socket and slowing every fan-out.
            if ws.isClosed {
                await sockets.remove(socket: ws, channelId: channel.id)
                return
            }

            // The ONLY per-connection open. `storeConfiguration` lets the
            // mount open files another writer created at a higher schema
            // version; the default raw open targets version 1 and would
            // refuse them (the "Could not open lattice for url" close-1001
            // class on projector-owned channel files). The relay's bounded
            // busy budget is layered on top (2s instead of the library's 30s)
            // unless the mount asked for a specific one — a live socket must
            // never park half a minute inside one `BEGIN IMMEDIATE`.
            let configuration = SyncRelayApplyPolicy.configuration(
                fileURL: latticeURL, storeConfiguration: storeConfiguration)
            guard let connectionLattice = try? Lattice(for: schema, configuration: configuration) else {
                print(">>> Could not open lattice for url: \(String(describing: latticeURL))")
                await sockets.remove(socket: ws, channelId: channel.id)
                try? await ws.close()
                return
            }
            let held = UnsafeSendableBox(connectionLattice)

            // Observer push: register a PARKED subscription now — BEFORE the
            // go-live hop and the catch-up snapshot below. The commit
            // observer is live from this point, so no commit can fall
            // between the snapshot and the watch: anything that lands during
            // catch-up buffers as a `dirty` nudge and activation's first
            // pump (which reads strictly beyond the catch-up boundary) picks
            // it up — no gaps, no dupes, in order. A nil subscription
            // (watcher open failure) leaves this socket catch-up-only.
            if let watchManager, let pushContext, let latticeURL {
                state.pushSubscription = await watchManager.subscribe(
                    fileURL: latticeURL, context: pushContext,
                    socket: ws, revocation: state.revocation)
            }

            // Go live: replay anything that arrived during the open, in
            // order, then hand subsequent frames straight to the lattice.
            // If a revocation closed this socket while we were opening,
            // abandon: never install the lattice on a dead connection
            // (onClose has already run its cleanup, which found nil).
            ws.eventLoop.execute {
                guard !ws.isClosed, !state.revocation.isRevoked else {
                    state.buffered.removeAll()
                    state.bufferedBytes = 0
                    // The catch-up task below force-unwraps `held.value`;
                    // clearing here would trap it. Mark abandoned instead
                    // and let the catch-up guard release it.
                    state.abandoned = true
                    return
                }
                state.process = processFrame
                // B3.2: applies run on a per-connection serial consumer, OFF
                // the event loop — one slow apply no longer blocks every
                // other socket on this loop (the client made the same move in
                // sync.cpp:1053 long ago). Ordering is preserved: one
                // consumer, frames yielded in arrival order, ack + fan-out
                // still happen inside processFrame after the apply commits.
                let lattice = held.value
                let (stream, cont) = AsyncStream<ByteBuffer>.makeStream()
                state.applyContinuation = cont
                state.applyConsumer = Task.detached {
                    for await frame in stream {
                        guard !state.revocation.isRevoked else { continue }
                        await processFrame(ws, frame, lattice)
                        let n = frame.readableBytes
                        ws.eventLoop.execute { state.queuedApplyBytes -= n }
                    }
                }
                for bb in state.buffered {
                    state.queuedApplyBytes += bb.readableBytes
                    cont.yield(bb)
                }
                state.buffered.removeAll()
                state.bufferedBytes = 0
                state.lattice = held.value
                // Keepalive on the healthy path (until here pings only ran on
                // kick/refusal). An idle-but-healthy connection otherwise sends
                // nothing, and intermediaries cut it: Cloudflare's proxied-WS
                // idle timeout is ~100s, AWS NLBs 340s. Browsers answer
                // protocol pings automatically, so this keeps traffic flowing
                // both ways for every client class — and gives the relay
                // dead-peer detection it previously got only on kicks.
                ws.pingInterval = .seconds(30)
            }

            // Catch-up AFTER handlers are live. Incoming frames during
            // catch-up serialize through the same per-channel lattice.
            do {
                try await Task {
                    // The go-live hop hands ownership here when it abandons:
                    // release the opened lattice off-loop and do not touch
                    // `held.value` again. A parked push subscription is
                    // dropped too — it would otherwise never activate.
                    if state.abandoned {
                        Task.detached { held.clear() }
                        if let sub = state.pushSubscription {
                            await watchManager?.unsubscribe(sub)
                        }
                        return
                    }
                    guard !ws.isClosed, !state.revocation.isRevoked else {
                        if let sub = state.pushSubscription {
                            await watchManager?.unsubscribe(sub)
                        }
                        return
                    }
                    let lattice = held.value

                    // TEST-ONLY fault injection (nil in production): proves
                    // the catch block below releases a parked subscription.
                    if let fault = _catchUpFaultForTesting.withLockedValue({ $0 }) {
                        try fault(channel.id)
                    }

                    let lastEventId = try? req.query.get(UUID?.self, at: "last-event-id")
                    let events = lattice.eventsAfter(globalId: lastEventId)
                    let count = events.count
                    // Observer-push activation boundary: the pk of the last
                    // catch-up entry this socket was sent, taken from the
                    // SAME results object (a separate MAX(id) read could
                    // skew against concurrent commits — dupe/skip window);
                    // else the checkpoint entry's pk when the client was
                    // already up to date; else 0 on an empty log. The first
                    // pump reads strictly beyond it.
                    var boundary: Int64 = 0
                    if count > 0 {
                        print(">>> Bringing channel \(channel.id) connection up to date with \(count) events")
                        for i in stride(from: 0, to: count, by: 1000) {
                            guard !state.revocation.isRevoked else { break }
                            let page = Array(events[i..<min(count, i + 1000)])
                            let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(page))
                            await ws.send(ByteBuffer(data: encoded))
                            boundary = page.last?.primaryKey ?? boundary
                        }
                    } else if let lastEventId, state.pushSubscription != nil {
                        // The boundary only feeds push activation — legacy
                        // mounts (and sockets whose watcher open failed)
                        // skip this SELECT entirely rather than paying it
                        // on every redial for a value nobody reads.
                        boundary = lattice.objects(AuditLog.self)
                            .where { $0.globalId == lastEventId }
                            .snapshot(limit: 1)
                            .first?.primaryKey ?? 0
                    }
                    // Activate push (cursor = catch-up boundary) — or drop
                    // the parked subscription if this socket died/was
                    // revoked during catch-up.
                    if let sub = state.pushSubscription {
                        if state.revocation.isRevoked || ws.isClosed {
                            await watchManager?.unsubscribe(sub)
                        } else {
                            await watchManager?.activate(sub, cursor: boundary)
                        }
                    }
                }.value
            } catch {
                print("Error bringing channel connection up to date: \(error.localizedDescription)")
                // A throw here (encode failure, a send that fails mid-page)
                // used to leave the push subscription PARKED: never
                // activated, never unsubscribed. That pins the file's watch
                // group — and its watcher `Lattice` — alive for the process
                // lifetime on a socket that can never receive a pushed frame
                // (no cursor), while the socket itself stayed OPEN so the
                // client's redial fallback never fired either: a
                // permanently silent observer plus a leaked watcher per
                // occurrence. Release the subscription, then close, so the
                // client redials and re-runs catch-up from its
                // last-event-id.
                if let sub = state.pushSubscription {
                    state.pushSubscription = nil
                    await watchManager?.unsubscribe(sub)
                }
                ws.pingInterval = .seconds(5)   // drop a peer that ignores the close
                try? await ws.close(code: .unexpectedServerError)
            }
        }
        return SyncRelayHandle(manager: sockets, pushManager: watchManager)
    }

    /// Personal-topology wrapper preserving the original API and on-disk
    /// layout: each user is their own channel, stored as `<userId>.sqlite`.
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        for schema: [any Lattice.Model.Type],
        storageURL: URL,
        userIdExtractor: @escaping @Sendable (Request) throws -> UUID
    ) {
        _ = configureSyncRelay(
            on: routes,
            path: ["sync"],
            for: schema,
            storageURL: storageURL
        ) { req in
            let userId = try userIdExtractor(req)
            return SyncChannel(id: userId.uuidString, userId: userId)
        }
    }
}

extension Data: DataProtocol {
}


/// Holds a non-Sendable value captured by the relay's @Sendable socket
/// callbacks. Access is serialized by the connection's event loop; `clear()`
/// releases on close.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    private var stored: T?
    init(_ value: T) { self.stored = value }
    var value: T { stored! }
    /// Non-trapping read for callers that can lose a release race and must
    /// exit cleanly instead (the observer-push pump path): `nil` after
    /// `clear()`.
    var valueIfPresent: T? { stored }
    func clear() { stored = nil }
}

/// Per-connection relay state. All access is confined to the socket's event
/// loop (handler bodies and the `execute` hops that mutate it), so the
/// unchecked-Sendable is a loop-confinement claim, not a locking one.
/// `lattice == nil` means "still opening": frames buffer in arrival order
/// and are replayed the moment the per-channel lattice goes live.
final class ConnectionRelayState: @unchecked Sendable {
    var lattice: Lattice?
    /// Installed at go-live: the frame processor bound to this connection's
    /// channel (handlers register before the channel is known).
    var process: ((WebSocket, ByteBuffer, Lattice) async -> Void)?
    var buffered: [ByteBuffer] = []
    var bufferedBytes: Int = 0

    /// Post-go-live apply pipeline (B3.2): frames are enqueued from the event
    /// loop and applied by ONE detached consumer per connection, so a slow
    /// apply no longer stalls every other socket sharing the loop. The
    /// continuation and queued-byte counter are loop-confined like the rest
    /// of the mutable state; the consumer task touches neither — it receives
    /// everything it needs as captured arguments and re-checks `revocation`
    /// (lock-backed) at dequeue.
    var applyContinuation: AsyncStream<ByteBuffer>.Continuation?
    var applyConsumer: Task<Void, Never>?
    var queuedApplyBytes: Int = 0

    /// Late-bound channel id. Written on the event loop, READ from the
    /// detached onClose task — so it lives in a lock, not in loop
    /// confinement. nil = never registered with the SocketManager.
    private let channelIdBox = NIOLockedValueBox<String?>(nil)
    var channelId: String? {
        get { channelIdBox.withLockedValue { $0 } }
        set { channelIdBox.withLockedValue { $0 = newValue } }
    }

    /// Set by the SocketManager on revocation; consulted before any apply,
    /// ack, or fan-out (the close frame alone is not authoritative).
    let revocation = RevocationFlag()

    /// Observer-push subscription (push-enabled mounts only). Written by the
    /// handler task after the per-connection open, READ from the detached
    /// onClose task — lock-backed like `channelId`, not loop-confined.
    /// nil = never subscribed (legacy mount, or watcher open failure).
    private let pushSubscriptionBox = NIOLockedValueBox<PushSubscription?>(nil)
    var pushSubscription: PushSubscription? {
        get { pushSubscriptionBox.withLockedValue { $0 } }
        set { pushSubscriptionBox.withLockedValue { $0 = newValue } }
    }

    /// Set when the connection is refused (handshake/authorization/unsafe
    /// name): the binary handler then discards instead of buffering, so a
    /// peer that ignores the close frame cannot pin memory.
    private let refusedBox = NIOLockedValueBox<Bool>(false)
    var isRefused: Bool {
        get { refusedBox.withLockedValue { $0 } }
        set { refusedBox.withLockedValue { $0 = newValue } }
    }

    /// Set on the go-live hop when the connection died (or was revoked)
    /// during the lattice open. The catch-up task, which force-unwraps the
    /// opened lattice's box, checks this and releases instead — clearing
    /// the box from the go-live hop itself would trap that unwrap.
    private let abandonedBox = NIOLockedValueBox<Bool>(false)
    var abandoned: Bool {
        get { abandonedBox.withLockedValue { $0 } }
        set { abandonedBox.withLockedValue { $0 = newValue } }
    }
}

/// Cap on frames held during the pre-go-live window. Generous for a real
/// client's opening burst, bounded against a peer that streams into a
/// connection that will never go live.
private let maxBufferedFrameBytes = 64 * 1024 * 1024

/// TEST-ONLY (internal — `@testable` reach only) fault injection for the
/// connect-time catch-up error path, which is otherwise unreachable from a
/// test: nothing a client can send makes the catch-up encode or send throw
/// on demand. When non-nil it is called once per connection at the top of
/// the catch-up task — AFTER the parked push subscription is registered,
/// BEFORE any frame is sent — with that connection's channel id, so a test
/// can scope the fault to its own channel (this box is process-global and
/// suites run in parallel). Nil in production: one lock-protected read per
/// connection, alongside the catch-up query.
let _catchUpFaultForTesting = NIOLockedValueBox<(@Sendable (String) throws -> Void)?>(nil)
