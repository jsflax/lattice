import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import Testing
@testable import Lattice

/// Tests that reproduce the SyncRelay pattern: a raw NIO WebSocket server
/// (not Vapor) sending binary frames to Lattice clients that use URLSessionWebSocketTask.
///
/// The CanaryBuilder SyncRelay uses raw NIO for WebSocket, while existing sync tests
/// use Vapor. This test isolates whether NIO→URLSessionWebSocketTask binary frame
/// delivery works correctly for Lattice sync.
@Suite("NIO Relay Sync Tests")
actor NIORelaySyncTests {

    let serverLatticeConfig: Lattice.Configuration
    let config1: Lattice.Configuration
    let config2: Lattice.Configuration

    init() {
        lattice_set_log_level(lattice.log_level.info)
        serverLatticeConfig = .init(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite"))
        config1 = .init(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite"))
        config2 = .init(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite"))
    }

    deinit {
        try? Lattice.delete(for: serverLatticeConfig)
        try? Lattice.delete(for: config1)
        try? Lattice.delete(for: config2)
    }

    // MARK: - Minimal NIO WebSocket Server (mirrors SyncRelay)

    actor NIOSyncRelay {
        private let lattice: Lattice
        private var connections: [UUID: NIOWebSocketConnection] = [:]
        var connectionCount: Int { connections.count }

        init(config: Lattice.Configuration) throws {
            self.lattice = try Lattice(SimpleSyncObject.self, configuration: config)
        }

        func addConnection(_ conn: NIOWebSocketConnection) {
            connections[conn.id] = conn
            fputs("[NIOSyncRelay] addConnection: \(conn.id) lastEventId=\(conn.lastEventId?.uuidString ?? "nil") total=\(connections.count)\n", stderr)
            do {
                let events = try lattice.eventsAfter(globalId: conn.lastEventId)
                fputs("[NIOSyncRelay] catch-up: \(events.count) events for \(conn.id)\n", stderr)
                if !events.isEmpty {
                    let data = try JSONEncoder().encode(ServerSentEvent.auditLog(events))
                    fputs("[NIOSyncRelay] sending catch-up: \(data.count) bytes to \(conn.id)\n", stderr)
                    conn.send(data)
                }
            } catch {
                fputs("[NIOSyncRelay] Error sending catch-up: \(error)\n", stderr)
            }
        }

        func removeConnection(_ id: UUID) {
            connections.removeValue(forKey: id)
            fputs("[NIOSyncRelay] removeConnection: \(id) remaining=\(connections.count)\n", stderr)
        }

        func handleBinaryFrame(_ data: Data, from sender: UUID) {
            do {
                let globalIds = try lattice.receive(data)
                fputs("[NIOSyncRelay] received \(globalIds.count) entries from \(sender), broadcasting to \(connections.count - 1) others\n", stderr)

                let ack = try JSONEncoder().encode(ServerSentEvent.ack(globalIds))
                connections[sender]?.send(ack)

                for (id, conn) in connections where id != sender {
                    fputs("[NIOSyncRelay] broadcast \(data.count) bytes to \(id)\n", stderr)
                    conn.send(data)
                }
            } catch {
                fputs("[NIOSyncRelay] Error handling binary frame: \(error)\n", stderr)
            }
        }

        /// Pre-seed data into the relay's Lattice (for catch-up tests).
        func seed(_ block: (Lattice) -> Void) {
            block(lattice)
        }

        func eventCount() throws -> Int {
            try lattice.eventsAfter(globalId: nil).count
        }
    }

    final class NIOWebSocketConnection: Sendable {
        let id: UUID
        let lastEventId: UUID?
        let channel: any Channel

        init(id: UUID, lastEventId: UUID?, channel: any Channel) {
            self.id = id
            self.lastEventId = lastEventId
            self.channel = channel
        }

        func send(_ data: Data) {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
            channel.writeAndFlush(frame, promise: nil)
        }
    }

    final class NIOWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        private let syncRelay: NIOSyncRelay
        private let lastEventId: UUID?
        private let connectionId = UUID()

        init(syncRelay: NIOSyncRelay, lastEventId: UUID?) {
            self.syncRelay = syncRelay
            self.lastEventId = lastEventId
        }

        func handlerAdded(context: ChannelHandlerContext) {
            let conn = NIOWebSocketConnection(
                id: connectionId, lastEventId: lastEventId, channel: context.channel
            )
            Task { await syncRelay.addConnection(conn) }
        }

        func handlerRemoved(context: ChannelHandlerContext) {
            let id = connectionId
            Task { await syncRelay.removeConnection(id) }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .binary:
                var frameData = frame.unmaskedData
                guard let bytes = frameData.readBytes(length: frameData.readableBytes) else { return }
                let data = Data(bytes)
                let senderId = connectionId
                Task { await syncRelay.handleBinaryFrame(data, from: senderId) }

            case .connectionClose:
                let id = connectionId
                Task { await syncRelay.removeConnection(id) }
                let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose,
                                                data: context.channel.allocator.buffer(capacity: 0))
                context.writeAndFlush(wrapOutboundOut(closeFrame), promise: nil)
                context.close(promise: nil)

            case .ping:
                let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
                context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

            default:
                break
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            let id = connectionId
            Task { await syncRelay.removeConnection(id) }
            context.close(promise: nil)
        }
    }

    private final class NIOHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            if case .end = part {
                let head = HTTPResponseHead(version: .http1_1, status: .notFound)
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    enum NIOWebSocketUpgradeError: Error {
        case unsupported
    }

    private func startNIOServer(relay: NIOSyncRelay) async throws -> (Channel, Int) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 27,
            shouldUpgrade: { channel, head in
                let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
                if path == "/sync" {
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                }
                return channel.eventLoop.makeFailedFuture(NIOWebSocketUpgradeError.unsupported)
            },
            upgradePipelineHandler: { channel, head in
                let lastEventId: UUID? = {
                    guard let query = head.uri.split(separator: "?").dropFirst().first else { return nil }
                    for param in query.split(separator: "&") {
                        let parts = param.split(separator: "=", maxSplits: 1)
                        if parts.first == "last-event-id", let val = parts.last {
                            return UUID(uuidString: String(val))
                        }
                    }
                    return nil
                }()
                return channel.pipeline.addHandler(
                    NIOWebSocketHandler(syncRelay: relay, lastEventId: lastEventId)
                )
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = NIOHTTPHandler()
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { ctx in
                            ctx.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress!.port!
        fputs("[NIORelaySyncTests] Server bound to port \(port)\n", stderr)
        return (channel, port)
    }

    // MARK: - Tests

    /// Core test: Two Lattice clients sync through a raw NIO WebSocket relay.
    /// Lattice1 inserts data → relay receives & broadcasts → Lattice2 should see it.
    @Test(.timeLimit(.minutes(1))) func test_NIORelayBasicSync() async throws {
        let relay = try NIOSyncRelay(config: serverLatticeConfig)
        let (serverChannel, port) = try await startNIOServer(relay: relay)
        defer { try? serverChannel.close().wait() }

        fputs("[NIORelaySyncTests] Server running on port \(port)\n", stderr)

        // Config with sync endpoint pointing to our NIO server
        // authorizationToken is required — is_sync_enabled() checks both url AND token
        let c1 = Lattice.Configuration(
            fileURL: config1.fileURL,
            authorizationToken: "test",
            wssEndpoint: URL(string: "ws://127.0.0.1:\(port)/sync")
        )
        let c2 = Lattice.Configuration(
            fileURL: config2.fileURL,
            authorizationToken: "test",
            wssEndpoint: URL(string: "ws://127.0.0.1:\(port)/sync")
        )

        // Create lattice2 first, set up changeStream watcher inside its own task
        let c2Copy = c2
        var receiverTask: Task<Void, any Error>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            receiverTask = Task.detached {
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: c2Copy)
                let stream = lattice2.changeStream
                continuation.resume()
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: lattice2) }
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        // Wait for lattice2 to connect to relay
        try await Task.sleep(for: .seconds(2))
        let connCount1 = await relay.connectionCount
        fputs("[NIORelaySyncTests] After lattice2 connect: relay has \(connCount1) connections\n", stderr)
        #expect(connCount1 >= 1, "Lattice2 should be connected to relay")

        // Create lattice1, wait for it to connect, then insert
        let c1Copy = c1
        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            syncTask = Task.detached {
                let lattice1 = try Lattice(SimpleSyncObject.self, configuration: c1Copy)
                let stream = lattice1.changeStream
                continuation.resume()
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: lattice1) }
                    if resolved.contains(where: { $0.isSynchronized && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        // Wait for lattice1 to connect
        try await Task.sleep(for: .seconds(2))
        let connCount2 = await relay.connectionCount
        fputs("[NIORelaySyncTests] After lattice1 connect: relay has \(connCount2) connections\n", stderr)
        #expect(connCount2 >= 2, "Both lattices should be connected to relay")

        // Insert on lattice1 (via a separate instance sharing the same DB)
        let inserter = try Lattice(SimpleSyncObject.self, configuration: c1)
        let obj = SimpleSyncObject(value: 42, floatValue: 3.14)
        inserter.add(obj)
        fputs("[NIORelaySyncTests] Inserted SimpleSyncObject(value: 42) on lattice1\n", stderr)

        // Wait for receiver to see the synced insert (with timeout)
        let receiver = receiverTask!
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await receiver.value }
            group.addTask { try await Task.sleep(for: .seconds(15)) }
            _ = try? await group.next()
            group.cancelAll()
        }

        // Check results via a fresh Lattice on lattice2's DB
        let verifier = try Lattice(SimpleSyncObject.self, configuration: c2)
        let objects2 = verifier.objects(SimpleSyncObject.self)
        fputs("[NIORelaySyncTests] lattice2 SimpleSyncObject count: \(objects2.count)\n", stderr)

        #expect(objects2.count == 1,
                "SimpleSyncObject should sync from lattice1 → NIO relay → lattice2. Got \(objects2.count) objects.")
        if let synced = objects2.first {
            #expect(synced.value == 42)
        }
    }

    /// Test catch-up: data exists in relay BEFORE a client connects.
    /// Mimics: MCP creates data → macOS app connects later → should receive catch-up.
    @Test(.timeLimit(.minutes(1))) func test_NIORelayCatchUp() async throws {
        let relay = try NIOSyncRelay(config: serverLatticeConfig)

        // Pre-populate the relay with data
        await relay.seed { lattice in
            let seedObj = SimpleSyncObject(value: 99, floatValue: 1.23)
            lattice.add(seedObj)
        }
        let eventCount = try await relay.eventCount()
        fputs("[NIORelaySyncTests] Server seeded with \(eventCount) events\n", stderr)
        #expect(eventCount > 0, "Server should have events to send as catch-up")

        let (serverChannel, port) = try await startNIOServer(relay: relay)
        defer { try? serverChannel.close().wait() }

        // Client connects AFTER data exists
        let clientConfig = Lattice.Configuration(
            fileURL: config1.fileURL,
            authorizationToken: "test",
            wssEndpoint: URL(string: "ws://127.0.0.1:\(port)/sync")
        )

        // Watch for catch-up inside a detached task
        var catchUpTask: Task<Bool, any Error>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            catchUpTask = Task.detached {
                let client = try Lattice(SimpleSyncObject.self, configuration: clientConfig)
                let stream = client.changeStream
                continuation.resume()
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: client) }
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        return true
                    }
                }
                return false
            }
        }

        // Wait with timeout
        let catcher = catchUpTask!
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await catcher.value }
            group.addTask { try await Task.sleep(for: .seconds(15)) }
            _ = try? await group.next()
            group.cancelAll()
        }

        // Verify via a fresh Lattice on the client's DB
        let verifier = try Lattice(SimpleSyncObject.self, configuration: clientConfig)
        let objects = verifier.objects(SimpleSyncObject.self)
        fputs("[NIORelaySyncTests] Client SimpleSyncObject count after catch-up: \(objects.count)\n", stderr)

        #expect(objects.count == 1,
                "Client should receive catch-up data from NIO relay. Got \(objects.count) objects.")
        if let synced = objects.first {
            #expect(synced.value == 99, "Caught-up object should have value 99")
        }
    }
}
