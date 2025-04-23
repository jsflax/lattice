import Foundation
import Combine
import Testing
import SwiftUICore
import Lattice
import Observation
import Vapor

@Model class SimpleSyncObject {
    var value: Int = 0
    
    init(value: Int) {
        self.value = value
    }
}

@Model class SequenceSyncObject {
    var open: Float = .random(in: 0...1000)
    var high: Float = .random(in: 0...1000)
    var low: Float = .random(in: 0...1000)
    var close: Float = .random(in: 0...1000)
    var volume: Float = .random(in: 0...1000)
}

@Suite("Sync Tests") class SyncTests: @unchecked Sendable {
    let app: Application
    static let syncLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "sync_test.sqlite")
    static let lattice1URL = FileManager.default.temporaryDirectory
        .appending(path: "lattice_ws1.sqlite")
    static let lattice2URL = FileManager.default.temporaryDirectory
        .appending(path: "lattice_ws2.sqlite")
    let sem = DispatchSemaphore(value: 0)
    let localLattice1: Lattice
    let localLattice2: Lattice
    let syncedLattice: Lattice
    let syncedLatticeConfiguration = Lattice.Configuration(fileURL: SyncTests.syncLatticeURL)
    let localLattice1Configuration = Lattice.Configuration.init(
        fileURL: lattice1URL,
        authorizationToken: "hi",
        wssEndpoint: URL(string: "http://localhost:1337/test"))
    let localLattice2Configuration = Lattice.Configuration.init(
        fileURL: lattice2URL,
        authorizationToken: "hi2",
        wssEndpoint: URL(string: "http://localhost:1337/test"))
    
    deinit {
        
        app.shutdown()
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
                let lattice = self.syncedLattice
                
                // bring the user up to date
                let encoded: Data? = try! await LatticeActor(lattice).withModelContext { lattice in
                    let events = try lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
                    return events.isEmpty ? nil : try JSONEncoder().encode(ServerSentEvent.auditLog(events))
                }
                encoded.map { encoded in ws.send(ByteBuffer(data: encoded)) }
            }.value
        }
    }
    
    init() async throws {
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
        
        self.app = try await Application.make(.detect())
        localLattice1 = try! Lattice(SimpleSyncObject.self, SequenceSyncObject.self,
                                     configuration: localLattice1Configuration)
        localLattice2 = try! Lattice(SimpleSyncObject.self, SequenceSyncObject.self,
                                     configuration: localLattice2Configuration)
        syncedLattice = try Lattice(for: [SimpleSyncObject.self, SequenceSyncObject.self], configuration: .init(fileURL: SyncTests.syncLatticeURL))
        app.http.server.configuration.port = 1337
        
        try await launchServer()
        try await app.startup()
    }
    @available(macOS 15.0, *)
    @Test func test_BasicSync() async throws {
        let lattice = localLattice1
        let lattice2 = localLattice2
        
        var task = Task { @MainActor in
            let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
            for await changes in lattice2.changeStream {
                if changes.contains(where: { $0.operation == .insert }) {
                    break
                }
            }
        }
        let object = SimpleSyncObject(value: 42)
        let taskForSynchronization = Task { @MainActor in
            let lattice1 = try Lattice(SimpleSyncObject.self, configuration: localLattice1Configuration)
            for await changes in lattice1.changeStream {
                if changes.allSatisfy({ $0.isSynchronized }) {
                    break
                }
            }
        }
        lattice.add(object)
        
        
        try await taskForSynchronization.value
        try await task.value
        
        #expect(lattice.objects(AuditLog.self).first?.isSynchronized == true)
        
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 42)
        
        task = Task { @MainActor in
            let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
            for await changes in lattice2.changeStream {
                if changes.contains(where: { $0.operation == .update }) {
                    break
                }
            }
        }
        
        object.value = 84
        try await task.value
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 84)
        
        task = Task { @MainActor in
            let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
            for await changes in lattice2.changeStream {
                if changes.contains(where: { $0.operation == .delete }) {
                    break
                }
            }
        }
        
        _ = lattice.delete(object)
        try await task.value
        #expect(lattice2.objects(SimpleSyncObject.self).count == 0)
    }
    
    @available(macOS 15.0, *)
    @Test func test_BigSync() async throws {
        let lattice = localLattice1
        let lattice2 = localLattice2
        
        let task = Task { @MainActor in
            let lattice2 = try Lattice(SequenceSyncObject.self, configuration: localLattice2Configuration)
            var changeCount = 0
            let cs = lattice2.changeStream
            for await changes in cs {
                changeCount += changes.count(where: { $0.tableName == "SequenceSyncObject" && $0.operation == .insert }) // why? updating isSynchronized will also update this block
                if changeCount == 100_000 {
                    break
                }
            }
        }
        let objects = (0..<100_000).map { _ in SequenceSyncObject() }
        lattice.transaction {
            lattice.add(contentsOf: objects)
        }
        try await task.value
        
        #expect(lattice2.objects(SequenceSyncObject.self).count == 100_000)
        #expect(lattice2.objects(AuditLog.self).count == 100_000)
    }
    
    @Test func testIsolation() async throws {
        await MainActor.shared.invoke { _ in
            await #isolation?.invoke { @Sendable _ in
                print("uhhh")
            }
        }
    }
}
