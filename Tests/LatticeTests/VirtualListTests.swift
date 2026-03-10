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
        lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        cat.indoor = true
        lattice.add(cat)

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
        lattice.add(person)

        let dog = TestDog()
        dog.name = "Buddy"
        dog.breed = "Golden"
        lattice.add(dog)

        let cat = TestCat()
        cat.name = "Mittens"
        lattice.add(cat)

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
        lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        lattice.add(cat)

        person.pets.append(dog as any Animal)
        person.pets.append(cat as any Animal)
        #expect(person.pets.count == 2)

        person.pets.removeAll()
        #expect(person.pets.count == 0)
    }
}
