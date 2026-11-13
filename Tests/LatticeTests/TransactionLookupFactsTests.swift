import Foundation
import Testing
@testable import Lattice

@Model
private final class TransactionLookupFactItem {
    var text: String = ""
}

@Suite("Transaction lookup behavior facts")
final class TransactionLookupFactsTests: BaseTest {
    // A file store is essential: an in-memory store has no separate reader.
    @Test func globalIDLookupSeesEarlierWritesInCheckedTransaction() throws {
        let store = try testLattice(TransactionLookupFactItem.self)
        defer { store.close() }
        let globalID = UUID()
        #expect(store.object(TransactionLookupFactItem.self, globalId: globalID) == nil)

        try store.withTransaction {
            let item = TransactionLookupFactItem()
            item.text = "inserted"
            try store.add(item, preservingGlobalId: globalID)
            let inserted = try #require(store.object(TransactionLookupFactItem.self, globalId: globalID))
            #expect(inserted.text == "inserted")

            item.text = "updated"
            let updated = try #require(store.object(TransactionLookupFactItem.self, globalId: globalID))
            #expect(updated.text == "updated")
        }
        #expect(store.object(TransactionLookupFactItem.self, globalId: globalID)?.text == "updated")
        print("QUERY_FACT global_id_transaction insert_visible=true update_visible=true")
    }
}
