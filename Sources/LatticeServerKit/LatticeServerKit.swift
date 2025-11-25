import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers
import Fluent

struct LoginRequest: Content { let username, password: String }
struct LoginResponse: Content { let token: String }

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
//
//struct LatticeDB: Database {
//    let app: Application
////    let lattice: Lattice
//    
//    public nonisolated func withConnection<T>(_ closure: @escaping @Sendable (any FluentKit.Database) -> NIOCore.EventLoopFuture<T>) -> NIOCore.EventLoopFuture<T> {
//        closure(self)
//    }
//    
//    public nonisolated func transaction<T>(_ closure: @escaping @Sendable (any FluentKit.Database) -> NIOCore.EventLoopFuture<T>) -> NIOCore.EventLoopFuture<T> {
//        app.eventLoopGroup.next().submit {
//            
//        }
//    }
//    
//    public nonisolated func execute(enum: FluentKit.DatabaseEnum) -> NIOCore.EventLoopFuture<Void> {
//        
//    }
//    
//    public nonisolated func execute(schema: FluentKit.DatabaseSchema) -> NIOCore.EventLoopFuture<Void> {
//        <#code#>
//    }
//    
//    public nonisolated func execute(query: FluentKit.DatabaseQuery, onOutput: @escaping @Sendable (any FluentKit.DatabaseOutput) -> ()) -> NIOCore.EventLoopFuture<Void> {
//        <#code#>
//    }
//    
//    public nonisolated var context: FluentKit.DatabaseContext {
//        
//    }
//    
//    public nonisolated var inTransaction: Bool {
//        
//    }
//}

extension Lattice {
    public static func configure(_ app: Application,
                                 for schema: [any Lattice.Model.Type],
                                 storagePath: String) throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        
        // Protect routes that need auth:
        // Migrations
        app.migrations.add(CreateUser())
        app.migrations.add(CreateOAuthAccount())
        app.migrations.add(CreateToken())
        
        // Session middleware (if you ever do cookies)
        app.middleware.use(app.sessions.middleware)
        
        // Token authenticator for "Bearer <token>"
        app.middleware.use(Token.authenticator())
        
        let auth = AuthController()
        // email/password
        app.post("register", use: auth.register)
        app.post("login",    use: auth.login)
        
        // OAuth
        app.post("auth", "apple",  use: auth.appleLogin)
        app.post("auth", "google", use: auth.googleLogin)
        
        // protected profile
        let sockets = SocketManager()
        
        let protected = app.grouped(DebugTokenAuth(), Token.authenticator(), User.guardMiddleware())
        protected.get("profile") { req in
            print(req)
            let user = try req.auth.require(User.self)
            return try await auth.attachProviders(to: user, req: req)
        }
        
        protected.webSocket("sync", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 300 * 1024 * 1024)) { req, ws in
            guard let user = try? req.auth.require(User.self) else {
                print(">>> Could not authenticate user for sync: \(req.auth)")
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
                .appending(path: "\(user.id!.uuidString).sqlite")
            
            await Task {
                guard let lattice = try? Lattice(for: schema, configuration: .init(fileURL: latticeURL)) else {
                    print(">>> Could not open lattice for url: \(latticeURL)")
                    try? await ws.close()
                    return
                }
                
                // bring the user up to date
                let encodedChunks: [Data] = try! await LatticeActor(lattice).withModelContext { lattice in
                    let events = try lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
                    print(">>> Bringing user up to date with \(events.count) events")
                    return try events.chunked(into: 1000).map { events in
                        try JSONEncoder().encode(ServerSentEvent.auditLog(events))
                    }
                }
                if !encodedChunks.isEmpty {
                    print(">>> Sending chunks")
                    for chunk in encodedChunks {
                        ws.send(ByteBuffer(data: chunk))
                    }
                }
            }.value
            await sockets.add(socket: ws, for: user.id!)
            ws.eventLoop.execute {
                ws.onText { ws, str in
                    print("🧦", "Received String Event", str)
                    print(str)
                }
                ws.onBinary { ws, bb in
                    print("🧦", "Received Binary Event")
                    
                    try? await LatticeActor(for: schema, configuration: .init(fileURL: latticeURL))
                        .withModelContext({ lattice in
                            do {
                                let globalIds = try lattice.receive(Data(buffer: bb))
                                ws.send(try JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                            } catch {
                                print("Error:", error)
                            }
                        })
                    
                    for socket in await sockets.sockets(for: user.id!) where socket !== ws {
                        socket.send(bb)
                    }
                }
                ws.onClose.whenComplete { _ in
                    Task {
                        await sockets.remove(socket: ws, for: user.id!)
                    }
                }
            }
        }
    }
}

extension Data: DataProtocol {
}

struct DebugTokenAuth: AsyncMiddleware {
  func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
    print(">>> Authorization header:", req.headers["Authorization"].first ?? "nil")
    return try await next.respond(to: req)
  }
}
