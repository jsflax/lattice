import Foundation
import Testing
@testable import Lattice

protocol Animal: VirtualModel {
    var name: String { get set }
}

@Model final class TestDog: Animal {
    var name: String = ""
    var breed: String = ""
}

@Model final class TestCat: Animal {
    var name: String = ""
    var indoor: Bool = true
}

@Model final class TestPersonWithPets {
    var label: String = ""
    var pets: VirtualList<any Animal> = .init()
}

class VirtualListTests: BaseTest {
    @Test func testAppendAndRead() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        person.label = "Alice"
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        cat.indoor = true
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)

        #expect(person.pets.count == 2)
        #expect(person.pets[0].name == "Rex")
        #expect(person.pets[1].name == "Whiskers")
        #expect((person.pets[0] as? TestDog)?.breed == "Lab")
        #expect((person.pets[1] as? TestCat)?.indoor == true)
    }

    @Test func testPersistence() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        person.label = "Bob"
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Buddy"
        dog.breed = "Golden"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Mittens"
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)

        // Fetch from DB
        let fetched = lattice.objects(TestPersonWithPets.self).where { $0.label == "Bob" }.first!
        #expect(fetched.pets.count == 2)
        #expect(fetched.pets[0].name == "Buddy")
        #expect(fetched.pets[1].name == "Mittens")
    }

    @Test func testRemove() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)
        #expect(person.pets.count == 2)

        person.pets.removeAll()
        #expect(person.pets.count == 0)
    }

    /// Deleting a child object from the lattice should cascade to virtual link tables.
    /// Without cascading cleanup, size() queries the link table (stale count)
    /// while cached_objects_ skips the deleted object → out-of-bounds crash.
    @Test func testDeleteChildFromLattice() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        person.label = "Alice"
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        cat.indoor = true
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)
        #expect(person.pets.count == 2)

        // Delete the dog from the lattice entirely
        lattice.delete(dog)

        // Fetch fresh to avoid any stale cache
        let fetched = lattice.objects(TestPersonWithPets.self).first!
        #expect(fetched.pets.count == 1, "Virtual list should reflect child deletion")
        #expect(fetched.pets[0].name == "Whiskers", "Remaining pet should be the cat")
    }

    @Test func testDeleteAllChildrenFromLattice() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)
        #expect(person.pets.count == 2)

        lattice.delete(dog)
        lattice.delete(cat)

        let fetched = lattice.objects(TestPersonWithPets.self).first!
        #expect(fetched.pets.count == 0, "Virtual list should be empty after deleting all children")
    }

    /// `delete(where:)` should also cascade — removing link table entries for deleted objects.
    @Test func testDeleteWhereChildCascades() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        person.label = "Alice"
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        cat.indoor = true
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)
        #expect(person.pets.count == 2)

        // Use delete(where:) instead of delete(object) — should also cascade
        lattice.delete(TestDog.self, where: { $0.name == "Rex" })

        let fetched = lattice.objects(TestPersonWithPets.self).first!
        #expect(fetched.pets.count == 1, "delete(where:) should cascade link table cleanup")
        #expect(fetched.pets[0].name == "Whiskers", "Remaining pet should be the cat")
    }

    @Test func testDeleteWhereAllChildrenCascades() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        try lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        try lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        try lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)
        #expect(person.pets.count == 2)

        // Bulk delete all dogs and cats via delete(where:)
        lattice.delete(TestDog.self)
        lattice.delete(TestCat.self)

        let fetched = lattice.objects(TestPersonWithPets.self).first!
        #expect(fetched.pets.count == 0, "delete(where:) should cascade — virtual list empty after bulk delete")
    }
}
