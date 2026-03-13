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

    @Test func testAddVirtualModel() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)

        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"

        // Add via existential (any VirtualModel) overload
        let animal: any Animal = dog
        lattice.add(animal)

        #expect(lattice.objects(TestDog.self).count == 1)
        #expect(lattice.objects(TestDog.self).first?.name == "Rex")
        #expect(lattice.objects(TestDog.self).first?.breed == "Lab")
    }

    @Test func testDeleteVirtualModel() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)

        let cat = TestCat()
        cat.name = "Whiskers"
        lattice.add(cat)
        #expect(lattice.objects(TestCat.self).count == 1)

        // Delete via existential (any VirtualModel) overload
        let animal: any Animal = cat
        lattice.delete(animal)
        #expect(lattice.objects(TestCat.self).count == 0)
    }

    @Test func testAddAndDeleteMultipleVirtualTypes() async throws {
        let lattice = try testLattice(TestDog.self, TestCat.self, TestPersonWithPet.self)

        let animals: [any Animal] = [
            { let d = TestDog(); d.name = "Rex"; d.breed = "Lab"; return d }(),
            { let c = TestCat(); c.name = "Whiskers"; c.indoor = true; return c }(),
            { let d = TestDog(); d.name = "Buddy"; d.breed = "Poodle"; return d }(),
        ]

        for animal in animals {
            lattice.add(animal)
        }

        #expect(lattice.objects(TestDog.self).count == 2)
        #expect(lattice.objects(TestCat.self).count == 1)

        // Delete first dog via existential
        lattice.delete(animals[0])
        #expect(lattice.objects(TestDog.self).count == 1)
        #expect(lattice.objects(TestDog.self).first?.name == "Buddy")
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
