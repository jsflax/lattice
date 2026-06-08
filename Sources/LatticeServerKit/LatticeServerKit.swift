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
            
            do {
                try await Task {
                    guard let lattice = try? Lattice(for: schema, configuration: .init(fileURL: latticeURL)) else {
                        print(">>> Could not open lattice for url: \(String(describing: latticeURL))")
                        try? await ws.close()
                        return
                    }
                    
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
            
            await sockets.add(socket: ws, for: userId)
            ws.eventLoop.execute {
                ws.onText { ws, str in
                    print("🧦", "Received String Event", str)
                    print(str)
                }
                ws.onBinary { ws, bb in
                    print("🧦", "Received Binary Event")

                    guard let lattice = try? Lattice(for: schema, configuration: .init(fileURL: latticeURL)) else {
                        print(">>> Could not open lattice for url: \(String(describing: latticeURL))")
                        try? await ws.close()
                        return
                    }
                    
                    do {
                        let globalIds = try lattice.receive(Data(buffer: bb))
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
                    }
                }
            }
        }
    }
}

extension Data: DataProtocol {
}
