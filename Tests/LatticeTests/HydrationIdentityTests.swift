import Foundation
import Testing
@testable import Lattice

@Model private final class HydrationIdentityItem {
    var rank: Int = 0
    var title: String = ""
}

@Suite("Query hydration identity", .serialized)
struct HydrationIdentityTests {
    private func store() throws -> Lattice {
        let db = try Lattice(HydrationIdentityItem.self,
                             configuration: .init(storage: .memory()))
        try db.withTransaction {
            for rank in 0..<25 {
                let item = HydrationIdentityItem()
                item.rank = rank
                item.title = "row-\(rank)"
                try db.add(item)
            }
        }
        return db
    }

    @Test func constructingQueryModelsDoesNotRefetchTheirIdentity() throws {
        let db = try store()
        defer { db.close() }
        let rows = db.backend.objects(table: HydrationIdentityItem.entityName,
                                      where: nil, orderBy: "rank ASC",
                                      limit: 25, offset: nil,
                                      groupBy: nil, distinctBy: nil)
        #expect(rows.count == 25)
        #expect(rows.allSatisfy { !$0.isRowCacheEnabled })

        let before = Lattice.threadSQLStatementCount
        let models = rows.map { HydrationIdentityItem(dynamicObject: $0) }
        let statements = Lattice.threadSQLStatementCount - before
        #expect(statements == 0, "identity and observer registration must use the bound key")
        #expect(models.allSatisfy { !$0.isMaterialized })
        #expect(models.map(\.rank) == Array(0..<25))
        #expect(models.map(\.title) == (0..<25).map { "row-\($0)" })
        withExtendedLifetime(models) {}
    }

    @Test func constructionPreservesAnExistingMaterializedImage() throws {
        let db = try store()
        defer { db.close() }
        let row = try #require(db.backend.objects(
            table: HydrationIdentityItem.entityName,
            where: "rank = ?", orderBy: nil, limit: 1, offset: nil,
            groupBy: nil, distinctBy: nil, params: [.integer(0)]).first)
        row.enableRowCache()
        let key = try #require(row._managedPrimaryKey)
        let writer = try #require(db.object(HydrationIdentityItem.self, primaryKey: key))
        writer.title = "changed after materialization"

        let before = Lattice.threadSQLStatementCount
        let model = HydrationIdentityItem(dynamicObject: row)
        #expect(Lattice.threadSQLStatementCount - before == 0)
        #expect(model.isMaterialized)
        #expect(model.title == "row-0", "constructing a model must not refresh a held snapshot")
        model.dematerialize()
        #expect(model.title == "changed after materialization")
    }
}
