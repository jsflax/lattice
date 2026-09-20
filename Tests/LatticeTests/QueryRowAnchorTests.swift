import Foundation
import Testing
@testable import Lattice

@Model private final class QueryRowAnchorItem {
    var rank: Int = 0
    var label: String? = nil
}

@Suite("SELECT row anchors", .serialized)
struct QueryRowAnchorTests {
    private func seed(_ db: Lattice, ranks: [Int]) throws -> [Int64] {
        var ids: [Int64] = []
        try db.withTransaction {
            for rank in ranks {
                let item = QueryRowAnchorItem()
                item.rank = rank
                try db.add(item)
                ids.append(try #require(item.primaryKey))
            }
        }
        return ids
    }

    private func selectedRow(_ db: Lattice) throws -> any ObjectBackend {
        try #require(db.backend.objects(
            table: QueryRowAnchorItem.entityName,
            where: nil, orderBy: "rank ASC, id ASC", limit: 1, offset: nil,
            groupBy: nil, distinctBy: nil).first)
    }

    private var rankSpec: KeysetSortSpec {
        KeysetSortSpec(column: "rank", ascending: true, kind: .int)
    }

    private func integerValue(_ anchor: KeysetAnchor?) -> Int64? {
        guard let anchor, case .int(let value) = anchor.value else { return nil }
        return value
    }

    @Test func selectedImageSurvivesSameHandleWritesAndDeletionWithoutSQL() throws {
        let db = try Lattice(QueryRowAnchorItem.self, configuration: .init(storage: .memory()))
        defer { db.close() }
        let ids = try seed(db, ranks: [10])
        let id = try #require(ids.first)
        let row = try selectedRow(db)
        try #require(row._queryRowValue(named: "rank") == .int64(10))

        // Mutating the very handle that owns the SELECT image must not
        // rewrite its captured boundary or switch it into snapshot reads.
        row.setInt(named: "rank", 99)
        #expect(row.getInt(named: "rank") == 99)
        let beforeWriteAnchor = Lattice.threadSQLStatementCount
        let afterWrite = KeysetSQL.extractAnchor(from: row, spec: rankSpec)
        #expect(integerValue(afterWrite) == 10)
        #expect(afterWrite?.id == id)
        #expect(!row.isRowCacheEnabled)
        #expect(Lattice.threadSQLStatementCount - beforeWriteAnchor == 0)

        db.delete(QueryRowAnchorItem.self, where: { $0.rank == 99 })
        #expect(db.objects(QueryRowAnchorItem.self).count == 0)
        let beforeDeleteAnchor = Lattice.threadSQLStatementCount
        let afterDelete = KeysetSQL.extractAnchor(from: row, spec: rankSpec)
        #expect(integerValue(afterDelete) == 10,
                "A deleted boundary row still has its original SELECT position")
        #expect(afterDelete?.id == id)
        #expect(Lattice.threadSQLStatementCount - beforeDeleteAnchor == 0)
    }

    @MainActor @Test func selectedImageSurvivesAnotherConnectionWriteWithoutSQL() async throws {
        let name = "query-anchor-\(UUID().uuidString)"
        let db = try Lattice(isolation: MainActor.shared, QueryRowAnchorItem.self,
                             configuration: .init(storage: .memory(named: name)))
        defer { db.close() }
        let ids = try seed(db, ranks: [10])
        let id = try #require(ids.first)
        let row = try selectedRow(db)

        // Different scheduler identities guarantee distinct Core handles.
        // Only value data crosses actors; the selected object stays here.
        let writerIdentity = try await Task.detached {
            let writer = try Lattice(isolation: nil, QueryRowAnchorItem.self,
                                     configuration: .init(storage: .memory(named: name)))
            defer { writer.close() }
            let target = try #require(writer.backend.object(
                primaryKey: id, table: QueryRowAnchorItem.entityName))
            target.setInt(named: "rank", 99)
            #expect(target.getInt(named: "rank") == 99)
            return writer.backend.identityHash
        }.value
        try #require(writerIdentity != db.backend.identityHash,
                     "This regression requires a distinct writer connection")
        #expect(row.getInt(named: "rank") == 99)

        let before = Lattice.threadSQLStatementCount
        let anchor = KeysetSQL.extractAnchor(from: row, spec: rankSpec)
        #expect(integerValue(anchor) == 10)
        #expect(anchor?.id == id)
        #expect(row._queryRowValue(named: "rank") == .int64(10))
        #expect(!row.isRowCacheEnabled)
        #expect(Lattice.threadSQLStatementCount - before == 0)
    }

    @Test func sqlNullIsAnAnchorButMissingOrReleasedMetadataIsNot() throws {
        let db = try Lattice(QueryRowAnchorItem.self, configuration: .init(storage: .memory()))
        defer { db.close() }
        _ = try seed(db, ranks: [10])
        let row = try selectedRow(db)
        let nullSpec = KeysetSortSpec(column: "label", ascending: true, kind: .string)
        let missingSpec = KeysetSortSpec(column: "not_selected", ascending: true, kind: .string)

        let before = Lattice.threadSQLStatementCount
        #expect(row._queryRowValue(named: "label") == .null)
        let nullAnchor = try #require(KeysetSQL.extractAnchor(from: row, spec: nullSpec))
        if case .null = nullAnchor.value {} else {
            Issue.record("A selected SQL NULL must produce a NULL anchor")
        }
        #expect(row._queryRowValue(named: "not_selected") == nil)
        #expect(KeysetSQL.extractAnchor(from: row, spec: missingSpec) == nil,
                "Missing metadata must never fabricate a NULL boundary")

        row._releaseQueryRowImage()
        row._releaseQueryRowImage() // Release is idempotent.
        #expect(row._queryRowValue(named: "id") == nil)
        #expect(row._queryRowValue(named: "label") == nil)
        #expect(KeysetSQL.extractAnchor(from: row, spec: nullSpec) == nil)
        #expect(KeysetSQL.extractAnchor(from: row, spec: rankSpec) == nil)
        #expect(!row.isRowCacheEnabled)
        #expect(Lattice.threadSQLStatementCount - before == 0)
        #expect(row.getInt(named: "rank") == 10,
                "Releasing query metadata must leave live reads intact")
    }

    @Test func publicationReleasesMetadataAndPreservesMaterializedReads() throws {
        let db = try Lattice(QueryRowAnchorItem.self, configuration: .init(storage: .memory()))
        defer { db.close() }
        let ids = try seed(db, ranks: [10])
        let id = try #require(ids.first)
        let row = try selectedRow(db)
        row.enableRowCache()
        let writer = try #require(db.backend.object(primaryKey: id, table: QueryRowAnchorItem.entityName))
        writer.setInt(named: "rank", 20)
        #expect(writer.getInt(named: "rank") == 20)
        try #require(row._queryRowValue(named: "rank") == .int64(10))

        let before = Lattice.threadSQLStatementCount
        let model = QueryRowAnchorItem(dynamicObject: row)
        #expect(model._dynamicObject._ref._queryRowValue(named: "id") == nil)
        #expect(row._queryRowValue(named: "rank") == nil)
        #expect(model.isMaterialized)
        #expect(model.rank == 10,
                "Discarding SELECT metadata must not clear or refresh the explicit snapshot")
        #expect(Lattice.threadSQLStatementCount - before == 0)

        model.refreshMaterialized()
        #expect(model.rank == 20)
        #expect(model.isMaterialized)
        model.dematerialize()
        #expect(!model.isMaterialized)
        #expect(model.rank == 20)
    }

    @Test(arguments: [false, true])
    func reusedMaterializedBoundaryCannotMovePageOrIteratorAnchor(useIterator: Bool) throws {
        // File-backed results exercise keyset pages; memory results use the
        // separate materialized-ID path. Keep fixtures inside this checkout.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/query-row-anchor-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Lattice.Configuration(fileURL: directory.appendingPathComponent("rows.sqlite"))
        configuration.resultsTuning.pageSize = 2
        let db = try Lattice(QueryRowAnchorItem.self, configuration: configuration)
        defer { db.close() }
        let ids = try seed(db, ranks: [10, 20, 30, 40, 50])
        let held = try #require(db.object(QueryRowAnchorItem.self, primaryKey: ids[1])).materialize()

        // The only registered instance of this row keeps rank 20, while the
        // actual SELECT boundary is now 25. An unregistered writer handle
        // makes the registry's reuse choice deterministic.
        let writer = try #require(db.backend.object(
            primaryKey: ids[1], table: QueryRowAnchorItem.entityName))
        writer.setInt(named: "rank", 25)
        #expect(writer.getInt(named: "rank") == 25)
        #expect(held.rank == 20)
        let results = db.objects(QueryRowAnchorItem.self).sortedBy(\.rank, order: .forward)
        #expect(results.count == 5)
        let shape = results._shapeState
        var delivered: [QueryRowAnchorItem] = []

        if useIterator {
            var iterator = results.makeIterator()
            delivered.append(try #require(iterator.next()))
            delivered.append(try #require(iterator.next()))
            let boundary = try #require(shape.nearestAnchor(atOrBefore: 0))
            #expect(boundary.page == 0)
            #expect(integerValue(boundary.anchor) == 25)
            #expect(boundary.anchor.id == ids[1])
            // Bound a broken walk that repeatedly redelivers the stale row.
            while delivered.count < 6, let row = iterator.next() { delivered.append(row) }
        } else {
            delivered.append(try #require(results.element(at: 0)))
            delivered.append(try #require(results.element(at: 1)))
            let boundary = try #require(shape.nearestAnchor(atOrBefore: 0))
            #expect(boundary.page == 0)
            #expect(integerValue(boundary.anchor) == 25)
            #expect(boundary.anchor.id == ids[1])
            for index in 2..<5 { delivered.append(try #require(results.element(at: index))) }
        }

        #expect(delivered[1] === held, "The regression must exercise instance reuse")
        #expect(delivered.compactMap { $0._dynamicObject._ref._managedPrimaryKey } == ids,
                "Resuming from the stale model value would redeliver its row")
        #expect(delivered.allSatisfy { $0._dynamicObject._ref._queryRowValue(named: "id") == nil },
                "No published model may retain its transient SELECT metadata")
        #expect(held.isMaterialized)
        #expect(held.rank == 20)
        #expect(delivered.enumerated().allSatisfy { $0.offset == 1 || !$0.element.isMaterialized })
    }
}
