import Foundation
import Testing
@testable import Lattice

@Model
private final class PrefixPredicateFactItem {
    var text: String = ""
}

@Suite("Prefix predicate behavior facts")
final class PrefixPredicateFactsTests: BaseTest {
    @Test func hasPrefixUsesUnescapedLikeWildcardsAndASCIICaseFolding() throws {
        let store = try testLattice(PrefixPredicateFactItem.self)
        defer { store.close() }
        let values = ["percent%literal", "percentXliteral", "under_literal",
                      "underXliteral", "Alpha", "alpha", "other"]
        for value in values {
            let item = PrefixPredicateFactItem()
            item.text = value
            try store.add(item)
        }
        let percent = store.objects(PrefixPredicateFactItem.self).where { $0.text.hasPrefix("percent%") }
            .map { $0.text }.sorted()
        let underscore = store.objects(PrefixPredicateFactItem.self).where { $0.text.hasPrefix("under_") }
            .map { $0.text }.sorted()
        let defaultCase = store.objects(PrefixPredicateFactItem.self).where { $0.text.hasPrefix("Al") }
            .map { $0.text }.sorted()
        let insensitiveCase = store.objects(PrefixPredicateFactItem.self).where {
            $0.text.hasPrefix("Al", caseInsensitive: true)
        }.map { $0.text }.sorted()
        // Current SQL LIKE behavior differs from Swift's literal, case-sensitive prefix.
        #expect(percent == ["percent%literal", "percentXliteral"])
        #expect(underscore == ["underXliteral", "under_literal"])
        #expect(defaultCase == ["Alpha", "alpha"])
        #expect(insensitiveCase == defaultCase)
        let swiftPercent = values.filter { $0.hasPrefix("percent%") }
        let swiftUnderscore = values.filter { $0.hasPrefix("under_") }
        let swiftCase = values.filter { $0.hasPrefix("Al") }
        #expect(swiftPercent == ["percent%literal"])
        #expect(swiftUnderscore == ["under_literal"])
        #expect(swiftCase == ["Alpha"])
        print("QUERY_FACT prefix sql_counts=\(percent.count),\(underscore.count),\(defaultCase.count) swift_counts=\(swiftPercent.count),\(swiftUnderscore.count),\(swiftCase.count)")
    }
}
