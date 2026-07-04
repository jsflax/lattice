import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

actor SocketManager {
    var sockets: [UUID: [WebSocket]] = [:]

    func sockets(for uuid: UUID) -> [WebSocket] {
        sockets[uuid, default: []]
    }

    func remove(socket: WebSocket, for uuid: UUID) {
        _ = sockets[uuid]?.firstIndex(where: {
            $0 === socket
        }).map {
            sockets[uuid, default: []].remove(at: $0)
        }
    }

    func add(socket: WebSocket, for uuid: UUID) {
        reap(for: uuid)
        sockets[uuid, default: []].append(socket)
    }

    func reap(for uuid: UUID) {
        for socket in sockets[uuid, default: []] {
            if socket.isClosed {
                remove(socket: socket, for: uuid)
            }
        }
    }
}


extension Lattice {
    /// Configures the sync relay WebSocket endpoint on the given route group.
    ///
    /// This is the only thing LatticeServerKit provides — auth, migrations, and route setup
    /// are the responsibility of the consuming application.
    ///
    /// - Parameters:
    ///   - routes: A `RoutesBuilder` (typically already protected by auth middleware)
    ///   - schema: The Lattice model types to sync
    ///   - storageURL: Directory URL for per-user databases. Created if it doesn't exist.
    ///   - userIdExtractor: Closure that extracts the authenticated user's UUID from the request
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        for schema: [any Lattice.Model.Type],
        storageURL: URL,
        userIdExtractor: @escaping @Sendable (Request) throws -> UUID
    ) {
        let sockets = SocketManager()
        nonisolated(unsafe) let schema = schema
        routes.webSocket("sync", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 300 * 1024 * 1024)) { req, ws in
            let userId: UUID
            do {
                userId = try userIdExtractor(req)
            } catch {
                print(">>> Could not authenticate user for sync: \(error)")
                try? await ws.close()
                return
            }

            try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

            let latticeURL: URL? = storageURL
                .appending(path: "\(userId.uuidString).sqlite")

            // ONE lattice per connection, opened before the handlers and held
            // for the socket's lifetime. The previous shape opened a fresh
            // Lattice inside EVERY onBinary invocation: under a real upload
            // burst (hundreds of frames landing on event-loop threads) the
            // weak instance cache raced open/dealloc across threads and the
            // production relay segfaulted (exit 139) seconds after a client
            // with a backlog connected.
            guard let connectionLattice = try? Lattice(for: schema, configuration: .init(fileURL: latticeURL)) else {
                print(">>> Could not open lattice for url: \(String(describing: latticeURL))")
                try? await ws.close()
                return
            }
            let held = UnsafeSendableBox(connectionLattice)

            // Register frame handlers BEFORE any await: clients upload their
            // pending entries immediately on connect, and any frame that
            // arrives before onBinary is registered is silently dropped by
            // WebSocketKit. The old order (catch-up first, handlers after)
            // lost the first upload of a fresh connection whenever the
            // per-user lattice open + eventsAfter took longer than the
            // client's connect→upload turnaround — the entry then sat
            // unACKed until the next reconnect. Registration must run on the
            // socket's event loop (NIOLoopBound), hence the execute hop.
            ws.eventLoop.execute {
                ws.onText { ws, str in
                    print("🧦", "Received String Event", str)
                }
                ws.onBinary { ws, bb in
                    do {
                        let globalIds = try held.value.receive(Data(buffer: bb))
                        ws.send(try JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    } catch {
                        print("Error:", error)
                    }

                    for socket in await sockets.sockets(for: userId) where socket !== ws {
                        socket.send(bb)
                    }
                }
                ws.onClose.whenComplete { _ in
                    Task {
                        await sockets.remove(socket: ws, for: userId)
                        // Release the per-connection lattice with the socket.
                        held.clear()
                    }
                }
            }
            await sockets.add(socket: ws, for: userId)

            // Catch-up AFTER handlers are live. Incoming frames during
            // catch-up serialize through the same per-user lattice.
            do {
                try await Task {
                    let lattice = held.value

                    let events = lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
                    let count = events.count
                    if count > 0 {
                        print(">>> Bringing user up to date with \(count) events")
                        for i in stride(from: 0, to: count, by: 1000) {
                            let page = events[i..<min(count, i + 1000)]
                            let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(page)))
                            await ws.send(ByteBuffer(data: encoded))
                        }
                    }
                }.value
            } catch {
                print("Error bringing user up to date: \(error.localizedDescription)")
            }
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
