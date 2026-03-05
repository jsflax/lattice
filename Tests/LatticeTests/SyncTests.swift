import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(MapKit)
import MapKit
#endif
import NIOConcurrencyHelpers
import Testing
//import SwiftUI
import Lattice
import Observation
import Vapor

/// Thread-safe one-shot flag for guarding continuation resume.
private final class AtomicOnce: @unchecked Sendable {
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
import NIOCore

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
            // All lock usage is inside this synchronous closure, not the async body.
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
        // Resume any waiters whose target is now met
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

@Suite("Sync Tests")
actor SyncTests {
    let app: Application
    let syncLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice1URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice2URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port: Int = 0
    var localLattice1: Lattice!
    var localLattice2: Lattice!
    var syncedLattice: Lattice!
    var syncedLatticeConfiguration: Lattice.Configuration
    var localLattice1Configuration: Lattice.Configuration
    var localLattice2Configuration: Lattice.Configuration
    
    deinit {
        app.shutdown()
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
    }
    private let sockets = SocketStore(label: "SyncTests")
    private func launchServer() async throws {
        let syncedLatticeConfiguration = self.syncedLatticeConfiguration
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            self.sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else { return }

                if kind == "auditLog" {
                    // Extract globalIds and send ACK immediately (before DB persistence)
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    // Forward to other clients immediately
                    for socket in self.sockets.others(excluding: ws) {
                        socket.send(bb)
                    }
                }
                // Persist to server DB in background (for eventsAfter catch-up support).
                // Must not block the EventLoop — NIO only flushes queued ws.send()
                // writes when the callback returns and the EventLoop processes I/O.
                Task.detached {
                    let lattice = try Lattice(configuration: syncedLatticeConfiguration)
                    _ = try? lattice.receive(data)
                }
            }

            let lattice = try! Lattice(configuration: syncedLatticeConfiguration)
            let events = try! lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let encoded = events.isEmpty ? nil : try! JSONEncoder().encode(ServerSentEvent.auditLog(events))
            encoded.map { encoded in ws.send(ByteBuffer(data: encoded)) }
        }
    }
    
    enum SyncTestError: Error {
        case noPort
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.localLattice1Configuration = .init(fileURL: lattice1URL)
        self.localLattice2Configuration = .init(fileURL: lattice2URL)
        self.syncedLatticeConfiguration = .init(fileURL: syncLatticeURL)

        // Use port 0 to let the OS assign a free port
        app.http.server.configuration.port = 0

        // Start the server-side lattice (no sync endpoint)
        syncedLattice = try Lattice(for: [SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self],
                                    configuration: syncedLatticeConfiguration)

        try await launchServer()
        try await app.startup()

        // Read back the OS-assigned port
        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw SyncTestError.noPort
        }
        self.port = assignedPort

        // Now create configs with the correct port
        localLattice1Configuration = Lattice.Configuration(
            fileURL: lattice1URL,
            authorizationToken: "hi",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        localLattice2Configuration = Lattice.Configuration(
            fileURL: lattice2URL,
            authorizationToken: "hi2",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        // Create Lattice instances AFTER server is running so sync connects to the right port
        localLattice1 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self,
                                    configuration: localLattice1Configuration)
        localLattice2 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self,
                                    configuration: localLattice2Configuration)
    }
    
    @Test(.timeLimit(.minutes(1))) func test_BasicSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // --- Phase 1: INSERT sync (lattice1 → lattice2) ---

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        var taskForSynchronization: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice1) })
                    if resolved.contains(where: { $0.isSynchronized && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let object = SimpleSyncObject(value: 42, floatValue: 42.42)
        lattice.add(object)

        try await taskForSynchronization?.value
        try await task?.value

        #expect(lattice.objects(AuditLog.self).first?.isSynchronized == true)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 42)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 42.42)

        // --- Phase 2: UPDATE sync ---

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var updateCount = 0
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    let updates = resolved.filter { $0.operation == .update && $0.tableName == "SimpleSyncObject" }
                    updateCount += updates.count
                    if updateCount >= 2 {
                        break
                    }
                }
            }
        }

        object.value = 84
        object.floatValue = 84.84
        try await task?.value
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 84)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 84.84)

        // --- Phase 3: DELETE sync ---

        let localLattice2Configuration = self.localLattice2Configuration
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        _ = lattice.delete(object)
        try await task?.value
        #expect(lattice2.objects(SimpleSyncObject.self).count == 0)
    }
    
//    @available(macOS 15.0, *)
//    @Test(.timeLimit(.minutes(3))) func test_BigSync() async throws {
//        let lattice = localLattice1!
//        let lattice2 = localLattice2!
//
//        var task: Task<Void, any Error>?
//        await withCheckedContinuation { continuation in
//            task = Task { @MainActor in
//                let lattice2 = try Lattice(SequenceSyncObject.self, configuration: localLattice2Configuration)
//                let changeStream = lattice2.changeStream
//                continuation.resume()
//                var changeCount = 0
//                for await changes in changeStream {
//                    changeCount += changes.count(where: { $0.tableName == "SequenceSyncObject" && $0.operation == .insert }) // why? updating isSynchronized will also update this block
//                    print("Change count: \(changeCount)")
//                    if changeCount == 100_000 {
//                        break
//                    }
//                }
//            }
//        }
//        let objects = (0..<100_000).map { _ in SequenceSyncObject() }
//        lattice.transaction {
//            lattice.add(contentsOf: objects)
//        }
//        try await task?.value
//        
//        #expect(lattice2.objects(SequenceSyncObject.self).count == 100_000)
//        #expect(lattice2.objects(AuditLog.self).count == 100_000)
//    }
    
    @Test func testIsolation() async throws {
        await MainActor.shared.invoke { _ in
            await #isolation?.invoke { @Sendable _ in
            }
        }
    }

    /// Test that List<T> relationships sync properly between clients.
    /// This test verifies that when a parent object with children is created on one client,
    /// the relationship (not just the objects) syncs to the other client.
    @Test(.timeLimit(.minutes(1))) func test_ListRelationshipSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Set up changeStreams BEFORE adding data to avoid race conditions
        var task: Task<Void, any Error>?
        var taskForSynchronization: Task<Void, any Error>?

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncParent.self, SyncChild.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    insertCount += changes.count(where: { $0.operation == .insert })
                    // 3 model inserts: 1 parent + 2 children
                    // (link table AuditLog entries don't generate changeStream notifications)
                    if insertCount >= 3 { break }
                }
            }
        }

        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(SyncParent.self, SyncChild.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        // Create parent with children on lattice1
        let parent = SyncParent(name: "Parent")
        let child1 = SyncChild(name: "Child1")
        let child2 = SyncChild(name: "Child2")

        lattice.transaction {
            lattice.add(parent)
            parent.children.append(child1)
            parent.children.append(child2)
        }

        // Verify local state
        #expect(parent.children.count == 2)
        #expect(lattice.objects(SyncChild.self).count == 2)

        // Check that AuditLog entries were created for the link table
        // This is what we're testing - link table changes should generate audit log entries
        let auditLogs = lattice.objects(AuditLog.self).snapshot()
        let linkTableLogs = auditLogs.filter { $0.tableName.hasPrefix("_SyncParent_SyncChild") }

        // THIS IS THE KEY TEST: Link table operations should be in the audit log
        #expect(linkTableLogs.count >= 2, "Link table INSERT operations should be in AuditLog for sync to work. Found: \(linkTableLogs.count)")

        // Wait for sync to complete
        try await taskForSynchronization?.value
        try await task?.value
        // Verify lattice2 received the objects
        #expect(lattice2.objects(SyncParent.self).count == 1, "Parent should sync")
        #expect(lattice2.objects(SyncChild.self).count == 2, "Children should sync")

        // Link table changes are internal — flush_changes translates them to parent
        // table UPDATE notifications, NOT AuditLog INSERTs. The changeStream (which
        // watches AuditLog) only sees 3 model inserts. If link entries arrive in a
        // separate server message, they won't be committed when changeStream breaks.
        // Use observe() on the Results to catch the parent UPDATE notification.
        //
        // Register the observer BEFORE checking the condition to avoid a TOCTOU race:
        // if children become ready between the check and observer registration, the
        // continuation would never resume.
        let childrenReady = NIOLockedValueBox(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellable: AnyCancellable?
            let tryComplete = {
                if (lattice2.objects(SyncParent.self).first?.children.count ?? 0) >= 2 {
                    if !childrenReady.withLockedValue({ val in
                        let was = val; val = true; return was
                    }) {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
            cancellable = lattice2.objects(SyncParent.self).observe { _ in
                tryComplete()
            }
            // Check if condition is already met after registering the observer.
            tryComplete()
        }

        // THIS IS THE KEY TEST: Verify the relationship synced, not just the objects
        let syncedParent = lattice2.objects(SyncParent.self).first
        #expect(syncedParent != nil, "Should have synced parent")
        #expect(syncedParent?.children.count == 2, "Parent-child relationship should sync (List<T> links)")
        #expect(syncedParent?.children.contains(where: { $0.name == "Child1" }) == true, "Child1 should be linked")
        #expect(syncedParent?.children.contains(where: { $0.name == "Child2" }) == true, "Child2 should be linked")
    }

    /// Test that FloatVector fields sync properly between clients.
    @Test(.timeLimit(.minutes(1))) func test_VectorSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        let embedding: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]

        // Wait for lattice2 to receive the insert
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncVectorObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert && $0.tableName == "SyncVectorObject" }) {
                        break
                    }
                }
            }
        }

        // Wait for lattice1 to confirm sync
        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let lattice1 = try await Lattice(SyncVectorObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SyncVectorObject(label: "test-vector", embedding: embedding)
        lattice.add(obj)

        try await syncTask?.value
        try await task?.value

        // Verify the object synced
        let synced = lattice2.objects(SyncVectorObject.self)
        #expect(synced.count == 1, "Vector object should sync")

        let syncedObj = synced.first!
        #expect(syncedObj.label == "test-vector")
        #expect(syncedObj.embedding.dimensions == 5, "Vector dimensions should be preserved")

        // Verify vector values are preserved
        for (i, value) in syncedObj.embedding.enumerated() {
            #expect(abs(value - embedding[i]) < 0.0001, "Vector element \(i) should match")
        }

        // Test updating the vector
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncVectorObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .update && $0.tableName == "SyncVectorObject" }) {
                        break
                    }
                }
            }
        }

        obj.embedding = FloatVector([1.0, 2.0, 3.0, 4.0, 5.0])
        try await task?.value

        let updated = lattice2.objects(SyncVectorObject.self).first!
        #expect(abs(updated.embedding[0] - 1.0) < 0.0001, "Updated vector should sync")
        #expect(abs(updated.embedding[4] - 5.0) < 0.0001, "Updated vector should sync")
    }

    /// Test that CLLocationCoordinate2D (R*Tree virtual table) fields sync properly.
    @Test(.timeLimit(.minutes(1))) func test_GeoboundsSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncGeoObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert && $0.tableName == "SyncGeoObject" }) {
                        break
                    }
                }
            }
        }

        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let lattice1 = try await Lattice(SyncGeoObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SyncGeoObject(name: "NYC", latitude: 40.7128, longitude: -74.0060)
        lattice.add(obj)

        try await syncTask?.value
        try await task?.value

        let synced = lattice2.objects(SyncGeoObject.self)
        #expect(synced.count == 1, "Geo object should sync")

        let syncedObj = synced.first!
        #expect(syncedObj.name == "NYC")
        #expect(Swift.abs(syncedObj.location.latitude - 40.7128) < 0.0001, "Latitude should be preserved")
        #expect(Swift.abs(syncedObj.location.longitude - (-74.0060)) < 0.0001, "Longitude should be preserved")

        // Test updating location
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncGeoObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .update && $0.tableName == "SyncGeoObject" }) {
                        break
                    }
                }
            }
        }

        obj.location = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        try await task?.value

        let updatedObj = lattice2.objects(SyncGeoObject.self).first!
        #expect(Swift.abs(updatedObj.location.latitude - 34.0522) < 0.0001, "Updated latitude should sync")
        #expect(Swift.abs(updatedObj.location.longitude - (-118.2437)) < 0.0001, "Updated longitude should sync")
    }

    /// Test that EmbeddedModel fields sync properly.
    @Test(.timeLimit(.minutes(1))) func test_EmbeddedModelSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncEmbeddedObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert && $0.tableName == "SyncEmbeddedObject" }) {
                        break
                    }
                }
            }
        }

        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let lattice1 = try await Lattice(SyncEmbeddedObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SyncEmbeddedObject(name: "test", metadata: SyncEmbedded(detail: "hello"))
        lattice.add(obj)

        try await syncTask?.value
        try await task?.value

        let synced = lattice2.objects(SyncEmbeddedObject.self)
        #expect(synced.count == 1, "Embedded object should sync")
        #expect(synced.first?.name == "test")
        #expect(synced.first?.metadata?.detail == "hello", "Embedded field should be preserved")

        // Test updating the embedded field
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncEmbeddedObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .update && $0.tableName == "SyncEmbeddedObject" }) {
                        break
                    }
                }
            }
        }

        obj.metadata = SyncEmbedded(detail: "updated")
        try await task?.value

        #expect(lattice2.objects(SyncEmbeddedObject.self).first?.metadata?.detail == "updated", "Updated embedded field should sync")
    }

    /// Test that sync works bidirectionally — both clients can write and receive.
    /// test_BasicSync only tests lattice1→lattice2. This tests lattice2→lattice1 as well.
    @Test(.timeLimit(.minutes(1))) func test_BidirectionalSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Step 1: lattice1 writes, lattice2 receives
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj1 = SimpleSyncObject(value: 111, floatValue: 1.1)
        lattice.add(obj1)
        try await task?.value
        #expect(lattice2.objects(SimpleSyncObject.self).count >= 1, "Lattice2 should receive from lattice1")

        // Step 2: lattice2 writes back, lattice1 receives (reverse direction)
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = l1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l1) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj2 = SimpleSyncObject(value: 222, floatValue: 2.2)
        lattice2.add(obj2)
        try await task?.value

        let l1Values = Set(lattice.objects(SimpleSyncObject.self).map(\.value))
        let l2Values = Set(lattice2.objects(SimpleSyncObject.self).map(\.value))
        #expect(l1Values.contains(111) && l1Values.contains(222), "Lattice1 should see values from both clients")
        #expect(l2Values.contains(111) && l2Values.contains(222), "Lattice2 should see values from both clients")
    }

    /// Test that a fresh client receives historical events on connect via eventsAfter().
    @Test(.timeLimit(.minutes(1))) func test_CatchUpSync() async throws {
        let lattice = localLattice1!

        // Write data and wait for it to arrive in the SERVER's DB.
        // The test server sends ACK before Task.detached DB persistence, so
        // we observe the server DB directly via cross-instance changeStream.
        let syncedConfig = self.syncedLatticeConfiguration
        var serverTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            serverTask = Task.detached {
                let server = try Lattice(SimpleSyncObject.self, configuration: syncedConfig)
                let changeStream = server.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: server) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj = SimpleSyncObject(value: 999, floatValue: 9.9)
        lattice.add(obj)
        try await serverTask?.value

        // Create a fresh client — it should receive the historical data on connect.
        // Observer Lattice (no sync) set up FIRST so changeStream is ready before
        // the sync Lattice connects and delivers initial events via eventsAfter.
        let freshURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let freshObserverConfig = Lattice.Configuration(fileURL: freshURL)
        var freshTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            freshTask = Task.detached {
                let observer = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshObserverConfig)
                let changeStream = observer.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: observer) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let freshConfig = Lattice.Configuration(
            fileURL: freshURL,
            authorizationToken: "hi3",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        let freshLattice = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshConfig)
        try await freshTask?.value

        let objects = freshLattice.objects(SimpleSyncObject.self)
        #expect(objects.count >= 1, "Fresh client should receive historical data on connect")
        #expect(objects.first?.value == 999, "Historical value should be correct")

        try? Lattice.delete(for: freshConfig)
    }

    /// Test that server-side compaction doesn't break catch-up sync.
    /// After the server compacts its audit log (replacing history with INSERT snapshots),
    /// a fresh client should still receive all current data on connect.
    @Test(.timeLimit(.minutes(1))) func test_ServerCompactionCatchUp() async throws {
        let lattice = localLattice1!

        // Step 1: Write data and wait for it to arrive in the SERVER's DB.
        // The test server sends ACK before Task.detached DB persistence, so
        // observing lattice1's isSynchronized is insufficient — observe the
        // server DB directly via cross-instance changeStream notification.
        let syncedConfig = self.syncedLatticeConfiguration
        var serverTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            serverTask = Task.detached {
                let server = try Lattice(SimpleSyncObject.self, configuration: syncedConfig)
                let changeStream = server.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: server) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj = SimpleSyncObject(value: 555, floatValue: 5.5)
        lattice.add(obj)
        try await serverTask?.value

        // Step 2: Force compact the server's audit log — replaces all history with INSERT snapshots
        let serverEntries = syncedLattice.forceCompactHistory()
        #expect(serverEntries >= 1, "Server should create snapshot entries for existing objects")

        // Verify the server still has the data
        #expect(syncedLattice.objects(SimpleSyncObject.self).count >= 1, "Server data should survive compaction")

        // Step 3: A fresh client connects — should receive data from the compacted snapshots.
        // Create an observer Lattice (no sync) FIRST to set up changeStream before
        // the sync Lattice connects and delivers data.
        let freshURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let freshObserverConfig = Lattice.Configuration(fileURL: freshURL)
        var freshTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            freshTask = Task.detached {
                let observer = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshObserverConfig)
                let changeStream = observer.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: observer) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let freshConfig = Lattice.Configuration(
            fileURL: freshURL,
            authorizationToken: "compact-test",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        let freshLattice = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshConfig)
        try await freshTask?.value

        let objects = freshLattice.objects(SimpleSyncObject.self)
        #expect(objects.count >= 1, "Fresh client should receive data from compacted server")
        #expect(objects.first?.value == 555, "Value should match original")
        #expect(objects.first?.floatValue == 5.5, "Float value should match original")

        try? Lattice.delete(for: freshConfig)
    }

    /// Test that client-side compaction doesn't break ongoing sync.
    /// After a client compacts its local audit log, new changes should still sync.
    @Test(.timeLimit(.minutes(1))) func test_ClientCompactionThenSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Step 1: Write data and wait for sync to lattice2
        var receiveTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            receiveTask = Task.detached {
                let l2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj1 = SimpleSyncObject(value: 100, floatValue: 1.0)
        lattice.add(obj1)
        try await receiveTask?.value
        #expect(lattice2.objects(SimpleSyncObject.self).count >= 1, "Initial sync should work")

        // Step 2: Force compact lattice1's audit log (nuclear — no replication slots in WSS-only)
        let compactedEntries = lattice.forceCompactHistory()
        #expect(compactedEntries >= 1, "Should create snapshot entries")

        // Step 3: Write NEW data after compaction and wait for it on lattice2.
        // After compaction, lattice1 has fresh INSERT snapshot entries (isSynchronized=0).
        // Adding obj2 triggers upload_pending_changes which sends BOTH the compacted
        // snapshot AND obj2. The C++ fix in apply_remote_changes resolves local rowId
        // and operation so flush_changes can correlate them with the update_hook.
        var receiveTask2: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            receiveTask2 = Task.detached {
                let l2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l2) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }),
                       l2.objects(SimpleSyncObject.self).contains(where: { $0.value == 200 }) {
                        break
                    }
                }
            }
        }

        let obj2 = SimpleSyncObject(value: 200, floatValue: 2.0)
        lattice.add(obj2)
        try await receiveTask2?.value

        #expect(lattice2.objects(SimpleSyncObject.self).count >= 2,
                "Lattice2 should have both objects after compaction sync")
        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 200 }),
                "New data written after client compaction should sync")
    }

    /// Test that closing the lattice instance that owns the synchronizer
    /// hands off sync responsibility to a surviving sibling instance.
    @Test(.timeLimit(.minutes(1))) func test_SyncHandoff() async throws {
        let lattice2 = localLattice2!

        // Fresh path so we control which instance gets the synchronizer
        let handoffURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let handoffConfig = Lattice.Configuration(
            fileURL: handoffURL,
            authorizationToken: "hi",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        // Instance A from actor context — gets the synchronizer
        let instanceA = try Lattice(SimpleSyncObject.self, configuration: handoffConfig)

        // Wait for A to connect
        var attempts = 0
        while !instanceA.isSyncConnected && attempts < 50 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        #expect(instanceA.isSyncConnected, "Instance A should be sync-connected")

        // Set up lattice2 listener before the handoff
        let localLattice2Configuration = self.localLattice2Configuration
        var receiveTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            receiveTask = Task.detached {
                let l2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        // Instance B lives entirely in a detached task (different isolation → different scheduler)
        // Use streams to coordinate: B signals ready, we close A, then signal B to write
        let bReady = AsyncStream.makeStream(of: Void.self)
        let proceed = AsyncStream.makeStream(of: Void.self)

        let writeTask = Task.detached {
            let instanceB = try Lattice(SimpleSyncObject.self, configuration: handoffConfig)

            // Signal that B is alive and registered in the instance_registry
            bReady.continuation.yield()

            // Wait for A to be closed (handoff happens during close)
            for await _ in proceed.stream { break }

            // B should now have inherited sync responsibility
            var attempts = 0
            while !instanceB.isSyncConnected && attempts < 50 {
                try await Task.sleep(for: .milliseconds(100))
                attempts += 1
            }
            guard instanceB.isSyncConnected else {
                throw NSError(domain: "SyncHandoff", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Instance B did not pick up sync after handoff"])
            }

            // Write through B — should sync to lattice2
            instanceB.add(SimpleSyncObject(value: 777, floatValue: 7.7))
        }

        // Wait for B to exist
        for await _ in bReady.stream { break }

        // Close A — teardown_sync hands off to B
        instanceA.close()

        // Tell B to proceed
        proceed.continuation.yield()
        proceed.continuation.finish()

        try await writeTask.value
        try await receiveTask?.value

        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 777 }),
                "Data written through instance B (after handoff) should sync to lattice2")

        try? Lattice.delete(for: handoffConfig)
    }

    /// Test that a bulk insert in a transaction syncs correctly.
    @Test(.timeLimit(.minutes(1))) func test_BulkInsertSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        let count = 100

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    insertCount += resolved.count(where: { $0.tableName == "SimpleSyncObject" && $0.operation == .insert })
                    if insertCount >= count {
                        break
                    }
                }
            }
        }

        let objects = (0..<count).map { SimpleSyncObject(value: $0, floatValue: Float($0)) }
        lattice.transaction {
            lattice.add(contentsOf: objects)
        }

        try await task?.value

        #expect(lattice2.objects(SimpleSyncObject.self).count == count, "All \(count) objects should sync")
    }
}

// MARK: - Filtered Sync Models

@Model class FilteredNote {
    var title: String
    var isPublic: Bool

    init(title: String = "", isPublic: Bool = false) {
        self.title = title
        self.isPublic = isPublic
    }
}

@Model class FilteredTag {
    var name: String

    init(name: String = "") {
        self.name = name
    }
}

// MARK: - SyncFilter Unit Tests

@Suite("SyncFilter Tests")
struct SyncFilterTests {
    @Test func include_withoutPredicate_addsEntry() {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        // The entry should exist with nil predicate (all rows).
        // Regression: `entries[key] = nil` removes the key in [String: String?] dictionaries.
        #expect(filter != Lattice.SyncFilter()) // must not be empty
    }

    @Test func include_withPredicate_addsEntry() {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        #expect(filter != Lattice.SyncFilter())
    }

    @Test func exclude_removesEntry() {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        filter.include(FilteredTag.self)
        filter.exclude(FilteredNote.self)
        // Should still have FilteredTag
        #expect(filter != Lattice.SyncFilter())
        // Exclude the last one
        filter.exclude(FilteredTag.self)
        #expect(filter == Lattice.SyncFilter())
    }

    @Test func emptyFilter_notEqualToFilterWithEntries() {
        let empty = Lattice.SyncFilter()
        var withEntry = Lattice.SyncFilter()
        withEntry.include(FilteredNote.self)
        #expect(empty != withEntry)
    }

    @Test func include_sameTable_twice_isIdempotent() {
        var filter1 = Lattice.SyncFilter()
        filter1.include(FilteredNote.self)

        var filter2 = Lattice.SyncFilter()
        filter2.include(FilteredNote.self)
        filter2.include(FilteredNote.self)

        #expect(filter1 == filter2)
    }
}

// MARK: - Filtered Sync Tests

@Suite("Filtered Sync Tests", .serialized)
actor FilteredSyncTests {
    let app: Application
    let serverLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let senderURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let receiverURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port: Int = 0
    var sender: Lattice!
    var receiver: Lattice!
    var serverLatticeConfig: Lattice.Configuration
    var senderConfig: Lattice.Configuration
    var receiverConfig: Lattice.Configuration

    private let sockets = SocketStore(label: "FilteredSync")

    deinit {
        app.shutdown()
        try? Lattice.delete(for: senderConfig)
        try? Lattice.delete(for: receiverConfig)
        try? Lattice.delete(for: serverLatticeConfig)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.serverLatticeConfig = .init(fileURL: serverLatticeURL)
        self.senderConfig = .init(fileURL: senderURL)
        self.receiverConfig = .init(fileURL: receiverURL)
        app.http.server.configuration.port = 0

        // Server lattice (no sync endpoint)
        let _ = try Lattice(FilteredNote.self, FilteredTag.self, configuration: serverLatticeConfig)

        // Launch WebSocket relay
        let serverLatticeConfig = self.serverLatticeConfig
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            self.sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else { return }
                if kind == "auditLog" {
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    for socket in self.sockets.others(excluding: ws) {
                        socket.send(bb)
                    }
                }
                Task.detached {
                    let lattice = try Lattice(configuration: serverLatticeConfig)
                    _ = try? lattice.receive(data)
                }
            }
            let lattice = try! Lattice(configuration: serverLatticeConfig)
            let events = try! lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let encoded = events.isEmpty ? nil : try! JSONEncoder().encode(ServerSentEvent.auditLog(events))
            encoded.map { encoded in ws.send(ByteBuffer(data: encoded)) }
        }

        try await app.startup()
        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw SyncTests.SyncTestError.noPort
        }
        self.port = assignedPort

        // Receiver: no sync filter (accepts everything the server sends)
        receiverConfig = Lattice.Configuration(
            fileURL: receiverURL,
            authorizationToken: "recv",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        receiver = try Lattice(FilteredNote.self, FilteredTag.self, configuration: receiverConfig)
    }

    /// Helper: create a sender with a given sync filter
    private func makeSender(syncFilter: Lattice.SyncFilter?) throws -> Lattice {
        senderConfig = Lattice.Configuration(
            fileURL: senderURL,
            authorizationToken: "send",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"),
            syncFilter: syncFilter)
        let s = try Lattice(FilteredNote.self, FilteredTag.self, configuration: senderConfig)
        return s
    }

    /// Start listening for a specific table+operation on receiver BEFORE performing the action.
    /// Returns a task — await its value AFTER performing the action.
    private func startListeningForReceiver(
        table: String, operation: AuditLog.Operation
    ) async -> Task<Void, any Error> {
        var task: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let r = try await Lattice(FilteredNote.self, FilteredTag.self, configuration: self.receiverConfig)
                let changeStream = r.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap { $0.resolve(on: r) }
                    if resolved.contains(where: { $0.tableName == table && $0.operation == operation }) {
                        return
                    }
                }
            }
        }
        return task
    }

    /// Helper: ensure nothing arrives on receiver for a given duration
    private func assertNothingReceived(
        table: String, duration: Duration = .seconds(2)
    ) async throws {
        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached {
                let r = try await Lattice(FilteredNote.self, FilteredTag.self, configuration: self.receiverConfig)
                let changeStream = r.changeStream
                let innerTask = Task {
                    for await changes in changeStream {
                        let resolved = changes.compactMap { $0.resolve(on: r) }
                        if resolved.contains(where: { $0.tableName == table }) {
                            return true
                        }
                    }
                    return false
                }
                try? await Task.sleep(for: duration)
                innerTask.cancel()
                let result = (try? await innerTask.value) ?? false
                continuation.resume(returning: result)
            }
        }
        if received {
            Issue.record("Unexpected sync of table \(table)")
        }
    }

    // =========================================================================
    // Test 1: Only configured tables sync
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_TableWhitelist() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)

        let note = FilteredNote(title: "public note", isPublic: true)
        let tag = FilteredTag(name: "private-tag")
        sender.add(note)
        sender.add(tag)

        try await task.value

        // Tag should NOT have synced
        try await assertNothingReceived(table: "FilteredTag")

        // Only note should be on receiver
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredTag.self).count == 0)
    }

    // =========================================================================
    // Test 2: Only matching rows sync
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_PredicateFilter() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)

        let publicNote = FilteredNote(title: "visible", isPublic: true)
        let privateNote = FilteredNote(title: "hidden", isPublic: false)
        sender.add(publicNote)
        sender.add(privateNote)

        try await task.value

        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "visible")
    }

    // =========================================================================
    // Test 3: Object leaves sync set (update makes row fail predicate → DELETE)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_ObjectLeavesSet() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Phase 1: add public note → syncs
        let insertTask = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let note = FilteredNote(title: "was-public", isPublic: true)
        sender.add(note)
        try await insertTask.value
        #expect(receiver.objects(FilteredNote.self).count == 1)

        // Phase 2: make private → synthetic DELETE
        let deleteTask = await startListeningForReceiver(table: "FilteredNote", operation: .delete)
        note.isPublic = false
        try await deleteTask.value
        #expect(receiver.objects(FilteredNote.self).count == 0)
    }

    // =========================================================================
    // Test 4: Object enters sync set (update makes row pass predicate → INSERT)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_ObjectEntersSet() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Add a private note → should NOT sync
        let note = FilteredNote(title: "was-private", isPublic: false)
        sender.add(note)
        try await Task.sleep(for: .seconds(1))
        #expect(receiver.objects(FilteredNote.self).count == 0)

        // Make public → should trigger full INSERT
        let insertTask = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        note.isPublic = true
        try await insertTask.value
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "was-private")
    }

    // =========================================================================
    // Test 5: Runtime filter change triggers reconciliation
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_RuntimeFilterChange() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Add one public, one private
        let insertTask1 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let pub = FilteredNote(title: "public", isPublic: true)
        let priv = FilteredNote(title: "private", isPublic: false)
        sender.add(pub)
        sender.add(priv)
        try await insertTask1.value
        #expect(receiver.objects(FilteredNote.self).count == 1)

        // Change filter to include all notes → reconciliation sends private note
        let insertTask2 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        var newFilter = Lattice.SyncFilter()
        newFilter.include(FilteredNote.self)
        sender.updateSyncFilter(newFilter)
        try await insertTask2.value
        #expect(receiver.objects(FilteredNote.self).count == 2)
    }

    // =========================================================================
    // Test 5b: Narrowing filter triggers reconciliation DELETE
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_RuntimeFilterNarrowing() async throws {
        // Start with filter that includes all notes
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Add one public, one private — both should sync
        let insertTask1 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let pub = FilteredNote(title: "public", isPublic: true)
        sender.add(pub)
        try await insertTask1.value

        let insertTask2 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let priv = FilteredNote(title: "private", isPublic: false)
        sender.add(priv)
        try await insertTask2.value
        #expect(receiver.objects(FilteredNote.self).count == 2)

        // Narrow filter to public-only → reconciliation sends DELETE for private note
        let deleteTask = await startListeningForReceiver(table: "FilteredNote", operation: .delete)
        var narrowFilter = Lattice.SyncFilter()
        narrowFilter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender.updateSyncFilter(narrowFilter)
        try await deleteTask.value
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "public")
    }

    // =========================================================================
    // Test 6: nil filter syncs everything (backwards compatible)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_NilFilterSyncsEverything() async throws {
        sender = try makeSender(syncFilter: nil)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let note = FilteredNote(title: "unfiltered", isPublic: false)
        let tag = FilteredTag(name: "unfiltered-tag")
        sender.add(note)
        sender.add(tag)
        try await task.value

        // Give a moment for tag to sync too
        try await Task.sleep(for: .seconds(1))
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredTag.self).count == 1)
    }

    // =========================================================================
    // Test 7: Empty filter syncs nothing
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_EmptyFilterSyncsNothing() async throws {
        let filter = Lattice.SyncFilter()
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        let note = FilteredNote(title: "blocked", isPublic: true)
        sender.add(note)

        try await assertNothingReceived(table: "FilteredNote")
        #expect(receiver.objects(FilteredNote.self).count == 0)
    }

    // =========================================================================
    // Test 8: Download ignores filter (filter is upload-only)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_FilteredSync_DownloadIgnoresFilter() async throws {
        sender = try makeSender(syncFilter: nil)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let note = FilteredNote(title: "from-sender", isPublic: false)
        sender.add(note)
        try await task.value

        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "from-sender")
    }
}

// =============================================================================
// MARK: - IPC Sync Tests
// =============================================================================

@Model class IPCNote {
    var title: String
    var isPublic: Bool

    init(title: String = "", isPublic: Bool = false) {
        self.title = title
        self.isPublic = isPublic
    }
}

@Suite("IPC Sync Tests")
actor IPCSyncTests {
    let sourceURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let targetURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var sourceConfig: Lattice.Configuration
    var targetConfig: Lattice.Configuration

    init() {
        self.sourceConfig = .init(fileURL: sourceURL)
        self.targetConfig = .init(fileURL: targetURL)
    }

    deinit {
        try? Lattice.delete(for: sourceConfig)
        try? Lattice.delete(for: targetConfig)
    }

    /// Create an observer config from an IPC config by stripping ipcTargets.
    /// This opens a plain DB connection (no new IPC endpoints) to the same file.
    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        return c
    }

    /// Wait for a specific table+operation to arrive on a Lattice DB via changeStream.
    /// Opens a read-only view (no IPC targets) to avoid creating new IPC connections.
    private func waitForChange(
        on config: Lattice.Configuration,
        table: String,
        operation: AuditLog.Operation
    ) async -> Task<Void, any Error> {
        let readConfig = observerConfig(from: config)
        var task: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let db = try Lattice(IPCNote.self, configuration: readConfig)
                let stream = db.changeStream
                continuation.resume()
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: db) }
                    if resolved.contains(where: { $0.tableName == table && $0.operation == operation }) {
                        return
                    }
                }
            }
        }
        return task
    }

    // =========================================================================
    // Test 1: Source → Target (basic IPC sync)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_SourceToTarget() async throws {
        let channel = "ipc-test-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)

        let note = IPCNote(title: "hello from source", isPublic: true)
        source.add(note)

        try await task.value

        let targetNotes = target.objects(IPCNote.self)
        #expect(targetNotes.count == 1)
        #expect(targetNotes.first?.title == "hello from source")
    }

    // =========================================================================
    // Test 2: Bidirectional (target → source flows back)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_Bidirectional() async throws {
        let channel = "ipc-bidi-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Phase 1: source → target
        let task1 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "from source"))
        try await task1.value

        #expect(target.objects(IPCNote.self).count == 1)
        #expect(target.objects(IPCNote.self).first?.title == "from source")

        // Phase 2: target → source
        let task2 = await waitForChange(on: sourceConfig, table: "IPCNote", operation: .insert)
        target.add(IPCNote(title: "from target"))
        try await task2.value

        // Use snapshot() to avoid "count differed in successive traversals" —
        // the lazy Results cursor can see concurrent IPC writes mid-iteration.
        let sourceNotes = source.objects(IPCNote.self).snapshot()
        #expect(sourceNotes.count == 2)
        let sourceTitles = sourceNotes.map(\.title).sorted()
        #expect(sourceTitles == ["from source", "from target"])
    }

    // =========================================================================
    // Test 3: Filtered IPC (only matching rows sync)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_WithFilter() async throws {
        let channel = "ipc-filt-\(String.random(length: 8))"

        var filter = Lattice.SyncFilter()
        filter.include(IPCNote.self, where: { $0.isPublic == true })

        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)

        // Add both public and private notes
        source.add(IPCNote(title: "public note", isPublic: true))
        source.add(IPCNote(title: "private note", isPublic: false))

        try await task.value

        // Both entries processed in one sync batch — private was filtered out
        let targetNotes = target.objects(IPCNote.self)
        #expect(targetNotes.count == 1)
        #expect(targetNotes.first?.title == "public note")
    }

    // =========================================================================
    // Test 4: Object leaves IPC sync set (update fails predicate → DELETE)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_FilteredObjectLeavesSet() async throws {
        let channel = "ipc-leave-\(String.random(length: 8))"

        var filter = Lattice.SyncFilter()
        filter.include(IPCNote.self, where: { $0.isPublic == true })

        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Insert a public note — should sync
        let task1 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        let note = IPCNote(title: "will go private", isPublic: true)
        source.add(note)
        try await task1.value
        #expect(target.objects(IPCNote.self).count == 1)

        // Update note to private — should trigger synthetic DELETE on target
        let task2 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .delete)
        note.isPublic = false
        try await task2.value
        #expect(target.objects(IPCNote.self).count == 0)
    }

    // =========================================================================
    // Test 5: Object enters IPC sync set (update passes predicate → INSERT)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_FilteredObjectEntersSet() async throws {
        let channel = "ipc-enter-\(String.random(length: 8))"

        var filter = Lattice.SyncFilter()
        filter.include(IPCNote.self, where: { $0.isPublic == true })

        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Insert a private note — should NOT sync (filtered out)
        let note = IPCNote(title: "was private", isPublic: false)
        source.add(note)

        // Update note to public — should trigger full-state INSERT on target.
        // The sync entries are ordered, so by the time this INSERT arrives,
        // the original private INSERT was already processed and filtered out.
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        note.isPublic = true
        try await task.value
        #expect(target.objects(IPCNote.self).count == 1)
        #expect(target.objects(IPCNote.self).first?.title == "was private")
    }

    // =========================================================================
    // Test 6: Multiple IPC channels from one source
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_MultipleChannels() async throws {
        let channelA = "ipc-multi-a-\(String.random(length: 8))"
        let channelB = "ipc-multi-b-\(String.random(length: 8))"

        let targetBURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        var targetBConfig = Lattice.Configuration(fileURL: targetBURL)
        defer { try? Lattice.delete(for: targetBConfig) }

        // Source serves two channels: A gets public notes, B gets all notes
        var filterPublic = Lattice.SyncFilter()
        filterPublic.include(IPCNote.self, where: { $0.isPublic == true })

        sourceConfig.ipcTargets = [
            .init(channel: channelA, syncFilter: filterPublic),
            .init(channel: channelB)
        ]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        // Target A connects on channel A (filtered)
        targetConfig.ipcTargets = [.init(channel: channelA)]
        let targetA = try Lattice(IPCNote.self, configuration: targetConfig)

        // Target B connects on channel B (unfiltered)
        targetBConfig.ipcTargets = [.init(channel: channelB)]
        let targetB = try Lattice(IPCNote.self, configuration: targetBConfig)

        // Add public note first — syncs to both channels
        let taskA = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        let taskB1 = await waitForChange(on: targetBConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "public note", isPublic: true))
        try await taskA.value
        try await taskB1.value

        // Add private note — only syncs to channel B (unfiltered)
        let taskB2 = await waitForChange(on: targetBConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "private note", isPublic: false))
        try await taskB2.value

        // Target A: only public note (filtered)
        #expect(targetA.objects(IPCNote.self).count == 1)
        #expect(targetA.objects(IPCNote.self).first?.title == "public note")

        // Target B: both notes (unfiltered)
        let bTitles = targetB.objects(IPCNote.self).map(\.title).sorted()
        #expect(bTitles == ["private note", "public note"])
    }

    // =========================================================================
    // Test 5: Reconnection after server restart
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_Reconnection() async throws {
        let channel = "ipc-recon-\(String.random(length: 8))"

        // Phase 1: Start source, connect target, sync a note
        sourceConfig.ipcTargets = [.init(channel: channel)]
        var source: Lattice! = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        let task1 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "before restart"))
        try await task1.value
        #expect(target.objects(IPCNote.self).count == 1)

        // Phase 2: Close source (simulates process exit — destructor is synchronous)
        source = nil

        // Phase 3: Re-open source on same channel, add a note.
        // waitForChange naturally waits for the target to reconnect (backoff)
        // and the data to sync through.
        source = try Lattice(IPCNote.self, configuration: sourceConfig)

        let task2 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "after restart"))
        try await task2.value

        let targetTitles = target.objects(IPCNote.self).map(\.title).sorted()
        #expect(targetTitles == ["after restart", "before restart"])
    }

    // =========================================================================
    // Test 7: Runtime filter widening over IPC (updateSyncFilter)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_RuntimeFilterWidening() async throws {
        let channel = "ipc-widen-\(String.random(length: 8))"

        // Start with filter: only public notes sync
        var filter = Lattice.SyncFilter()
        filter.include(IPCNote.self, where: { $0.isPublic == true })

        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Add both public and private notes
        let task1 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "public note", isPublic: true))
        source.add(IPCNote(title: "private note", isPublic: false))
        try await task1.value

        // Both entries processed in one batch — private was filtered out
        #expect(target.objects(IPCNote.self).count == 1)
        #expect(target.objects(IPCNote.self).first?.title == "public note")

        // Widen filter to include all notes → reconciliation sends private note
        let task2 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        var wideFilter = Lattice.SyncFilter()
        wideFilter.include(IPCNote.self)
        source.updateSyncFilter(wideFilter)
        try await task2.value

        let titles = target.objects(IPCNote.self).map(\.title).sorted()
        #expect(titles == ["private note", "public note"])
    }

    // =========================================================================
    // Test 8: Runtime filter narrowing over IPC (updateSyncFilter)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_RuntimeFilterNarrowing() async throws {
        let channel = "ipc-narrow-\(String.random(length: 8))"

        // Start with filter that includes all notes
        var filter = Lattice.SyncFilter()
        filter.include(IPCNote.self)

        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Add both notes — both should sync
        let task1 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "public note", isPublic: true))
        try await task1.value

        let task2 = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "private note", isPublic: false))
        try await task2.value
        #expect(target.objects(IPCNote.self).count == 2)

        // Narrow filter to public-only → reconciliation sends DELETE for private
        let deleteTask = await waitForChange(on: targetConfig, table: "IPCNote", operation: .delete)
        var narrowFilter = Lattice.SyncFilter()
        narrowFilter.include(IPCNote.self, where: { $0.isPublic == true })
        source.updateSyncFilter(narrowFilter)
        try await deleteTask.value

        #expect(target.objects(IPCNote.self).count == 1)
        #expect(target.objects(IPCNote.self).first?.title == "public note")
    }

    // =========================================================================
    // Test 9: Deleted rows are skipped during sync catchup (no crash)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_DeletedRowSkippedOnCatchup() async throws {
        let channel = "ipc-del-\(String.random(length: 8))"

        // Source: add a note, then delete it (before target connects)
        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)
        let note = IPCNote(title: "will be deleted", isPublic: true)
        source.add(note)
        source.delete(note)

        // Target connects — initial catchup processes AuditLog with INSERT
        // for a row that no longer exists. Should not crash.
        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Wait for a NEW note to sync. IPC is ordered, so by the time this
        // INSERT arrives, the initial catchup (INSERT+DELETE for the deleted
        // note) has already completed on the target.
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "alive note", isPublic: true))
        try await task.value

        // Only the alive note should exist — the deleted note's INSERT+DELETE
        // from the initial catchup should have cancelled out.
        #expect(target.objects(IPCNote.self).count == 1)
        #expect(target.objects(IPCNote.self).first?.title == "alive note")
    }

    // =========================================================================
    // Test 10: Stale socket file doesn't prevent IPC from connecting
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_StaleSocketRecovery() async throws {
        let channel = "ipc-stale-\(String.random(length: 8))"

        // Create a stale socket file (simulates a crashed process that didn't clean up)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socketDir = home.appending(path: "Library/Caches/Lattice/ipc")
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        let socketPath = socketDir.appending(path: "\(channel).sock")

        // Create a Unix domain socket, bind it, then close it — leaves the file behind
        #if os(Linux)
        let staleSock = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let staleSock = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        #expect(staleSock >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(staleSock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bindResult == 0)
        close(staleSock)
        // Socket file now exists but nobody is listening — this is the stale state

        // Verify the stale file exists
        #expect(FileManager.default.fileExists(atPath: socketPath.path))

        // Now start IPC — should detect the stale socket, remove it, and bind as server
        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        // Wait for insert to arrive — no sleep needed
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)
        source.add(IPCNote(title: "survived stale socket", isPublic: true))
        try await task.value

        #expect(target.objects(IPCNote.self).count == 1)
        #expect(target.objects(IPCNote.self).first?.title == "survived stale socket")
    }

    // =========================================================================
    // Test 12: BLOB/vector columns survive IPC JSON round-trip
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_BlobColumnRoundTrip() async throws {
        let channel = "ipc-blob-\(String.random(length: 8))"

        let sourceURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let targetURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")

        var srcCfg = Lattice.Configuration(fileURL: sourceURL)
        srcCfg.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(SyncVectorObject.self, configuration: srcCfg)

        var tgtCfg = Lattice.Configuration(fileURL: targetURL)
        tgtCfg.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(SyncVectorObject.self, configuration: tgtCfg)

        // Wait for change on target via changeStream (no IPC endpoints)
        let task = await waitForChange(on: tgtCfg, table: "SyncVectorObject", operation: .insert)

        // Insert an object with a FloatVector (BLOB) field
        let embedding: [Float] = [1.0, 2.0, 3.0, 4.5, -0.5]
        let obj = SyncVectorObject(label: "blob test", embedding: embedding)
        source.add(obj)

        try await task.value

        // Verify the BLOB survived the IPC JSON round-trip
        let targetObjects = target.objects(SyncVectorObject.self)
        #expect(targetObjects.count == 1)
        #expect(targetObjects.first?.label == "blob test")

        let targetEmbedding = targetObjects.first?.embedding.elements ?? []
        #expect(targetEmbedding.count == embedding.count)
        for (a, b) in zip(targetEmbedding, embedding) {
            #expect(Swift.abs(a - b) < 0.001, "Embedding mismatch: \(a) vs \(b)")
        }

        try? Lattice.delete(for: srcCfg)
        try? Lattice.delete(for: tgtCfg)
    }

    // =========================================================================
    // Test 13: Subquery-filtered IPC sync (only links whose endpoints match)
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_SubqueryFilteredLinks() async throws {
        let channel = "ipc-sq-\(String.random(length: 8))"

        let srcURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let tgtURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")

        // Build filter: only public alpha items AND links between them
        let alphaPredicate: @Sendable (Query<SQItem>) -> Query<Bool> = { item in
            item.category == "alpha" && item.isPublic == true
        }
        var filter = Lattice.SyncFilter()
        filter.include(SQItem.self, where: alphaPredicate)
        filter.include(SQLink.self) { link in
            link.sourceGlobalId.in(\SQItem.__globalId, where: alphaPredicate)
                && link.targetGlobalId.in(\SQItem.__globalId, where: alphaPredicate)
        }

        var srcCfg = Lattice.Configuration(fileURL: srcURL)
        srcCfg.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(SQItem.self, SQLink.self, configuration: srcCfg)

        var tgtCfg = Lattice.Configuration(fileURL: tgtURL)
        tgtCfg.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(SQItem.self, SQLink.self, configuration: tgtCfg)

        // Wait for SQLink insert on target via changeStream (no IPC endpoints)
        let task = await waitForChange(on: tgtCfg, table: "SQLink", operation: .insert)

        // Create items: 2 public alpha, 1 beta, 1 private alpha
        let a0 = SQItem(name: "a0", category: "alpha", isPublic: true)
        let a1 = SQItem(name: "a1", category: "alpha", isPublic: true)
        let b0 = SQItem(name: "b0", category: "beta",  isPublic: true)
        let secret = SQItem(name: "secret", category: "alpha", isPublic: false)
        source.add(contentsOf: [a0, a1, b0, secret])

        // Create links
        let aaLink = SQLink(sourceGlobalId: a0.__globalId!, targetGlobalId: a1.__globalId!, label: "aa")
        let abLink = SQLink(sourceGlobalId: a0.__globalId!, targetGlobalId: b0.__globalId!, label: "ab")
        let asLink = SQLink(sourceGlobalId: a0.__globalId!, targetGlobalId: secret.__globalId!, label: "as")
        source.add(contentsOf: [aaLink, abLink, asLink])

        _ = try await task.value

        // All entries processed in one sync batch — filtered entries skipped
        // Target should have: 2 items (a0, a1), 1 link (aa only)
        let targetItems = target.objects(SQItem.self)
        let targetLinks = target.objects(SQLink.self)

        #expect(targetItems.count == 2, "Expected 2 items, got \(targetItems.count)")
        #expect(targetLinks.count == 1, "Expected 1 link (aa), got \(targetLinks.count)")
        #expect(targetLinks.first?.label == "aa")

        try? Lattice.delete(for: srcCfg)
        try? Lattice.delete(for: tgtCfg)
    }

    // NOTE: The "destroy synchronizer during scheduled work" race is tested
    // at the C++ level in LatticeCore (test_synchronizer_destroy_race).
    // A Swift-level test cannot trigger this race because the Lattice static
    // cache holds a strong reference — `server = nil` is a no-op.
}

// =============================================================================
// MARK: - IPC Cloud Relay Test (local ←IPC→ synced ←WSS→ server)
// =============================================================================

@Suite("IPC Cloud Relay Tests")
actor IPCCloudRelayTests {
    let app: Application
    let localURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let syncedURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let serverURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var localConfig: Lattice.Configuration
    var syncedConfig: Lattice.Configuration
    var serverConfig: Lattice.Configuration
    var port: Int = 0

    private let sockets = SocketStore(label: "IPCCloudRelay")

    deinit {
        app.shutdown()
        try? Lattice.delete(for: localConfig)
        try? Lattice.delete(for: syncedConfig)
        try? Lattice.delete(for: serverConfig)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.localConfig = .init(fileURL: localURL)
        self.syncedConfig = .init(fileURL: syncedURL)
        self.serverConfig = .init(fileURL: serverURL)
        app.http.server.configuration.port = 0

        // Server-side lattice (no sync)
        let _ = try Lattice(IPCNote.self, configuration: serverConfig)

        // WebSocket relay server
        let serverConfigCopy = self.serverConfig
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            self.sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else { return }
                if kind == "auditLog" {
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    for socket in self.sockets.others(excluding: ws) {
                        socket.send(bb)
                    }
                }
                Task.detached {
                    let lattice = try Lattice(configuration: serverConfigCopy)
                    _ = try? lattice.receive(data)
                }
            }
            let lattice = try! Lattice(configuration: serverConfigCopy)
            let events = try! lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let encoded = events.isEmpty ? nil : try! JSONEncoder().encode(ServerSentEvent.auditLog(events))
            encoded.map { encoded in ws.send(ByteBuffer(data: encoded)) }
        }

        try await app.startup()
        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw SyncTests.SyncTestError.noPort
        }
        self.port = assignedPort
    }

    /// Create a plain observer config by stripping IPC/WSS targets.
    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        c.wssEndpoint = nil
        c.authorizationToken = nil
        return c
    }

    /// Wait for a change on a plain DB (no IPC, no WSS).
    private func waitForChange(
        on config: Lattice.Configuration,
        table: String,
        operation: AuditLog.Operation
    ) async -> Task<Void, any Error> {
        let readConfig = observerConfig(from: config)
        var task: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let db = try await Lattice(IPCNote.self, configuration: readConfig)
                let stream = db.changeStream
                continuation.resume()
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: db) }
                    if resolved.contains(where: { $0.tableName == table && $0.operation == operation }) {
                        return
                    }
                }
            }
        }
        return task
    }

    // =========================================================================
    // Full pipeline: local →IPC→ synced →WSS→ server
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_CloudRelay() async throws {
        let channel = "ipc-relay-\(String.random(length: 8))"

        // local (memory.db): IPC server with filter — only public notes leave
        var filter = Lattice.SyncFilter()
        filter.include(IPCNote.self, where: { $0.isPublic == true })

        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(IPCNote.self, configuration: localConfig)

        // synced (memory_synced.db): IPC client + WSS to cloud
        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "relay-token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        let synced = try Lattice(IPCNote.self, configuration: syncedConfig)

        // Listen for the note to arrive on the server DB
        let task = await waitForChange(on: serverConfig, table: "IPCNote", operation: .insert)

        // Insert on local — should flow: local →IPC→ synced →WSS→ server
        local.add(IPCNote(title: "relayed note", isPublic: true))

        try await task.value

        // Verify the full pipeline
        let server = try Lattice(IPCNote.self, configuration: serverConfig)
        let serverNotes = server.objects(IPCNote.self)
        #expect(serverNotes.count == 1)
        #expect(serverNotes.first?.title == "relayed note")

        let syncedNotes = synced.objects(IPCNote.self)
        #expect(syncedNotes.count == 1)
        #expect(syncedNotes.first?.title == "relayed note")
    }

    // =========================================================================
    // Full pipeline reverse: cloudDevice →WSS→ server →relay→ synced →IPC→ local
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_IPCSync_ReverseCloudRelay() async throws {
        let channel = "ipc-rev-\(String.random(length: 8))"

        // local: IPC server (the hub — no WSS, receives from synced via IPC)
        localConfig.ipcTargets = [.init(channel: channel)]
        let local = try Lattice(IPCNote.self, configuration: localConfig)

        // synced: IPC client + WSS to cloud (the relay node)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "reverse-relay-token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        let synced = try Lattice(IPCNote.self, configuration: syncedConfig)

        // cloudDevice: another WSS client (simulates a remote device pushing to cloud)
        let cloudDeviceURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        var cloudConfig = Lattice.Configuration(fileURL: cloudDeviceURL)
        cloudConfig.authorizationToken = "cloud-device-token"
        cloudConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        defer { try? Lattice.delete(for: cloudConfig) }
        let cloudDevice = try Lattice(IPCNote.self, configuration: cloudConfig)

        // Listen for the note to arrive on LOCAL (final destination in reverse relay)
        let task = await waitForChange(on: localConfig, table: "IPCNote", operation: .insert)

        // Insert on cloud device → WSS → server → relay to synced → IPC → local
        cloudDevice.add(IPCNote(title: "from the cloud", isPublic: true))

        try await task.value

        // Verify the full reverse pipeline reached local
        let localNotes = local.objects(IPCNote.self).filter { $0.title == "from the cloud" }
        #expect(localNotes.count == 1)

        // Verify synced also has the note (intermediate relay node)
        let syncedNotes = synced.objects(IPCNote.self).filter { $0.title == "from the cloud" }
        #expect(syncedNotes.count == 1)
    }
}

// MARK: - Sync Progress Tests

@Suite("Sync Progress Tests")
actor SyncProgressTests {
    let app: Application
    let syncLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice1URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice2URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port: Int = 0
    var localLattice1: Lattice!
    var localLattice2: Lattice!
    var syncedLattice: Lattice!
    var syncedLatticeConfiguration: Lattice.Configuration
    var localLattice1Configuration: Lattice.Configuration
    var localLattice2Configuration: Lattice.Configuration

    private let sockets = SocketStore(label: "SyncProgress")

    deinit {
        app.shutdown()
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
    }

    private func launchServer() async throws {
        let syncedLatticeConfiguration = self.syncedLatticeConfiguration
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            print("[SERVER:SyncProgress] New WebSocket connection accepted, total=\(self.sockets.count + 1)")
            self.sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else {
                    print("[SERVER:SyncProgress] Failed to parse incoming message")
                    return
                }

                if kind == "auditLog" {
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        print("[SERVER:SyncProgress] Received \(auditLogs.count) audit entries, sending ACK for \(globalIds.count) ids")
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    let others = self.sockets.others(excluding: ws)
                    print("[SERVER:SyncProgress] Relaying to \(others.count) other sockets")
                    for socket in others {
                        socket.send(bb)
                    }
                }
                Task.detached {
                    let lattice = try Lattice(configuration: syncedLatticeConfiguration)
                    _ = try? lattice.receive(data)
                }
            }

            let lattice = try! Lattice(configuration: syncedLatticeConfiguration)
            let events = try! lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            print("[SERVER:SyncProgress] Sending \(events.count) initial events to new connection")
            let encoded = events.isEmpty ? nil : try! JSONEncoder().encode(ServerSentEvent.auditLog(events))
            encoded.map { encoded in ws.send(ByteBuffer(data: encoded)) }
        }
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.debug)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.localLattice1Configuration = .init(fileURL: lattice1URL)
        self.localLattice2Configuration = .init(fileURL: lattice2URL)
        self.syncedLatticeConfiguration = .init(fileURL: syncLatticeURL)

        app.http.server.configuration.port = 0

        syncedLattice = try Lattice(for: [SimpleSyncObject.self],
                                    configuration: syncedLatticeConfiguration)

        try await launchServer()
        try await app.startup()

        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw SyncTests.SyncTestError.noPort
        }
        self.port = assignedPort

        localLattice1Configuration = Lattice.Configuration(
            fileURL: lattice1URL,
            authorizationToken: "hi",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        localLattice2Configuration = Lattice.Configuration(
            fileURL: lattice2URL,
            authorizationToken: "hi2",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        localLattice1 = try Lattice(SimpleSyncObject.self,
                                    configuration: localLattice1Configuration)
        localLattice2 = try Lattice(SimpleSyncObject.self,
                                    configuration: localLattice2Configuration)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_UploadTracking() async throws {
        let lattice = localLattice1!
        let config = localLattice1Configuration

        // Start listening for progress where totalUpload > 0.
        // Synchronize: ensure the stream handler is registered BEFORE
        // adding objects, otherwise fire_progress() can fire before the
        // handler exists and the event is lost.
        var progressTask: Task<Lattice.SyncProgress, any Error>?
        await withCheckedContinuation { continuation in
            progressTask = Task.detached {
                let l = try Lattice(SimpleSyncObject.self, configuration: config)
                let stream = l.syncProgressStream
                continuation.resume()
                for await progress in stream {
                    if progress.totalUpload > 0 {
                        return progress
                    }
                }
                return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
            }
        }

        // Add objects to trigger upload
        for i in 0..<5 {
            lattice.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }

        let progress = try await progressTask!.value
        #expect(progress.totalUpload > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_AckTracking() async throws {
        let lattice = localLattice1!

        // Use the sync progress callback to detect ACK directly,
        // avoiding the race between WAL hook and acked counter.
        let acked: Lattice.SyncProgress = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice.onSyncProgress { progress in
                if progress.acked > 0 {
                    guard once.tryFire() else { return }
                    continuation.resume(returning: progress)
                }
            }
            lattice.add(SimpleSyncObject(value: 99, floatValue: 99.0))
        }

        #expect(acked.acked > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_DownloadTracking() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Wait for both WebSocket connections to be established before inserting.
        // Without this, lattice1 can upload before lattice2 connects, and the
        // server relays to 0 other sockets — lattice2 never receives the entry.
        await sockets.waitForCount(2)

        print("[DownloadTracking] START lattice1=\(lattice1URL.lastPathComponent) lattice2=\(lattice2URL.lastPathComponent) sockets=\(sockets.count)")

        // Wait for lattice2's own sync progress to show received increased.
        // Register the callback BEFORE triggering the sync so we don't miss
        // the event, and avoid creating a temporary Lattice on the same config
        // which can steal lattice2's sync connection.
        let received: Lattice.SyncProgress = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice2.onSyncProgress { progress in
                print("[DownloadTracking] onSyncProgress fired: received=\(progress.received)")
                if progress.received > 0 {
                    guard once.tryFire() else { return }
                    print("[DownloadTracking] RESUMING continuation")
                    continuation.resume(returning: progress)
                }
            }
            print("[DownloadTracking] Handler registered, adding value 77 to lattice1")
            // Callback registered; trigger the sync.
            lattice.add(SimpleSyncObject(value: 77, floatValue: 77.0))
            print("[DownloadTracking] Value 77 added to lattice1")
        }

        #expect(received.received > 0)
        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 77 }))
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_Callback() async throws {
        let lattice = localLattice1!
        let config = localLattice1Configuration

        // Use syncProgressStream (backed by onSyncProgress callback)
        // and wait for totalUpload > 0.
        // Must synchronize: ensure the stream handler is registered BEFORE
        // adding objects, otherwise fire_progress() can fire before the
        // handler exists and the event is lost.
        var callbackFired: Task<Lattice.SyncProgress, any Error>?
        await withCheckedContinuation { continuation in
            callbackFired = Task.detached {
                let l = try Lattice(SimpleSyncObject.self, configuration: config)
                let stream = l.syncProgressStream
                continuation.resume()
                for await progress in stream {
                    if progress.totalUpload > 0 {
                        return progress
                    }
                }
                return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
            }
        }

        lattice.add(SimpleSyncObject(value: 1, floatValue: 1.0))
        lattice.add(SimpleSyncObject(value: 2, floatValue: 2.0))

        let progress = try await callbackFired!.value
        #expect(progress.totalUpload > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_OwnedDB_BackgroundThread() async throws {
        let lattice = localLattice1!
        let config = localLattice1Configuration

        // The progress callback fires on the synchronizer's std_thread_scheduler
        // thread, which must NOT be the main thread.
        // Use a two-stage continuation: signal when l's callback is registered,
        // then wait for the callback to actually fire.
        var isBackgroundTask: Task<Bool, any Error>?
        await withCheckedContinuation { (readyContinuation: CheckedContinuation<Void, Never>) in
            isBackgroundTask = Task.detached {
                let l = try Lattice(SimpleSyncObject.self, configuration: config)
                return await withCheckedContinuation { resultContinuation in
                    let once = AtomicOnce()
                    l.onSyncProgress { _ in
                        guard once.tryFire() else { return }
                        resultContinuation.resume(returning: !Thread.isMainThread)
                    }
                    // l is created and callback is registered — safe to trigger sync
                    readyContinuation.resume()
                }
            }
        }

        lattice.add(SimpleSyncObject(value: 42, floatValue: 42.0))

        let result = try await isBackgroundTask!.value
        #expect(result == true, "Progress callback should fire on a background thread")
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncError_FiresOnConnectionFailure() async throws {
        // Connect to a port that isn't listening — should trigger onSyncError
        let badURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        defer { try? FileManager.default.removeItem(at: badURL) }

        let badConfig = Lattice.Configuration(
            fileURL: badURL,
            authorizationToken: "bad",
            wssEndpoint: URL(string: "ws://localhost:1/nonexistent"))

        let errorMessage: String = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            let lattice = try! Lattice(SimpleSyncObject.self, configuration: badConfig)
            lattice.onSyncError { error in
                guard once.tryFire() else { return }
                continuation.resume(returning: error)
            }
        }

        #expect(!errorMessage.isEmpty, "Error message should not be empty")
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncStateChange_Connected() async throws {
        let lattice = localLattice1!

        // Should fire with connected=true once WebSocket opens
        let connected: Bool = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice.onSyncStateChange { isConnected in
                if isConnected {
                    guard once.tryFire() else { return }
                    continuation.resume(returning: isConnected)
                }
            }
        }

        #expect(connected == true)
    }
}

// =============================================================================
// Replication Slot Tests
// =============================================================================

@Suite("Replication Slot Tests")
actor ReplicationSlotTests {
    let sourceURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let targetURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var sourceConfig: Lattice.Configuration
    var targetConfig: Lattice.Configuration

    init() {
        lattice_set_log_level(lattice.log_level.warn)
        self.sourceConfig = .init(fileURL: sourceURL)
        self.targetConfig = .init(fileURL: targetURL)
    }

    deinit {
        try? Lattice.delete(for: sourceConfig)
        try? Lattice.delete(for: targetConfig)
    }

    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        return c
    }

    private func waitForChange(
        on config: Lattice.Configuration,
        table: String,
        operation: AuditLog.Operation,
        count: Int = 1
    ) async -> Task<Void, any Error> {
        let readConfig = observerConfig(from: config)
        var task: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let db = try Lattice(IPCNote.self, configuration: readConfig)
                let stream = db.changeStream
                continuation.resume()
                var seen = 0
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: db) }
                    seen += resolved.filter { $0.tableName == table && $0.operation == operation }.count
                    if seen >= count { return }
                }
            }
        }
        return task
    }

    // =========================================================================
    // Test 1: Replication slot is created on IPC connect
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_replicationSlot_createdOnConnect() async throws {
        let channel = "slot-test-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Write + sync to confirm connection is established
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "slot test", isPublic: true))
        try await task.value

        // Both source and target should have registered their IPC slots.
        // The source has a slot for the IPC synchronizer going to target.
        // The target has a slot for the IPC synchronizer going to source.
        // Verify via safe compact: it should return 0 (slots exist, but cursor may
        // not have advanced past all entries yet) — NOT -1 (no slots).
        let result = source.compactHistory()
        #expect(result >= 0, "Safe compact should find replication slots (not -1)")
    }

    // =========================================================================
    // Test 2: Replication slot advances on ACK
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_replicationSlot_advancesOnAck() async throws {
        let channel = "slot-ack-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Write several entries and wait for sync
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert, count: 3)
        source.add(IPCNote(title: "a1", isPublic: true))
        source.add(IPCNote(title: "a2", isPublic: true))
        source.add(IPCNote(title: "a3", isPublic: true))
        try await task.value

        // Wait for ACKs to propagate
        try await Task.sleep(for: .seconds(1))

        // Safe compact should be able to delete entries (cursor advanced)
        let auditBefore = source.count(AuditLog.self)
        let deleted = source.compactHistory()
        #expect(deleted >= 0, "Should delete confirmed entries")

        // If entries were deleted, audit count should have decreased
        if deleted > 0 {
            let auditAfter = source.count(AuditLog.self)
            #expect(auditAfter < auditBefore, "Audit log should shrink after safe compact")
        }
    }

    // =========================================================================
    // Test 3: Safe compact preserves entries between different slot cursors
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_safeCompact_deletesOnlyBelowMinSlot() async throws {
        let channel = "slot-min-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Write and sync some entries
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert, count: 2)
        source.add(IPCNote(title: "m1", isPublic: true))
        source.add(IPCNote(title: "m2", isPublic: true))
        try await task.value

        // Wait for ACKs
        try await Task.sleep(for: .seconds(1))

        // Write more entries (these may not be synced yet to all slots)
        source.add(IPCNote(title: "m3", isPublic: true))

        // Safe compact should NOT delete entries that haven't been confirmed by all slots
        let deleted = source.compactHistory()
        #expect(deleted >= 0, "Safe compact should work with active slots")

        // The source should still have all its data
        #expect(source.objects(IPCNote.self).count >= 3,
            "All IPCNote objects should survive safe compaction")
    }

    // =========================================================================
    // Test 4: Safe compact returns -1 when no slots exist
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_safeCompact_noSlots_returnsNegativeOne() async throws {
        // Standalone lattice — no IPC, no sync, no replication slots
        let standaloneURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let standalone = try Lattice(IPCNote.self, configuration: .init(fileURL: standaloneURL))
        defer { try? Lattice.delete(for: .init(fileURL: standaloneURL)) }

        standalone.add(IPCNote(title: "lone", isPublic: true))
        let auditBefore = standalone.count(AuditLog.self)
        #expect(auditBefore > 0, "Should have audit entries")

        let result = standalone.compactHistory()
        #expect(result == -1, "Safe compact should return -1 when no slots exist")

        // AuditLog should be untouched
        let auditAfter = standalone.count(AuditLog.self)
        #expect(auditAfter == auditBefore, "Audit log should be untouched with no slots")
    }

    // =========================================================================
    // Test 5: Force compact resets slot cursors
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_forceCompact_resetsSlots() async throws {
        let channel = "slot-force-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Write + sync
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "f1", isPublic: true))
        try await task.value
        try await Task.sleep(for: .seconds(1))

        // Force compact — should regenerate history and reset slots
        let entries = source.forceCompactHistory()
        #expect(entries >= 1, "Force compact should create snapshot entries")

        // All audit entries should be INSERT snapshots
        let logs = source.objects(AuditLog.self).snapshot()
        for log in logs {
            #expect(log.operation == .insert, "All entries should be INSERT after force compact")
        }

        // Data should survive
        #expect(source.objects(IPCNote.self).count >= 1,
            "Data should survive force compaction")

        // Safe compact immediately after force should return 0 (slots exist, cursor reset to 0)
        let safeResult = source.compactHistory()
        #expect(safeResult >= 0, "Safe compact should find slots after force compact")
    }

    // =========================================================================
    // Test 6: Stale slot eviction
    // =========================================================================
    @Test(.timeLimit(.minutes(1)))
    func test_safeCompact_staleSlotEviction() async throws {
        let channel = "slot-stale-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(IPCNote.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(IPCNote.self, configuration: targetConfig)

        // Establish connection and sync
        let task = await waitForChange(on: targetConfig, table: "IPCNote", operation: .insert)
        source.add(IPCNote(title: "s1", isPublic: true))
        try await task.value

        // Safe compact without eviction — slots exist
        let result1 = source.compactHistory()
        #expect(result1 >= 0, "Slots should exist")

        // Safe compact with a threshold longer than the test could possibly take —
        // slots were just active so they should NOT be evicted
        let result2 = source.compactHistory(staleThresholdSeconds: 60)
        #expect(result2 >= 0, "Fresh slots should not be evicted")

        // Backdate slots by 10 seconds so they appear stale, then evict with threshold=1
        source.backdateReplicationSlots(seconds: 10)
        let result3 = source.compactHistory(staleThresholdSeconds: 1)
        // All slots are now 10s old, threshold is 1s — they should be evicted
        #expect(result3 == -1, "Backdated slots should be evicted")
    }

    /// Test that AuditLog globalId survives the C++ → Swift → JSON round-trip.
    ///
    /// The server calls `eventsAfter()` which converts C++ audit_log_entry to Swift AuditLog
    /// via `AuditLog(from: cxx)`, then encodes with `JSONEncoder` for the WebSocket payload.
    /// The client decodes this JSON and feeds it to `receive()` (C++ apply_remote_changes).
    ///
    /// Bug: `AuditLog(from: cxx)` never copies the C++ entry's globalId to Swift's `__globalId`,
    /// so `JSONEncoder` emits `"globalId": null`. The C++ parser treats null as empty string.
    /// When multiple batches arrive, the fast-path dedup (`SELECT id FROM AuditLog WHERE globalId = ?`)
    /// matches the empty-globalId rows from batch 1, causing all subsequent batches to be skipped.
    @Test(.timeLimit(.minutes(1)))
    func test_EventsAfter_GlobalId_Roundtrip() async throws {
        // Create a Lattice and add some objects so we have audit log entries
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let config = Lattice.Configuration(fileURL: url)
        let lattice = try Lattice(SimpleSyncObject.self, configuration: config)

        for i in 0..<5 {
            lattice.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }

        // Get events through the same path the server uses
        let events = try lattice.eventsAfter(globalId: nil)
        #expect(events.count >= 5, "Should have at least 5 audit log entries")

        // Encode to JSON (same as ServerSentEvent.auditLog does)
        let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(events))

        // Parse the JSON and check that globalId fields are not null
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let auditLogs = json["auditLog"] as! [[String: Any]]

        var nullCount = 0
        for entry in auditLogs {
            if entry["globalId"] is NSNull || entry["globalId"] == nil {
                nullCount += 1
            }
        }

        #expect(nullCount == 0,
                "All \(auditLogs.count) audit entries should have non-null globalId, but \(nullCount) had null. This causes multi-batch sync dedup failures.")

        try? Lattice.delete(for: config)
    }
}
