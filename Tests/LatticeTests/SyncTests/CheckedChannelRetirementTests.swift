import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice

@Model private final class RetirementRecord { var name: String = "kept" }

private final class RetirementErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; messages.append(value) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
}

@Suite("Checked channel retirement", .serialized, .timeLimit(.minutes(1)))
struct CheckedChannelRetirementTests {
    private func fixture(_ body: (Lattice, URL) throws -> Void) throws {
        let configured = ProcessInfo.processInfo.environment["LATTICE_TEST_TMPDIR"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("localdev/hud-scratch/lattice-retirement-tests", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let store = try Lattice(RetirementRecord.self, configuration: .init(fileURL: url))
        defer { store.close() }
        try store.add(RetirementRecord())
        try execute(url, """
            INSERT INTO _lattice_replication_slots(sync_id) VALUES('ipc:retire'),('ipc:keep');
            INSERT INTO _lattice_sync_set(sync_id,table_name,global_row_id)
              SELECT 'ipc:retire','RetirementRecord',globalId FROM RetirementRecord;
            INSERT INTO _lattice_sync_state(audit_entry_id,sync_id,is_synchronized)
              SELECT id,'ipc:retire',0 FROM AuditLog;
            INSERT INTO _lattice_meta(key,value) VALUES('sync_reset_through_v1:ipc:retire','1');
            """)
        try body(store, url)
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func number(_ url: URL, _ sql: String) throws -> Int64 {
        var connection: OpaquePointer?, statement: OpaquePointer?
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    @Test func checkedRetirementIsScopedAndPreservesDocuments() throws {
        try fixture { store, url in
            try store.removeSyncChannelStateChecked(ipcChannel: "retire")
            #expect(store.lastQueryError() == nil)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_replication_slots WHERE sync_id='ipc:retire'") == 0)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_replication_slots WHERE sync_id='ipc:keep'") == 1)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_sync_set") == 0)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_sync_state WHERE sync_id='ipc:retire'") == 0)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_meta WHERE key='sync_reset_through_v1:ipc:retire'") == 0)
            #expect(try number(url, "SELECT COUNT(*) FROM RetirementRecord") == 1)
            // Repeated permanent cleanup is harmless; later callers may reuse this ID.
            try store.removeSyncChannelStateChecked(syncId: "ipc:retire")
        }
    }

    @Test func nativeRefusalThrowsAndLegacyCallReportsWithoutEscapingCpp() throws {
        try fixture { store, url in
            try execute(url, "CREATE TRIGGER refuse_retirement BEFORE DELETE ON _lattice_sync_set BEGIN SELECT RAISE(ABORT,'retirement fixture refusal'); END")
            let errors = RetirementErrors(); store.onQueryError { errors.append($0) }
            #expect(throws: Lattice.Error.self) { try store.removeSyncChannelStateChecked(syncId: "ipc:retire") }
            #expect(store.lastQueryError()?.contains("retirement fixture refusal") == true)
            #expect(errors.count == 1)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_meta WHERE key='sync_reset_through_v1:ipc:retire'") == 1)
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_replication_slots WHERE sync_id='ipc:retire'") == 1)
            store.removeSyncChannelState(syncId: "ipc:retire")
            #expect(store.lastQueryError()?.contains("retirement fixture refusal") == true)
            #expect(errors.count == 2)
            try execute(url, "DROP TRIGGER refuse_retirement")
            try store.removeSyncChannelStateChecked(syncId: "ipc:retire")
            #expect(store.lastQueryError() == nil)
        }
    }

    @Test func nestedTransactionAndInvalidIdentityRefuseWithoutPartialChanges() throws {
        try fixture { store, url in
            #expect(throws: (any Error).self) {
                try store.withTransaction { try store.removeSyncChannelStateChecked(syncId: "ipc:retire") }
            }
            #expect(try number(url, "SELECT COUNT(*) FROM _lattice_meta WHERE key='sync_reset_through_v1:ipc:retire'") == 1)
            #expect(throws: Lattice.Error.self) { try store.removeSyncChannelStateChecked(syncId: "bad\0id") }
            #expect(throws: Lattice.Error.self) { try store.removeSyncChannelStateChecked(syncId: String(repeating: "x", count: 4_097)) }
            try store.removeSyncChannelStateChecked(syncId: "ipc:retire")
        }
    }

    @Test func closedStoreCannotReportSuccessfulRetirement() throws {
        try fixture { store, url in
            store.close()
            #expect(throws: Lattice.Error.self) { try store.removeSyncChannelStateChecked(syncId: "ipc:retire") }
            #expect(store.lastQueryError() != nil)
            let remaining = try number(url, "SELECT COUNT(*) FROM _lattice_replication_slots WHERE sync_id='ipc:retire'")
            #expect(remaining == 1)
        }
    }
}
