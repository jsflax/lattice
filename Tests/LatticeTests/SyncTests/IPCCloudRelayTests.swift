import Foundation
#if canImport(Combine)
import Combine
#endif
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Observation
import Vapor

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
            let events = lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let count = events.count
            for i in stride(from: 0, to: count, by: 1000) {
                let page = events[i..<min(count, i + 1000)]
                let encoded = try! JSONEncoder().encode(ServerSentEvent.auditLog(page))
                ws.send(ByteBuffer(data: encoded))
            }
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
