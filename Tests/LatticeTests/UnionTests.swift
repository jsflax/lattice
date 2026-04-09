import Testing
import Foundation
import Lattice

// MARK: - Test models

@Model final class TestDogU {
    var name: String = ""
}

@Model final class TestCatU {
    var name: String = ""
}

@Union enum TestFeedItem {
    case dog(TestDogU?)
    case cat(TestCatU?)
    case note(name: String, date: Int)
    case empty
}

@Model final class TestFeed {
    var label: String = ""
    var item: TestFeedItem = .empty
}

// MARK: - Tests

class UnionTests: BaseTest {
    
    @Test func test_bareCase_roundTrip() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed = TestFeed()
        feed.item = .empty
        lattice.add(feed)

        let fetched = lattice.objects(TestFeed.self).first!
        if case .empty = fetched.item {
            // pass
        } else {
            #expect(Bool(false), "Expected .empty, got \(fetched.item)")
        }
    }

    @Test func test_primitiveCase_roundTrip() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed = TestFeed()
        feed.item = .note(name: "hello", date: 42)
        lattice.add(feed)

        let fetched = lattice.objects(TestFeed.self).first!
        if case .note(let name, let date) = fetched.item {
            #expect(name == "hello")
            #expect(date == 42)
        } else {
            #expect(Bool(false), "Expected .note, got \(fetched.item)")
        }
    }

    @Test func test_linkCase_roundTrip() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let dog = TestDogU()
        dog.name = "Rex"
        lattice.add(dog)

        let feed = TestFeed()
        feed.item = .dog(dog)
        lattice.add(feed)

        let fetched = lattice.objects(TestFeed.self).first!
        if case .dog(let fetchedDog) = fetched.item {
            #expect(fetchedDog?.name == "Rex")
        } else {
            #expect(Bool(false), "Expected .dog, got \(fetched.item)")
        }
    }

    @Test func test_switchCase() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)

        let feed = TestFeed()
        feed.item = .note(name: "first", date: 1)
        lattice.add(feed)

        // Switch from .note to .empty
        feed.item = .empty

        let fetched = lattice.objects(TestFeed.self).first!
        if case .empty = fetched.item {
            // pass
        } else {
            #expect(Bool(false), "Expected .empty after switch, got \(fetched.item)")
        }
    }

    @Test func test_switchBetweenCases_erasesOldValues() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)

        let dog = TestDogU()
        dog.name = "Rex"
        lattice.add(dog)

        let feed = TestFeed()
        feed.item = .dog(dog)
        lattice.add(feed)

        // Verify dog case
        if case .dog(let d) = feed.item {
            #expect(d?.name == "Rex")
        } else {
            #expect(Bool(false), "Expected .dog")
        }

        // Switch to .note — the dog column should be NULLed
        feed.item = .note(name: "switched", date: 99)

        let fetched = lattice.objects(TestFeed.self).first!
        if case .note(let name, let date) = fetched.item {
            #expect(name == "switched")
            #expect(date == 99)
        } else {
            #expect(Bool(false), "Expected .note after switch, got \(fetched.item)")
        }

        // Switch back to .dog — the note columns should be NULLed
        let dog2 = TestDogU()
        dog2.name = "Buddy"
        lattice.add(dog2)
        feed.item = .dog(dog2)

        let fetched2 = lattice.objects(TestFeed.self).first!
        if case .dog(let d) = fetched2.item {
            #expect(d?.name == "Buddy")
        } else {
            #expect(Bool(false), "Expected .dog after second switch, got \(fetched2.item)")
        }
    }

    @Test func test_unmanagedRoundTrip() async throws {
        let feed = TestFeed()
        feed.item = .note(name: "test", date: 99)

        if case .note(let name, let date) = feed.item {
            #expect(name == "test")
            #expect(date == 99)
        } else {
            #expect(Bool(false), "Expected .note on unmanaged object")
        }
    }

    @Test func test_unmanagedLinkRoundTrip() async throws {
        let dog = TestDogU()
        dog.name = "Buddy"

        let feed = TestFeed()
        feed.item = .dog(dog)

        if case .dog(let fetchedDog) = feed.item {
            #expect(fetchedDog?.name == "Buddy")
        } else {
            #expect(Bool(false), "Expected .dog on unmanaged object")
        }
    }

    // MARK: - Query tests

    @Test func test_queryNonUnionField() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.label = "alpha"; feed1.item = .empty; lattice.add(feed1)
        let feed2 = TestFeed(); feed2.label = "beta"; feed2.item = .empty; lattice.add(feed2)

        let results = lattice.objects(TestFeed.self).where { $0.label == "alpha" }
        #expect(results.count == 1)
    }

    @Test func test_queryNonUnionFieldOnUnionModel() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.label = "alpha"; feed1.item = .note(name: "x", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.label = "beta"; feed2.item = .note(name: "y", date: 2); lattice.add(feed2)

        let results = lattice.objects(TestFeed.self).where { $0.label == "alpha" }
        #expect(results.count == 1)
    }

    @Test func test_querySwitchSingleCase() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.item = .note(name: "hello", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .note(name: "world", date: 2); lattice.add(feed2)
        let feed3 = TestFeed(); feed3.item = .empty; lattice.add(feed3)

        let results = lattice.objects(TestFeed.self).where { q in
            switch q.item {
            case .note(let name, _): return name == "hello"
            default: return false
            }
        }
        #expect(results.count == 1)
    }

    @Test func test_querySwitchMultipleCases() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let dog = TestDogU(); dog.name = "Rex"; lattice.add(dog)
        let feed1 = TestFeed(); feed1.item = .dog(dog); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .note(name: "hi", date: 1); lattice.add(feed2)
        let feed3 = TestFeed(); feed3.item = .empty; lattice.add(feed3)

        let results = lattice.objects(TestFeed.self).where { q in
            switch q.item {
            case .dog(let dog): return dog != nil
            case .note(let name, _): return name == "hi"
            default: return false
            }
        }
        #expect(results.count == 2)
    }

    @Test func test_queryCaseOnly() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.item = .note(name: "a", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .note(name: "b", date: 2); lattice.add(feed2)
        let feed3 = TestFeed(); feed3.item = .empty; lattice.add(feed3)

        let results = lattice.objects(TestFeed.self).where { q in
            switch q.item {
            case .note: return true
            default: return false
            }
        }
        // Debug: check if query enum works
        let queryEnum = TestFeedItem.TestFeedItem_Query()
        print("queryEnum: \(queryEnum)")
        let variants = TestFeedItem._makeQueryVariants(parentKeyPath: ["item"])
        print("variants count: \(variants.count)")
        for (name, _) in variants {
            print("variant: \(name)")
        }
        #expect(results.count == 2)
    }

    @Test func test_queryNoMatchingCase() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.item = .note(name: "a", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .empty; lattice.add(feed2)

        let results = lattice.objects(TestFeed.self).where { q in
            switch q.item {
            case .dog(let dog): return dog != nil
            default: return false
            }
        }
        #expect(results.count == 0)
    }

    @Test func test_queryIfCaseLet() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.item = .note(name: "hello", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .empty; lattice.add(feed2)

        let results = lattice.objects(TestFeed.self).where { q in
            if case .note(let name, _) = q.item {
                return name == "hello"
            }
            return false
        }
        #expect(results.count == 1)
    }

    @Test func test_queryGuardCaseLet() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let dog = TestDogU(); dog.name = "Rex"; lattice.add(dog)
        let feed1 = TestFeed(); feed1.item = .dog(dog); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .empty; lattice.add(feed2)

        let results = lattice.objects(TestFeed.self).where { q in
            guard case .dog(let dog) = q.item else { return false }
            return dog != nil
        }
        #expect(results.count == 1)
    }

    @Test func test_queryNonUnionPredicateOutsideSwitch() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.label = "a"; feed1.item = .note(name: "hello", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.label = "b"; feed2.item = .note(name: "hello", date: 2); lattice.add(feed2)
        let feed3 = TestFeed(); feed3.label = "a"; feed3.item = .empty; lattice.add(feed3)

        let results = lattice.objects(TestFeed.self).where { q in
            let labelMatch = q.label == "a"
            switch q.item {
            case .note(let name, _): return labelMatch && name == "hello"
            default: return false
            }
        }
        #expect(results.count == 1)
    }

    @Test func test_queryMultipleFieldPredicates() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.item = .note(name: "hello", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.item = .note(name: "hello", date: 99); lattice.add(feed2)
        let feed3 = TestFeed(); feed3.item = .note(name: "other", date: 99); lattice.add(feed3)

        let results = lattice.objects(TestFeed.self).where { q in
            switch q.item {
            case .note(let name, let date): return name == "hello" && date > 50
            default: return false
            }
        }
        #expect(results.count == 1)
    }

    @Test func test_queryChainedWhere() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        let feed1 = TestFeed(); feed1.label = "x"; feed1.item = .note(name: "a", date: 1); lattice.add(feed1)
        let feed2 = TestFeed(); feed2.label = "y"; feed2.item = .note(name: "b", date: 2); lattice.add(feed2)

        let results = lattice.objects(TestFeed.self)
            .where { q in
                switch q.item {
                case .note: return true
                default: return false
                }
            }
            .where { $0.label == "x" }
        #expect(results.count == 1)
    }

    @Test func test_queryUnionCount() async throws {
        let lattice = try testLattice(TestFeed.self, TestDogU.self, TestCatU.self)
        for i in 0..<5 {
            let feed = TestFeed(); feed.item = .note(name: "n\(i)", date: i); lattice.add(feed)
        }
        let feed6 = TestFeed(); feed6.item = .empty; lattice.add(feed6)

        let count = lattice.objects(TestFeed.self).where { q in
            switch q.item {
            case .note: return true
            default: return false
            }
        }.count
        #expect(count == 5)
    }
}

// MARK: - Schema Evolution Models

enum UnionSchemaV1 {
    @Model final class Dog { var name: String = "" }

    @Union enum FeedItem {
        case dog(UnionSchemaV1.Dog?)
        case note(name: String, date: Int)
        case empty
    }

    @Model final class Feed {
        var label: String = ""
        var item: UnionSchemaV1.FeedItem = .empty
    }
}

enum UnionSchemaV2 {
    @Model final class Dog { var name: String = "" }
    @Model final class Cat { var name: String = "" }

    @Union enum FeedItem {
        case dog(UnionSchemaV2.Dog?)
        case cat(UnionSchemaV2.Cat?)
        case note(name: String, date: Int)
        case tagged(label: String, score: Double)
        case empty
    }

    @Model final class Feed {
        var label: String = ""
        var item: UnionSchemaV2.FeedItem = .empty
    }
}

class UnionSchemaEvolutionTests: BaseTest {

    @Test func test_addCaseToUnion_oldDataReadable() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: write data
        do {
            let lattice = try Lattice(
                UnionSchemaV1.Feed.self, UnionSchemaV1.Dog.self,
                configuration: .init(fileURL: dbPath))

            let dog = UnionSchemaV1.Dog(); dog.name = "Rex"
            lattice.add(dog)

            let feed1 = UnionSchemaV1.Feed()
            feed1.item = .dog(dog)
            lattice.add(feed1)

            let feed2 = UnionSchemaV1.Feed()
            feed2.item = .note(name: "hello", date: 42)
            lattice.add(feed2)

            #expect(lattice.objects(UnionSchemaV1.Feed.self).count == 2)
        }

        // V2: reopen same DB with new cases added
        do {
            let lattice = try Lattice(
                UnionSchemaV2.Feed.self, UnionSchemaV2.Dog.self, UnionSchemaV2.Cat.self,
                configuration: .init(fileURL: dbPath))

            let feeds = lattice.objects(UnionSchemaV2.Feed.self)
            #expect(feeds.count == 2)

            // Old V1 data should still read back correctly
            for feed in feeds.snapshot() {
                switch feed.item {
                case .dog(let d):
                    #expect(d?.name == "Rex")
                case .note(let name, let date):
                    #expect(name == "hello")
                    #expect(date == 42)
                default:
                    #expect(Bool(false), "Unexpected case: \(feed.item)")
                }
            }

            // Write data using the new V2 case
            let feed3 = UnionSchemaV2.Feed()
            feed3.item = .tagged(label: "important", score: 9.5)
            lattice.add(feed3)

            #expect(lattice.objects(UnionSchemaV2.Feed.self).count == 3)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_removeCaseFromUnion_unknownCaseFallsBackToDefault() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // Write data with V2 (has cat + tagged cases)
        do {
            let lattice = try Lattice(
                UnionSchemaV2.Feed.self, UnionSchemaV2.Dog.self, UnionSchemaV2.Cat.self,
                configuration: .init(fileURL: dbPath))

            let cat = UnionSchemaV2.Cat(); cat.name = "Whiskers"
            lattice.add(cat)

            let feed1 = UnionSchemaV2.Feed()
            feed1.item = .cat(cat)
            lattice.add(feed1)

            let feed2 = UnionSchemaV2.Feed()
            feed2.item = .note(name: "hello", date: 42)
            lattice.add(feed2)

            let feed3 = UnionSchemaV2.Feed()
            feed3.item = .tagged(label: "important", score: 9.5)
            lattice.add(feed3)

            #expect(lattice.objects(UnionSchemaV2.Feed.self).count == 3)
        }

        // Read with V1 (no cat, no tagged case) — unknown cases should fallback to defaultValue
        do {
            let lattice = try Lattice(
                UnionSchemaV1.Feed.self, UnionSchemaV1.Dog.self,
                configuration: .init(fileURL: dbPath))

            let feeds = lattice.objects(UnionSchemaV1.Feed.self)
            #expect(feeds.count == 3)

            var foundNote = false
            var defaultCount = 0
            for feed in feeds {
                switch feed.item {
                case .note(let name, let date):
                    #expect(name == "hello")
                    #expect(date == 42)
                    foundNote = true
                default:
                    // "cat" and "tagged" are unknown to V1 → fallback to defaultValue
                    defaultCount += 1
                }
            }
            #expect(foundNote)
            #expect(defaultCount == 2)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }
}
