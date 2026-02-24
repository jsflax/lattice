import Foundation
#if canImport(Combine)
import Combine
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
                print("🧦", "Server Received Binary Event")

                let lattice = try! Lattice(configuration: syncedLatticeConfiguration)
                do {
                    let globalIds = try lattice.receive(Data(buffer: bb))
                    ws.send(try JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                } catch {
                    print("Error:", error)
                }

                // Only forward audit_log data to other clients, NOT ACK messages.
                // ACKs are a sender↔server protocol; forwarding them causes
                // mark_as_synced to fire on receivers, producing duplicate
                // AuditLog observer notifications.
                let data = Data(buffer: bb)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let kind = json["kind"] as? String,
                   kind == "auditLog" {
                    for socket in self.sockets.others(excluding: ws) {
                        socket.send(bb)
                    }
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
        syncedLattice = try Lattice(for: [SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self],
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
        localLattice1 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self,
                                    configuration: localLattice1Configuration)
        localLattice2 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self,
                                    configuration: localLattice2Configuration)
    }
    
    @Test(.timeLimit(.minutes(1))) func test_BasicSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!
        
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                print("Awaiting changes lattice 2")
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert }) {
                        break
                    }
                }
            }
        }
        let object = SimpleSyncObject(value: 42, floatValue: 42.42)
        var taskForSynchronization: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                print("Awaiting changes lattice 1")
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }
        lattice.add(object)
        
        try await taskForSynchronization?.value
        try await task?.value

        #expect(lattice.objects(AuditLog.self).first?.isSynchronized == true)

        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 42)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 42.42)

        await withCheckedContinuation { continuation in
            task = Task { @MainActor in
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var changeCount = 0
                for await _ in changeStream {
                    changeCount += 1
                    if changeCount == 2 {
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

        await withCheckedContinuation { continuation in
            task = Task { @MainActor in
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    if changes.contains(where: { $0.operation == .delete }) {
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
}
