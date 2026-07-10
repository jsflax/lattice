import Foundation
import Testing
import Lattice
import Vapor

// =============================================================================
// Test model mimicking Engram's Memory — content, project, topic, embedding, isPrivate
// =============================================================================

#if os(macOS)
@Model class EngramMemory {
    var content: String
    var project: String
    var topic: String
    var embedding: FloatVector
    var importance: Int
    var isPrivate: Bool

    init(
        content: String = "",
        project: String = "global",
        topic: String = "general",
        embedding: [Float] = [],
        importance: Int = 0,
        isPrivate: Bool = false
    ) {
        self.content = content
        self.project = project
        self.topic = topic
        self.embedding = FloatVector(embedding)
        self.importance = importance
        self.isPrivate = isPrivate
    }
}

@Model class EngramEdge {
    var sourceGlobalId: UUID
    var targetGlobalId: UUID
    var relation: String

    init(sourceGlobalId: UUID = UUID(), targetGlobalId: UUID = UUID(), relation: String = "relates_to") {
        self.sourceGlobalId = sourceGlobalId
        self.targetGlobalId = targetGlobalId
        self.relation = relation
    }
}

// =============================================================================
// Engram Integration Test — full pipeline at scale
//
// Mirrors the real Engram sync topology:
//   local (memory.db)  →IPC→  synced (memory_synced.db)  →WSS→  server (cloud)
//
// 1000 memories across 10 projects (100 each). One project syncs.
// Only that project's non-private memories should reach the server.
// Validates: sync filter, IPC relay, WSS upload, BLOB round-trip (embeddings).
// =============================================================================

@Suite("Engram Integration Tests", .serialized)
actor EngramIntegrationTests {
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

    private let sockets = SocketStore()

    deinit {
        app.shutdown()
        try? Lattice.delete(for: localConfig)
        try? Lattice.delete(for: syncedConfig)
        try? Lattice.delete(for: serverConfig)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.debug)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.localConfig = .init(fileURL: localURL)
        self.syncedConfig = .init(fileURL: syncedURL)
        self.serverConfig = .init(fileURL: serverURL)
        app.http.server.configuration.port = 0

        // Server-side schema (no sync — plain DB)
        let _ = try Lattice(EngramMemory.self, configuration: serverConfig)

        // WebSocket relay server (same pattern as IPCCloudRelayTests)
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
                let encoded = try! JSONEncoder().encode(ServerSentEvent.auditLog(Array(page)))
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

    /// Strip sync targets from config for plain DB observer.
    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        c.wssEndpoint = nil
        c.authorizationToken = nil
        c.syncFilter = nil
        return c
    }

    // =========================================================================
    // Full Engram pipeline: 1000 memories, 10 projects, 1 project syncs
    // local →IPC→ synced →WSS→ server
    // =========================================================================
    @Test(.timeLimit(.minutes(3)))
    func test_EngramFullPipeline_1000Memories() async throws {
        let channel = "engram-full-\(String.random(length: 8))"
        let syncedProject = "project-5"
        let totalProjects = 10
        let memoriesPerProject = 100
        let expectedSynced = memoriesPerProject  // 100 non-private memories from project-5

        print("[TEST] Starting Engram full pipeline test")
        print("[TEST] Channel: \(channel), synced project: \(syncedProject)")
        print("[TEST] Will insert \(totalProjects * memoriesPerProject) memories total")

        // --- 1. Set up the 3-tier pipeline ---

        // LOCAL (memory.db): IPC server with sync filter — only syncedProject
        var filter = Lattice.SyncFilter()
        filter.include(EngramMemory.self, where: { $0.project == syncedProject })

        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(EngramMemory.self, configuration: localConfig)
        print("[TEST] Local Lattice created with IPC server + sync filter")
        try await Task.sleep(for: .milliseconds(200))

        // SYNCED (memory_synced.db): IPC client + WSS to cloud
        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "engram-token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        let synced = try Lattice(EngramMemory.self, configuration: syncedConfig)
        print("[TEST] Synced Lattice created with IPC client + WSS (port \(port))")
        try await Task.sleep(for: .milliseconds(500))

        // --- 2. Set up observer on server DB to wait for all synced memories ---
        // Uses the same pattern as IPCCloudRelayTests.waitForChange but counts to expectedSynced.

        let serverObserverConfig = observerConfig(from: serverConfig)
        var serverTask: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            serverTask = Task.detached {
                let db = try Lattice(EngramMemory.self, configuration: serverObserverConfig)
                let stream = db.changeStream
                continuation.resume()
                var insertCount = 0
                print("[TEST] Server observer started, waiting for \(expectedSynced) inserts...")
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: db) }
                    let inserts = resolved.filter {
                        $0.tableName == "EngramMemory" && $0.operation == .insert
                    }
                    if !inserts.isEmpty {
                        insertCount += inserts.count
                        print("[TEST] Server observer: +\(inserts.count) inserts (total: \(insertCount)/\(expectedSynced))")
                    }
                    if insertCount >= expectedSynced {
                        print("[TEST] Server observer: reached \(insertCount) inserts, done")
                        return
                    }
                }
                print("[TEST] Server observer: stream ended early with \(insertCount) inserts")
            }
        }

        // --- 3. Insert 1000 memories across 10 projects ---
        // Yield the actor between batches so the scheduler can dispatch
        // upload_pending_changes (the scheduler captures this actor's isolation).

        print("[TEST] Inserting \(totalProjects * memoriesPerProject) memories...")
        for projectIndex in 0..<totalProjects {
            let projectName = "project-\(projectIndex)"
            for memoryIndex in 0..<memoriesPerProject {
                let embedding: [Float] = [
                    Float(projectIndex) * 100 + Float(memoryIndex),
                    Float(memoryIndex) * 0.1,
                    Float(projectIndex) + 0.5
                ]
                let memory = EngramMemory(
                    content: "Memory \(memoryIndex) for \(projectName): some knowledge about topic-\(memoryIndex % 5)",
                    project: projectName,
                    topic: "topic-\(memoryIndex % 5)",
                    embedding: embedding,
                    importance: (memoryIndex % 5) + 1,
                    isPrivate: false
                )
                local.add(memory)
            }
            // Yield after each project batch so the actor's scheduler can
            // process queued upload_pending_changes dispatches
            await Task.yield()
            if projectIndex % 3 == 0 {
                print("[TEST] Inserted through project-\(projectIndex)...")
            }
        }
        print("[TEST] All \(totalProjects * memoriesPerProject) memories inserted")

        // LOCAL: verify all 1000 memories are in the source DB
        let localMemories = local.objects(EngramMemory.self)
        print("[TEST] Local DB has \(localMemories.count) memories")
        #expect(localMemories.count == totalProjects * memoriesPerProject,
                "Local should have \(totalProjects * memoriesPerProject) memories, got \(localMemories.count)")

        // Check local AuditLog for the synced project
        let localAuditLogs = local.objects(AuditLog.self).filter { $0.tableName == "EngramMemory" }
        print("[TEST] Local has \(localAuditLogs.count) EngramMemory audit entries")

        // --- 4. Wait for full pipeline: server should get 100 memories ---

        print("[TEST] Waiting for server observer (full pipeline: local →IPC→ synced →WSS→ server)...")
        _ = await serverTask.value

        // --- 5. Verify the full pipeline ---

        // SYNCED: should have exactly 100 memories (IPC relay target)
        let syncedMemories = synced.objects(EngramMemory.self)
        print("[TEST] Synced DB has \(syncedMemories.count) EngramMemory objects")
        #expect(syncedMemories.count == expectedSynced,
                "Synced should have \(expectedSynced) memories, got \(syncedMemories.count)")

        let syncedProjects = Set(syncedMemories.map(\.project))
        print("[TEST] Synced projects: \(syncedProjects)")
        for mem in syncedMemories {
            #expect(mem.project == syncedProject,
                    "Synced memory has wrong project: \(mem.project)")
        }

        // SERVER: should have exactly 100 memories
        let server = try Lattice(EngramMemory.self, configuration: serverConfig)
        let serverMemories = server.objects(EngramMemory.self)
        print("[TEST] Server DB has \(serverMemories.count) EngramMemory objects")
        #expect(serverMemories.count == expectedSynced,
                "Server should have \(expectedSynced) memories, got \(serverMemories.count)")

        // All server memories should be from the synced project
        let serverProjects = Set(serverMemories.map(\.project))
        print("[TEST] Server projects: \(serverProjects)")
        for mem in serverMemories {
            #expect(mem.project == syncedProject,
                    "Server memory has wrong project: \(mem.project)")
        }

        // Verify topics are distributed correctly (20 per topic, 5 topics)
        let topicCounts = Dictionary(grouping: serverMemories, by: \.topic)
            .mapValues(\.count)
        print("[TEST] Server topic counts: \(topicCounts)")
        for topicIndex in 0..<5 {
            let topic = "topic-\(topicIndex)"
            #expect(topicCounts[topic] == 20,
                    "Expected 20 memories for \(topic), got \(topicCounts[topic] ?? 0)")
        }

        // --- 6. Verify embedding BLOB round-trip ---

        let sampleMemory = serverMemories.first { $0.content.contains("Memory 0 for project-5") }
        #expect(sampleMemory != nil, "Sample memory 0 not found on server")
        if let sample = sampleMemory {
            let elements = sample.embedding.elements
            #expect(elements.count == 3, "Expected 3-element embedding, got \(elements.count)")
            // projectIndex=5, memoryIndex=0: [500.0, 0.0, 5.5]
            #expect(Swift.abs(elements[0] - 500.0) < 0.001, "embedding[0]: \(elements[0]) != 500.0")
            #expect(Swift.abs(elements[1] - 0.0) < 0.001, "embedding[1]: \(elements[1]) != 0.0")
            #expect(Swift.abs(elements[2] - 5.5) < 0.001, "embedding[2]: \(elements[2]) != 5.5")
            print("[TEST] Embedding round-trip OK for memory 0: \(elements)")
        }

        let sampleMemory99 = serverMemories.first { $0.content.contains("Memory 99 for project-5") }
        #expect(sampleMemory99 != nil, "Sample memory 99 not found on server")
        if let sample = sampleMemory99 {
            let elements = sample.embedding.elements
            #expect(elements.count == 3, "Expected 3-element embedding, got \(elements.count)")
            // projectIndex=5, memoryIndex=99: [599.0, 9.9, 5.5]
            #expect(Swift.abs(elements[0] - 599.0) < 0.001, "embedding[0]: \(elements[0]) != 599.0")
            #expect(Swift.abs(elements[1] - 9.9) < 0.001, "embedding[1]: \(elements[1]) != 9.9")
            #expect(Swift.abs(elements[2] - 5.5) < 0.001, "embedding[2]: \(elements[2]) != 5.5")
            print("[TEST] Embedding round-trip OK for memory 99: \(elements)")
        }

        print("[TEST] Full pipeline test complete!")
    }
}

// =============================================================================
// Engram Sync Realism Tests — exercises the actual slow paths in Engram
//
// The key difference from EngramIntegrationTests above: data is inserted
// BEFORE sync is configured, then a filter toggle triggers reconciliation.
// This mirrors the Engram UX: user has 500 memories, signs in, toggles sync.
// =============================================================================

@Suite("Engram Sync Realism Tests")
actor EngramSyncRealismTests {
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

    private let sockets = SocketStore()

    deinit {
        app.shutdown()
        try? Lattice.delete(for: localConfig)
        try? Lattice.delete(for: syncedConfig)
        try? Lattice.delete(for: serverConfig)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.debug)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.localConfig = .init(fileURL: localURL)
        self.syncedConfig = .init(fileURL: syncedURL)
        self.serverConfig = .init(fileURL: serverURL)
        app.http.server.configuration.port = 0

        // Server-side schema (plain DB, no sync)
        let _ = try Lattice(EngramMemory.self, EngramEdge.self, configuration: serverConfig)

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
                    let lattice = try Lattice(EngramMemory.self, EngramEdge.self, configuration: serverConfigCopy)
                    _ = try? lattice.receive(data)
                }
            }
            let lattice = try! Lattice(EngramMemory.self, EngramEdge.self, configuration: serverConfigCopy)
            let events = lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
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
            throw SyncTests.SyncTestError.noPort
        }
        self.port = assignedPort
    }

    /// Strip sync targets from config for plain DB observer.
    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        c.wssEndpoint = nil
        c.authorizationToken = nil
        c.syncFilter = nil
        return c
    }

    /// Set up a server-side observer that counts inserts of `tableName`.
    /// The observer is **guaranteed to be listening** before this method returns
    /// (via withCheckedContinuation), eliminating the race where data arrives
    /// before the observer is ready.
    /// Returns a detached Task whose value is the total insert count.
    /// Timeout is handled by each test's .timeLimit.
    private func observeInserts(
        on config: Lattice.Configuration,
        tableName: String,
        expected: Int
    ) async -> Task<Int, any Error> {
        let observerCfg = observerConfig(from: config)
        var task: Task<Int, any Error>!
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            task = Task<Int, any Error>.detached {
                let db = try Lattice(EngramMemory.self, EngramEdge.self, configuration: observerCfg)
                let stream = db.changeStream
                continuation.resume()
                var count = 0
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: db) }
                    let inserts = resolved.filter { $0.tableName == tableName && $0.operation == .insert }
                    if !inserts.isEmpty {
                        count += inserts.count
                        print("[TEST] Server observer: +\(inserts.count) \(tableName) (total: \(count)/\(expected))")
                    }
                    if count >= expected { return count }
                }
                return count
            }
        }
        return task
    }

    // =========================================================================
    // TEST 1: Full Engram-realistic pipeline
    //
    // 1. Create local Lattice with NO sync (just IPC target, no filter yet)
    // 2. Insert 500 memories across 5 projects + edges
    // 3. THEN toggle sync for one project (updateSyncFilter)
    // 4. Create synced Lattice (IPC + WSS) — this triggers reconcile_sync_filter
    // 5. Verify server receives only the matching memories + edges
    // =========================================================================
    @Test(.timeLimit(.minutes(3)))
    func test_ToggleSyncOnPreExistingData() async throws {
        let channel = "realism-toggle-\(String.random(length: 8))"
        let syncedProject = "project-2"
        let totalProjects = 5
        let memoriesPerProject = 100
        let edgesPerProject = 50  // 50 edges per project (between consecutive memories)

        print("[TEST] === Toggle Sync on Pre-Existing Data ===")

        // --- 1. Create local Lattice with IPC target but NO sync filter ---
        localConfig.ipcTargets = [.init(channel: channel)]
        let local = try Lattice(EngramMemory.self, EngramEdge.self, configuration: localConfig)
        print("[TEST] Local Lattice created (no sync filter yet)")

        // --- 2. Insert 500 memories + 250 edges into local BEFORE any sync ---
        print("[TEST] Inserting \(totalProjects * memoriesPerProject) memories + \(totalProjects * edgesPerProject) edges...")
        var globalIdsByProject: [String: [UUID]] = [:]

        for projectIndex in 0..<totalProjects {
            let projectName = "project-\(projectIndex)"
            var projectGlobalIds: [UUID] = []

            for memoryIndex in 0..<memoriesPerProject {
                let memory = EngramMemory(
                    content: "Memory \(memoryIndex) for \(projectName)",
                    project: projectName,
                    topic: "topic-\(memoryIndex % 5)",
                    embedding: [Float(projectIndex) * 100 + Float(memoryIndex), Float(memoryIndex) * 0.1],
                    importance: (memoryIndex % 5) + 1,
                    isPrivate: false
                )
                local.add(memory)
                projectGlobalIds.append(memory.globalId!)
            }
            globalIdsByProject[projectName] = projectGlobalIds

            // Create edges between consecutive memories
            for edgeIndex in 0..<edgesPerProject {
                let edge = EngramEdge(
                    sourceGlobalId: projectGlobalIds[edgeIndex],
                    targetGlobalId: projectGlobalIds[edgeIndex + 1],
                    relation: "relates_to"
                )
                local.add(edge)
            }
        }
        print("[TEST] All data inserted. Local has \(local.objects(EngramMemory.self).count) memories, \(local.objects(EngramEdge.self).count) edges")

        // --- 3. NOW toggle sync: build filter for one project ---
        let expectedMemories = memoriesPerProject  // 100
        // filter.include(EngramEdge.self) with no WHERE syncs ALL edges (250).
        // In real Engram, edges are filtered by endpoint membership — TODO: add subquery filter.
        let expectedEdges = totalProjects * edgesPerProject  // 250 (all edges, unfiltered)

        let memoryPredicate: @Sendable (Query<EngramMemory>) -> Query<Bool> = { $0.project == syncedProject }
        var filter = Lattice.SyncFilter()
        filter.include(EngramMemory.self, where: memoryPredicate)
        filter.include(EngramEdge.self)

        let startTime = ContinuousClock.now
        print("[TEST] Applying sync filter (project=\(syncedProject))...")
        local.updateSyncFilter(filter)
        let filterApplyTime = ContinuousClock.now - startTime
        print("[TEST] updateSyncFilter took \(filterApplyTime)")

        // --- 4. Start server observers BEFORE creating synced Lattice ---
        // Observer is guaranteed listening before observeInserts returns.
        let serverMemoryWaitTask = await observeInserts(on: serverConfig, tableName: "EngramMemory", expected: expectedMemories)
        let serverEdgeWaitTask = await observeInserts(on: serverConfig, tableName: "EngramEdge", expected: expectedEdges)

        // --- 5. Create synced Lattice (IPC client + WSS) ---
        try await Task.sleep(for: .milliseconds(200))
        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "engram-token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        let synced = try Lattice(EngramMemory.self, EngramEdge.self, configuration: syncedConfig)
        let connectTime = ContinuousClock.now - startTime
        print("[TEST] Synced Lattice created (IPC + WSS), elapsed: \(connectTime)")

        // --- 6. Wait for server to receive memories AND edges ---
        let serverMemoryCount = try await serverMemoryWaitTask.value
        let serverEdgeCount = try await serverEdgeWaitTask.value
        let totalTime = ContinuousClock.now - startTime
        print("[TEST] Server received \(serverMemoryCount) memories, \(serverEdgeCount) edges in \(totalTime)")

        // --- 7. Verify ---
        let syncedMemories = synced.objects(EngramMemory.self)
        print("[TEST] Synced DB: \(syncedMemories.count) memories")
        #expect(syncedMemories.count == expectedMemories,
                "Synced should have \(expectedMemories) memories, got \(syncedMemories.count)")
        for mem in syncedMemories {
            #expect(mem.project == syncedProject, "Wrong project: \(mem.project)")
        }

        let server = try Lattice(EngramMemory.self, EngramEdge.self, configuration: serverConfig)
        let serverMemories = server.objects(EngramMemory.self)
        let serverEdges = server.objects(EngramEdge.self)
        print("[TEST] Server DB: \(serverMemories.count) memories, \(serverEdges.count) edges")
        let syncedCheck = try Lattice(EngramMemory.self, EngramEdge.self, configuration: observerConfig(from: syncedConfig))
        print("[TEST] Synced DB: \(syncedCheck.objects(EngramMemory.self).count) memories, \(syncedCheck.objects(EngramEdge.self).count) edges")
        #expect(serverMemories.count == expectedMemories,
                "Server should have \(expectedMemories) memories, got \(serverMemories.count)")
        #expect(serverEdges.count == expectedEdges,
                "Server should have \(expectedEdges) edges, got \(serverEdges.count)")

        // Verify embedding round-trip
        let sample = serverMemories.first { $0.content.contains("Memory 0 for project-2") }
        #expect(sample != nil, "Sample memory not found on server")
        if let s = sample {
            let e = s.embedding.elements
            #expect(e.count == 2)
            #expect(Swift.abs(e[0] - 200.0) < 0.001, "embedding[0] mismatch: \(e[0])")
        }

        print("[TEST] === Toggle sync test complete ===")
        print("[TEST] TIMING: filter apply=\(filterApplyTime), total=\(totalTime)")
    }

    // =========================================================================
    // TEST 2: Toggle off then back on (reconcile removals + re-additions)
    // =========================================================================
    @Test(.timeLimit(.minutes(2)))
    func test_ToggleOffThenOn() async throws {
        let channel = "realism-offon-\(String.random(length: 8))"
        let syncedProject = "my-project"

        print("[TEST] === Toggle Off Then On ===")

        // Local with IPC + initial filter
        var filter = Lattice.SyncFilter()
        filter.include(EngramMemory.self, where: { $0.project == syncedProject })
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(EngramMemory.self, configuration: localConfig)
        try await Task.sleep(for: .milliseconds(200))

        // Synced with IPC + WSS
        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        // The IPC→WSS relay hub. It must stay alive for the whole test: dropping
        // the last reference tears the instance down (weak instance cache) and
        // takes the relay with it. `let _ =` only ever worked because the old
        // strong cache leaked the instance.
        let hub = try Lattice(EngramMemory.self, configuration: syncedConfig)
        defer { withExtendedLifetime(hub) {} }
        try await Task.sleep(for: .milliseconds(500))

        // Set up observer BEFORE inserting so we don't miss events
        let phase1Task = await observeInserts(on: serverConfig, tableName: "EngramMemory", expected: 50)

        // Insert 50 memories
        for i in 0..<50 {
            local.add(EngramMemory(
                content: "Mem \(i)",
                project: syncedProject,
                embedding: [Float(i)]
            ))
        }
        print("[TEST] Inserted 50 memories")

        // Wait for server to receive them
        let count1 = try await phase1Task.value
        print("[TEST] Server has \(count1) after initial sync")

        let server1 = try Lattice(EngramMemory.self, configuration: serverConfig)
        #expect(server1.objects(EngramMemory.self).count == 50)

        // --- Toggle OFF ---
        let startOff = ContinuousClock.now
        local.updateSyncFilter(Lattice.SyncFilter())  // empty filter = sync nothing
        let offTime = ContinuousClock.now - startOff
        print("[TEST] Toggle OFF took \(offTime)")

        // Insert 20 more while sync is off — these should NOT reach server
        for i in 50..<70 {
            local.add(EngramMemory(
                content: "Mem \(i)",
                project: syncedProject,
                embedding: [Float(i)]
            ))
        }
        try await Task.sleep(for: .seconds(1))
        let server2 = try Lattice(EngramMemory.self, configuration: serverConfig)
        let countWhileOff = server2.objects(EngramMemory.self).count
        print("[TEST] Server has \(countWhileOff) after inserting 20 while off (should still be 50)")
        // Note: server may have received synthetic DELETEs from toggle-off reconciliation,
        // so count could be 0 or 50 depending on implementation. The key assertion is
        // that the 20 new memories did NOT arrive.
        #expect(countWhileOff <= 50, "Server should not have the 20 new memories")

        // --- Toggle back ON ---
        // Set up observer BEFORE toggling so we don't miss events
        let phase3Task = await observeInserts(on: serverConfig, tableName: "EngramMemory", expected: 20)

        var filterOn = Lattice.SyncFilter()
        filterOn.include(EngramMemory.self, where: { $0.project == syncedProject })
        let startOn = ContinuousClock.now
        local.updateSyncFilter(filterOn)
        let onTime = ContinuousClock.now - startOn
        print("[TEST] Toggle ON took \(onTime)")

        // Should eventually get all 70 memories on server
        // (reconcile_sync_filter Phase 2 re-sends everything matching the new filter)
        // After re-toggle, reconcile sends all 70 matching rows. But 50 are duplicates on
        // the server (already synced). Only 20 new inserts appear in the server's AuditLog.
        let count3 = try await phase3Task.value
        print("[TEST] Server received \(count3) new inserts after toggle back on")

        let server3 = try Lattice(EngramMemory.self, configuration: serverConfig)
        let finalCount = server3.objects(EngramMemory.self).count
        print("[TEST] Server total: \(finalCount) memories")
        #expect(finalCount >= 70,
                "Server should have all 70 memories after re-toggle, got \(finalCount)")

        print("[TEST] === Toggle off/on complete ===")
        print("[TEST] TIMING: off=\(offTime), on=\(onTime)")
    }

    // =========================================================================
    // TEST 3: Private memories are never synced
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_PrivateMemoriesNeverSync() async throws {
        let channel = "realism-private-\(String.random(length: 8))"

        print("[TEST] === Private Memories Never Sync ===")

        var filter = Lattice.SyncFilter()
        filter.include(EngramMemory.self, where: { $0.project == "myproject" && !$0.isPrivate })
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(EngramMemory.self, configuration: localConfig)
        try await Task.sleep(for: .milliseconds(200))

        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        // The IPC→WSS relay hub. It must stay alive for the whole test: dropping
        // the last reference tears the instance down (weak instance cache) and
        // takes the relay with it. `let _ =` only ever worked because the old
        // strong cache leaked the instance.
        let hub = try Lattice(EngramMemory.self, configuration: syncedConfig)
        defer { withExtendedLifetime(hub) {} }
        try await Task.sleep(for: .milliseconds(500))

        // Set up observer BEFORE inserting so we don't miss events
        let observerTask = await observeInserts(on: serverConfig, tableName: "EngramMemory", expected: 30)

        // Insert mix of private and public
        for i in 0..<30 {
            local.add(EngramMemory(
                content: "Public \(i)", project: "myproject", isPrivate: false
            ))
        }
        for i in 0..<20 {
            local.add(EngramMemory(
                content: "Private \(i)", project: "myproject", isPrivate: true
            ))
        }
        print("[TEST] Inserted 30 public + 20 private")

        let count = try await observerTask.value
        print("[TEST] Server received \(count) memories (expected 30 public)")

        let server = try Lattice(EngramMemory.self, configuration: serverConfig)
        let serverMemories = server.objects(EngramMemory.self)
        #expect(serverMemories.count == 30, "Server should have 30, got \(serverMemories.count)")
        for mem in serverMemories {
            #expect(!mem.isPrivate, "Private memory leaked to server: \(mem.content)")
        }

        print("[TEST] === Private memories test complete ===")
    }

    // =========================================================================
    // TEST 4: Multiple projects synced simultaneously
    // =========================================================================
    @Test(.timeLimit(.minutes(2)))
    func test_MultipleProjectsSync() async throws {
        let channel = "realism-multi-\(String.random(length: 8))"
        let syncedProjects = ["alpha", "beta", "gamma"]

        print("[TEST] === Multiple Projects Sync ===")

        var filter = Lattice.SyncFilter()
        filter.include(EngramMemory.self, where: { $0.project.in(syncedProjects) })
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(EngramMemory.self, configuration: localConfig)
        try await Task.sleep(for: .milliseconds(200))

        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        // The IPC→WSS relay hub. It must stay alive for the whole test: dropping
        // the last reference tears the instance down (weak instance cache) and
        // takes the relay with it. `let _ =` only ever worked because the old
        // strong cache leaked the instance.
        let hub = try Lattice(EngramMemory.self, configuration: syncedConfig)
        defer { withExtendedLifetime(hub) {} }
        try await Task.sleep(for: .milliseconds(500))

        // Set up observer BEFORE inserting so we don't miss events
        let perProject = 40
        let expectedTotal = syncedProjects.count * perProject  // 120
        let observerTask = await observeInserts(on: serverConfig, tableName: "EngramMemory", expected: expectedTotal)

        // Insert across synced + unsynced projects
        for project in syncedProjects {
            for i in 0..<perProject {
                local.add(EngramMemory(content: "\(project)-\(i)", project: project))
            }
        }
        // Also insert into projects NOT in filter
        for i in 0..<perProject {
            local.add(EngramMemory(content: "unsynced-\(i)", project: "unsynced-project"))
        }
        for i in 0..<perProject {
            local.add(EngramMemory(content: "private-proj-\(i)", project: "private-only"))
        }
        print("[TEST] Inserted \(syncedProjects.count * perProject) synced + \(2 * perProject) unsynced")

        let count = try await observerTask.value
        print("[TEST] Server received \(count) memories (expected \(expectedTotal))")

        let server = try Lattice(EngramMemory.self, configuration: serverConfig)
        let serverMemories = server.objects(EngramMemory.self)
        #expect(serverMemories.count == expectedTotal,
                "Server should have \(expectedTotal), got \(serverMemories.count)")

        let serverProjectNames = Set(serverMemories.map(\.project))
        #expect(serverProjectNames == Set(syncedProjects),
                "Server projects should be \(syncedProjects), got \(serverProjectNames)")

        print("[TEST] === Multiple projects test complete ===")
    }

    // =========================================================================
    // TEST 5: Updates to already-synced memories
    // =========================================================================
    // QUARANTINED (Jul 8 2026): hangs — sends never reach the in-process
    // relay server (entries loop "unACKed after timeout" forever) and the
    // timeLimit trait never fires (non-cancellable await). Verified
    // PRE-EXISTING: reproduces identically at bb34cad (main before the
    // 0.13.3 sync work) against remote LatticeCore 0.10.3. These tests were
    // unrunnable since Jul 5 (the @Union compile break masked them).
    // See the fix/sync-lifetime-tests effort; re-enable with a real fix.
    @Test(.disabled("non-INSERT relay delivery defect — owner: 1.0 item D2 (UPDATE/reconcile-DELETE never reach the peer; frame-drop half fixed by the connect-window buffer, this half is the apply/classify path)"), .timeLimit(.minutes(5)))
    func test_UpdatesSyncCorrectly() async throws {
        let channel = "realism-update-\(String.random(length: 8))"

        print("[TEST] === Updates Sync Correctly ===")

        var filter = Lattice.SyncFilter()
        filter.include(EngramMemory.self, where: { $0.project == "myproject" })
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(EngramMemory.self, configuration: localConfig)
        try await Task.sleep(for: .milliseconds(200))

        syncedConfig.ipcTargets = [.init(channel: channel)]
        syncedConfig.authorizationToken = "token"
        syncedConfig.wssEndpoint = URL(string: "http://localhost:\(port)/test")
        // The IPC→WSS relay hub. It must stay alive for the whole test: dropping
        // the last reference tears the instance down (weak instance cache) and
        // takes the relay with it. `let _ =` only ever worked because the old
        // strong cache leaked the instance.
        let hub = try Lattice(EngramMemory.self, configuration: syncedConfig)
        defer { withExtendedLifetime(hub) {} }
        try await Task.sleep(for: .milliseconds(500))

        // Set up observer BEFORE inserting so we don't miss events
        let observerTask = await observeInserts(on: serverConfig, tableName: "EngramMemory", expected: 10)

        // Insert 10 memories
        for i in 0..<10 {
            local.add(EngramMemory(content: "Original \(i)", project: "myproject", importance: 1))
        }
        let _ = try await observerTask.value
        print("[TEST] Initial 10 synced")

        // Update importance on all of them
        for mem in local.objects(EngramMemory.self) {
            mem.importance = 5
        }
        print("[TEST] Updated all 10 importance → 5")

        // Give sync time to propagate updates (per-entry sync is ~1/sec)
        try await Task.sleep(for: .seconds(15))

        let server = try Lattice(EngramMemory.self, configuration: serverConfig)
        let serverMemories = server.objects(EngramMemory.self)
        #expect(serverMemories.count == 10, "Server should still have 10")
        for mem in serverMemories {
            #expect(mem.importance == 5, "Server memory importance should be 5, got \(mem.importance)")
        }

        print("[TEST] === Updates test complete ===")
    }
}
#endif // ENGRAM_TESTS
