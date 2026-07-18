import Foundation
import Testing
import Lattice

// MARK: - Fixtures

@Model final class RccPet {
    var name: String = ""
    var age: Int = 0
}

@Model final class RccOwner {
    var name: String = ""
    var visits: Int = 0
    var pet: RccPet? = nil
    var tags: List<RccPet> = List()
}

/// Row-cache v1 CONTRACT pins (see the contract block in RowCache.swift):
/// materialization snapshots exactly ONE row image — scalars are the
/// snapshot; links/lists/unions FALL THROUGH to the live path. These tests
/// gate any future extension of materialization across links (that would be
/// a deliberate behavior change, surfaced by failing pins here).
///
/// Statement-budget assertions use the THREAD-LOCAL counter
/// (`Lattice.threadSQLStatementCount`) — NEVER the process-global total:
/// swift-testing runs suites in parallel in-process and background pacer /
/// sync threads pollute the global counter. (`.serialized` keeps the
/// fixtures' own writes ordered.)
@Suite("Row cache v1 contract (links/lists fall through)", .serialized)
final class RowCacheContractTests: BaseTest {

    private func makeGraph(_ lattice: Lattice) throws {
        let pet = RccPet(); pet.name = "Rex"; pet.age = 3
        try lattice.add(pet)
        let owner = RccOwner(); owner.name = "Alice"; owner.visits = 1
        try lattice.add(owner)
        owner.pet = pet
    }

    // Contract pin 1: a LINK read through a materialized object reflects a
    // concurrent writer — traversal hydrates the target live (fallthrough).
    @Test func linkReadThroughMaterializedObjectIsLive() throws {
        let lattice = try testLattice(RccOwner.self, RccPet.self)
        try makeGraph(lattice)

        let m = try #require(lattice.objects(RccOwner.self).first).materialize()
        #expect(m.pet?.name == "Rex")

        // Concurrent writer (separate handle) mutates the TARGET row.
        let writerPet = try #require(lattice.objects(RccPet.self).first)
        writerPet.name = "Bolt"

        #expect(m.pet?.name == "Bolt",
                "link traversal must fall through to the live path — the target's fields reflect a concurrent writer even while the parent is materialized")

        // Relinking is live too: traversal re-resolves the link column by
        // parent id (bridge get_object), it does not read the snapshot.
        let writerOwner = try #require(lattice.objects(RccOwner.self).first)
        let other = RccPet(); other.name = "Ziggy"; try lattice.add(other)
        writerOwner.pet = other
        #expect(m.pet?.name == "Ziggy",
                "a concurrent RELINK must be visible through a materialized parent (link resolution is live, not snapshotted)")
    }

    // Contract pin 2: a SCALAR read through the same materialized object does
    // NOT see the concurrent writer until refreshMaterialized() (snapshot
    // semantics) — the counterpart that makes pin 1 meaningful.
    @Test func scalarReadThroughMaterializedObjectIsSnapshot() throws {
        let lattice = try testLattice(RccOwner.self, RccPet.self)
        try makeGraph(lattice)

        let m = try #require(lattice.objects(RccOwner.self).first).materialize()
        #expect(m.visits == 1)

        let writer = try #require(lattice.objects(RccOwner.self).first)
        writer.visits = 99

        #expect(m.visits == 1, "scalar reads must serve the row snapshot (stale) under a concurrent writer")
        m.refreshMaterialized()
        #expect(m.visits == 99, "refreshMaterialized() must pick up the concurrent write")
    }

    // Contract pin 3: statement budgets prove WHERE each read is served from,
    // using the thread-local counter. Scalars: zero SQL. Link traversal: SQL
    // every time (live fallthrough is observable in the budget, not just the
    // values).
    @Test func statementBudgetsSeparateSnapshotFromFallthrough() throws {
        let lattice = try testLattice(RccOwner.self, RccPet.self)
        try makeGraph(lattice)

        let m = try #require(lattice.objects(RccOwner.self).first).materialize()
        _ = m.pet?.name  // warm any lazy schema lookups before the budget

        let scalarBase = Lattice.threadSQLStatementCount
        for _ in 0..<5 { _ = m.name; _ = m.visits }
        #expect(Lattice.threadSQLStatementCount - scalarBase == 0,
                "materialized scalar reads must issue zero SQL")

        let linkBase = Lattice.threadSQLStatementCount
        _ = m.pet?.name
        #expect(Lattice.threadSQLStatementCount - linkBase >= 1,
                "link traversal through a materialized object must go to the database (live fallthrough)")
    }

    // Contract pin 4: LIST reads through a materialized object are live —
    // membership added by a concurrent writer is visible without refresh.
    @Test func listReadThroughMaterializedObjectIsLive() throws {
        let lattice = try testLattice(RccOwner.self, RccPet.self)
        try makeGraph(lattice)

        let m = try #require(lattice.objects(RccOwner.self).first).materialize()
        #expect(m.tags.count == 0)

        let writer = try #require(lattice.objects(RccOwner.self).first)
        let extra = RccPet(); extra.name = "New"; try lattice.add(extra)
        writer.tags.append(extra)

        #expect(m.tags.count == 1,
                "list membership must fall through to the live link-list backend while the parent is materialized")
        #expect(m.tags.first?.name == "New")
    }
}
