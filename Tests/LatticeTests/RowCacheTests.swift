import Foundation
import Testing
import Lattice

// MARK: - Fixtures

@Model @Detached
final class RcNote {
    var title: String = ""
    var body: String = ""
    var views: Int = 0
    var rating: Double = 0
    var pinned: Bool = false
    var subtitle: String? = nil
}

/// Statement-budget assertions use the THREAD-LOCAL statement counter: these
/// tests read synchronously on one thread, and swift-testing runs other
/// suites in parallel in-process — the global counter races their SQL.
/// (.serialized keeps the fixtures' own writes ordered.)
@Suite("Row cache (materialized reads)", .serialized)
final class RowCacheTests: BaseTest {

    private func makeNote(_ lattice: Lattice) throws -> RcNote {
        let n = RcNote()
        n.title = "T"; n.body = "B"; n.views = 7; n.rating = 4.5; n.pinned = true
        n.subtitle = "S"
        try lattice.add(n)
        return n
    }

    // 1. Query-fetched + materialized: repeated property reads issue ZERO SQL.
    //    The same reads on a live object issue at least one statement each.
    @Test func materializedReadsAreStatementFree() throws {
        let lattice = try testLattice(RcNote.self)
        _ = try makeNote(lattice)

        let fetched = try #require(lattice.objects(RcNote.self).first)
        fetched.materialize()
        #expect(fetched.isMaterialized)

        let base = Lattice.threadSQLStatementCount
        for _ in 0..<5 {
            #expect(fetched.title == "T")
            #expect(fetched.views == 7)
            #expect(fetched.rating == 4.5)
            #expect(fetched.pinned == true)
            #expect(fetched.subtitle == "S")
        }
        #expect(Lattice.threadSQLStatementCount - base == 0,
                "materialized reads must not issue SQL")

        // Contrast: live object pays per read.
        let live = try #require(lattice.objects(RcNote.self).first)
        let liveBase = Lattice.threadSQLStatementCount
        _ = live.title; _ = live.views; _ = live.rating
        #expect(Lattice.threadSQLStatementCount - liveBase >= 3,
                "expected the live path to issue one statement per read")
    }

    // 2. Write-through: the DB row updates AND the materialized read sees it.
    @Test func writeThroughKeepsReadYourWrites() throws {
        let lattice = try testLattice(RcNote.self)
        _ = try makeNote(lattice)

        let m = try #require(lattice.objects(RcNote.self).first).materialize()
        m.views = 8
        m.title = "T2"

        let base = Lattice.threadSQLStatementCount
        #expect(m.views == 8)
        #expect(m.title == "T2")
        #expect(Lattice.threadSQLStatementCount - base == 0,
                "read-your-writes must be served from the snapshot")

        let verify = try #require(lattice.objects(RcNote.self).first)
        #expect(verify.views == 8, "write-through missed the DB")
        #expect(verify.title == "T2")
    }

    // 3. Snapshot semantics + refresh + dematerialize fallthrough.
    @Test func snapshotIsStaleUntilRefreshed() throws {
        let lattice = try testLattice(RcNote.self)
        _ = try makeNote(lattice)

        let m = try #require(lattice.objects(RcNote.self).first).materialize()
        #expect(m.views == 7)

        // External writer (separate handle).
        let other = try #require(lattice.objects(RcNote.self).first)
        other.views = 99

        #expect(m.views == 7, "materialized object must be a snapshot")
        m.refreshMaterialized()
        #expect(m.views == 99, "refresh must pick up the external write")

        m.dematerialize()
        other.views = 100
        #expect(m.views == 100, "dematerialized object must read live")
    }

    // 4. Optionals: setNull writes through — a stale non-nil after nil-out
    //    would be silent corruption.
    @Test func optionalNilRoundTrip() throws {
        let lattice = try testLattice(RcNote.self)
        _ = try makeNote(lattice)

        let m = try #require(lattice.objects(RcNote.self).first).materialize()
        #expect(m.subtitle == "S")
        m.subtitle = nil
        #expect(m.subtitle == nil, "cache returned stale non-nil after nil-out")
        m.subtitle = "S2"
        #expect(m.subtitle == "S2")
    }

    // 5. detached(): ≤ a handful of statements (was one per field), and keeps
    //    read-time freshness for live objects.
    @Test func detachedIsCheapAndFresh() throws {
        let lattice = try testLattice(RcNote.self)
        _ = try makeNote(lattice)

        let live = try #require(lattice.objects(RcNote.self).first)
        // External write BEFORE detaching: detached() must see it (freshness).
        let other = try #require(lattice.objects(RcNote.self).first)
        other.views = 42

        let base = Lattice.threadSQLStatementCount
        let snap = live.detached()
        let used = Lattice.threadSQLStatementCount - base
        #expect(snap.views == 42, "detached() lost read-time freshness")
        #expect(used <= 3, "detached() issued \(used) statements — expected ~1 (refresh), not one per field")
        #expect(!live.isMaterialized, "detached() must restore live-read mode")

        // Explicitly materialized: detaches from the existing snapshot.
        live.materialize()
        let base2 = Lattice.threadSQLStatementCount
        let snap2 = live.detached()
        #expect(Lattice.threadSQLStatementCount - base2 == 0,
                "materialized detach should be statement-free")
        #expect(snap2.views == 42)
    }

    // 6. increment(): atomic SQL-side bump; materialized reads never go stale.
    @Test func incrementIsAtomicAndCacheCoherent() throws {
        let lattice = try testLattice(RcNote.self)
        _ = try makeNote(lattice)

        let m = try #require(lattice.objects(RcNote.self).first).materialize()
        #expect(m.views == 7)
        m.increment("views")
        #expect(m.views == 8, "cached read went stale after increment")
        m.increment("views", by: 5)
        #expect(m.views == 13)

        let verify = try #require(lattice.objects(RcNote.self).first)
        #expect(verify.views == 13)
    }

    // 7. materializedSnapshot(): every element reads statement-free.
    @Test func materializedSnapshotCoversAllElements() throws {
        let lattice = try testLattice(RcNote.self)
        for i in 0..<10 {
            let n = RcNote(); n.title = "n\(i)"; n.views = i
            try lattice.add(n)
        }
        let all = lattice.objects(RcNote.self).materializedSnapshot()
        #expect(all.count == 10)
        let base = Lattice.threadSQLStatementCount
        for n in all {
            _ = n.title; _ = n.views; _ = n.pinned
        }
        #expect(Lattice.threadSQLStatementCount - base == 0,
                "materializedSnapshot elements must read statement-free")
    }
}

