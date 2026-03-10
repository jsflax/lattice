import Foundation
#if canImport(Combine)
import Combine
#endif
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Observation
import Vapor

// MARK: - VirtualList & VirtualLink Sync Tests

extension SyncTests {
    @Test(.timeLimit(.minutes(1))) func test_VirtualListSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Set up changeStream on lattice2 BEFORE inserting data
        var task: Task<Void, any Error>?
        var taskForSynchronization: Task<Void, any Error>?

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    insertCount += changes.count(where: { $0.operation == .insert })
                    // 3 model inserts: 1 person + 1 dog + 1 cat
                    if insertCount >= 3 { break }
                }
            }
        }

        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        // Create person with virtual list pets on lattice1
        let person = TestPersonWithPets()
        person.label = "Alice"
        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        let cat = TestCat()
        cat.name = "Whiskers"
        cat.indoor = true

        lattice.transaction {
            lattice.add(person)
            lattice.add(dog)
            lattice.add(cat)
            person.pets.append(dog as any Animal)
            person.pets.append(cat as any Animal)
        }

        #expect(person.pets.count == 2)

        // Wait for sync
        try await taskForSynchronization?.value
        try await task?.value

        #expect(lattice2.objects(TestPersonWithPets.self).count == 1)
        #expect(lattice2.objects(TestDog.self).count == 1)
        #expect(lattice2.objects(TestCat.self).count == 1)

        // Wait for virtual list link entries to arrive
        let petsReady = NIOLockedValueBox(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellable: AnyCancellable?
            let tryComplete = {
                if (lattice2.objects(TestPersonWithPets.self).first?.pets.count ?? 0) >= 2 {
                    if !petsReady.withLockedValue({ val in
                        let was = val; val = true; return was
                    }) {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
            cancellable = lattice2.objects(TestPersonWithPets.self).observe { _ in
                tryComplete()
            }
            tryComplete()
        }

        let syncedPerson = lattice2.objects(TestPersonWithPets.self).first!
        #expect(syncedPerson.pets.count == 2, "VirtualList should sync")
        #expect(syncedPerson.pets.contains(where: { $0.name == "Rex" }), "Dog should be in synced virtual list")
        #expect(syncedPerson.pets.contains(where: { $0.name == "Whiskers" }), "Cat should be in synced virtual list")
        #expect((syncedPerson.pets.first(where: { $0.name == "Rex" }) as? TestDog)?.breed == "Lab")
    }

    @Test(.timeLimit(.minutes(1))) func test_VirtualLinkSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Set up changeStream on lattice2 BEFORE inserting data
        var task: Task<Void, any Error>?
        var taskForSynchronization: Task<Void, any Error>?

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(TestDog.self, TestCat.self, TestPersonWithPet.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice2) })
                    insertCount += changes.count(where: { $0.operation == .insert })
                    // 2 model inserts: 1 person + 1 cat
                    if insertCount >= 2 { break }
                }
            }
        }

        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(TestDog.self, TestCat.self, TestPersonWithPet.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        // Create person with virtual link pet on lattice1
        let person = TestPersonWithPet()
        person.label = "Bob"
        let cat = TestCat()
        cat.name = "Mittens"
        cat.indoor = false

        lattice.transaction {
            lattice.add(person)
            lattice.add(cat)
            person.favoritePet = cat as any Animal
        }

        #expect(person.favoritePet?.name == "Mittens")

        // Wait for sync
        try await taskForSynchronization?.value
        try await task?.value

        #expect(lattice2.objects(TestPersonWithPet.self).count == 1)
        #expect(lattice2.objects(TestCat.self).count == 1)

        // Wait for virtual link entry to arrive
        let petReady = NIOLockedValueBox(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellable: AnyCancellable?
            let tryComplete = {
                if lattice2.objects(TestPersonWithPet.self).first?.favoritePet != nil {
                    if !petReady.withLockedValue({ val in
                        let was = val; val = true; return was
                    }) {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
            cancellable = lattice2.objects(TestPersonWithPet.self).observe { _ in
                tryComplete()
            }
            tryComplete()
        }

        let syncedPerson = lattice2.objects(TestPersonWithPet.self).first!
        #expect(syncedPerson.favoritePet != nil, "VirtualLink should sync")
        #expect(syncedPerson.favoritePet?.name == "Mittens", "Linked cat name should sync")
        #expect((syncedPerson.favoritePet as? TestCat)?.indoor == false, "Cat properties should sync through virtual link")
    }
}
