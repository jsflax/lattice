import Testing
import Foundation
@testable import Lattice

// MARK: - Item A Commit 7 — identity stability + instance reuse (T7)
//
// §1.6: `Model.id` resolves to `AnyHashable(primaryKey)` for managed objects
// and `==` compares primaryKeys, so SwiftUI diffing keys rows by DATABASE
// identity across generations. Two obligations, both pinned here:
//
//  1. PIN IT: `Model.id == primaryKey` semantics, and a `ForEach`-diff
//     simulation across an epoch bump produces no delete+insert pair for
//     surviving rows (id-level stability).
//  2. PREFER INSTANCE REUSE: page refills consult `ModelInstanceRegistry`
//     (`lookup(databasePath:tableName:primaryKey:)`) and reuse the live
//     registered instance — a re-hydrated row is the SAME object identity
//     when one is live (instance-level stability; the object-path
//     observation keeps its fields fresh). A dead weak ref hydrates fresh,
//     as before. Observer-registration churn under fling-scroll is bounded
//     (A1 risk 3), pinned via LatticePerf counters + the registry's
//     per-key live-instance count.

@Model final class Gen7Item {
    var name: String
    var rank: Int
}

@Suite("Live Results Identity Tests (item A Commit 7)", .serialized)
class LiveResultsIdentityTests: BaseTest {

    private func seed(_ lattice: Lattice, count: Int) throws {
        try lattice.add(contentsOf: (0..<count).map { i -> Gen7Item in
            let item = Gen7Item()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })
    }

    // MARK: T7 — Model.id == primaryKey (pinned)

    @Test func t7_modelID_equalsPrimaryKey_pinned() throws {
        let lattice = try testLattice(Gen7Item.self)
        try seed(lattice, count: 3)

        let results = lattice.objects(Gen7Item.self)
        let row = try #require(results.element(at: 0))
        let primaryKey = try #require(row.primaryKey)

        // Managed: `id` IS the primary key (AnyHashable(primaryKey)) — the
        // SwiftUI diff identity that survives epoch bumps and re-hydration.
        let idValue = try #require((row.id as Any) as? AnyHashable)
        #expect(idValue == AnyHashable(primaryKey))

        // Equality keys on primaryKey: a second hydration of the same row
        // (bypassing the reuse path via the direct pk fetch) compares equal.
        let second = try #require(lattice.object(Gen7Item.self, primaryKey: primaryKey))
        #expect(second == row)

        // Unmanaged (no primaryKey yet): identity-keyed fallback.
        let unmanaged = Gen7Item()
        let unmanagedID = try #require((unmanaged.id as Any) as? AnyHashable)
        #expect(unmanagedID == AnyHashable(ObjectIdentifier(unmanaged)))
    }

    // MARK: T7 — ForEach-diff simulation across an epoch bump (file DB)

    @Test func t7_forEachDiff_noDeleteInsertForSurvivors_fileDB() throws {
        let lattice = try testLattice(Gen7Item.self)
        try seed(lattice, count: 30)

        let results = lattice.objects(Gen7Item.self).sortedBy(\.rank, order: .forward)
        #expect(results.count == 30)
        // Realize and HOLD the rows, as a rendered List does: live weak refs
        // in the instance registry are the reuse precondition.
        let held: [Gen7Item] = (0..<30).compactMap { results.element(at: $0) }
        try #require(held.count == 30)
        let idsBefore = held.map { AnyHashable($0.id) }
        let identitiesBefore = held.map(ObjectIdentifier.init)

        // Epoch bump that keeps every held row a survivor: append a tail row.
        let extra = Gen7Item()
        extra.name = "tail"
        extra.rank = 100
        try lattice.add(extra)

        #expect(results.count == 31)
        let refilled: [Gen7Item] = (0..<31).compactMap { results.element(at: $0) }
        try #require(refilled.count == 31)
        let idsAfter = refilled.map { AnyHashable($0.id) }

        // ForEach-diff simulation: SwiftUI diffs by `id`. Across the bump
        // the difference must be EXACTLY the insertion — a delete+insert
        // pair for a surviving row is the animation-breaking failure mode.
        let diff = idsAfter.difference(from: idsBefore)
        #expect(diff.removals.isEmpty,
                "surviving rows produced deletions across the epoch bump: \(diff.removals)")
        #expect(diff.insertions.count == 1,
                "expected exactly the appended row as an insertion, got \(diff.insertions.count)")

        // Instance-level stability (§1.6 obligation 2): the refill reused
        // the live instances — identical ObjectIdentifiers, not just ids.
        let identitiesAfter = Set(refilled.map(ObjectIdentifier.init))
        for (index, identity) in identitiesBefore.enumerated() {
            #expect(identitiesAfter.contains(identity),
                    "row \(index) was re-hydrated as a NEW instance across the epoch bump")
        }
    }

    // MARK: T7 — same contract on the memory family (materialized-id path)

    @Test func t7_forEachDiff_noDeleteInsertForSurvivors_memoryFamily() throws {
        let lattice = try Lattice(Gen7Item.self, configuration: .init(storage: .memory()))
        try seed(lattice, count: 30)

        let results = lattice.objects(Gen7Item.self).sortedBy(\.rank, order: .forward)
        #expect(results.count == 30)
        let held: [Gen7Item] = (0..<30).compactMap { results.element(at: $0) }
        try #require(held.count == 30)
        let idsBefore = held.map { AnyHashable($0.id) }
        let identitiesBefore = held.map(ObjectIdentifier.init)

        let extra = Gen7Item()
        extra.name = "tail"
        extra.rank = 100
        try lattice.add(extra)

        #expect(results.count == 31)
        let refilled: [Gen7Item] = (0..<31).compactMap { results.element(at: $0) }
        try #require(refilled.count == 31)

        let diff = refilled.map { AnyHashable($0.id) }.difference(from: idsBefore)
        #expect(diff.removals.isEmpty)
        #expect(diff.insertions.count == 1)

        let identitiesAfter = Set(refilled.map(ObjectIdentifier.init))
        for (index, identity) in identitiesBefore.enumerated() {
            #expect(identitiesAfter.contains(identity),
                    "memory-family row \(index) was re-hydrated as a NEW instance (id-vector hydration must reuse)")
        }
    }

    // MARK: T7 — reused instance identity where the weak ref is live

    @Test func t7_reuse_liveWeakRefIsSameObject_deadRefHydratesFresh() throws {
        let lattice = try testLattice(Gen7Item.self)
        try seed(lattice, count: 5)

        let results = lattice.objects(Gen7Item.self)
        let row = try #require(results.element(at: 2))
        let primaryKey = try #require(row.primaryKey)
        let identity = ObjectIdentifier(row)

        // Registry lookup resolves the live instance.
        let found = ModelInstanceRegistry.shared.lookup(databasePath: lattice.backend.path,
                                                        tableName: Gen7Item.entityName,
                                                        primaryKey: primaryKey,
                                                        backendIdentity: lattice.backend.identityHash)
        #expect(found.map(ObjectIdentifier.init) == identity)

        // A page refill across a forced epoch bump serves the SAME object.
        results.refresh()
        #expect(results.element(at: 2).map(ObjectIdentifier.init) == identity,
                "refill must reuse the live registered instance")
        // The reused instance's fields stay fresh via the object path.
        #expect(results.element(at: 2)?.rank == 2)

        // Dead weak ref (§1.6: best-effort): on a store with NO page caches
        // holding hydrations alive, dropping the only strong ref must make
        // the lookup miss — and the next hydration builds a fresh instance.
        let isolated = try testLattice(Gen7Item.self)
        try seed(isolated, count: 1)
        var solo: Gen7Item? = isolated.objects(Gen7Item.self).snapshot().first
        let soloPK = try #require(solo?.primaryKey)
        #expect(ModelInstanceRegistry.shared.lookup(databasePath: isolated.backend.path,
                                                    tableName: Gen7Item.entityName,
                                                    primaryKey: soloPK,
                                                    backendIdentity: isolated.backend.identityHash) != nil)
        solo = nil   // last strong ref → deinit → deregister
        #expect(ModelInstanceRegistry.shared.lookup(databasePath: isolated.backend.path,
                                                    tableName: Gen7Item.entityName,
                                                    primaryKey: soloPK,
                                                    backendIdentity: isolated.backend.identityHash) == nil,
                "a dead weak ref must not resolve")
        // Fresh hydration still serves the row (as before Commit 7).
        #expect(isolated.objects(Gen7Item.self).element(at: 0)?.primaryKey == soloPK)
    }

    // MARK: T7 — reuse is scoped to the facade's own core handle

    /// A managed instance's property writes route through ITS OWN handle's
    /// connection. Reuse must therefore never adopt an instance hydrated by
    /// a DIFFERENT Lattice handle on the same file: doing so would send this
    /// facade's writes through the other handle's connection, interleaving
    /// with that handle's transactions (an overlapping BEGIN throws — the
    /// `test_WriteWhileIterating` crash class). Cross-handle rows hydrate
    /// fresh; same-handle refills still reuse.
    @Test func t7_reuse_scopedToSameHandle_crossHandleHydratesFresh() throws {
        let lattice = try testLattice(Gen7Item.self)
        try seed(lattice, count: 5)

        // Hold a live instance on handle A.
        let resultsA = lattice.objects(Gen7Item.self)
        let rowA = try #require(resultsA.element(at: 2))
        let primaryKey = try #require(rowA.primaryKey)

        // A second handle to the SAME file (fresh core handle, same path).
        let latticeB = try Lattice(for: [Gen7Item.self], configuration: lattice.configuration)
        guard latticeB.backend.identityHash != lattice.backend.identityHash else {
            // Same core handle resurrected from the cache — reuse across the
            // two Swift facades IS same-connection and safe; nothing to pin.
            return
        }

        // The registry has A's instance under this (path, table, pk) — but a
        // lookup scoped to B's handle must NOT return it…
        #expect(ModelInstanceRegistry.shared.lookup(databasePath: latticeB.backend.path,
                                                    tableName: Gen7Item.entityName,
                                                    primaryKey: primaryKey,
                                                    backendIdentity: latticeB.backend.identityHash)
                    .map(ObjectIdentifier.init) != ObjectIdentifier(rowA))
        // …and B's fill hydrates a FRESH instance for the same row.
        let rowB = try #require(latticeB.objects(Gen7Item.self).element(at: 2))
        #expect(rowB.primaryKey == primaryKey)
        #expect(ObjectIdentifier(rowB) != ObjectIdentifier(rowA),
                "cross-handle reuse would route this facade's writes through the other handle's connection")
        // Database identity is still shared — SwiftUI diffing stays stable.
        #expect(rowB == rowA)
    }

    // MARK: T7 — observer-registration churn budget under fling-scroll

    @Test func t7_flingScroll_registrationChurnBounded() throws {
        let lattice = try testLattice(Gen7Item.self)
        let rows = 300
        try seed(lattice, count: rows)

        let results = lattice.objects(Gen7Item.self)
        #expect(results.count == rows)
        // The rendered window: realize every row once and HOLD the instances
        // (a List keeps its visible + cached rows alive across refills).
        let held: [Gen7Item] = (0..<rows).compactMap { results.element(at: $0) }
        try #require(held.count == rows)

        #if DEBUG && !ORBITAL_PERF
        // Thread-scoped LatticePerf counters: this test body is synchronous
        // (one thread), so every registration/deregistration it causes —
        // and ONLY those — lands in the thread twin. Process-global
        // counters would be polluted by parallel suites hydrating models.
        // (The twin only exists in DEBUG-without-ORBITAL_PERF builds — the
        // profiling build keeps its single-lock hot path.)
        let before = LatticePerf.threadCounters()
        #endif

        // Fling-scroll under a write burst: each iteration lands a commit
        // (epoch bump — every page cache for the shape drops) and then
        // re-scrolls the whole window, refilling every page.
        let flings = 8
        for f in 0..<flings {
            let writer = Gen7Item()
            writer.name = "burst_\(f)"
            writer.rank = 1000 + f
            try lattice.add(writer)
            for i in 0..<rows {
                _ = results.element(at: i)
            }
        }

        #if DEBUG && !ORBITAL_PERF
        let after = LatticePerf.threadCounters()
        let registrations = after.registrations - before.registrations
        let deregistrations = after.deregistrations - before.deregistrations

        // Naive (pre-Commit-7) churn: every refill re-hydrates + registers
        // every row — flings × rows registrations, then the same again in
        // deregistrations as rotated pages die. With reuse the attributable
        // churn is O(flings): the burst writers themselves (registered on
        // add, deregistered when each loop iteration drops them).
        let naive = flings * rows
        #expect(registrations < naive / 4,
                "registration churn under fling-scroll: \(registrations) (naive would be ≥ \(naive))")
        #expect(deregistrations < naive / 4,
                "deregistration churn under fling-scroll: \(deregistrations) (naive would be ≥ \(naive))")
        #endif

        // Scoped, parallel-proof churn pin: a held row re-filled `flings`
        // times is still ONE live registered instance — duplicates do not
        // accumulate per (path, table, pk).
        for sample in [0, rows / 2, rows - 1] {
            let primaryKey = try #require(held[sample].primaryKey)
            let live = ModelInstanceRegistry.shared._liveInstanceCount(
                databasePath: lattice.backend.path,
                tableName: Gen7Item.entityName,
                primaryKey: primaryKey)
            #expect(live == 1,
                    "row \(sample): \(live) live instances registered — refills must reuse, not duplicate")
        }
    }
}
