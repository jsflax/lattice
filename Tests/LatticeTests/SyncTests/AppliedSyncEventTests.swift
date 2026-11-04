import Foundation
import Testing
@testable import Lattice
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CLatticeTestSQLite)
import CLatticeTestSQLite
#endif

@Model private final class AppliedEventPerson { var name: String = "" }

@Suite("Exact applied sync event", .serialized)
struct AppliedSyncEventTests {
    @Test func auditEvidenceReusesCheckedScopeAndDoesNotChangeHistory() throws {
        let url = testTemporaryDirectory.appending(path: "applied-event-\(UUID()).sqlite")
        let db = try Lattice(AppliedEventPerson.self, configuration: .init(fileURL: url))
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        try db.withTransaction { try db.add(AppliedEventPerson()) }
        let event = try #require(db.objects(AuditLog.self).first?.globalId)
        let ids = Set(db.objects(AuditLog.self).compactMap(\.globalId))
        #expect(try db.hasAppliedSyncEvent(globalID: event))
        try db.withTransaction { () throws -> Void in
            #expect(try db.hasAppliedSyncEvent(globalID: event))
            #expect(try !db.hasAppliedSyncEvent(globalID: UUID()))
        }
        #expect(Set(db.objects(AuditLog.self).compactMap(\.globalId)) == ids)
        enum AbortFixture: Error { case rollback }
        do {
            try db.withTransaction { () throws -> Void in
                let person = try #require(db.objects(AppliedEventPerson.self).first)
                person.name = "uncommitted fixture value"
                #expect(try db.hasAppliedSyncEvent(globalID: event))
                throw AbortFixture.rollback
            }
        } catch AbortFixture.rollback {}
        #expect(db.objects(AppliedEventPerson.self).first?.name == "",
                "An accessor inside an owned transaction must not commit that transaction.")
    }

    @Test func standalonePollingDoesNotInvalidateLiveResultsOrEmitCommitSignals() throws {
        let url = testTemporaryDirectory.appending(path: "applied-event-polling-\(UUID()).sqlite")
        var configuration = Lattice.Configuration(fileURL: url)
        configuration.resultsTuning.crossProcessBeltIntervalMs = nil
        let db = try Lattice(AppliedEventPerson.self, configuration: configuration)
        defer { db.close(); try? Lattice.delete(for: configuration) }
        try db.add(AppliedEventPerson())
        let event = try #require(db.objects(AuditLog.self).first?.globalId)
        let missing = UUID()
        let results = db.objects(AppliedEventPerson.self)
        #expect(results.count == 1)
        let coordinator = GenerationCoordinatorRegistry.coordinator(for: db.backend, tuning: configuration.resultsTuning)
        let before = coordinator.resolve(table: AppliedEventPerson.entityName)
        let signals = AppliedEventSignalCounter()
        // This is the synchronous, pre-fanout hook, not a timing-dependent
        // assertion that an asynchronous callback has not arrived yet.
        let token = db.backend.addInvalidationHook { _, _ in signals.increment() }
        defer { db.backend.removeInvalidationHook(token: token) }
        for _ in 0..<100 {
            #expect(try db.hasAppliedSyncEvent(globalID: event))
            #expect(try !db.hasAppliedSyncEvent(globalID: missing))
        }
        let after = coordinator.resolve(table: AppliedEventPerson.entityName)
        #expect(after.epoch == before.epoch)
        #expect(after.generationID == before.generationID)
        #expect(signals.count == 0, "Readiness polling must not produce commit/rollback invalidation or notification work.")
        #expect(results.count == 1)
        // Positive control: actual writes still synchronously invalidate the
        // same observer/generation, so the zero above is not an absent hook.
        try db.add(AppliedEventPerson())
        #expect(signals.count > 0)
        #expect(coordinator.resolve(table: AppliedEventPerson.entityName).epoch > after.epoch)
        #expect(results.count == 2)
    }

    #if canImport(SQLite3) || canImport(CLatticeTestSQLite)
    @Test func readOnlyReceiptAndExactCursorEvidenceNeedsNoSchemaWrites() throws {
        let url = testTemporaryDirectory.appending(path: "applied-event-readonly-\(UUID()).sqlite")
        let db = try Lattice(AppliedEventPerson.self, configuration: .init(fileURL: url))
        db.close()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let receipt = UUID(), cursor = UUID(), absent = UUID()
        // Test-only metadata fixture. The real per-sync suppression/cursor and
        // rollback behavior is exercised in Core's AuditHygiene regressions.
        try sql(url, "CREATE TABLE IF NOT EXISTS _lattice_applied_receipts (globalId TEXT PRIMARY KEY)")
        try sql(url, "INSERT INTO _lattice_applied_receipts(globalId) VALUES ('\(receipt.uuidString.lowercased())')")
        try sql(url, "DROP TABLE IF EXISTS _lattice_replication_slots")
        try sql(url, "CREATE TABLE _lattice_replication_slots (sync_id TEXT PRIMARY KEY, last_received_event_id TEXT)")
        try sql(url, "INSERT INTO _lattice_replication_slots VALUES ('fixture-channel','\(cursor.uuidString.lowercased())')")
        let reader = try Lattice(AppliedEventPerson.self, configuration: .init(fileURL: url, isReadOnly: true))
        #expect(try reader.hasAppliedSyncEvent(globalID: receipt))
        #expect(try reader.hasAppliedSyncEvent(globalID: cursor))
        try reader.withTransaction { () throws -> Void in
            #expect(try reader.hasAppliedSyncEvent(globalID: receipt))
            #expect(try reader.hasAppliedSyncEvent(globalID: cursor))
            #expect(try !reader.hasAppliedSyncEvent(globalID: absent))
            #expect(reader.objects(AuditLog.self).isEmpty)
        }
        reader.close()

        // Legacy or never-synced databases need no new table or column merely
        // to reject a missing checkpoint on a genuinely read-only handle.
        try sql(url, "DROP TABLE _lattice_applied_receipts")
        try sql(url, "DROP TABLE _lattice_replication_slots")
        let legacy = try Lattice(AppliedEventPerson.self, configuration: .init(fileURL: url, isReadOnly: true))
        defer { legacy.close() }
        #expect(try !legacy.hasAppliedSyncEvent(globalID: receipt))
        try legacy.withTransaction { () throws -> Void in
            #expect(try !legacy.hasAppliedSyncEvent(globalID: receipt))
            #expect(try !legacy.hasAppliedSyncEvent(globalID: cursor))
        }
    }

    private func sql(_ url: URL, _ statement: String) throws {
        var pointer: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        let db = try #require(pointer)
        defer { sqlite3_close(db) }
        // This connection intentionally writes the owned current-epoch fixture.
        // The read-only Lattice probes above do not register this capability.
        try registerCurrentWriterForFixtureMutation(db)
        let result = sqlite3_exec(db, statement, nil, nil, nil)
        guard result == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(db))
            throw LatticeError.transactionError("Owned applied-event metadata fixture failed (SQLite \(result)): \(reason); statement: \(statement)")
        }
    }
    #endif
}

private final class AppliedEventSignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
