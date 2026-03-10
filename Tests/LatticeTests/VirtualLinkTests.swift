import Foundation
import Testing
@testable import Lattice

@Model final class TestPersonWithPet {
    var label: String = ""
    var favoritePet: (any Animal)? = nil
}

class VirtualLinkTests: BaseTest {
    @Test func testSetAndRead() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)
        let person = TestPersonWithPet()
        person.label = "Alice"
        lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        lattice.add(dog)

        person.favoritePet = dog as any Animal
        #expect(person.favoritePet?.name == "Rex")
        #expect((person.favoritePet as? TestDog)?.breed == "Lab")
    }

    @Test func testNil() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)
        let person = TestPersonWithPet()
        lattice.add(person)
        #expect(person.favoritePet == nil)
    }

    @Test func testOverwrite() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)
        let person = TestPersonWithPet()
        lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        lattice.add(dog)

        let cat = TestCat()
        cat.name = "Whiskers"
        lattice.add(cat)

        person.favoritePet = dog as any Animal
        #expect(person.favoritePet?.name == "Rex")

        person.favoritePet = cat as any Animal
        #expect(person.favoritePet?.name == "Whiskers")
        #expect((person.favoritePet as? TestCat)?.indoor == true)
    }

    @Test func testClearLink() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)
        let person = TestPersonWithPet()
        lattice.add(person)

        let dog = TestDog()
        dog.name = "Rex"
        lattice.add(dog)

        person.favoritePet = dog as any Animal
        #expect(person.favoritePet != nil)

        person.favoritePet = nil
        #expect(person.favoritePet == nil)
    }

    @Test func testPersistence() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)
        let person = TestPersonWithPet()
        person.label = "Bob"
        lattice.add(person)

        let cat = TestCat()
        cat.name = "Mittens"
        lattice.add(cat)

        person.favoritePet = cat as any Animal

        let fetched = lattice.objects(TestPersonWithPet.self).where { $0.label == "Bob" }.first!
        #expect(fetched.favoritePet?.name == "Mittens")
        #expect((fetched.favoritePet as? TestCat) != nil)
    }
}
