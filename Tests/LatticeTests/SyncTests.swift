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
        print("[init] START")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        print("[init] creating app")
        self.app = try await Application.make(env)
        print("[init] app created")
        self.localLattice1Configuration = .init(fileURL: lattice1URL)
        self.localLattice2Configuration = .init(fileURL: lattice2URL)
        self.syncedLatticeConfiguration = .init(fileURL: syncLatticeURL)

        // Use port 0 to let the OS assign a free port
        app.http.server.configuration.port = 0

        // Start the server-side lattice (no sync endpoint)
        print("[init] creating synced lattice")
        syncedLattice = try Lattice(for: [SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self],
                                    configuration: syncedLatticeConfiguration)

        print("[init] launching server")
        try await launchServer()
        print("[init] starting app")
        try await app.startup()
        print("[init] app started")

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
        print("[init] creating localLattice1 (sync enabled, port=\(port))")
        localLattice1 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self,
                                    configuration: localLattice1Configuration)
        print("[init] localLattice1 created, creating localLattice2")
        localLattice2 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self,
                                    configuration: localLattice2Configuration)
        print("[init] localLattice2 created, init complete")
    }
    
    @Test(.timeLimit(.minutes(1))) func test_BasicSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // --- Phase 1: INSERT sync (lattice1 → lattice2) ---
        print("[test] Phase 1: INSERT sync")

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                print("[test][l2-recv] Awaiting INSERT on lattice2")
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    print("[test][l2-recv] Got \(resolved.count) changes: \(resolved.map { "\($0.tableName).\($0.operation)" })")
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        print("[test][l2-recv] INSERT received, breaking")
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
                print("[test][l1-sync] Awaiting isSynchronized on lattice1")
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice1) })
                    print("[test][l1-sync] Got \(resolved.count) changes: \(resolved.map { "\($0.tableName).\($0.operation) synced=\($0.isSynchronized)" })")
                    if resolved.contains(where: { $0.isSynchronized && $0.tableName == "SimpleSyncObject" }) {
                        print("[test][l1-sync] Synchronized, breaking")
                        break
                    }
                }
            }
        }

        let object = SimpleSyncObject(value: 42, floatValue: 42.42)
        print("[test] Adding object")
        lattice.add(object)

        try await taskForSynchronization?.value
        print("[test] Phase 1: sync confirmed")
        try await task?.value
        print("[test] Phase 1: insert received on lattice2")

        #expect(lattice.objects(AuditLog.self).first?.isSynchronized == true)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 42)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 42.42)

        // --- Phase 2: UPDATE sync ---
        print("[test] Phase 2: UPDATE sync")

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                print("[test][l2-update] Awaiting UPDATEs on lattice2")
                var updateCount = 0
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    let updates = resolved.filter { $0.operation == .update && $0.tableName == "SimpleSyncObject" }
                    updateCount += updates.count
                    print("[test][l2-update] Got \(resolved.count) changes (\(updates.count) updates, total=\(updateCount)): \(resolved.map { "\($0.tableName).\($0.operation)" })")
                    if updateCount >= 2 {
                        print("[test][l2-update] 2 updates received, breaking")
                        break
                    }
                }
            }
        }

        object.value = 84
        object.floatValue = 84.84
        print("[test] Updated object properties")
        try await task?.value
        print("[test] Phase 2: updates received on lattice2")
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 84)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 84.84)

        // --- Phase 3: DELETE sync ---
        print("[test] Phase 3: DELETE sync")

        let localLattice2Configuration = self.localLattice2Configuration
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                print("[test][l2-delete] Awaiting DELETE on lattice2")
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(on: lattice2) })
                    print("[test][l2-delete] Got \(resolved.count) changes: \(resolved.map { "\($0.tableName).\($0.operation)" })")
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == "SimpleSyncObject" }) {
                        print("[test][l2-delete] DELETE received, breaking")
                        break
                    }
                }
            }
        }

        _ = lattice.delete(object)
        print("[test] Deleted object")
        try await task?.value
        print("[test] Phase 3: delete received on lattice2")
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
                print("uhhh")
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

        print("📋 Total audit logs: \(auditLogs.count)")
        print("📋 Link table audit logs: \(linkTableLogs.count)")
        for log in auditLogs {
            print("  - \(log.tableName): \(log.operation)")
        }

        // THIS IS THE KEY TEST: Link table operations should be in the audit log
        #expect(linkTableLogs.count >= 2, "Link table INSERT operations should be in AuditLog for sync to work. Found: \(linkTableLogs.count)")

        // Wait for sync to complete
        print("Waiting for sync to complete")
        try await taskForSynchronization?.value
        print("Waiting for next task to complete")
        try await task?.value
        print("Sync complete")
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
