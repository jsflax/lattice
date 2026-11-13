import Foundation
import Testing
@testable import Lattice

@Model
private final class SubqueryFactItem {
    var key: String = ""
}

@Model
private final class SubqueryFactMembership {
    var key: String = ""
    var enabled: Bool = false
}

@Suite("Subquery predicate behavior facts")
final class SubqueryPredicateFactsTests: BaseTest {
    @Test func subqueriesSeeTransactionWritesButOtherTableInsertLeavesCachedCounts() throws {
        let store = try testLattice(SubqueryFactItem.self, SubqueryFactMembership.self)
        defer { store.close() }
        for key in ["a", "b", "c"] {
            let item = SubqueryFactItem()
            item.key = key
            try store.add(item)
        }
        let first = SubqueryFactMembership()
        first.key = "a"
        first.enabled = true
        try store.add(first)
        let excluded = store.objects(SubqueryFactItem.self).where {
            $0.key.notIn(\SubqueryFactMembership.key)
        }
        let included = store.objects(SubqueryFactItem.self).where {
            $0.key.in(\SubqueryFactMembership.key, where: { $0.enabled == true })
        }
        #expect(excluded.count == 2)
        #expect(included.count == 1)

        try store.withTransaction {
            let second = SubqueryFactMembership()
            second.key = "b"
            try store.add(second)
            #expect(excluded.count == 1)
            #expect(included.count == 1)
            second.enabled = true
            #expect(included.count == 2)
        }
        // Commit invalidates all shapes. Warm both counts before a write
        // that names only the subquery table, rather than another transaction.
        #expect(excluded.count == 1)
        #expect(included.count == 2)
        let third = SubqueryFactMembership()
        third.key = "c"
        third.enabled = true
        try store.add(third)
        let liveExcluded = store.count(SubqueryFactItem.self, where: {
            $0.key.notIn(\SubqueryFactMembership.key)
        })
        let liveIncluded = store.count(SubqueryFactItem.self, where: {
            $0.key.in(\SubqueryFactMembership.key, where: { $0.enabled == true })
        })
        let cachedExcluded = excluded.count
        let cachedIncluded = included.count
        #expect(liveExcluded == 0)
        #expect(liveIncluded == 3)
        // Current behavior: outer-table cache floors omit subquery dependencies.
        // These assertions document the discrepancy, not the desired contract.
        #expect(cachedExcluded == 1)
        #expect(cachedIncluded == 2)
        excluded.refresh()
        #expect(excluded.count == 0)
        #expect(included.count == 3)
        print("QUERY_FACT subquery_counts cached=\(cachedExcluded),\(cachedIncluded) live=\(liveExcluded),\(liveIncluded)")
    }
}
