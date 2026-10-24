import Foundation
import Testing
import CLatticeTestSQLite
import LatticeTestSupport
@testable import Lattice

@Model private final class StoredVersionItem {
    var value: String = "fixture"
}

@Suite("Stored schema version", .serialized)
struct StoredSchemaVersionTests {
    private func fixture(version: Int = 1) throws -> URL {
        let url = LatticeTestScratch.directory.appendingPathComponent("stored-version-\(UUID().uuidString).sqlite")
        let writer = try Lattice(StoredVersionItem.self,
            configuration: .init(fileURL: url, migration: [version: Migration()]))
        try writer.add(StoredVersionItem())
        writer.close()
        return url
    }
    private func reader(_ url: URL, target: Int = 5) throws -> Lattice {
        try Lattice(StoredVersionItem.self,
            configuration: .init(fileURL: url, isReadOnly: true, migration: [target: Migration()]))
    }
    private func cleanup(_ url: URL) {
        try? Lattice.delete(for: .init(fileURL: url))
    }
    // Test-only corruption oracle. Production reads use only the Lattice API.
    private func execute(_ url: URL, _ sql: String) throws {
        var pointer: OpaquePointer?
        let opened = sqlite3_open(url.path, &pointer)
        defer { if let pointer { sqlite3_close(pointer) } }
        #expect(opened == SQLITE_OK)
        let db = try #require(pointer)
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        #expect(result == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        if result != SQLITE_OK { throw Lattice.Error.databaseError("fixture SQL failed") }
    }

    @Test func readOnlyReturnsActualOldAndNewVersionsWithoutMutation() throws {
        for actual in [1, 6] {
            let url = try fixture(version: actual); defer { cleanup(url) }
            let before = try Data(contentsOf: url)
            let db = try reader(url)
            #expect(try db.storedSchemaVersion() == actual)
            #expect(db.lastQueryError() == nil)
            db.close()
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func malformedMissingAndMissingTableThrowWithoutWriting() throws {
        let mutations = [
            "UPDATE _lattice_meta SET value='' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value='0' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value='-1' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value='5tail' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value='2147483648' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value=x'35' WHERE key='schema_version'",
            "DELETE FROM _lattice_meta WHERE key='schema_version'",
            "DROP TABLE _lattice_meta"
        ]
        for mutation in mutations {
            let url = try fixture(); defer { cleanup(url) }
            let db = try reader(url)
            try execute(url, mutation)
            #expect(throws: Lattice.Error.self) { try db.storedSchemaVersion() }
            #expect(db.lastQueryError()?.isEmpty == false)
            db.close()
        }
    }

    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func record(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
    }

    @Test func failureReportsCallbackSuccessClearsErrorAndClosedThrows() throws {
        let url = try fixture(); defer { cleanup(url) }
        let db = try reader(url), errors = Errors()
        db.onQueryError { errors.record($0) }
        #expect(try db.storedSchemaVersion() == 1)
        #expect(errors.count == 0)
        try execute(url, "UPDATE _lattice_meta SET value='bad' WHERE key='schema_version'")
        #expect(throws: Lattice.Error.self) { try db.storedSchemaVersion() }
        #expect(errors.count == 1)
        try execute(url, "UPDATE _lattice_meta SET value='6' WHERE key='schema_version'")
        #expect(try db.storedSchemaVersion() == 6)
        #expect(db.lastQueryError() == nil)
        #expect(errors.count == 1)
        db.close()
        #expect(throws: Lattice.Error.self) { try db.storedSchemaVersion() }
        #expect(errors.count == 2)
    }
}
