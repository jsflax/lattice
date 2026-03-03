import Foundation
import Testing
#if canImport(SwiftUI)
import SwiftUI
#endif
import Lattice
import Observation

@Suite("Results Tests")
class ResultsTests: BaseTest {
    @Test func testQuery_In() async throws {
        let lattice = try testLattice(Person.self, Dog.self)
        let person = Person()
        person.age = 10
        lattice.add(person)
        #expect(lattice.objects(Person.self).where {
            $0.age.in([5, 10, 15])
        }.count == 1)
        #expect(lattice.objects(Person.self).where {
            $0.age.in([5, 15, 20])
        }.count == 0)
        
        let globalId = person.__globalId
        #expect(lattice.objects(Person.self).where {
            $0.__globalId.in([UUID(), UUID(), globalId])
        }.count == 1)
    }
    
    #if TEST_CURSOR
    @Test func testCursor() async throws {
        let lattice = try testLattice(SequenceSyncObject.self)
        let objects = (0..<100_000).map { _ in SequenceSyncObject() }
        lattice.transaction {
            lattice.add(contentsOf: objects)
        }

        let results = lattice.objects(SequenceSyncObject.self)

        // Test 1: Slice iteration (batched - 1 query for the range)
        var duration = Test.Clock().measure {
            for result in results[0..<1000] {
                _ = result.open
            }
        }
        print("Slice iteration (1000 items): \(duration)")

        // Test 2: Cursor iteration (batched - queries of 100)
        let cursor = Cursor<SequenceSyncObject>(results)
        duration = Test.Clock().measure {
            var idx = 0
            while idx < 1000, let result = cursor.next()  {
                _ = result.open
                idx += 1
            }
        }
        print("Cursor iteration (1000 items): \(duration)")

        // Test 3: Full results iteration via for-in (uses Cursor)
        duration = Test.Clock().measure {
            var count = 0
            for result in results {
                _ = result.open
                count += 1
                if count >= 1000 { break }
            }
        }
        print("For-in iteration (1000 items): \(duration)")
    }
    #endif
    
    @Test func test_WriteWhileIterating() async throws {
        let lattice = try testLattice(SequenceSyncObject.self)
        let config = lattice.configuration
        let objects = (0..<1000).map { _ in SequenceSyncObject() }
        lattice.transaction {
            lattice.add(contentsOf: objects)
        }

        func doWork(isolation: isolated (any Actor)? = #isolation) throws {
            let lattice = try Lattice(for: [SequenceSyncObject.self], configuration: config)
            let results = lattice.objects(SequenceSyncObject.self)
            lattice.transaction {
                for object in results {
                    object.low = 5000
                }
            }
        }

        let task1 = Task { @TestActor in
            try doWork()
        }
        let task2 = Task { @TestActor in
            try doWork()
        }
        let results = lattice.objects(SequenceSyncObject.self)
        for object in results {
            lattice.transaction {
                object.high = 5000
            }
        }

        // Wait for concurrent tasks to complete
        try await task1.value
        try await task2.value
    }
    
    @Test
    func test_ResultsSendableReference() async throws {
        let lattice = try testLattice(Person.self, Dog.self)
        let person = Person()
        person.age = 10
        lattice.add(person)
        
        let person2 = Person()
        person2.age = 20
        lattice.add(person2)
        
        let results = lattice.objects(Person.self).where {
            $0.age.in([5, 10, 15])
        }
        #expect(results.count == 1)
        let ref = results.sendableReference
        let configuration = lattice.configuration
        try await Task { [ref] in
            let results = try ref.resolve(on: Lattice(Person.self, Dog.self, configuration: configuration))
            #expect(results?.count == 1)
        }.value
        
        #expect(lattice.objects(Person.self).count == 2)
    }
}

// MARK: - Subquery IN models

@Model class SQItem {
    var name: String
    var category: String
    var isPublic: Bool

    init(name: String = "", category: String = "", isPublic: Bool = true) {
        self.name = name
        self.category = category
        self.isPublic = isPublic
    }
}

@Model class SQLink {
    var sourceGlobalId: UUID
    var targetGlobalId: UUID
    var label: String

    init(sourceGlobalId: UUID = UUID(), targetGlobalId: UUID = UUID(), label: String = "") {
        self.sourceGlobalId = sourceGlobalId
        self.targetGlobalId = targetGlobalId
        self.label = label
    }
}

@Suite("Subquery IN Tests")
class SubqueryInTests: BaseTest {
    @Test func testIn_subqueryWithWhere() async throws {
        let lattice = try testLattice(SQItem.self, SQLink.self)

        // Create items in two categories
        let alphaItems = (0..<3).map { SQItem(name: "a\($0)", category: "alpha", isPublic: true) }
        let betaItems  = (0..<2).map { SQItem(name: "b\($0)", category: "beta",  isPublic: true) }
        let privateItem = SQItem(name: "secret", category: "alpha", isPublic: false)
        lattice.add(contentsOf: alphaItems + betaItems + [privateItem])

        // Create links: alpha↔alpha, alpha↔beta, beta↔beta
        let alphaAlpha = SQLink(sourceGlobalId: alphaItems[0].__globalId!,
                                targetGlobalId: alphaItems[1].__globalId!, label: "aa")
        let alphaBeta  = SQLink(sourceGlobalId: alphaItems[2].__globalId!,
                                targetGlobalId: betaItems[0].__globalId!,  label: "ab")
        let betaBeta   = SQLink(sourceGlobalId: betaItems[0].__globalId!,
                                targetGlobalId: betaItems[1].__globalId!,  label: "bb")
        // Link involving the private item
        let alphaPrivate = SQLink(sourceGlobalId: alphaItems[0].__globalId!,
                                  targetGlobalId: privateItem.__globalId!,  label: "ap")
        lattice.add(contentsOf: [alphaAlpha, alphaBeta, betaBeta, alphaPrivate])

        // Query: links where BOTH endpoints are public alpha items
        let alphaPredicate: @Sendable (Query<SQItem>) -> Query<Bool> = { item in
            item.category == "alpha" && item.isPublic == true
        }
        let alphaLinks = lattice.objects(SQLink.self).where { link in
            link.sourceGlobalId.in(\SQItem.__globalId, where: alphaPredicate)
                && link.targetGlobalId.in(\SQItem.__globalId, where: alphaPredicate)
        }

        // Only alphaAlpha qualifies (both endpoints are public alpha)
        #expect(alphaLinks.count == 1)
        #expect(alphaLinks.first?.label == "aa")

        // Query: links where source is any public item (alpha or beta)
        let anyPublicLinks = lattice.objects(SQLink.self).where { link in
            link.sourceGlobalId.in(\SQItem.__globalId, where: { $0.isPublic == true })
        }
        // alphaAlpha (source=a0 public), alphaBeta (source=a2 public),
        // betaBeta (source=b0 public), alphaPrivate (source=a0 public) → 4
        #expect(anyPublicLinks.count == 4)

        // Query: links where target is a beta item
        let targetBetaLinks = lattice.objects(SQLink.self).where { link in
            link.targetGlobalId.in(\SQItem.__globalId, where: { $0.category == "beta" })
        }
        // alphaBeta (target=b0), betaBeta (target=b1) → 2
        #expect(targetBetaLinks.count == 2)
    }

    @Test func testIn_subqueryEmptyResult() async throws {
        let lattice = try testLattice(SQItem.self, SQLink.self)

        let item = SQItem(name: "only", category: "gamma", isPublic: true)
        lattice.add(item)
        let link = SQLink(sourceGlobalId: item.__globalId!, targetGlobalId: item.__globalId!, label: "self")
        lattice.add(link)

        // No items match category "nonexistent" → subquery returns empty → no links match
        let results = lattice.objects(SQLink.self).where { link in
            link.sourceGlobalId.in(\SQItem.__globalId, where: { $0.category == "nonexistent" })
        }
        #expect(results.count == 0)
    }

    @Test func testIn_subqueryMultipleCategories() async throws {
        let lattice = try testLattice(SQItem.self, SQLink.self)

        // Create items across 3 categories
        let cats = SQItem(name: "c0", category: "cats", isPublic: true)
        let dogs = SQItem(name: "d0", category: "dogs", isPublic: true)
        let fish = SQItem(name: "f0", category: "fish", isPublic: true)
        lattice.add(contentsOf: [cats, dogs, fish])

        let cdLink = SQLink(sourceGlobalId: cats.__globalId!, targetGlobalId: dogs.__globalId!, label: "cd")
        let cfLink = SQLink(sourceGlobalId: cats.__globalId!, targetGlobalId: fish.__globalId!, label: "cf")
        let dfLink = SQLink(sourceGlobalId: dogs.__globalId!, targetGlobalId: fish.__globalId!, label: "df")
        lattice.add(contentsOf: [cdLink, cfLink, dfLink])

        // Combined predicate: source in (cats OR dogs), target in (cats OR dogs)
        let petPredicate: @Sendable (Query<SQItem>) -> Query<Bool> = { item in
            item.category == "cats" || item.category == "dogs"
        }
        let petLinks = lattice.objects(SQLink.self).where { link in
            link.sourceGlobalId.in(\SQItem.__globalId, where: petPredicate)
                && link.targetGlobalId.in(\SQItem.__globalId, where: petPredicate)
        }
        // Only cd qualifies (both endpoints are cats/dogs)
        #expect(petLinks.count == 1)
        #expect(petLinks.first?.label == "cd")
    }
}

@globalActor struct TestActor {
    actor ActorType {}
    static let shared = ActorType()
}
