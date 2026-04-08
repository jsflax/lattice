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
}
