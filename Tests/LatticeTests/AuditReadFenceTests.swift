import Foundation
import Testing
import CLatticeTestSQLite
import LatticeTestSupport
@testable import Lattice

@Model private final class ServerAuditFenceItem { var payload: Data = Data() }

@Suite("Server additive audit read fence", .serialized)
struct AuditReadFenceTests {

    private func file() -> URL {
        LatticeTestScratch.directory.appendingPathComponent("server-audit-fence-\(UUID().uuidString).sqlite")
    }
    private func cleanup(_ url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] { try? FileManager.default.removeItem(atPath: path) }
    }
    private func configuration(_ url: URL, readOnly: Bool = false) -> Lattice.Configuration {
        .init(fileURL: url, isReadOnly: readOnly, migration: [6: Migration()])
    }
    private func seed(_ url: URL) throws {
        let db = try Lattice(ServerAuditFenceItem.self, configuration: configuration(url))
        defer { db.close() }
        let row = ServerAuditFenceItem(); row.payload = Data("saved".utf8)
        try db.add(row)
    }
    private func execute(_ url: URL, _ sql: String) throws {
        var pointer: OpaquePointer?
        try #require(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        defer { sqlite3_close(pointer) }
        try #require(sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK)
    }
    private func image(_ url: URL) -> [Data] {
        [url.path, url.path + "-wal"].map { (try? Data(contentsOf: URL(fileURLWithPath: $0))) ?? Data() }
    }

    @Test func readFenceDetectsPruningThatRestoresTheSameCursorAndForceReset() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let db = try Lattice(ServerAuditFenceItem.self, configuration: configuration(url))
        defer { db.close() }
        // NULL/missing persisted receive cursor makes Core preserve the newest remote audit row.
        try execute(url, "INSERT INTO _lattice_replication_slots(sync_id,upload_floor,last_active_at) VALUES('fence-reader',0,datetime('now'))")
        try execute(url, "UPDATE AuditLog SET isFromRemote=1")
        let before = try db.auditReadFence()
        #expect(before.historyGeneration == nil)
        var lastGeneration: UUID?
        for value in ["first", "second"] {
            try db.withTransaction {
                let row = try #require(db.objects(ServerAuditFenceItem.self).first)
                row.payload = Data(value.utf8)
            }
            #expect(try db.auditReadFence().cursor.head > before.cursor.head)
            try execute(url, "UPDATE _lattice_replication_slots SET upload_floor=(SELECT MAX(id) FROM AuditLog)")
            #expect(db.compactHistory() > 0)
            let after = try db.auditReadFence()
            #expect(after.cursor == before.cursor)
            #expect(after != before)
            #expect(after.historyGeneration != nil && after.historyGeneration != lastGeneration)
            #expect(db.objects(ServerAuditFenceItem.self).first?.payload == Data(value.utf8))
            lastGeneration = after.historyGeneration
        }
        #expect(db.forceCompactHistory() > 0)
        let reset = try db.auditReadFence()
        #expect(reset.historyGeneration != nil && reset.historyGeneration != lastGeneration)
    }

    @Test func readFenceDoesNotWriteOnReadOnlyAndUsesCurrentTransaction() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let before = image(url)
        do {
            let reader = try Lattice(ServerAuditFenceItem.self, configuration: configuration(url, readOnly: true))
            let fence = try reader.auditReadFence()
            #expect(fence.historyGeneration == nil && fence.cursor.head > 0)
            #expect(try reader.auditReadFence() == fence)
            reader.close()
        }
        #expect(image(url) == before)
        let writer = try Lattice(ServerAuditFenceItem.self, configuration: configuration(url))
        defer { writer.close() }
        let original = try writer.auditReadFence()
        enum Rollback: Swift.Error { case expected }
        #expect(throws: Rollback.self) {
            try writer.withTransaction {
                let row = try #require(writer.objects(ServerAuditFenceItem.self).first)
                row.payload = Data("uncommitted".utf8)
                let inside = try writer.auditReadFence()
                #expect(inside.cursor.head > original.cursor.head)
                #expect(inside.historyGeneration == original.historyGeneration)
                throw Rollback.expected
            }
        }
        #expect(try writer.auditReadFence() == original)
    }

    @Test func readFenceRejectsMalformedGenerationMissingTableAndClosedHandle() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let db = try Lattice(ServerAuditFenceItem.self, configuration: configuration(url))
        for expression in ["'bad'", "'00000000-0000-0000-0000-00000000000z'", "x'30303030'", "zeroblob(1048576)"] {
            try execute(url, "INSERT OR REPLACE INTO _lattice_meta(key,value) VALUES('history_generation_revision_v1',\(expression))")
            #expect(throws: Lattice.Error.self) { try db.auditReadFence() }
            #expect(db.lastQueryError() != nil)
        }
        try execute(url, "DELETE FROM _lattice_meta WHERE key='history_generation_revision_v1'")
        #expect(try db.auditReadFence().historyGeneration == nil)
        try execute(url, "DROP TABLE _lattice_meta")
        #expect(throws: Lattice.Error.self) { try db.auditReadFence() }
        db.close()
        #expect(throws: Lattice.Error.self) { try db.auditReadFence() }
    }
}
