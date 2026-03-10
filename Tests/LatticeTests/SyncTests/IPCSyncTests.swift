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

