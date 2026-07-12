import Foundation
import Testing
import Lattice

@Model @Detached
final class DRItem {
    var name: String = ""
    var rank: Int = 0
}

@Suite("DetachedResults")
final class DetachedResultsTests: BaseTest {

    @MainActor
    private func wait(_ timeoutMs: Int = 3000, until cond: @MainActor () -> Bool) async {
        var waited = 0
        while waited < timeoutMs {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
    }

    /// Insert / update / delete each flow through the observe → off-main detach →
    /// main-actor splice path, keeping `items` sorted and current.
    @Test @MainActor func reactiveInsertUpdateDelete() async throws {
        guard #available(macOS 14, iOS 17, *) else { return }
        let lattice = try testLattice(DRItem.self)
        let results = DetachedResults<DRItem>(lattice: lattice, sortedBy: { ($0.rank ?? 0) < ($1.rank ?? 0) })
        #expect(results.items.isEmpty)

        let a = DRItem(); a.name = "a"; a.rank = 1
        try lattice.transaction { try lattice.add(a) }
        await wait { results.items.count == 1 }
        #expect(results.items.first?.value?.name == "a")

        // Inserted out of order → must land sorted (order 0 before order 1).
        let b = DRItem(); b.name = "b"; b.rank = 0
        try lattice.transaction { try lattice.add(b) }
        await wait { results.items.count == 2 }
        #expect(results.items.compactMap { $0.value?.name } == ["b", "a"])

        // Update → the changed row's snapshot refreshes in place.
        lattice.transaction { a.name = "a2" }
        await wait { results.items.compactMap { $0.value?.name } == ["b", "a2"] }
        #expect(results.items.compactMap { $0.value?.name } == ["b", "a2"])

        // Delete → drops out, indices stay consistent.
        lattice.transaction { lattice.delete(b) }
        await wait { results.items.count == 1 }
        #expect(results.items.first?.value?.name == "a2")

        results.stop()
    }

    /// Detaching the SAME persisted row twice must yield value-identical
    /// snapshots — a render-model's Equatable per-row skip depends on this.
    /// (Probes whether the `defaultDepthIsFive` nondeterminism reaches
    /// persisted rows.)
    ///
    /// Byte-level comparison requires `.sortedKeys`: JSONEncoder serializes
    /// keyed containers in hash order, which varies PER ENCODER INSTANCE —
    /// two back-to-back encodes of equal values legitimately differ in key
    /// order (caught live under the parallel suite: identical values,
    /// shuffled keys). Consumers memoizing on encoded bytes must sort keys;
    /// consumers diffing rows should compare `Detached` values directly.
    @Test func detachOfPersistedRowIsStable() throws {
        let lattice = try testLattice(DRItem.self)
        let a = DRItem(); a.name = "x"; a.rank = 3
        try lattice.transaction { try lattice.add(a) }
        // The actual contract: value-identical snapshots.
        #expect(a.detached() == a.detached())
        // Byte stability under deterministic key ordering.
        let enc1 = JSONEncoder(); enc1.outputFormatting = .sortedKeys
        let enc2 = JSONEncoder(); enc2.outputFormatting = .sortedKeys
        let d1 = try enc1.encode(a.detached())
        let d2 = try enc2.encode(a.detached())
        #expect(d1 == d2)
    }
}
