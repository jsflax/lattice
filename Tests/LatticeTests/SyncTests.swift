import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(MapKit)
import MapKit
#endif
import Testing
//import SwiftUI
import Lattice
import Observation
import Vapor

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
private final class SocketStore: @unchecked Sendable {
    private var _sockets: [WebSocket] = []
    private let lock = NSLock()

    func append(_ ws: WebSocket) {
        lock.lock()
        _sockets.append(ws)
        lock.unlock()
    }

    func others(excluding ws: WebSocket) -> [WebSocket] {
        lock.lock()
        let result = _sockets.filter { $0 !== ws }
        lock.unlock()
        return result
    }
}

@Suite("Sync Tests", .serialized)
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
    private let sockets = SocketStore()
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
        lattice_set_log_level(lattice.log_level.debug)
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

        let l1Values = Set(lattice.objects(SimpleSyncObject.self).snapshot().map(\.value))
        let l2Values = Set(lattice2.objects(SimpleSyncObject.self).snapshot().map(\.value))
        #expect(l1Values.contains(111) && l1Values.contains(222), "Lattice1 should see values from both clients")
        #expect(l2Values.contains(111) && l2Values.contains(222), "Lattice2 should see values from both clients")
    }

    /// Test that a fresh client receives historical events on connect via eventsAfter().
    @Test(.timeLimit(.minutes(1))) func test_CatchUpSync() async throws {
        let lattice = localLattice1!

        // Write data and wait for it to sync to the server
        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let l1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = l1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l1) })
                    if resolved.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SimpleSyncObject(value: 999, floatValue: 9.9)
        lattice.add(obj)
        try await syncTask?.value

        // Create a fresh client — it should receive the historical data on connect
        let freshURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let freshConfig = Lattice.Configuration(
            fileURL: freshURL,
            authorizationToken: "hi3",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        // Historical events arrive during init (server sends eventsAfter on ws open).
        // Poll since events may arrive before we can attach a changeStream listener.
        let freshLattice = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshConfig)
        var attempts = 0
        while freshLattice.objects(SimpleSyncObject.self).count == 0 && attempts < 50 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }

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

        // Step 1: Write data and wait for it to sync to the server
        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let l1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = l1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: l1) })
                    if resolved.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SimpleSyncObject(value: 555, floatValue: 5.5)
        lattice.add(obj)
        try await syncTask?.value

        // Step 2: Compact the server's audit log — replaces all history with INSERT snapshots
        let serverEntries = syncedLattice.compactHistory()
        #expect(serverEntries >= 1, "Server should create snapshot entries for existing objects")

        // Verify the server still has the data
        #expect(syncedLattice.objects(SimpleSyncObject.self).count >= 1, "Server data should survive compaction")

        // Step 3: A fresh client connects — should receive data from the compacted snapshots
        let freshURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let freshConfig = Lattice.Configuration(
            fileURL: freshURL,
            authorizationToken: "compact-test",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        let freshLattice = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshConfig)
        var attempts = 0
        while freshLattice.objects(SimpleSyncObject.self).count == 0 && attempts < 50 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }

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

        // Step 2: Compact lattice1's audit log
        let compactedEntries = lattice.compactHistory()
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

    private let sockets = SocketStore()

    deinit {
        app.shutdown()
        try? Lattice.delete(for: senderConfig)
        try? Lattice.delete(for: receiverConfig)
        try? Lattice.delete(for: serverLatticeConfig)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.debug)
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
