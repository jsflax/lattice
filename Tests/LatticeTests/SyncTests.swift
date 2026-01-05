import Foundation
import Combine
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

@Suite("Sync Tests")
class SyncTests: @unchecked Sendable {
    let app: Application
    let syncLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice1URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice2URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port = isPortOpen(port: 1337) ? 1337 : 1338
    let sem = DispatchSemaphore(value: 0)
    var localLattice1: Lattice!
    var localLattice2: Lattice!
    var syncedLattice: Lattice!
    lazy var syncedLatticeConfiguration = Lattice.Configuration(fileURL: syncLatticeURL)
    lazy var localLattice1Configuration = Lattice.Configuration.init(
        fileURL: lattice1URL,
        authorizationToken: "hi",
        wssEndpoint: URL(string: "http://localhost:\(port)/test"))
    lazy var localLattice2Configuration = Lattice.Configuration.init(
        fileURL: lattice2URL,
        authorizationToken: "hi2",
        wssEndpoint: URL(string: "http://localhost:\(port)/test"))
    
    deinit {
        app.shutdown()
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
    }
    var sockets: [WebSocket] = []
    private func launchServer() async throws {
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            self.sockets.append(ws)
            ws.onBinary { ws, bb in
                print("🧦", "Server Received Binary Event")
                
                try? await LatticeActor(self.syncedLattice)
                .withModelContext({ lattice in
                    do {
                        let globalIds = try lattice.receive(Data(buffer: bb))
                        ws.send(try JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                        self.sem.signal()
                    } catch {
                        print("Error:", error)
                    }
                })
                
                for socket in self.sockets where socket !== ws {
                    socket.send(bb)
                }
            }

            await Task {
                let lattice = self.syncedLattice!
                
                // bring the user up to date
                let encoded: Data? = try! await LatticeActor(lattice).withModelContext { lattice in
                    let events = try lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
                    return events.isEmpty ? nil : try JSONEncoder().encode(ServerSentEvent.auditLog(events))
                }
                encoded.map { encoded in ws.send(ByteBuffer(data: encoded)) }
            }.value
        }
    }
    
    private static func isPortOpen(port: UInt16) -> Bool {
        let socketFileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        if socketFileDescriptor == -1 {
            return false
        }

        var addr = sockaddr_in()
        let sizeOfSockAddr = MemoryLayout<sockaddr_in>.size
        addr.sin_len = UInt8(sizeOfSockAddr)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian // Convert to network byte order
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian) // Bind to all available interfaces
        addr.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)

        var bindAddr = sockaddr()
        memcpy(&bindAddr, &addr, Int(sizeOfSockAddr))

        let bindResult = Darwin.bind(socketFileDescriptor, &bindAddr, socklen_t(sizeOfSockAddr))
        if bindResult == -1 {
            close(socketFileDescriptor) // Close the socket if bind fails
            return false // Port is likely in use
        }

        // Attempt to listen on the port (optional, but good practice for server-like checks)
        let listenResult = listen(socketFileDescriptor, SOMAXCONN)
        if listenResult == -1 {
            close(socketFileDescriptor)
            return false // Port might be available but not suitable for listening
        }

        close(socketFileDescriptor) // Close the socket after successful bind/listen
        return true // Port appears to be available
    }
    
    
    init() async throws {
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
        
        localLattice1 = try! Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self,
                                     configuration: localLattice1Configuration)
        localLattice2 = try! Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self,
                                     configuration: localLattice2Configuration)
        syncedLattice = try Lattice(for: [SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self], configuration: .init(fileURL: syncLatticeURL))
        app.http.server.configuration.port = port
        
        print("Lattice1:", localLattice1Configuration.fileURL)
        print("Lattice2:", localLattice2Configuration.fileURL)
        try await launchServer()
        var retries = 0
        while retries < 5 {
            do {
                try await app.startup()
                break  // Successfully started, exit loop
            } catch let error as IOError {
                if error.errnoCode == 48 {
                    app.http.server.configuration.port += 1
                    port = app.http.server.configuration.port
                }
                retries += 1
                if retries == 5 {
                    throw error
                }
            }
        }
    }
    
    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(1))) func test_BasicSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!
        
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task { @MainActor in
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    if changes.contains(where: { $0.operation == .insert }) {
                        break
                    }
                }
            }
        }
        let object = SimpleSyncObject(value: 42, floatValue: 42.42)
        var taskForSynchronization: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            taskForSynchronization = Task { @MainActor in
                let lattice1 = try Lattice(SimpleSyncObject.self, configuration: localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
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
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
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
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
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
    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(1))) func test_ListRelationshipSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Set up changeStreams BEFORE adding data to avoid race conditions
        var task: Task<Void, any Error>?
        var taskForSynchronization: Task<Void, any Error>?

        await withCheckedContinuation { continuation in
            task = Task { @MainActor in
                let lattice2 = try Lattice(SyncParent.self, SyncChild.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in changeStream {
                    insertCount += changes.count(where: { $0.operation == .insert })
                    // We need at least 3 inserts: 1 parent + 2 children
                    // If links are synced, we'd also see link table changes (5 total)
                    if insertCount >= 3 {
                        break
                    }
                }
            }
        }

        await withCheckedContinuation { continuation in
            taskForSynchronization = Task { @MainActor in
                let lattice1 = try Lattice(SyncParent.self, SyncChild.self, configuration: localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
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

        lattice.add(parent)
        parent.children.append(child1)
        parent.children.append(child2)

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
