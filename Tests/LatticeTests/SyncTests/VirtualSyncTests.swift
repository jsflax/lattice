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
    @Test(.timeLimit(.minutes(5))) func test_VirtualListSync() async throws {
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
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
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
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
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

    @Test(.timeLimit(.minutes(5))) func test_VirtualLinkSync() async throws {
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
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
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
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
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

    // MARK: - Cascade Delete Sync (WSS)

    /// Deleting a child object should cascade-remove link table entries and sync both deletions.
    @Test(.disabled(if: isMacOSCI, "Darwin CI hang class — await never resumes and .timeLimit cannot interrupt on macOS; runs locally and on Linux CI. Owner: 1.0 item D1b/D2"), .timeLimit(.minutes(5))) func test_VirtualListCascadeDeleteSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Phase 1: Insert person + 2 pets, sync to lattice2
        var task: Task<Void, any Error>?
        var taskForSynchronization: Task<Void, any Error>?

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    insertCount += changes.count(where: { $0.operation == .insert })
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
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let person = TestPersonWithPets()
        person.label = "CascadeTest"
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

        try await taskForSynchronization?.value
        try await task?.value

        // Wait for virtual list links to arrive on lattice2
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

        #expect(lattice2.objects(TestPersonWithPets.self).first!.pets.count == 2)

        // Phase 2: Delete the dog on lattice1 — cascade removes link table entry too.
        // Wait for the model delete to arrive on lattice2 via changeStream.
        let localLattice2Configuration = self.localLattice2Configuration
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == "TestDog" }) {
                        break
                    }
                }
            }
        }

        lattice.delete(dog)
        #expect(person.pets.count == 1, "Local cascade should remove link entry")

        try await task?.value

        #expect(lattice2.objects(TestDog.self).count == 0, "Dog should be deleted on lattice2")
        #expect(lattice2.objects(TestCat.self).count == 1, "Cat should still exist on lattice2")

        let syncedPerson = lattice2.objects(TestPersonWithPets.self).first!
        #expect(syncedPerson.pets.count == 1, "Cascade link table delete should sync — virtual list reflects child deletion")
    }
}

// MARK: - IPC Virtual Cascade Delete Sync Tests

@Suite("IPC Virtual Cascade Delete Sync Tests")
actor IPCVirtualCascadeDeleteTests {
    let sourceURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let targetURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var sourceConfig: Lattice.Configuration
    var targetConfig: Lattice.Configuration

    init() {
        self.sourceConfig = .init(fileURL: sourceURL)
        self.targetConfig = .init(fileURL: targetURL)
    }

    deinit {
        try? Lattice.delete(for: sourceConfig)
        try? Lattice.delete(for: targetConfig)
    }

    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        return c
    }

    /// Deleting a child object should cascade-remove link table entries and sync both via IPC.
    @Test(.timeLimit(.minutes(5)))
    func test_IPCSync_VirtualListCascadeDelete() async throws {
        let channel = "ipc-vcascade-\(String.random(length: 8))"

        sourceConfig.ipcTargets = [.init(channel: channel)]
        let source = try Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: sourceConfig)

        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: targetConfig)

        // Phase 1: Insert person + 2 pets on source, wait for sync to target
        let readConfig = observerConfig(from: targetConfig)
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let db = try Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: readConfig)
                let stream = db.changeStream
                continuation.resume()
                var insertCount = 0
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: db) }
                    insertCount += resolved.count(where: { $0.operation == .insert })
                    if insertCount >= 3 { break }
                }
            }
        }

        let person = TestPersonWithPets()
        person.label = "IPCCascade"
        let dog = TestDog()
        dog.name = "Buddy"
        dog.breed = "Golden"
        let cat = TestCat()
        cat.name = "Mittens"
        cat.indoor = false

        source.transaction {
            source.add(person)
            source.add(dog)
            source.add(cat)
            person.pets.append(dog as any Animal)
            person.pets.append(cat as any Animal)
        }

        try await task?.value

        // Wait for virtual list links to arrive on target
        let petsReady = NIOLockedValueBox(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellable: AnyCancellable?
            let tryComplete = {
                if (target.objects(TestPersonWithPets.self).first?.pets.count ?? 0) >= 2 {
                    if !petsReady.withLockedValue({ val in
                        let was = val; val = true; return was
                    }) {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
            cancellable = target.objects(TestPersonWithPets.self).observe { _ in
                tryComplete()
            }
            tryComplete()
        }

        #expect(target.objects(TestPersonWithPets.self).first!.pets.count == 2)

        // Phase 2: Delete the dog on source — cascade removes link entry, both sync via IPC.
        // Wait for the model delete to arrive on target via changeStream.
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let db = try Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self, configuration: readConfig)
                let stream = db.changeStream
                continuation.resume()
                for await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: db) }
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == "TestDog" }) {
                        break
                    }
                }
            }
        }

        source.delete(dog)
        #expect(person.pets.count == 1, "Local cascade should remove link entry")

        try await task?.value

        #expect(target.objects(TestDog.self).count == 0, "Dog should be deleted on target")
        #expect(target.objects(TestCat.self).count == 1, "Cat should still exist on target")

        let syncedPerson = target.objects(TestPersonWithPets.self).first!
        #expect(syncedPerson.pets.count == 1, "Cascade link table delete should sync — virtual list reflects child deletion via IPC")
    }
}
