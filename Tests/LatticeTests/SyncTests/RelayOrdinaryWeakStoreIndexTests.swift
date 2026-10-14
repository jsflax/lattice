import Foundation
import Testing
import NIOConcurrencyHelpers
@testable import LatticeServerKit

private final class RelayRegistryLifetimeOwner {
    let index: RelayOrdinaryWeakStoreIndex<RelayRegistryLifetimeOwner>
    let retired: NIOLockedValueBox<[Int]>
    let identity: Int
    init(_ identity: Int, index: RelayOrdinaryWeakStoreIndex<RelayRegistryLifetimeOwner>, retired: NIOLockedValueBox<[Int]>) {
        self.identity = identity; self.index = index; self.retired = retired
    }
    deinit {
        // Real deinit re-enters the actual same index/mutex used by production
        // connection retirement. No mock owner or callback claims closure.
        index.remove(self)
        retired.withLockedValue { $0.append(identity) }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayOrdinaryWeakStoreIndexTests {
    @Test func unmatchedLastOwnerSurvivesMatchingVisitUntilOutsideRegistryLock() throws {
        let index = RelayOrdinaryWeakStoreIndex<RelayRegistryLifetimeOwner>(), retired = NIOLockedValueBox<[Int]>([])
        let matched = RelayRegistryLifetimeOwner(1, index: index, retired: retired)
        var unmatched: RelayRegistryLifetimeOwner? = .init(2, index: index, retired: retired)
        weak var weakUnmatched = unmatched
        try index.register(matched, key: "store-a")
        do { let starting = try #require(unmatched); try index.register(starting, key: "store-b") }
        var calls = 0
        index.visit(key: "store-a") { owner in
            calls += 1; #expect(owner === matched)
            unmatched = nil // Drop the last external owner during the real visit.
            #expect(weakUnmatched != nil && retired.withLockedValue { $0 }.isEmpty)
        }
        // The owning snapshot is gone; actual destructor has reentered remove.
        #expect(calls == 1 && weakUnmatched == nil && retired.withLockedValue { $0 } == [2])
        var staleVisits = 0
        index.visit(key: "store-b") { _ in staleVisits += 1 }
        #expect(staleVisits == 0)
        withExtendedLifetime(matched) {}
    }

    @Test func reentrantRemovalKeepsMatchedOwnerThroughActualVisit() throws {
        let index = RelayOrdinaryWeakStoreIndex<RelayRegistryLifetimeOwner>(), retired = NIOLockedValueBox<[Int]>([])
        var owner: RelayRegistryLifetimeOwner? = .init(3, index: index, retired: retired)
        weak var weakOwner = owner
        do { let starting = try #require(owner); try index.register(starting, key: "store") }
        index.visit(key: "store") { live in
            index.remove(live) // Same mutex can be reacquired during the callback.
            owner = nil
            #expect(weakOwner != nil && retired.withLockedValue { $0 }.isEmpty)
        }
        #expect(weakOwner == nil && retired.withLockedValue { $0 } == [3])
    }
}
