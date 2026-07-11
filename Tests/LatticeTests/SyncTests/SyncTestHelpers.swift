import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(MapKit)
import MapKit
#endif
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Observation
import Vapor

/// Thread-safe one-shot flag for guarding continuation resume.
final class AtomicOnce: @unchecked Sendable {
    private let _lock = NSLock()
    private var _fired = false
    func tryFire() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        if _fired { return false }
        _fired = true
        return true
    }
}

@Model class SimpleSyncObject {
    var value: Int = 0
    var floatValue: Float

    init(value: Int, floatValue: Float) {
        self.value = value
        self.floatValue = floatValue
    }
}

@Model class SyncParent {
    var name: String
    var children: List<SyncChild>
    var favorite: SyncChild?

    init(name: String) {
        self.name = name
    }
}

@Model class SyncChild {
    var name: String

    init(name: String) {
        self.name = name
    }
}


@Model class SyncVectorObject {
    var label: String
    var embedding: FloatVector

    init(label: String = "", embedding: [Float] = []) {
        self.label = label
        self.embedding = FloatVector(embedding)
    }
}

@Model class SyncGeoObject {
    var name: String
    var location: CLLocationCoordinate2D

    init(name: String = "", latitude: Double = 0, longitude: Double = 0) {
        self.name = name
        self.location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct SyncEmbedded: EmbeddedModel {
    var detail: String = ""
}

@Model class SyncEmbeddedObject {
    var name: String
    var metadata: SyncEmbedded?

    init(name: String = "", metadata: SyncEmbedded? = nil) {
        self.name = name
        self.metadata = metadata
    }
}

@Model class SequenceSyncObject {
    var open: Float = .random(in: 0...1000)
    var high: Float = .random(in: 0...1000)
    var low: Float = .random(in: 0...1000)
    var close: Float = .random(in: 0...1000)
    var volume: Float = .random(in: 0...1000)
}

/// Thread-safe WebSocket store for test server.
final class SocketStore: @unchecked Sendable {
    private var _sockets: [WebSocket] = []
    private let lock = NSLock()
    let label: String
    private var _waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(label: String = "unnamed") {
        self.label = label
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sockets.count
    }

    /// Suspends until the socket count reaches at least `target`.
    func waitForCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if _sockets.count >= target {
                lock.unlock()
                continuation.resume()
            } else {
                _waiters.append((target: target, continuation: continuation))
                lock.unlock()
            }
        }
    }

    func append(_ ws: WebSocket) {
        lock.lock()
        _sockets.append(ws)
        let total = _sockets.count
        let ready = _waiters.filter { $0.target <= total }
        _waiters.removeAll { $0.target <= total }
        lock.unlock()
        print("[SocketStore:\(label)] append: total=\(total)")
        for waiter in ready {
            waiter.continuation.resume()
        }
        ws.onClose.whenComplete { [weak self] _ in
            self?.remove(ws)
        }
    }

    private func remove(_ ws: WebSocket) {
        lock.lock()
        _sockets.removeAll { $0 === ws }
        let total = _sockets.count
        lock.unlock()
        print("[SocketStore:\(label)] remove (onClose): total=\(total)")
    }

    func others(excluding ws: WebSocket) -> [WebSocket] {
        lock.lock()
        let result = _sockets.filter { $0 !== ws && !$0.isClosed }
        let total = _sockets.count
        lock.unlock()
        print("[SocketStore:\(label)] others: \(result.count) live of \(total) total (excluding sender)")
        return result
    }
}

/// Internal `UncheckedSendable` twin (the source one is internal to Lattice).
struct TestUncheckedSendable<T>: @unchecked Sendable { let value: T }

// MARK: - TestSyncServer (1.0 item D1b)

/// Shared in-process relay server for sync tests. Replaces the four
/// copy-pasted inline Vapor handlers that opened a FRESH `Lattice` per
/// incoming frame inside `Task.detached` (unordered application, one
/// connection churn per frame) and another per connection for catch-up.
///
/// Shape (mirrors NIOSyncRelay): ONE server-lifetime `Lattice`, created
/// before the route is registered; ACK + broadcast run synchronously on the
/// event loop (no DB work); persistence runs OFF the event loop but IN
/// COMMIT-ARRIVAL ORDER through a single-consumer AsyncStream pipeline.
final class TestSyncServer: @unchecked Sendable {
    let app: Application
    let lattice: Lattice
    let sockets: SocketStore
    private let path: String
    private(set) var port: Int = 0

    final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    private let frameCounter = FrameCounter()
    /// Number of auditLog frames the server has received (I2's frame-count probe).
    var auditFrameCount: Int { frameCounter.value }
    private let frameContinuation: AsyncStream<Data>.Continuation
    private var consumer: Task<Void, Never>?

    /// - Parameters:
    ///   - models: model types the server-side lattice registers.
    ///   - configuration: the server lattice's configuration (no sync endpoint).
    ///   - path: WebSocket route path (default "test", matching the old inline servers).
    init(models: [any Model.Type],
         configuration: Lattice.Configuration,
         path: String = "test",
         label: String = "TestSyncServer") async throws {
        // Server-lifetime lattice — constructed BEFORE any handler can fire.
        self.lattice = try Lattice(for: models, configuration: configuration)
        self.sockets = SocketStore(label: label)
        self.path = path

        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        app.http.server.configuration.port = 0

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.frameContinuation = continuation
        let serverLattice = TestUncheckedSendable(value: lattice)
        // Single consumer: frames apply in arrival order, off the event loop.
        self.consumer = Task.detached {
            for await data in stream {
                _ = try? serverLattice.value.receive(data)
            }
        }

        let sockets = self.sockets
        let frames = self.frameCounter
        app.webSocket(.constant(path), maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else { return }
                if kind == "auditLog" {
                    frames.increment()
                    // ACK immediately (before persistence) and forward to the
                    // other clients — synchronous, no DB work on the event loop.
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    for socket in sockets.others(excluding: ws) {
                        socket.send(bb)
                    }
                }
                continuation.yield(data)
            }

            // Catch-up from the SHARED lattice (old code opened a fresh one).
            let events = serverLattice.value.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let count = events.count
            for i in stride(from: 0, to: count, by: 1000) {
                let page = events[i..<min(count, i + 1000)]
                let encoded = try! JSONEncoder().encode(ServerSentEvent.auditLog(Array(page)))
                ws.send(ByteBuffer(data: encoded))
            }
        }

        try await app.startup()
        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw TestSyncServerError.noPort
        }
        self.port = assignedPort
    }

    var endpoint: URL { URL(string: "http://localhost:\(port)/\(path)")! }

    func shutdown() {
        frameContinuation.finish()
        consumer?.cancel()
        app.shutdown()
    }

    enum TestSyncServerError: Error { case noPort }
}
