import Foundation
import Testing
import CLatticeTestSQLite
import LatticeTestSupport
@testable import Lattice

@Model private final class DynamicGroupedItem {
    var scope: String = ""
    var label: String = ""
    var payload: Data = Data()
}

@Suite("Dynamic scalar projection", .serialized)
struct DynamicGroupedCountTests {
    private func withStore(_ body: (Lattice) throws -> Void) throws {
        let directory = testTemporaryDirectory.appendingPathComponent("dynamic-grouped-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try Lattice(DynamicGroupedItem.self, configuration: .init(fileURL: directory.appendingPathComponent("store.sqlite")))
        defer { store.close(); try? FileManager.default.removeItem(at: directory) }
        try body(store)
    }
    private func add(_ store: Lattice, scope: String, label: String, id: UUID = UUID()) throws {
        let row = DynamicGroupedItem(); row.scope = scope; row.label = label
        row.payload = Data(repeating: 7, count: 65_536)
        try store.add(row, preservingGlobalId: id)
    }
    private func withAuditStore(_ body: (Lattice, URL) throws -> Void) throws {
        // LATTICE_TEST_TMPDIR selects the runner's owned localdev scratch through testTemporaryDirectory.
        let directory = testTemporaryDirectory.appendingPathComponent("dynamic-audit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try Lattice(DynamicGroupedItem.self,
            configuration: .init(fileURL: url, migration: [6: Migration()]))
        defer { store.close(); try? FileManager.default.removeItem(at: directory) }
        try body(store, url)
    }
    private func strictAuditReader(_ url: URL) throws -> Lattice {
        try Lattice(DynamicGroupedItem.self,
            configuration: .init(fileURL: url, isReadOnly: true, requiredExistingSchemaVersion: 6))
    }
    private func mutateAuditFixture(_ url: URL, sql: String) throws {
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try registerCurrentWriterForFixtureMutation(connection)
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }
    private func image(_ url: URL) -> [Data] {
        [url.path, url.path + "-wal"].map { (try? Data(contentsOf: URL(fileURLWithPath: $0))) ?? Data() }
    }

    @Test func reservedAuditHeadersUseStrictSameSchemaWithoutRegisteringAuditModel() throws {
        try withAuditStore { writer, url in
            let rowID = try #require(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef"))
            let row = DynamicGroupedItem(); row.scope = "chosen"; row.label = "Before"
            row.payload = Data(repeating: 7, count: 65_536)
            try writer.add(row, preservingGlobalId: rowID)
            let inserted = try writer.auditCursor()
            try writer.withTransaction { row.label = "After" }
            let updated = try writer.auditCursor()
            let insertedID = try #require(inserted.headID)
            let updatedID = try #require(updated.headID)
            let schema = writer.dynamicSchema
            let models = writer.modelTypes.map { $0.entityName }
            let fence = try writer.auditReadFence()
            let before = image(url)
            try #require(!before[0].isEmpty, "the schema/image conservation check needs a readable main file")
            #expect(!models.contains("AuditLog") && !schema.contains { $0.name == "AuditLog" })
            #expect(updated.head > inserted.head && updatedID != insertedID)

            let reader = try strictAuditReader(url)
            defer { reader.close() }
            let version = try reader.storedSchemaVersion()
            #expect(version == 6 && reader.modelTypes.map { $0.entityName } == models)
            #expect(reader.dynamicSchema == schema)
            func expectAuditIdentity(_ groups: [GroupedCount], at auditID: Int64, expected: UUID) throws {
                try #require(groups.count == 1 && groups[0].count == 1)
                let rawKey = groups[0].key
                let identifier = try #require(UUID(uuidString: rawKey))
                #expect(identifier == expected)
                let exact = try reader.dynamicObjects("AuditLog")
                    .where("id = ? AND globalId COLLATE BINARY = ?")
                    .groupedCounts(by: "globalId", parameters: [.integer(auditID), .text(rawKey)])
                #expect(exact == groups, "UUID identity and stored header spelling must both be preserved")
            }
            #if DEBUG && !ORBITAL_PERF
            let materializations = LatticePerf.threadCounters().materializations
            #endif
            let expected = [
                ("globalId", updatedID.uuidString),
                ("tableName", "DynamicGroupedItem"),
                ("globalRowId", rowID.uuidString.lowercased()),
                ("operation", "UPDATE"),
            ]
            for (column, key) in expected {
                let result = try reader.dynamicObjects("AuditLog").where("id = ?")
                    .groupedCounts(by: column, parameters: [.integer(updated.head)])
                if column == "globalId" {
                    try expectAuditIdentity(result, at: updated.head, expected: updatedID)
                } else {
                    #expect(result == [.init(key: key, count: 1)], "reserved header \(column) must preserve stored text and slots")
                }
            }
            let names = try reader.dynamicObjects("AuditLog").where("id = ?")
                .groupedCounts(by: "changedFieldsNames", parameters: [.integer(updated.head)])
            let namesRow = try #require(names.first)
            let slots = try JSONDecoder().decode([String?].self, from: Data(namesRow.key.utf8))
            #expect(names.count == 1 && namesRow.count == 1)
            #expect(slots.count == 3 && slots.compactMap { $0 } == ["label"] && slots.filter { $0 == nil }.count == 2,
                "changed-name headers retain every null slot without assuming physical column order")
            let anchor = try reader.dynamicObjects("AuditLog").where("id = ?")
                .groupedCounts(by: "globalId", parameters: [.integer(inserted.head)])
            try expectAuditIdentity(anchor, at: inserted.head, expected: insertedID)
            let absent = try reader.dynamicObjects("AuditLog").where("globalId = ?")
                .groupedCounts(by: "globalId", parameters: [.text(updatedID.uuidString.lowercased() + "' OR 1=1 --")])
            #expect(absent.isEmpty, "reserved headers retain typed parameter binding")
            #if DEBUG && !ORBITAL_PERF
            #expect(LatticePerf.threadCounters().materializations == materializations)
            #endif
            let afterFence = try reader.auditReadFence()
            let afterVersion = try reader.storedSchemaVersion()
            #expect(afterFence == fence && afterVersion == version)
            #expect(reader.modelTypes.map { $0.entityName } == models && reader.dynamicSchema == schema)
            reader.close()
            #expect(image(url) == before, "header reads must not change schema fingerprints, audit or sync state")
        }
    }

    @Test func reservedAuditHeadersKeepUnknownColumnsTablesAndSortedShapesRefused() throws {
        try withAuditStore { writer, url in
            try add(writer, scope: "one", label: "One")
            let reader = try strictAuditReader(url)
            defer { reader.close() }
            for column in ["changedFields", "id", "rowId", "timestamp", "isSynchronized", "missing", "operation) FROM AuditLog; --"] {
                #expect(throws: (any Error).self) {
                    try reader.dynamicObjects("AuditLog").groupedCounts(by: column)
                }
            }
            for table in ["Missing", "auditlog", "AuditLog_suffix"] {
                #expect(throws: (any Error).self) {
                    try reader.dynamicObjects(table).groupedCounts(by: "globalId")
                }
            }
            #expect(throws: (any Error).self) {
                try reader.dynamicObjects("AuditLog").sortedBy("id").groupedCounts(by: "globalId")
            }
        }
    }

    @Test func explicitlyRegisteredAuditModelRetainsNonHeaderScalarColumns() throws {
        try withAuditStore { writer, url in
            let row = DynamicGroupedItem(); row.scope = "registered"; row.label = "Registered control"
            try writer.add(row)
            let cursor = try writer.auditCursor()
            let before = image(url)
            // Augment descriptors only in a read-only handle; do not register AuditLog on a writer.
            // Exact fingerprint admission is deliberately absent for this legacy metadata-path control.
            let reader = try Lattice(DynamicGroupedItem.self, AuditLog.self,
                configuration: .init(fileURL: url, isReadOnly: true, migration: [6: Migration()]))
            defer { reader.close() }
            #expect(reader.dynamicSchema.contains { $0.name == "AuditLog" })
            let result = try reader.dynamicObjects("AuditLog").where("id = ?")
                .groupedCounts(by: "changedFields", parameters: [.integer(cursor.head)])
            let payload = try #require(result.first)
            let decoded = try JSONSerialization.jsonObject(with: Data(payload.key.utf8))
            let fields = try #require(decoded as? [String: Any])
            #expect(result.count == 1 && payload.count == 1)
            #expect(fields["scope"] as? String == "registered" && fields["label"] as? String == "Registered control",
                "the reserved fallback must not narrow previously registered stored TEXT columns")
            reader.close()
            #expect(image(url) == before, "read-only descriptor registration must not change tables or triggers")
        }
    }

    @Test(arguments: ["predicate", "missing-table", "closed"])
    func reservedAuditHeaderErrorsAreNotLegitimateEmptyResults(failure: String) throws {
        try withAuditStore { writer, url in
            try add(writer, scope: "one", label: "One")
            let cursor = try writer.auditCursor()
            let reader = try strictAuditReader(url)
            defer { reader.close() }
            let query = reader.dynamicObjects("AuditLog")
            let absent = try query.where("id = ?")
                .groupedCounts(by: "globalId", parameters: [.integer(cursor.head + 1)])
            #expect(absent.isEmpty)
            switch failure {
            case "predicate":
                #expect(throws: (any Error).self) {
                    try query.where("missing_audit_header = ?")
                        .groupedCounts(by: "globalId", parameters: [.integer(cursor.head)])
                }
            case "missing-table":
                writer.close()
                try mutateAuditFixture(url, sql: "DROP TABLE AuditLog")
                #expect(throws: (any Error).self) { try query.groupedCounts(by: "globalId") }
            default:
                reader.close()
                #expect(throws: (any Error).self) { try query.groupedCounts(by: "globalId") }
            }
        }
    }
    @Test func boundKeysetPagesDoNotHydratePayloadOrCrossScope() throws {
        try withStore { store in
            let scope = "selected ' ? -- \u{2603}"
            var expected: [String] = []
            try store.transaction {
                for index in 1...35 {
                    let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                    expected.append(id.uuidString.lowercased())
                    try add(store, scope: scope, label: "Seat \(index)", id: id)
                }
                try add(store, scope: "other", label: "Excluded")
            }
            func page(after: String) throws -> [String] {
                try store.dynamicObjects("DynamicGroupedItem")
                    .where("id IN (SELECT id FROM DynamicGroupedItem WHERE scope = ? AND globalId > ? ORDER BY globalId LIMIT 32)")
                    .groupedCounts(by: "globalId", parameters: [.text(scope), .text(after)]).map(\.key).sorted()
            }
            #if DEBUG && !ORBITAL_PERF
            let before = LatticePerf.threadCounters().materializations
            #endif
            let first = try page(after: ""), last = try #require(first.last)
            let second = try page(after: last)
            #expect(first.count == 32 && second.count == 3)
            #expect(first + second == expected)
            let finalKey = try #require(second.last)
            #expect(try page(after: finalKey).isEmpty)
            #if DEBUG && !ORBITAL_PERF
            #expect(LatticePerf.threadCounters().materializations == before)
            #endif
            let rejected = try store.dynamicObjects("DynamicGroupedItem").where("scope = ?")
                .groupedCounts(by: "label", parameters: [.text(scope + "' OR 1=1 --")])
            #expect(rejected.isEmpty)
        }
    }
    @Test func schemaOrderingAndClosedHandleRefuseInsteadOfEmptySuccess() throws {
        try withStore { store in
            try add(store, scope: "one", label: "One")
            for column in ["missing", "label) FROM DynamicGroupedItem; --"] {
                #expect(throws: (any Error).self) {
                    try store.dynamicObjects("DynamicGroupedItem").groupedCounts(by: column)
                }
            }
            #expect(throws: (any Error).self) { try store.dynamicObjects("Missing").groupedCounts(by: "globalId") }
            #expect(throws: (any Error).self) {
                try store.dynamicObjects("DynamicGroupedItem").sortedBy("label").groupedCounts(by: "label")
            }
            let query = store.dynamicObjects("DynamicGroupedItem")
            store.close()
            #expect(throws: (any Error).self) { try query.groupedCounts(by: "label") }
        }
    }
    @Test func liveProjectionSeesOwnTransactionAndRollback() throws {
        struct Abort: Error {}
        try withStore { store in
            try add(store, scope: "selected", label: "Kept")
            let rows = store.dynamicObjects("DynamicGroupedItem").where("scope = ?")
            #expect(throws: Abort.self) {
                try store.transaction {
                    try add(store, scope: "selected", label: "Temporary")
                    let keys = try rows.groupedCounts(by: "label", parameters: [.text("selected")]).map(\.key)
                    #expect(Set(keys) == ["Kept", "Temporary"])
                    throw Abort()
                }
            }
            #expect(try rows.groupedCounts(by: "label", parameters: [.text("selected")]) == [.init(key: "Kept", count: 1)])
        }
    }
}
