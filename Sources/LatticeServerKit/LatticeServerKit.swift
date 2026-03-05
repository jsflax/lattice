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
    ///   - storagePath: Subdirectory under Application Support for per-user databases
    ///   - userIdExtractor: Closure that extracts the authenticated user's UUID from the request
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        for schema: [any Lattice.Model.Type],
        storagePath: String,
        userIdExtractor: @escaping @Sendable (Request) throws -> UUID
    ) {
        let sockets = SocketManager()

        routes.webSocket("sync", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 300 * 1024 * 1024)) { req, ws in
            let userId: UUID
            do {
                userId = try userIdExtractor(req)
            } catch {
                print(">>> Could not authenticate user for sync: \(error)")
                try? await ws.close()
                return
            }

            try? FileManager.default.createDirectory(at: FileManager.default.url(for: .applicationSupportDirectory,
                                                                                 in: .userDomainMask,
                                                                                 appropriateFor: nil,
                                                                                 create: false)
                .appending(path: storagePath), withIntermediateDirectories: true)

            let latticeURL = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                          in: .userDomainMask,
                                                          appropriateFor: nil,
                                                          create: false)
                .appending(path: storagePath)
                .appending(path: "\(userId.uuidString).sqlite")

            do {
                try await Task {
                    guard let lattice = try? Lattice(for: schema, configuration: .init(fileURL: latticeURL)) else {
                        print(">>> Could not open lattice for url: \(String(describing: latticeURL))")
                        try? await ws.close()
                        return
                    }
                    
                    let encodedChunks: [Data] = try {
                        let events = try lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
                        print(">>> Bringing user up to date with \(events.count) events")
                        return try events.chunked(into: 1000).map { events in
                            try JSONEncoder().encode(ServerSentEvent.auditLog(events))
                        }
                    }()
                    
                    if !encodedChunks.isEmpty {
                        print(">>> Sending chunks")
                        for chunk in encodedChunks {
                            await ws.send(ByteBuffer(data: chunk))
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
