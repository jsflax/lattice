import Foundation
import Testing
import Lattice
import MapKit

class MigrationV1 { // for namespacing
    @Model class Person {
        var name: String
        var age: String
    }
    @Model class Dog {
        var name: String
        var age: String
    }
    @Model class Restaurant {
        var name: String
        var category: String
        var latitude: Double
        var longitude: Double
    }
}

class MigrationV2 { // for namespacing
    @Model class Person {
        var name: String
        var age: Int
    }
    @Model class Dog {
        var name: String
        var age: Int
    }
    @Model class Restaurant {
        var name: String
        var category: String
        var coordinate: CLLocationCoordinate2D
    }
}

// MARK: - Link Migration Test Models

class LinkMigrationV1 {
    @Model class Person {
        var name: String
        var bestFriend: Person?
    }
}

class LinkMigrationV2 {
    @Model class Person {
        var name: String
        var bestFriend: Person?
        var friendshipScore: Int  // New field added in V2
    }
}

// MARK: - Link List Migration Test Models

class LinkListMigrationV1 {
    @Model class Team {
        var name: String
        var members: List<LinkListMigrationV1.Player>
    }
    @Model class Player {
        var name: String
        var jerseyNumber: String  // String in V1
    }
}

class LinkListMigrationV2 {
    @Model class Team {
        var name: String
        var members: List<LinkListMigrationV2.Player>
    }
    @Model class Player {
        var name: String
        var jerseyNumber: Int  // Int in V2
    }
}

// MARK: - Vector Migration Test Models

class VectorMigrationV1 {
    @Model class Document {
        var title: String
        var embedding: FloatVector
    }
}

class VectorMigrationV2 {
    @Model class Document {
        var title: String
        var embedding: FloatVector
        var version: Int  // New field added in V2
    }
}

@Suite("Migration Tests")
class MigrationTests: BaseTest {
    @Test
    func test_BasicMigration() throws {
        typealias M1Person = MigrationV1.Person
        typealias M2Person = MigrationV2.Person
        typealias M1Dog = MigrationV1.Dog
        typealias M2Dog = MigrationV2.Dog

        // Use a consistent path for both phases
        let dbPath = "migration_test.sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        // Clean up before and after
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, MigrationV1.Person.self, MigrationV1.Dog.self)
            let person = M1Person()
            person.name = "Foo"
            person.age = "30"
            lattice.add(person)
        }

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, MigrationV2.Person.self, MigrationV2.Dog.self, migration: [
                2: Migration((from: M1Person.self, to: M2Person.self),
                             (from: M1Dog.self, to: M2Dog.self),
                             blocks: { old, new in
                                 new.age = Int(old.age) ?? 0
                }, { old, new in
                    // Dog migration - no changes needed
                })
            ])

            // Verify the migration worked
            let people = lattice.objects(M2Person.self)
            #expect(people.count == 1)

            let person = people.first!
            
            #expect(person.age == 30) // Should be migrated from "30" string to 30 Int
            #expect(person.name == "Foo")
        }
    }
    
    @Test
    func test_GeoboundsMigration() throws {
        typealias M1Restaurant = MigrationV1.Restaurant
        typealias M2Restaurant = MigrationV2.Restaurant

        // Use a consistent path for both phases
        let dbPath = "migration_test_\(String.random(length: 32)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        // Clean up before and after
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M1Restaurant.self)
            let restaurant = M1Restaurant()
            restaurant.name = "McDonald's"
            restaurant.latitude = 37.7749
            restaurant.longitude = -122.4194
            lattice.add(restaurant)
        }

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M2Restaurant.self, migration: [
                2: Migration((from: M1Restaurant.self, to: M2Restaurant.self),
                             blocks: { old, new in
                     new.coordinate = .init(latitude: old.latitude, longitude: old.longitude)
                })
            ])

            // Verify the migration worked
            let restaurants = lattice.objects(M2Restaurant.self)
            #expect(restaurants.count == 1)

            let restaurant = restaurants.first!
            
            #expect(restaurant.name == "McDonald's")
            #expect(restaurant.coordinate.latitude == 37.7749)
            #expect(restaurant.coordinate.longitude == -122.4194)
        }
    }

    // MARK: - Link Migration Test

    @Test
    func test_LinkMigration() throws {
        typealias M1Person = LinkMigrationV1.Person
        typealias M2Person = LinkMigrationV2.Person

        let dbPath = "migration_link_test.sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema including a link
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M1Person.self)

            let alice = M1Person()
            alice.name = "Alice"

            let bob = M1Person()
            bob.name = "Bob"
            bob.bestFriend = alice

            lattice.add(alice)
            lattice.add(bob)

            // Verify link works in V1
            #expect(bob.bestFriend?.name == "Alice")
        }

        // Phase 2: Open with V2 schema and migrate
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M2Person.self, migration: [
                2: Migration((from: M1Person.self, to: M2Person.self),
                             blocks: { old, new in
                                 // Set default value for new field
                                 new.friendshipScore = 100
                })
            ])

            let people = lattice.objects(M2Person.self)
            #expect(people.count == 2)

            // Find Bob and verify link is preserved
            let bob = people.first { $0.name == "Bob" }!
            #expect(bob.bestFriend?.name == "Alice")
            #expect(bob.friendshipScore == 100)

            // Verify Alice has no bestFriend
            let alice = people.first { $0.name == "Alice" }!
            #expect(alice.bestFriend == nil)
            #expect(alice.friendshipScore == 100)
        }
    }

    // MARK: - Link List Migration Test

    @Test
    func test_LinkListMigration() throws {
        typealias M1Team = LinkListMigrationV1.Team
        typealias M1Player = LinkListMigrationV1.Player
        typealias M2Team = LinkListMigrationV2.Team
        typealias M2Player = LinkListMigrationV2.Player

        let dbPath = "migration_linklist_test.sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema including link lists
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M1Team.self, M1Player.self)

            let team = M1Team()
            team.name = "Lakers"

            let player1 = M1Player()
            player1.name = "LeBron"
            player1.jerseyNumber = "23"

            let player2 = M1Player()
            player2.name = "AD"
            player2.jerseyNumber = "3"

            team.members.append(player1)
            team.members.append(player2)

            lattice.add(team)

            // Verify link list works in V1
            #expect(team.members.count == 2)
            #expect(team.members[0].name == "LeBron")
            #expect(team.members[0].jerseyNumber == "23")
        }

        // Phase 2: Open with V2 schema and migrate
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M2Team.self, M2Player.self, migration: [
                2: Migration((from: M1Team.self, to: M2Team.self),
                             (from: M1Player.self, to: M2Player.self),
                             blocks: { old, new in
                                 // Team migration - no changes needed
                }, { old, new in
                    // Player migration - convert jerseyNumber from String to Int
                    new.jerseyNumber = Int(old.jerseyNumber) ?? 0
                })
            ])

            let teams = lattice.objects(M2Team.self)
            #expect(teams.count == 1)

            let team = teams.first!
            #expect(team.name == "Lakers")

            // Verify link list is preserved with migrated data
            #expect(team.members.count == 2)

            let lebron = team.members.first { $0.name == "LeBron" }!
            #expect(lebron.jerseyNumber == 23)  // Converted from "23" to 23

            let ad = team.members.first { $0.name == "AD" }!
            #expect(ad.jerseyNumber == 3)  // Converted from "3" to 3
        }
    }

    // MARK: - Vector Migration Test

    @Test
    func test_VectorMigration() throws {
        typealias M1Document = VectorMigrationV1.Document
        typealias M2Document = VectorMigrationV2.Document

        let dbPath = "migration_vector_test.sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema including vector embedding
        let originalEmbedding: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M1Document.self)

            let doc = M1Document()
            doc.title = "Test Document"
            doc.embedding = FloatVector(originalEmbedding)

            lattice.add(doc)

            // Verify vector is stored correctly in V1
            let docs = lattice.objects(M1Document.self)
            #expect(docs.count == 1)
            #expect(docs.first!.embedding.dimensions == 5)
        }

        // Phase 2: Open with V2 schema and migrate
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M2Document.self, migration: [
                2: Migration((from: M1Document.self, to: M2Document.self),
                             blocks: { old, new in
                                 // Set default value for new version field
                                 new.version = 1
                })
            ])

            let docs = lattice.objects(M2Document.self)
            #expect(docs.count == 1)

            let doc = docs.first!
            #expect(doc.title == "Test Document")
            #expect(doc.version == 1)

            // Verify vector embedding is preserved
            #expect(doc.embedding.dimensions == 5)
            for (i, value) in doc.embedding.enumerated() {
                #expect(abs(value - originalEmbedding[i]) < 0.0001)
            }
        }
    }
}
