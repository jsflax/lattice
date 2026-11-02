import Foundation
import Testing
import CLatticeTestSQLite
import LatticeTestSupport
@testable import Lattice

@Model private final class AuditStampItem {
    var value: String = "initial"
    var payload: Data = Data()
}

@Suite("Payload-free latest audit stamps", .serialized)
struct LatestAuditStampTests {
    private func withStore(_ body: (Lattice, URL) throws -> Void) throws {
        let file = LatticeTestScratch.directory.appendingPathComponent("audit-stamp-\(UUID()).sqlite")
        let db = try Lattice(AuditStampItem.self, configuration: .init(fileURL: file))
        defer {
            db.close()
            for path in [file.path, file.path + "-wal", file.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try body(db, file)
    }
    private func execute(_ file: URL, _ sql: String) throws {
        var connection: OpaquePointer?
        try #require(sqlite3_open(file.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try registerCurrentWriterForFixtureMutation(connection)
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }
    private func oldStamp(_ db: Lattice, _ id: UUID) throws -> UUID {
        let row = try #require(db.objects(AuditLog.self)
            .where { $0.tableName == AuditStampItem.entityName && $0.globalRowId == id }
            .sortedBy(\.primaryKey, order: .reverse).snapshot(limit: 1).first)
        return try #require(row.globalId)
    }
    @Test func emptyOwnerAndBoundHostileTableNameReturnAbsent() throws {
        try withStore { db, _ in
            #expect(try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: UUID()) == nil)
            let row = AuditStampItem(); try db.add(row)
            let id = try #require(row.globalId)
            #expect(try db.latestAuditStamp(tableName: "x' OR 1=1 -- ?", globalRowID: id) == nil)
            for name in ["", "bad\0name", String(repeating: "a", count: 129)] {
                #expect(throws: (any Error).self) { try db.latestAuditStamp(tableName: name, globalRowID: id) }
            }
        }
    }
    @Test func latestInsertUpdateDeleteMatchesOriginalAuditIdentity() throws {
        try withStore { db, _ in
            let row = AuditStampItem(); try db.add(row)
            let id = try #require(row.globalId)
            let inserted = try oldStamp(db, id)
            #expect(try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id) == inserted)
            row.value = "updated"
            let updated = try oldStamp(db, id)
            #expect(updated != inserted)
            #expect(try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id) == updated)
            try db.delete(row)
            let deleted = try oldStamp(db, id)
            #expect(deleted != updated)
            #expect(try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id) == deleted)
        }
    }
    @Test func transactionReadsOwnWritesAndRollbackRestoresStamp() throws {
        enum Rollback: Error { case requested }
        try withStore { db, _ in
            let row = AuditStampItem(); try db.add(row)
            let id = try #require(row.globalId), original = try oldStamp(db, id)
            #expect(throws: Rollback.self) {
                try db.withTransaction {
                    row.value = "uncommitted"
                    let current = try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id)
                    #expect(current == (try oldStamp(db, id)))
                    #expect(current != original)
                    throw Rollback.requested
                }
            }
            #expect(try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id) == original)
        }
    }
    @Test(arguments: ["NULL", "zeroblob(36)", "'not-a-uuid'", "quote(zeroblob(1024))"])
    func malformedLatestUUIDNeverBecomesMissingOrHydratesPayload(_ sql: String) throws {
        try withStore { db, file in
            let row = AuditStampItem(); try db.add(row)
            let id = try #require(row.globalId)
            // Keep the corrupted owner below the global cursor; the scoped lookup, rather than
            // the already-strict cursor validation, must reject its malformed UUID.
            try db.add(AuditStampItem())
            try execute(file, "UPDATE AuditLog SET globalId = \(sql) WHERE id = (SELECT max(id) FROM AuditLog WHERE globalRowId = '\(id.uuidString.lowercased())')")
            #expect(throws: (any Error).self) { try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id) }
        }
    }
    @Test func actualGroupedBackendIgnoresUnselectedAuditAndExtraPayloadColumns() throws {
        try withStore { db, file in
            #expect(db.backend is any GroupedCountBackend)
            let row = AuditStampItem(); row.payload = Data(repeating: 7, count: 4096); try db.add(row)
            let id = try #require(row.globalId), expected = try oldStamp(db, id)
            try db.add(AuditStampItem())
            // An ORM AuditLog hydration/decoder would consume these corrupt/large cells. The
            // scalar API explicitly selects only bounded tableName/globalId keys and counts.
            try execute(file, "ALTER TABLE AuditLog ADD COLUMN unrelatedPayload BLOB")
            try execute(file, "UPDATE AuditLog SET changedFields = zeroblob(1048576), unrelatedPayload = zeroblob(1048576) WHERE globalRowId = '\(id.uuidString.lowercased())'")
            let value = try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id)
            #expect(value == expected)
        }
    }
    @Test func interQueryMutationRefusesThenFreshCaptureSeesLatest() throws {
        try withStore { db, _ in
            let row = AuditStampItem(); try db.add(row)
            let id = try #require(row.globalId), before = try oldStamp(db, id)
            #expect(throws: (any Error).self) {
                try db._latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id,
                    betweenQueries: { row.value = "changed between scalar queries" })
            }
            let current = try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: id)
            #expect(current == (try oldStamp(db, id)))
            #expect(current != before)
        }
    }
    @Test func closedConnectionThrowsInsteadOfReturningEmpty() throws {
        try withStore { db, _ in
            db.close()
            #expect(throws: (any Error).self) { try db.latestAuditStamp(tableName: AuditStampItem.entityName, globalRowID: UUID()) }
        }
    }
}
