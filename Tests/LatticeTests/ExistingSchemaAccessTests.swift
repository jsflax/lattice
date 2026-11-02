import Foundation
import Testing
import CLatticeTestSQLite
import LatticeTestSupport
@testable import Lattice

@Model private final class ExistingOpenItem { var payload: Data = Data() }
@Model private final class ExistingOpenUnexpected { var value: String = "" }

@Suite("Existing schema access and scalar audit cursor", .serialized)
struct ExistingSchemaAccessTests {
    private func file() -> URL {
        LatticeTestScratch.directory.appendingPathComponent("existing-open-\(UUID().uuidString).sqlite")
    }
    private func cleanup(_ url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] { try? FileManager.default.removeItem(atPath: path) }
    }
    private func seed(_ url: URL, version: Int = 6) throws {
        let db = try Lattice(ExistingOpenItem.self, configuration: .init(fileURL: url, migration: [version: Migration()]))
        defer { db.close() }
        let row = ExistingOpenItem(); row.payload = Data("saved".utf8)
        try db.add(row)
    }
    private func configuration(_ url: URL, readOnly: Bool = false, version: Int = 6) -> Lattice.Configuration {
        .init(fileURL: url, isReadOnly: readOnly, requiredExistingSchemaVersion: version)
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

    @Test func exactOpenIsUsableAndReadOnlyNeverFallsBackToWriter() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        do {
            var config = configuration(url)
            config.migration = [:]
            let db = try Lattice(ExistingOpenItem.self, configuration: config)
            #expect(try db.storedSchemaVersion() == 6)
            db.close()
        }
        do {
            let db = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
            defer { db.close() }
            #expect(try db.storedSchemaVersion() == 6)
            try db.withTransaction {
                let row = try #require(db.objects(ExistingOpenItem.self).first)
                row.payload = Data("updated".utf8)
            }
            #expect(db.objects(ExistingOpenItem.self).first?.payload == Data("updated".utf8))
        }
        let before = image(url)
        do {
            let reader = try Lattice(ExistingOpenItem.self, configuration: configuration(url, readOnly: true))
            defer { reader.close() }
            #expect(reader.objects(ExistingOpenItem.self).first?.payload == Data("updated".utf8))
            #expect(throws: (any Error).self) { try reader.add(ExistingOpenItem()) }
        }
        #expect(image(url) == before)
    }

    @Test func invalidRequiredVersionsAndConflictingTargetsThrowBeforeCreatingAnything() throws {
        let url = file(); defer { cleanup(url) }
        for required in [0, -1, Int(Int32.max) + 1, Int.max] {
            #expect(throws: Lattice.Error.self) {
                try Lattice(ExistingOpenItem.self, configuration: configuration(url, version: required))
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        var conflict = configuration(url)
        conflict.migration = [7: Migration()]
        #expect(throws: Lattice.Error.self) { try Lattice(ExistingOpenItem.self, configuration: conflict) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: (any Error).self) { try Lattice(ExistingOpenItem.self, configuration: configuration(url)) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func wrongVersionMissingOrMalformedMetadataCannotMigrateOrRepair() throws {
        for mutation in [
            "UPDATE _lattice_meta SET value='5' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value='7' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value='6tail' WHERE key='schema_version'",
            "UPDATE _lattice_meta SET value=x'36' WHERE key='schema_version'",
            "DELETE FROM _lattice_meta WHERE key='schema_version'",
            "DROP TABLE _lattice_meta",
            "UPDATE _lattice_meta SET value=value || 'junk' WHERE key LIKE 'schema_fingerprint:%'"
        ] {
            let url = file(); defer { cleanup(url) }; try seed(url)
            try execute(url, mutation)
            let before = image(url)
            for readOnly in [false, true] {
                #expect(throws: (any Error).self) {
                    try Lattice(ExistingOpenItem.self, configuration: configuration(url, readOnly: readOnly))
                }
                #expect(image(url) == before)
            }
        }
    }

    @Test func sameVersionWithDifferentModelsIsRejectedWithoutNewTableOrRows() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let before = image(url)
        #expect(throws: (any Error).self) {
            try Lattice(for: [ExistingOpenItem.self, ExistingOpenUnexpected.self], configuration: configuration(url))
        }
        #expect(image(url) == before)
        let valid = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        #expect(valid.objects(ExistingOpenItem.self).count == 1)
        valid.close()
    }

    @Test func eachOpenChecksCurrentFileAndUsesDistinctNativeIdentity() throws {
        let url = file(), replacement = file()
        defer { cleanup(url); cleanup(replacement) }
        try seed(url); try seed(replacement, version: 5)
        let first = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        let second = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        #expect(first.backend.identityHash != second.backend.identityHash)
        first.close(); second.close()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: replacement, to: url)
        let before = image(url)
        #expect(throws: (any Error).self) { try Lattice(ExistingOpenItem.self, configuration: configuration(url)) }
        #expect(image(url) == before)
    }

    @Test func existingFileAdmissionCannotAcquireBackgroundLifecycle() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let before = image(url)
        var config = configuration(url)
        config.backgroundSync = .appRefresh(identifier: "test.existing-file.must-not-register")
        #expect(throws: Lattice.Error.self) { try Lattice(ExistingOpenItem.self, configuration: config) }
        #expect(image(url) == before)
        config.backgroundSync = nil
        config.backgroundSyncManaged = true
        #expect(throws: Lattice.Error.self) { try Lattice(ExistingOpenItem.self, configuration: config) }
        #expect(image(url) == before)
        config.backgroundSyncManaged = false
        config.backgroundSyncLineage = BackgroundSyncLineage()
        #expect(throws: Lattice.Error.self) { try Lattice(ExistingOpenItem.self, configuration: config) }
        #expect(image(url) == before)
        config.backgroundSyncLineage = nil
        let reader = try Lattice(ExistingOpenItem.self, configuration: config)
        #expect(reader.objects(ExistingOpenItem.self).first?.payload == Data("saved".utf8))
        reader.close()
    }

    @Test func transportAndAttachmentOptionsCannotEscapeExistingFileAdmission() throws {
        let url = file(), otherURL = file(); defer { cleanup(url); cleanup(otherURL) }
        try seed(url); try seed(otherURL)
        var config = configuration(url)
        config.wssEndpoint = URL(string: "wss://invalid.example/sync")
        #expect(throws: Lattice.Error.self) { try Lattice(ExistingOpenItem.self, configuration: config) }
        config.wssEndpoint = nil; config.ipcTargets = [.init(channel: "existing-open-must-not-connect")]
        #expect(throws: Lattice.Error.self) { try Lattice(ExistingOpenItem.self, configuration: config) }
        var exact = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        var other = try Lattice(ExistingOpenItem.self, configuration: .init(fileURL: otherURL, migration: [6: Migration()]))
        defer { exact.close(); other.close() }
        #expect(throws: LatticeError.self) { try exact.attach(lattice: other) }
        #expect(throws: LatticeError.self) { try other.attach(lattice: exact) }
        #expect(throws: LatticeError.self) { try exact.attaching(lattice: other) }
        #expect(throws: LatticeError.self) { try other.attaching(lattice: exact) }
        let normal = Lattice.Configuration(fileURL: url)
        var required = normal; required.requiredExistingSchemaVersion = 6
        #expect(normal != required && Set([normal, required]).count == 2)
    }

    @Test func scalarCursorSeesTransactionRowsAndEmptyRetentionStateWithoutPayloadCopies() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let db = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        defer { db.close() }
        let before = try db.auditCursor()
        #expect(before.head > 0 && before.floor > 0 && before.headID != nil)
        try db.withTransaction {
            let row = try #require(db.objects(ExistingOpenItem.self).first)
            row.payload = Data(repeating: 7, count: 256 * 1024)
            let inside = try db.auditCursor()
            #expect(inside.head > before.head && inside.headID != before.headID && inside.floor == before.floor)
        }
        let after = try db.auditCursor()
        #expect(after.head > before.head)
        try execute(url, "DELETE FROM AuditLog WHERE id < \(after.head)")
        let retained = try db.auditCursor()
        #expect(retained.head == after.head && retained.floor == after.head && retained.headID == after.headID)
        try execute(url, "DELETE FROM AuditLog")
        #expect(try db.auditCursor() == AuditCursor(head: 0, headID: nil, floor: 0))
    }

    @Test func cursorFailuresThrowInsteadOfLookingLikeAnEmptyStore() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let db = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        try execute(url, "UPDATE AuditLog SET globalId='invalid' WHERE id=(SELECT MAX(id) FROM AuditLog)")
        #expect(throws: Lattice.Error.self) { try db.auditCursor() }
        #expect(db.lastQueryError() != nil)
        try execute(url, "DROP TABLE AuditLog")
        #expect(throws: Lattice.Error.self) { try db.auditCursor() }
        db.close()
        #expect(throws: Lattice.Error.self) { try db.auditCursor() }
    }
}


extension ExistingSchemaAccessTests {
    @Test func readFenceDetectsPruningThatRestoresTheSameCursorAndForceReset() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let db = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        defer { db.close() }
        // NULL/missing persisted receive cursor makes Core preserve the newest remote audit row.
        try execute(url, "INSERT INTO _lattice_replication_slots(sync_id,upload_floor,last_active_at) VALUES('fence-reader',0,datetime('now'))")
        try execute(url, "UPDATE AuditLog SET isFromRemote=1")
        let before = try db.auditReadFence()
        #expect(before.historyGeneration == nil)
        var lastGeneration: UUID?
        for value in ["first", "second"] {
            try db.withTransaction {
                let row = try #require(db.objects(ExistingOpenItem.self).first)
                row.payload = Data(value.utf8)
            }
            #expect(try db.auditReadFence().cursor.head > before.cursor.head)
            try execute(url, "UPDATE _lattice_replication_slots SET upload_floor=(SELECT MAX(id) FROM AuditLog)")
            #expect(db.compactHistory() > 0)
            let after = try db.auditReadFence()
            #expect(after.cursor == before.cursor)
            #expect(after != before)
            #expect(after.historyGeneration != nil && after.historyGeneration != lastGeneration)
            #expect(db.objects(ExistingOpenItem.self).first?.payload == Data(value.utf8))
            lastGeneration = after.historyGeneration
        }
        #expect(db.forceCompactHistory() > 0)
        let reset = try db.auditReadFence()
        #expect(reset.historyGeneration != nil && reset.historyGeneration != lastGeneration)
    }

    @Test func readFenceDoesNotWriteOnStrictReadOnlyAndUsesCurrentTransaction() throws {
        let url = file(); defer { cleanup(url) }; try seed(url)
        let before = image(url)
        do {
            let reader = try Lattice(ExistingOpenItem.self, configuration: configuration(url, readOnly: true))
            let fence = try reader.auditReadFence()
            #expect(fence.historyGeneration == nil && fence.cursor.head > 0)
            #expect(try reader.auditReadFence() == fence)
            reader.close()
        }
        #expect(image(url) == before)
        let writer = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
        defer { writer.close() }
        let original = try writer.auditReadFence()
        enum Rollback: Swift.Error { case expected }
        #expect(throws: Rollback.self) {
            try writer.withTransaction {
                let row = try #require(writer.objects(ExistingOpenItem.self).first)
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
        let db = try Lattice(ExistingOpenItem.self, configuration: configuration(url))
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
