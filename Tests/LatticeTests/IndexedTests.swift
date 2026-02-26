import Foundation
import Lattice
import Testing

@Model final class IndexedProduct {
    @Indexed var category: String
    @Indexed var price: Double
    var name: String

    init(category: String = "", price: Double = 0, name: String = "") {
        self.category = category
        self.price = price
        self.name = name
    }
}

@Suite("Indexed Tests")
class IndexedTests: BaseTest {

    @Test func test_IndexedPropertiesReported() async throws {
        #expect(IndexedProduct.indexedProperties == ["category", "price"])
    }

    @Test func test_IndexedColumnQuery() async throws {
        let lattice = try testLattice(IndexedProduct.self)

        lattice.add(IndexedProduct(category: "Electronics", price: 999.99, name: "Laptop"))
        lattice.add(IndexedProduct(category: "Electronics", price: 29.99, name: "Cable"))
        lattice.add(IndexedProduct(category: "Books", price: 14.99, name: "Novel"))
        lattice.add(IndexedProduct(category: "Books", price: 39.99, name: "Textbook"))

        // Query on indexed column
        let electronics = lattice.objects(IndexedProduct.self)
            .where { $0.category == "Electronics" }
        #expect(electronics.count == 2)

        let cheap = lattice.objects(IndexedProduct.self)
            .where { $0.price < 30.0 }
        #expect(cheap.count == 2)
    }

    @Test func test_IndexedWithNonIndexedMix() async throws {
        let lattice = try testLattice(IndexedProduct.self)

        lattice.add(IndexedProduct(category: "A", price: 10, name: "Item1"))
        lattice.add(IndexedProduct(category: "B", price: 20, name: "Item2"))

        // Query combining indexed and non-indexed columns
        let result = lattice.objects(IndexedProduct.self)
            .where { $0.category == "A" && $0.name == "Item1" }
        #expect(result.count == 1)
        #expect(result.first?.name == "Item1")
    }

    @Test func test_IndexedColumnSort() async throws {
        let lattice = try testLattice(IndexedProduct.self)

        lattice.add(IndexedProduct(category: "C", price: 30, name: "Third"))
        lattice.add(IndexedProduct(category: "A", price: 10, name: "First"))
        lattice.add(IndexedProduct(category: "B", price: 20, name: "Second"))

        let sorted = lattice.objects(IndexedProduct.self)
            .sortedBy(.init(\.price, order: .forward))
            .snapshot()
        #expect(sorted.count == 3)
        #expect(sorted[0].name == "First")
        #expect(sorted[1].name == "Second")
        #expect(sorted[2].name == "Third")
    }
}
