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

    // State belongs to one request and is protected by this store's lock.
    // A cancellation before installation stays on that request, not in a
    // process-lifetime set of cancelled IDs.
    private final class CancellableCountWaiter: @unchecked Sendable {
        let target: Int
        var cancelled = false
        var finished = false
        var continuation: CheckedContinuation<Void, any Error>?
        init(target: Int) { self.target = target }
    }
    private var _cancellableWaiters: [ObjectIdentifier: CancellableCountWaiter] = [:]

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

    /// Cancellation-aware readiness for the bidirectional fixture. Other
    /// existing waitForCount callers retain their original contract.
    /// The optional test seam runs after registration and outside the lock.
    func waitForCountOrCancellation(
        _ target: Int,
        afterRegistrationForTesting: (@Sendable () -> Void)? = nil
    ) async throws {
        let waiter = CancellableCountWaiter(target: target)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>?
                lock.lock()
                if waiter.cancelled {
                    waiter.finished = true
                    result = .failure(CancellationError())
                } else if _sockets.count >= target {
                    waiter.finished = true
                    result = .success(())
                } else {
                    waiter.continuation = continuation
                    _cancellableWaiters[ObjectIdentifier(waiter)] = waiter
                    result = nil
                }
                lock.unlock()
                afterRegistrationForTesting?()
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancelCountWaiter(waiter)
        }
        // Cancellation can race a successful ready selection; it must not
        // allow this fixture to proceed to its originating write.
        try Task.checkCancellation()
    }

    private func cancelCountWaiter(_ waiter: CancellableCountWaiter) {
        lock.lock()
        guard !waiter.finished else { lock.unlock(); return }
        waiter.cancelled = true
        let continuation = waiter.continuation
        if continuation != nil {
            waiter.finished = true
            waiter.continuation = nil
            _cancellableWaiters.removeValue(forKey: ObjectIdentifier(waiter))
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    var cancellableCountWaitersForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return _cancellableWaiters.count
    }

    func append(_ ws: WebSocket) {
        lock.lock()
        _sockets.append(ws)
        let total = _sockets.count
        let ready = _waiters.filter { $0.target <= total }
        _waiters.removeAll { $0.target <= total }
        let cancellableReady = _cancellableWaiters.values.filter { $0.target <= total }
        var cancellableContinuations: [CheckedContinuation<Void, any Error>] = []
        for waiter in cancellableReady {
            _cancellableWaiters.removeValue(forKey: ObjectIdentifier(waiter))
            waiter.finished = true
            if let continuation = waiter.continuation {
                cancellableContinuations.append(continuation)
                waiter.continuation = nil
            }
        }
        lock.unlock()
        print("[SocketStore:\(label)] append: total=\(total)")
        for waiter in ready {
            waiter.continuation.resume()
        }
        for continuation in cancellableContinuations {
            continuation.resume()
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
/// before the route is registered. ACK remains immediate on the event loop.
/// One consumer serializes connect/catch-up and fanout/persistence commands.
/// Registration and fanout may wait behind earlier SQL, but no SQL runs on
/// the event loop. This is test-fixture scheduling, not the production relay.
final class TestSyncServer: @unchecked Sendable {
    let app: Application
    let lattice: Lattice
    let sockets: SocketStore
    private let path: String
    let diagnostic: SyncTestStageLog
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
    private enum Command: Sendable {
        case barrier(@Sendable () -> Void)
        case connect(socket: TestUncheckedSendable<WebSocket>, cursor: UUID?)
        case frame(socket: TestUncheckedSendable<WebSocket>, data: Data,
                   audit: Bool, frame: UUID, auditIDs: [UUID], rowIDs: [UUID])
    }
    private let frameContinuation: AsyncStream<Command>.Continuation

    // Optional async test seams. They suspend this fixture's consumer only;
    // they never park an event-loop or observation worker thread.
    struct Hooks: Sendable {
        var beforePersistence: (@Sendable () async -> Void)?
        var beforeCatchUp: (@Sendable (Int) async -> Void)?
        var connectEnqueued: (@Sendable () -> Void)?
        var frameEnqueued: (@Sendable () -> Void)?
    }
    private var consumer: Task<Void, Never>?

    /// - Parameters:
    ///   - models: model types the server-side lattice registers.
    ///   - configuration: the server lattice's configuration (no sync endpoint).
    ///   - path: WebSocket route path (default "test", matching the old inline servers).
    init(models: [any Model.Type],
         configuration: Lattice.Configuration,
         path: String = "test",
         label: String = "TestSyncServer",
         hooks: Hooks = .init()) async throws {
        // Server-lifetime lattice — constructed BEFORE any handler can fire.
        self.lattice = try Lattice(for: models, configuration: configuration)
        self.sockets = SocketStore(label: label)
        self.path = path
        self.diagnostic = SyncTestStageLog(label: label, store: configuration.fileURL.path)

        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        app.http.server.configuration.port = 0

        let (stream, continuation) = AsyncStream<Command>.makeStream()
        self.frameContinuation = continuation
        let serverLattice = TestUncheckedSendable(value: lattice)
        let sockets = self.sockets
        let frames = self.frameCounter
        let diagnostic = self.diagnostic
        // AsyncStream linearizes concurrent yields. A frame's fanout and
        // persistence cannot straddle a connect command's initial catch-up.
        self.consumer = Task.detached {
            for await command in stream {
                guard !Task.isCancelled else { break }
                switch command {
                case .barrier(let finish): finish()
                case .connect(let socket, let cursor):
                    let ws = socket.value
                    guard !ws.isClosed else { continue }
                    sockets.append(ws)
                    diagnostic.record("server_registered", count: sockets.count)
                    await hooks.beforeCatchUp?(sockets.count)
                    guard !Task.isCancelled else { break }
                    diagnostic.record("server_catchup_begin", auditIDs: cursor.map { [$0] } ?? [])
                    let events = serverLattice.value.eventsAfter(globalId: cursor)
                    let count = events.count
                    diagnostic.record("server_catchup_count", count: count)
                    for i in stride(from: 0, to: count, by: 1000) {
                        let page = Array(events[i..<min(count, i + 1000)])
                        diagnostic.record("server_catchup_page", count: page.count,
                                          auditIDs: page.prefix(8).compactMap(\.globalId),
                                          rowIDs: page.prefix(8).compactMap(\.globalRowId))
                        let encoded = try! JSONEncoder().encode(ServerSentEvent.auditLog(page))
                        ws.send(ByteBuffer(data: encoded))
                    }
                    diagnostic.record("server_catchup_enqueued", count: count)
                case .frame(let socket, let data, let audit, let frame, let auditIDs, let rowIDs):
                    if audit {
                        let peers = sockets.others(excluding: socket.value)
                        diagnostic.record("server_fanout", frame: frame, count: peers.count,
                                          auditIDs: auditIDs, rowIDs: rowIDs)
                        for peer in peers { peer.send(ByteBuffer(data: data)) }
                    }
                    if audit { await hooks.beforePersistence?() }
                    guard !Task.isCancelled else { break }
                    diagnostic.record("server_apply_begin", frame: frame,
                                      auditIDs: auditIDs, rowIDs: rowIDs)
                    do {
                        let ids = try serverLattice.value.receive(data)
                        diagnostic.record("server_apply_returned", frame: frame,
                                          count: ids.count, auditIDs: Array(ids.prefix(8)))
                    } catch {
                        // Preserve the previous try? policy, expose its failure.
                        diagnostic.record("server_apply_failed", frame: frame,
                                          detail: String(reflecting: type(of: error)))
                    }
                }
            }
            diagnostic.record("server_consumer_finished")
        }

        app.webSocket(.constant(path), maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else { return }
                let frame = UUID()
                let logs = json["auditLog"] as? [[String: Any]] ?? []
                let auditIDs = logs.prefix(8).compactMap { $0["globalId"] as? String }.compactMap(UUID.init(uuidString:))
                let rowIDs = logs.prefix(8).compactMap { $0["globalRowId"] as? String }.compactMap(UUID.init(uuidString:))
                diagnostic.record("server_frame_received", frame: frame, count: logs.count,
                                  auditIDs: auditIDs, rowIDs: rowIDs)
                if kind == "auditLog" {
                    frames.increment()
                    // ACK still means accepted for queued processing, not durable.
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                        diagnostic.record("server_ack_enqueued", frame: frame, count: globalIds.count)
                    }
                }
                continuation.yield(.frame(socket: TestUncheckedSendable(value: ws), data: data,
                                          audit: kind == "auditLog", frame: frame,
                                          auditIDs: auditIDs, rowIDs: rowIDs))
                hooks.frameEnqueued?()
            }
            let cursor = try? req.query.get(UUID?.self, at: "last-event-id")
            diagnostic.record("server_connect_enqueue")
            continuation.yield(.connect(socket: TestUncheckedSendable(value: ws), cursor: cursor))
            hooks.connectEnqueued?()
        }

        try await app.startup()
        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw TestSyncServerError.noPort
        }
        self.port = assignedPort
    }

    // A test-only queue fence. AsyncStream cancellation releases the waiter
    // without requiring this queued notice to run; no synchronous wait occurs.
    func waitForCommandsForTesting() async throws {
        let notice = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frameContinuation.yield(.barrier {
            notice.continuation.yield(())
            notice.continuation.finish()
        })
        for await _ in notice.stream { break }
        try Task.checkCancellation()
    }

    var endpoint: URL { URL(string: "http://localhost:\(port)/\(path)")! }

    /// New controlled fixtures release their async hooks first, then join the
    /// consumer before shutting down transport and closing its native owner.
    /// Existing tests retain the synchronous shutdown contract below.
    func shutdownAndWaitForTesting() async throws {
        frameContinuation.finish()
        consumer?.cancel()
        await consumer?.value
        try await app.asyncShutdown()
        lattice.close()
    }

    func shutdown() {
        frameContinuation.finish()
        consumer?.cancel()
        app.shutdown()
    }

    enum TestSyncServerError: Error { case noPort }
}
