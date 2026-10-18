import Foundation
import Testing
@testable import Lattice

@Model private final class GroupCountItem {
    var topic: String = ""
    var project: String = ""
    var payload: Data = Data()
    var computedKey: String { topic + ":" + project }
}

@Suite("Scalar grouped counts", .serialized)
struct GroupedCountTests {
    private func withStore(_ body: (Lattice) throws -> Void) throws {
        let directory = testTemporaryDirectory
            .appendingPathComponent("group-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = Lattice.Configuration(fileURL: directory.appendingPathComponent("store.sqlite"))
        let db = try Lattice(GroupCountItem.self, configuration: config)
        defer { db.close(); try? FileManager.default.removeItem(at: directory) }
        try body(db)
    }

    private func add(_ db: Lattice, topic: String, project: String = "p", id: UUID? = nil) throws {
        let row = GroupCountItem()
        row.topic = topic; row.project = project
        row.payload = Data(repeating: 7, count: 4096)
        if let id { try db.add(row, preservingGlobalId: id) }
        else { try db.add(row) }
    }

    @Test func emptyAndBoundFiltersKeepScalarKeysExact() throws {
        try withStore { db in
            #expect(try db.objects(GroupCountItem.self).groupedCounts(by: \.topic).isEmpty)
            let hostile = "quotes ' ? -- and unicode \u{2603}"
            try add(db, topic: hostile, project: "selected")
            try add(db, topic: hostile, project: "selected")
            try add(db, topic: "hidden", project: "other")
            let projects = ["selected"] + (0..<200).map { "unused-\($0)" }
            let rows = try db.objects(GroupCountItem.self).distinct(by: \.globalId)
                .where { $0.project.in(projects) }.groupedCounts(by: \.topic)
            #expect(rows == [GroupedCount(key: hostile, count: 2)])
        }
    }

    @Test func attachedConflictingCopiesMatchLegacyPerKeyCounts() throws {
        try withStore { local in
            try withStore { remote in
                let shared = UUID()
                try add(local, topic: "a", id: shared)
                try add(remote, topic: "b", id: shared)
                try add(local, topic: "a")
                try add(remote, topic: "b")
                let union = try local.attaching(lattice: remote)
                defer { union.close() }
                let base = union.objects(GroupCountItem.self).distinct(by: \.globalId)
                let oldNames = Set(base.group(by: \.topic).materializedSnapshot().map(\.topic))
                let actual = try base.groupedCounts(by: \.topic)
                #expect(Set(actual.map(\.key)) == oldNames)
                for row in actual {
                    #expect(row.count == Int64(base.where { $0.topic == row.key }.count))
                }
                #expect(actual.reduce(0) { $0 + $1.count } == 4)
                #expect(base.count == 3)
            }
        }
    }

    @Test func conflictOnlyCopiesSelectOneUnspecifiedRepresentative() throws {
        try withStore { local in
            try withStore { remote in
                let shared = UUID()
                try add(local, topic: "a", id: shared)
                try add(remote, topic: "b", id: shared)
                let union = try local.attaching(lattice: remote)
                defer { union.close() }
                let base = union.objects(GroupCountItem.self).distinct(by: \.globalId)
                let rows = try base.groupedCounts(by: \.topic)
                #expect(rows.count == 1)
                #expect(Set(rows.map(\.key)).isSubset(of: ["a", "b"]))
                #expect(rows.first?.count == 1)
                // Legacy representatives are also unspecified; do not impose
                // accidental equality between different SQLite query plans.
                #expect(base.group(by: \.topic).materializedSnapshot().count == 1)
            }
        }
    }

    @Test func computedStringKeyIsRejectedInsteadOfReadingItsLastStoredProperty() throws {
        try withStore { db in
            try add(db, topic: "topic", project: "project")
            #expect(throws: (any Error).self) {
                try db.objects(GroupCountItem.self).groupedCounts(by: \.computedKey)
            }
        }
    }

    @Test func oneStatementRegardlessOfGroupCardinality() throws {
        try withStore { db in
            try add(db, topic: "first")
            let base = db.objects(GroupCountItem.self).distinct(by: \.globalId)
            _ = try base.groupedCounts(by: \.topic) // Initialize the ordinary reader.
            let smallBefore = Lattice.threadSQLStatementCount
            #expect(try base.groupedCounts(by: \.topic).count == 1)
            let small = Lattice.threadSQLStatementCount - smallBefore
            try db.transaction { for i in 0..<220 { try add(db, topic: "topic-\(i)") } }
            _ = try base.groupedCounts(by: \.topic)
            let largeBefore = Lattice.threadSQLStatementCount
            #if DEBUG && !ORBITAL_PERF
            let hydratedBefore = LatticePerf.threadCounters().materializations
            #endif
            #expect(try base.groupedCounts(by: \.topic).count == 221)
            let large = Lattice.threadSQLStatementCount - largeBefore
            #expect(small == 1)
            #expect(large == small)
            #if DEBUG && !ORBITAL_PERF
            #expect(LatticePerf.threadCounters().materializations == hydratedBefore)
            #endif
        }
    }

    @Test func readsOwnUncommittedRowsWithoutPoisoningRollback() throws {
        struct Abort: Error {}
        try withStore { db in
            try add(db, topic: "kept")
            #expect(throws: Abort.self) {
                try db.transaction {
                    try add(db, topic: "temporary")
                    let rows = try db.objects(GroupCountItem.self).groupedCounts(by: \.topic)
                    #expect(Set(rows.map(\.key)) == ["kept", "temporary"])
                    throw Abort()
                }
            }
            #expect(try db.objects(GroupCountItem.self).groupedCounts(by: \.topic)
                    == [GroupedCount(key: "kept", count: 1)])
        }
    }

    @Test func unsupportedShapeAndClosedStoreDoNotReportEmptySuccess() throws {
        try withStore { db in
            let grouped = db.objects(GroupCountItem.self).group(by: \.project)
            #expect(throws: (any Error).self) { try grouped.groupedCounts(by: \.topic) }
            db.close()
            #expect(throws: (any Error).self) {
                try db.objects(GroupCountItem.self).groupedCounts(by: \.topic)
            }
        }
    }
}
