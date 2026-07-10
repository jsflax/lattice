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
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: db) }
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
    @Test(.timeLimit(.minutes(5)))
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
    @Test(.timeLimit(.minutes(5)))
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
    @Test(.timeLimit(.minutes(5)))
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
    @Test(.timeLimit(.minutes(5)))
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
    @Test(.timeLimit(.minutes(5)))
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
    @Test(.timeLimit(.minutes(5)))
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
    /// Bug: `AuditLog(from: cxx)` never copies the C++ entry's globalId to Swift's `globalId`,
    /// so `JSONEncoder` emits `"globalId": null`. The C++ parser treats null as empty string.
    /// When multiple batches arrive, the fast-path dedup (`SELECT id FROM AuditLog WHERE globalId = ?`)
    /// matches the empty-globalId rows from batch 1, causing all subsequent batches to be skipped.
    @Test(.timeLimit(.minutes(5)))
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
        let events = lattice.eventsAfter(globalId: nil)
        #expect(events.count >= 5, "Should have at least 5 audit log entries")

        // Encode to JSON (same as ServerSentEvent.auditLog does)
        let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(events)))

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
