import Foundation
import Lattice
import Testing

@Suite("Distinct Tests", .serialized)
class DistinctTests: BaseTest {

    // MARK: - KeyPath tracking for globalId

    @Test func distinct_globalId_keyPathTracking() async throws {
        let lattice = try testLattice(PlainItem.self)
        let item = PlainItem(content: "test", project: "test")
        try lattice.add(item)

        // Verify _name(for:) resolves globalId to "globalId"
        let results = lattice.objects(PlainItem.self)
            .distinct(by: \.globalId)
            .snapshot()
        // Should return 1 (one unique globalId)
        #expect(results.count == 1)
    }

    // MARK: - Basic distinct on single DB

    @Test func distinct_removeDuplicates_singleDB() async throws {
        let lattice = try testLattice(PlainItem.self)

        // Insert items with duplicate project values
        try lattice.add(PlainItem(content: "a", project: "alpha"))
        try lattice.add(PlainItem(content: "b", project: "alpha"))
        try lattice.add(PlainItem(content: "c", project: "beta"))

        // Without distinct: 3 items
        #expect(lattice.objects(PlainItem.self).count == 3)

        // With distinct by project: 2 unique projects
        let results = lattice.objects(PlainItem.self)
            .distinct(by: \.project)
            .snapshot()
        #expect(results.count == 2)

        let projects = Set(results.map(\.project))
        #expect(projects == ["alpha", "beta"])
    }

    @Test func distinct_count_singleDB() async throws {
        let lattice = try testLattice(PlainItem.self)

        try lattice.add(PlainItem(content: "a", project: "alpha"))
        try lattice.add(PlainItem(content: "b", project: "alpha"))
        try lattice.add(PlainItem(content: "c", project: "beta"))
        try lattice.add(PlainItem(content: "d", project: "beta"))
        try lattice.add(PlainItem(content: "e", project: "gamma"))

        // Without distinct: 5
        #expect(lattice.objects(PlainItem.self).count == 5)

        // With distinct by project: 3 unique projects
        #expect(lattice.objects(PlainItem.self).distinct(by: \.project).count == 3)
    }

    @Test func distinct_preservesWhereClause() async throws {
        let lattice = try testLattice(PlainItem.self)

        try lattice.add(PlainItem(content: "a", project: "alpha"))
        try lattice.add(PlainItem(content: "b", project: "alpha"))
        try lattice.add(PlainItem(content: "c", project: "beta"))
        try lattice.add(PlainItem(content: "d", project: "beta"))
        try lattice.add(PlainItem(content: "e", project: "gamma"))

        // WHERE + distinct: only "alpha" project items, deduplicated
        let results = lattice.objects(PlainItem.self)
            .where { $0.project == "alpha" }
            .distinct(by: \.project)
            .snapshot()
        #expect(results.count == 1)
        #expect(results.first?.project == "alpha")
    }

    @Test func distinct_withGroupBy_attachedDBs() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        // Simulate overlapping memories across two DBs
        let shared1 = PlainItem(content: "memory1", project: "alpha")
        try local.add(shared1)
        let gid1 = shared1.globalId!
        try synced.add(PlainItem(content: "memory1", project: "alpha"), preservingGlobalId: gid1)

        let shared2 = PlainItem(content: "memory2", project: "beta")
        try local.add(shared2)
        let gid2 = shared2.globalId!
        try synced.add(PlainItem(content: "memory2", project: "beta"), preservingGlobalId: gid2)

        // Unique to synced
        try synced.add(PlainItem(content: "memory3", project: "alpha"))

        let query = try local.attaching(lattice: synced)

        // Without distinct: 5 rows (2 local + 3 synced)
        #expect(query.objects(PlainItem.self).count == 5)

        // distinct by globalId + group by project:
        // After dedup: memory1(alpha), memory2(beta), memory3(alpha) = 3 rows
        // After group by project: alpha, beta = 2 groups
        let results = query.objects(PlainItem.self)
            .distinct(by: \.globalId)
            .group(by: \.project)
            .snapshot()
        #expect(results.count == 2)

        // distinct by globalId: count should be 3
        #expect(query.objects(PlainItem.self).distinct(by: \.globalId).count == 3)

        // distinct by globalId + group by project: count should be 2
        #expect(query.objects(PlainItem.self).distinct(by: \.globalId).group(by: \.project).count == 2)
    }

    // MARK: - Distinct across attached DBs (the real use case)

    @Test func distinct_attachedDBs_deduplicatesByGlobalId() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        // Simulate the same item existing in both DBs (same globalId)
        let item = PlainItem(content: "shared item", project: "test")
        try local.add(item)
        let globalId = item.globalId!

        // Insert with same globalId into synced DB
        try synced.add(PlainItem(content: "shared item", project: "test"), preservingGlobalId: globalId)

        // Without distinct, UNION ALL returns both
        let query = try local.attaching(lattice: synced)
        #expect(query.objects(PlainItem.self).count == 2)

        // With distinct by globalId, deduplicates to 1
        let results = query.objects(PlainItem.self)
            .distinct(by: \.globalId)
            .snapshot()
        #expect(results.count == 1)
    }

    @Test func distinct_attachedDBs_count() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        // 2 items in local, 1 overlapping + 1 unique in synced
        let item1 = PlainItem(content: "shared", project: "test")
        try local.add(item1)
        let gid1 = item1.globalId!

        let item2 = PlainItem(content: "local only", project: "test")
        try local.add(item2)

        // Same globalId as item1
        try synced.add(PlainItem(content: "shared", project: "test"), preservingGlobalId: gid1)

        // Unique to synced
        try synced.add(PlainItem(content: "synced only", project: "test"))

        let query = try local.attaching(lattice: synced)

        // Without distinct: 4 (2 local + 2 synced)
        #expect(query.objects(PlainItem.self).count == 4)

        // With distinct: 3 (shared deduped + local only + synced only)
        #expect(query.objects(PlainItem.self).distinct(by: \.globalId).count == 3)
    }

    @Test func distinct_attachedDBs_withWhereClause() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        // Overlapping item
        let shared = PlainItem(content: "shared", project: "alpha")
        try local.add(shared)
        let gid = shared.globalId!

        try synced.add(PlainItem(content: "shared", project: "alpha"), preservingGlobalId: gid)

        // Non-overlapping
        try local.add(PlainItem(content: "local beta", project: "beta"))
        try synced.add(PlainItem(content: "synced beta", project: "beta"))

        let query = try local.attaching(lattice: synced)

        // Filter to alpha + distinct: should be 1
        let alphaResults = query.objects(PlainItem.self)
            .where { $0.project == "alpha" }
            .distinct(by: \.globalId)
            .snapshot()
        #expect(alphaResults.count == 1)

        // Filter to beta + distinct: 2 (different globalIds)
        let betaResults = query.objects(PlainItem.self)
            .where { $0.project == "beta" }
            .distinct(by: \.globalId)
            .snapshot()
        #expect(betaResults.count == 2)
    }

    @Test func distinct_chainingPreserved_throughSortedBy() async throws {
        let lattice = try testLattice(PlainItem.self)

        try lattice.add(PlainItem(content: "a", project: "alpha"))
        try lattice.add(PlainItem(content: "b", project: "alpha"))
        try lattice.add(PlainItem(content: "c", project: "beta"))

        let results = lattice.objects(PlainItem.self)
            .distinct(by: \.project)
            .sortedBy(.init(\.content, order: .forward))
            .snapshot()

        #expect(results.count == 2)
        // Should be sorted by content
        #expect(results.first?.content ?? "" <= results.last?.content ?? "")
    }

    @Test func distinct_noEffect_whenAlreadyUnique() async throws {
        let lattice = try testLattice(PlainItem.self)

        try lattice.add(PlainItem(content: "a", project: "alpha"))
        try lattice.add(PlainItem(content: "b", project: "beta"))
        try lattice.add(PlainItem(content: "c", project: "gamma"))

        // All projects unique — distinct should return same count
        let results = lattice.objects(PlainItem.self)
            .distinct(by: \.project)
            .snapshot()
        #expect(results.count == 3)
    }
}
