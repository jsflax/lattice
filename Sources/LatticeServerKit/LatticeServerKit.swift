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
/// Tables absent from `allowedOperations` are unrestricted. A violating
/// frame is answered with `ServerSentEvent.rejected(reason:)` and dropped
/// whole — nothing applied, nothing fanned out, entries left unACKed.
public struct SyncWritePolicy: Sendable {
    public enum Operation: String, Sendable, CaseIterable {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }

    /// tableName → operations allowed on that table.
    public var allowedOperations: [String: Set<Operation>]
    /// Optional cap on DELETE entries per frame across ALL tables — a
    /// mass-deletion brake that still admits legitimate single-row
    /// retractions on tables whose policy allows deletes.
    public var maxDeletesPerFrame: Int?

    public init(allowedOperations: [String: Set<Operation>], maxDeletesPerFrame: Int? = nil) {
        self.allowedOperations = allowedOperations
        self.maxDeletesPerFrame = maxDeletesPerFrame
    }

    /// First violation in the frame, or nil when the frame passes. Frames
    /// that are not audit-log uploads (acks etc.) pass untouched; a frame
    /// that fails to parse as JSON also passes — `Lattice.receive` is the
    /// authority on malformed input and will surface its own error.
    func violation(inFrame data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["auditLog"] as? [[String: Any]]
        else { return nil }

        var deleteCount = 0
        for entry in entries {
            guard
                let table = entry["tableName"] as? String,
                let opRaw = entry["operation"] as? String
            else { continue }
            let op = Operation(rawValue: opRaw)
            if op == .delete { deleteCount += 1 }
            if let allowed = allowedOperations[table] {
                guard let op, allowed.contains(op) else {
                    return "operation \(opRaw) not permitted on \(table) for this channel"
                }
            }
            if let cap = maxDeletesPerFrame, deleteCount > cap {
                return "frame exceeds the \(cap)-delete limit for this channel"
            }
        }
        return nil
    }
}

// MARK: - Schema handshake

/// Declared-version gate at connect time. When configured, a client whose
/// `headerName` header is missing (if required) or below `minimumVersion`
/// is answered with a human-readable text frame and a policy-violation
/// close — a visible, attributable error instead of a silent apply-wedge
/// when wire schemas drift (the W1.0 failure class).
public struct SyncSchemaHandshake: Sendable {
    public var headerName: String
    public var minimumVersion: Int
    /// When false, clients that send no header at all are admitted (legacy
    /// tolerance); a header that is present but unparsable/low still closes.
    public var requireHeader: Bool

    public init(headerName: String = "X-Lattice-Schema", minimumVersion: Int, requireHeader: Bool = true) {
        self.headerName = headerName
        self.minimumVersion = minimumVersion
        self.requireHeader = requireHeader
    }

    /// Reason to refuse this request, or nil to admit.
    func refusal(for req: Request) -> String? {
        guard let raw = req.headers.first(name: headerName) else {
            return requireHeader
                ? "missing \(headerName) header (server requires schema >= \(minimumVersion))"
                : nil
        }
        guard let version = Int(raw) else {
            return "unparsable \(headerName) header '\(raw)'"
        }
        guard version >= minimumVersion else {
            return "client schema \(version) below server minimum \(minimumVersion) — upgrade required"
        }
        return nil
    }
}

// MARK: - Socket registry

actor SocketManager {
    struct Entry {
        let socket: WebSocket
        let userId: UUID
    }

    private var channels: [String: [Entry]] = [:]

    func sockets(channelId: String) -> [WebSocket] {
        channels[channelId, default: []].map(\.socket)
    }

    func connectionCount(channelId: String) -> Int {
        reap(channelId: channelId)
        return channels[channelId, default: []].count
    }

    func add(socket: WebSocket, channelId: String, userId: UUID) {
        reap(channelId: channelId)
        channels[channelId, default: []].append(Entry(socket: socket, userId: userId))
    }

    func remove(socket: WebSocket, channelId: String) {
        channels[channelId]?.removeAll { $0.socket === socket }
    }

    private func reap(channelId: String) {
        channels[channelId]?.removeAll { $0.socket.isClosed }
    }

    /// Close + deregister one user's live sockets on a channel (membership
    /// revocation). Sockets registered pre-open are included — closing them
    /// makes the relay's post-open `isClosed` check abandon the connection.
    func disconnect(channelId: String, userId: UUID) {
        for entry in channels[channelId, default: []] where entry.userId == userId {
            _ = entry.socket.close(code: .goingAway)
        }
        channels[channelId]?.removeAll { $0.userId == userId }
    }

    /// Close + deregister every socket on a channel (group deletion; also
    /// the post-purge nudge that forces reconnect-and-catch-up).
    func disconnectAll(channelId: String) {
        for entry in channels[channelId, default: []] {
            _ = entry.socket.close(code: .goingAway)
        }
        channels[channelId] = nil
    }
}

/// Operational handle over a configured relay: revocation kicks and
/// visibility. Returned by `configureSyncRelay`; safe to hold anywhere.
public struct SyncRelayHandle: Sendable {
    let manager: SocketManager

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
    ///   - channelExtractor: Maps the request to its `SyncChannel`
    @discardableResult
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        path: [PathComponent] = ["sync"],
        for schema: [any Lattice.Model.Type],
        storageURL: URL,
        writePolicy: SyncWritePolicy? = nil,
        handshake: SyncSchemaHandshake? = nil,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel
    ) -> SyncRelayHandle {
        let sockets = SocketManager()
        nonisolated(unsafe) let schema = schema
        routes.webSocket(path, maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 300 * 1024 * 1024)) { req, ws in
            // Schema handshake FIRST: version skew closes with an explicit,
            // attributable reason instead of the silent apply-wedge class.
            if let refusal = handshake?.refusal(for: req) {
                print(">>> Sync handshake refused: \(refusal)")
                try? await ws.send("schema-handshake: \(refusal)")
                try? await ws.close(code: .policyViolation)
                return
            }

            let channel: SyncChannel
            do {
                channel = try await channelExtractor(req)
            } catch {
                print(">>> Could not authorize sync connection: \(error)")
                try? await ws.close()
                return
            }

            try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

            let latticeURL: URL? = storageURL
                .appending(path: channel.databaseFileName)

            // Per-connection state, confined to the socket's event loop.
            // Frames that arrive before the (slow — schema ensure, epoch
            // migrations) per-channel lattice open finishes are BUFFERED and
            // replayed in arrival order the moment it's live. Previously the
            // open ran before handler registration, and WebSocketKit silently
            // drops frames with no onBinary registered — a client that
            // uploaded within the open window lost that frame, its entries
            // sat unACKed until the resend/reconnect, and the relay tests
            // that await that first delivery hung (the intermittent CI hang
            // class). ONE lattice per connection, held for the socket's
            // lifetime (a fresh Lattice per frame raced the weak instance
            // cache and segfaulted under real bursts — exit 139).
            let state = ConnectionRelayState()

            @Sendable func processFrame(_ ws: WebSocket, _ bb: ByteBuffer, _ lattice: Lattice) {
                let data = Data(buffer: bb)
                // Write-policy gate: a violating frame is refused whole —
                // not applied, not fanned out, its entries left unACKed.
                if let policy = writePolicy, let reason = policy.violation(inFrame: data) {
                    print(">>> Sync frame rejected on \(channel.id): \(reason)")
                    if let encoded = try? JSONEncoder().encode(ServerSentEvent.rejected(reason: reason)) {
                        ws.send(ByteBuffer(data: encoded))
                    }
                    return
                }
                do {
                    let globalIds = try lattice.receive(data)
                    ws.send(try JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                } catch {
                    print("Error:", error)
                }
                Task {
                    for socket in await sockets.sockets(channelId: channel.id) where socket !== ws {
                        socket.send(bb)
                    }
                }
            }

            // Handlers go live FIRST — synchronously on the socket's event
            // loop, before the lattice open. The sync onBinary body keeps
            // receive() strictly frame-ordered on the loop.
            ws.eventLoop.execute {
                ws.onText { ws, str in
                    print("🧦", "Received String Event", str)
                }
                ws.onBinary { ws, bb in
                    if let lattice = state.lattice {
                        processFrame(ws, bb, lattice)
                    } else {
                        state.buffered.append(bb)
                    }
                }
                ws.onClose.whenComplete { _ in
                    Task {
                        await sockets.remove(socket: ws, channelId: channel.id)
                        // Detach the per-connection lattice ON the loop (state
                        // is loop-confined) but RELEASE it OFF the loop:
                        // ~lattice_db tears down sync threads, and running
                        // that inline in `execute` stalls the shared event
                        // loop for every other connection (observed as
                        // time-limit storms in the in-process relay tests).
                        ws.eventLoop.execute {
                            let box = state.lattice.map(UnsafeSendableBox.init)
                            state.lattice = nil
                            state.buffered.removeAll()
                            if let box {
                                Task.detached { box.clear() }
                            }
                        }
                    }
                }
            }

            // Register BEFORE the slow lattice open (kick-race fix): a
            // revocation during the open window can now see — and close —
            // this socket. Fan-out frames sent to a pre-open socket are fine
            // (the client applies them independently of our open state).
            await sockets.add(socket: ws, channelId: channel.id, userId: channel.userId)

            guard let connectionLattice = try? Lattice(for: schema, configuration: .init(fileURL: latticeURL)) else {
                print(">>> Could not open lattice for url: \(String(describing: latticeURL))")
                await sockets.remove(socket: ws, channelId: channel.id)
                try? await ws.close()
                return
            }
            let held = UnsafeSendableBox(connectionLattice)

            // Go live: replay anything that arrived during the open, in
            // order, then hand subsequent frames straight to the lattice.
            // If a revocation closed this socket while we were opening,
            // abandon: never install the lattice on a dead connection
            // (onClose has already run its cleanup, which found nil).
            ws.eventLoop.execute {
                guard !ws.isClosed else {
                    state.buffered.removeAll()
                    Task.detached { held.clear() }
                    return
                }
                for bb in state.buffered { processFrame(ws, bb, held.value) }
                state.buffered.removeAll()
                state.lattice = held.value
            }

            // Catch-up AFTER handlers are live. Incoming frames during
            // catch-up serialize through the same per-channel lattice.
            do {
                try await Task {
                    guard !ws.isClosed else { return }
                    let lattice = held.value

                    let events = lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
                    let count = events.count
                    if count > 0 {
                        print(">>> Bringing channel \(channel.id) connection up to date with \(count) events")
                        for i in stride(from: 0, to: count, by: 1000) {
                            let page = events[i..<min(count, i + 1000)]
                            let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(page)))
                            await ws.send(ByteBuffer(data: encoded))
                        }
                    }
                }.value
            } catch {
                print("Error bringing channel connection up to date: \(error.localizedDescription)")
            }
        }
        return SyncRelayHandle(manager: sockets)
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
    func clear() { stored = nil }
}

/// Per-connection relay state. All access is confined to the socket's event
/// loop (handler bodies and the `execute` hops that mutate it), so the
/// unchecked-Sendable is a loop-confinement claim, not a locking one.
/// `lattice == nil` means "still opening": frames buffer in arrival order
/// and are replayed the moment the per-channel lattice goes live.
final class ConnectionRelayState: @unchecked Sendable {
    var lattice: Lattice?
    var buffered: [ByteBuffer] = []
}
