import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice
@testable import LatticeServerKit

@Model private final class CheckedBindingRecord {
    @NoHistory var body: String?
}

@Suite("Checked outbound no-history binding", .serialized, .timeLimit(.minutes(1)))
struct CheckedNoHistoryBindingTests {
    private func fixture(_ body: (Lattice, URL) throws -> Void) throws {
        let configured = ProcessInfo.processInfo.environment["LATTICE_TEST_TMPDIR"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("localdev/hud-scratch/lattice-checked-binding-tests", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let store = try Lattice(CheckedBindingRecord.self, configuration: .init(fileURL: url))
        defer { store.close() }
        try body(store, url)
    }

    private func update(_ store: Lattice) throws -> (CheckedBindingRecord, AuditLog) {
        let record = CheckedBindingRecord(); record.body = "first"
        try store.add(record)
        try store.withTransaction { record.body = "latest" }
        let rows = store.eventsAfter(id: 0).where { $0.operation == .update }
            .materializedSnapshot()
        try #require(store.lastQueryError() == nil)
        return (record, try #require(rows.last { $0.tableName == "CheckedBindingRecord" }))
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func liveNullAndGoneValuesPreserveCursorAndNeverRewriteHistory() throws {
        try fixture { store, _ in
            let (record, raw) = try update(store)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(raw.changedFields)
            let value = try #require(store.lateBindNoHistoryChecked([raw]).first)
            #expect(value.primaryKey == raw.primaryKey && value.globalId == raw.globalId)
            #expect(value.changedFields["body"]?.stringValue == "latest")
            try store.withTransaction { record.body = nil }
            let cleared = try #require(store.lateBindNoHistoryChecked([raw]).first)
            #expect(cleared.noHistoryNulls == ["body"])
            guard case .null? = cleared.changedFields["body"] else { Issue.record("Expected observed NULL"); return }
            store.delete(CheckedBindingRecord.self)
            let gone = try #require(store.lateBindNoHistoryChecked([raw]).first)
            #expect(gone.changedFields["body"] == nil && gone.changedFieldsNames?.contains("body") == false)
            #expect(try encoder.encode(raw.changedFields) == before)
            #expect(raw.noHistoryNulls.isEmpty)
        }
    }

    @Test func failedLiveValueQueryCannotBecomeOmissionOrACompletedFrame() throws {
        try fixture { store, url in
            let (_, raw) = try update(store)
            let cursor = try #require(raw.primaryKey)
            try #require(cursor > 0)
            try execute(url, "DROP TABLE CheckedBindingRecord")
            #expect(throws: Lattice.NoHistoryBindingError.self) {
                _ = try store.lateBindNoHistoryChecked([raw])
            }
            #expect(throws: Lattice.NoHistoryBindingError.self) {
                _ = try BoundedAuditFrame.encode(start: 0, maxCount: 1) { _ in
                    try BoundedAuditFrame.nextRow(in: store, events: store.eventsAfter(id: cursor - 1),
                                                after: cursor - 1)
                }
            }
            #expect(raw.changedFieldsNames?.contains("body") == true)
        }
    }

    @Test func malformedBridgeJSONAndInvalidWireEncodingBothFail() throws {
        try fixture { store, _ in
            let (_, raw) = try update(store)
            #expect(throws: DecodingError.self) {
                _ = try store._lateBindNoHistoryChecked([raw]) { _, _, _ in "not-json" }
            }
            let malformed = try JSONDecoder().decode(AuditLog.self, from: JSONEncoder().encode(raw))
            malformed.primaryKey = raw.primaryKey
            malformed.noHistoryNulls = ["missing"]
            var attemptedRead = false
            #expect(throws: (any Error).self) {
                _ = try store._lateBindNoHistoryChecked([malformed]) { _, _, _ in
                    attemptedRead = true
                    return "{}"
                }
            }
            #expect(!attemptedRead)
        }
    }

    @Test func anActualEmptyTailSucceedsButQueryAndClosedReadsFail() throws {
        try fixture { store, url in
            let (_, raw) = try update(store)
            let cursor = try #require(raw.primaryKey)
            #expect(try BoundedAuditFrame.nextRow(in: store, events: store.eventsAfter(id: cursor),
                                                after: cursor) == nil)
            try execute(url, "DROP TABLE AuditLog")
            #expect(throws: (any Error).self) {
                _ = try BoundedAuditFrame.nextRow(in: store, events: store.eventsAfter(id: 0), after: 0)
            }
        }
        try fixture { store, _ in
            let (_, raw) = try update(store)
            let detached = try JSONDecoder().decode(AuditLog.self, from: JSONEncoder().encode(raw))
            store.close()
            #expect(throws: (any Error).self) {
                _ = try BoundedAuditFrame.nextRow(in: store, events: store.eventsAfter(id: 0), after: 0)
            }
            #expect(throws: (any Error).self) { _ = try store.lateBindNoHistoryChecked([detached]) }
        }
    }
}
