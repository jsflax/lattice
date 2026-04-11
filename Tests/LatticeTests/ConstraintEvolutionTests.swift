import Testing
import Foundation
import Lattice

// V1: no unique constraint
enum ConstraintV1 {
    @Model final class Item {
        var name: String = ""
        var category: String = ""
    }
}

// V2: @Unique added to name
enum ConstraintV2 {
    @Model final class Item {
        @Unique var name: String = ""
        var category: String = ""
    }
}

class ConstraintEvolutionTests: BaseTest {

    @Test func test_addUniqueConstraint_onSubsequentOpen() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: insert data without unique constraint
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV1.Item.self, configuration: .init(fileURL: dbPath))
            let item1 = ConstraintV1.Item(); item1.name = "alpha"; lattice.add(item1)
            let item2 = ConstraintV1.Item(); item2.name = "beta"; lattice.add(item2)
            #expect(lattice.objects(ConstraintV1.Item.self).count == 2)
            lattice.close()
        }

        // V2: reopen with @Unique on name — constraint should be auto-created
        do {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(ConstraintV2.Item.self).count == 2)

            // New unique name inserts fine
            let item3 = ConstraintV2.Item(); item3.name = "gamma"
            lattice.add(item3)
            #expect(lattice.objects(ConstraintV2.Item.self).count == 3)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_addUniqueConstraint_withExistingDuplicates() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: insert duplicate data
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV1.Item.self, configuration: .init(fileURL: dbPath))
            let item1 = ConstraintV1.Item(); item1.name = "alpha"; item1.category = "a"; lattice.add(item1)
            let item2 = ConstraintV1.Item(); item2.name = "alpha"; item2.category = "b"; lattice.add(item2)
            let item3 = ConstraintV1.Item(); item3.name = "beta"; item3.category = "c"; lattice.add(item3)
            #expect(lattice.objects(ConstraintV1.Item.self).count == 3)
            lattice.close()
        }

        // V2: reopen with @Unique on name — should deduplicate, keeping newest per name
        do {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            let items = lattice.objects(ConstraintV2.Item.self)
            // "alpha" had 2 rows — deduplication keeps the newest (id=2, category="b")
            #expect(items.count == 2)

            let alpha = items.where { $0.name == "alpha" }.first
            #expect(alpha?.category == "b")
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_addUniqueConstraint_deduplicatesManyDuplicates() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: insert lots of duplicates
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV1.Item.self, configuration: .init(fileURL: dbPath))
            for i in 0..<10 {
                let item = ConstraintV1.Item()
                item.name = "dup"
                item.category = "cat-\(i)"
                lattice.add(item)
            }
            #expect(lattice.objects(ConstraintV1.Item.self).count == 10)
            lattice.close()
        }

        // V2: reopen with @Unique — should not crash, should deduplicate to 1
        do {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(ConstraintV2.Item.self).count == 1)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }
}
