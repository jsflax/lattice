import Foundation
import Testing
@testable import Lattice

@Model
private final class DatePredicateFactItem {
    var key: String = ""
    var createdAt: Date = Date(timeIntervalSince1970: 0)
}

@Suite("Date predicate behavior facts")
final class DatePredicateFactsTests: BaseTest {
    @Test func dateEqualityMatchesStoredFractionalSecondsExactly() throws {
        let store = try testLattice(DatePredicateFactItem.self)
        defer { store.close() }
        let seconds = 1_700_000_000.1234567
        let date = Date(timeIntervalSince1970: seconds)
        let adjacent = Date(timeIntervalSince1970: seconds.nextUp)
        #expect(date != adjacent)
        let item = DatePredicateFactItem()
        item.key = "exact"
        item.createdAt = date
        let neighbor = DatePredicateFactItem()
        neighbor.key = "adjacent"
        neighbor.createdAt = adjacent
        try store.add(item)
        try store.add(neighbor)

        let globalID = try #require(item.globalId)
        let persisted = try #require(store.object(DatePredicateFactItem.self, globalId: globalID))
        #expect(persisted.createdAt == date)
        let matches = store.objects(DatePredicateFactItem.self).where { $0.createdAt == date }
        let keys = matches.map { $0.key }
        #expect(keys == ["exact"])
        let adjacentCount = store.count(DatePredicateFactItem.self, where: { $0.createdAt == adjacent })
        #expect(adjacentCount == 1)
        let predicate = (Query<DatePredicateFactItem>().createdAt == date).predicate
        #expect(predicate.contains(String(date.timeIntervalSince1970)))
        print("QUERY_FACT date_equality exact_matches=\(keys.count) adjacent_matches=\(adjacentCount)")
    }
}
