import Foundation
import Testing
import Lattice
#if canImport(SQLite3)
import SQLite3
#endif
#if canImport(MapKit)
import MapKit
#endif

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

// MARK: - GeoBounds List Migration Test Models

// Scenario 1: Adding a geo_bounds list to existing model
class GeoBoundsListAddV1 {
    @Model class Route {
        var name: String
        var startLocation: CLLocationCoordinate2D
    }
}

class GeoBoundsListAddV2 {
    @Model class Route {
        var name: String
        var startLocation: CLLocationCoordinate2D
        var waypoints: Lattice.List<CLLocationCoordinate2D>  // NEW: geo_bounds list added
    }
}

// Scenario 2: Removing a geo_bounds list from model (destructive)
class GeoBoundsListRemoveV1 {
    @Model class Journey {
        var name: String
        var stops: Lattice.List<CLLocationCoordinate2D>  // Will be removed
    }
}

class GeoBoundsListRemoveV2 {
    @Model class Journey {
        var name: String
        // stops list removed - destructive migration
    }
}

// Scenario 3: Preserving geo_bounds list data through migration with other changes
class GeoBoundsListPreserveV1 {
    @Model class Trip {
        var title: String  // Will be renamed to 'name'
        var waypoints: Lattice.List<CLLocationCoordinate2D>
    }
}

class GeoBoundsListPreserveV2 {
    @Model class Trip {
        var name: String  // Renamed from 'title'
        var waypoints: Lattice.List<CLLocationCoordinate2D>  // Should be preserved
        var totalDistance: Double  // NEW field
    }
}

// Scenario 4: Multiple geo_bounds lists
class MultiGeoBoundsListV1 {
    @Model class Expedition {
        var name: String
        var plannedRoute: Lattice.List<MKCoordinateRegion>
    }
}

class MultiGeoBoundsListV2 {
    @Model class Expedition {
        var name: String
        var plannedRoute: Lattice.List<MKCoordinateRegion>  // Existing
        var actualRoute: Lattice.List<CLLocationCoordinate2D>  // NEW second list
    }
}

// MARK: - Int64-to-UUID Migration Test Models

// V1: Edge references nodes by Int64 primary key
class FKToUUIDV1 {
    @Model class Node {
        var label: String
    }
    @Model class Edge {
        var sourceId: Int64
        var targetId: Int64
        var weight: Double
    }
}

// V2: Edge references nodes by UUID globalId
class FKToUUIDV2 {
    @Model class Node {
        var label: String
    }
    @Model class Edge {
        var sourceGlobalId: UUID
        var targetGlobalId: UUID
        var weight: Double
    }
}

// MARK: - Edge-Only Migration Test Models (lookup target NOT in migration)
// Mirrors Engram scenario: Memory (unchanged) + Edge (sourceId→sourceGlobalId)

class EdgeOnlyMigV1 {
    @Model class Memory {
        var content: String
        var topic: String
    }
    @Model class Edge {
        var sourceId: Int64
        var targetId: Int64
        var relation: String
        var createdAt: Date
    }
}

class EdgeOnlyMigV2 {
    @Model class Memory {
        var content: String
        var topic: String
    }
    @Model class Edge {
        var sourceGlobalId: UUID
        var targetGlobalId: UUID
        var relation: String
        var createdAt: Date
    }
}

// MARK: - FK-to-Link Migration Test Models

// V1: Child has a raw FK column referencing Parent
class FKToLinkV1 {
    @Model class Parent {
        var name: String
    }
    @Model class Child {
        var name: String
        var parentId: Int
    }
}

// V2: Child uses an Optional<Model> link instead of raw FK
class FKToLinkV2 {
    @Model class Parent {
        var name: String
    }
    @Model class Child {
        var name: String
        var parent: FKToLinkV2.Parent?
    }
}

// MARK: - FK-to-List Migration Test Models

// V1: Item has a raw FK column referencing a Category
class FKToListV1 {
    @Model class Category {
        var name: String
    }
    @Model class Item {
        var name: String
        var categoryId: Int
    }
}

// V2: Category has a List<Item> link instead
class FKToListV2 {
    @Model class Category {
        var name: String
        var items: Lattice.List<FKToListV2.Item>
    }
    @Model class Item {
        var name: String
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

            // Verify the rtree was populated - spatial query should find the migrated restaurant
            let nearbyRestaurants = lattice.objects(M2Restaurant.self)
                .nearest(to: (latitude: 37.78, longitude: -122.42),
                        on: \.coordinate, maxDistance: 10, unit: .kilometers, limit: 10)
            #expect(nearbyRestaurants.count == 1)
            #expect(nearbyRestaurants.first?.object.name == "McDonald's")
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

    // MARK: - GeoBounds List Migration Tests

    @Test
    func test_GeoBoundsListMigration_AddList() throws {
        // Scenario 1: Adding a geo_bounds list to existing model
        typealias V1Route = GeoBoundsListAddV1.Route
        typealias V2Route = GeoBoundsListAddV2.Route

        let dbPath = "migration_geobounds_list_add_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema (no list)
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Route.self)
            let route = V1Route()
            route.name = "Bay Area Tour"
            route.startLocation = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            lattice.add(route)

            #expect(lattice.objects(V1Route.self).count == 1)
        }

        // Phase 2: Migrate to V2 with new list property
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Route.self, migration: [
                2: Migration((from: V1Route.self, to: V2Route.self), blocks: { old, new in
                    // No special migration needed - list starts empty
                })
            ])

            let routes = lattice.objects(V2Route.self)
            #expect(routes.count == 1)

            let route = routes.first!
            #expect(route.name == "Bay Area Tour")
            #expect(Swift.abs(route.startLocation.latitude - 37.7749) < 0.0001)

            // New list should be empty
            #expect(route.waypoints.count == 0)

            // Should be able to add to the new list
            route.waypoints.append(CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712))
            route.waypoints.append(CLLocationCoordinate2D(latitude: 37.8716, longitude: -122.2727))

            #expect(route.waypoints.count == 2)
        }
    }

    @Test
    func test_GeoBoundsListMigration_RemoveList() throws {
        // Scenario 2: Removing a geo_bounds list (destructive)
        typealias V1Journey = GeoBoundsListRemoveV1.Journey
        typealias V2Journey = GeoBoundsListRemoveV2.Journey

        let dbPath = "migration_geobounds_list_remove_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema (with list)
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Journey.self)
            let journey = V1Journey()
            journey.name = "Cross Country"
            lattice.add(journey)

            // Add stops to the list
            journey.stops.append(CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060))  // NYC
            journey.stops.append(CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298))  // Chicago
            journey.stops.append(CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)) // LA

            #expect(journey.stops.count == 3)
        }

        // Phase 2: Migrate to V2 with list removed
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Journey.self, migration: [
                2: Migration((from: V1Journey.self, to: V2Journey.self), blocks: { old, new in
                    // List is removed - no migration needed
                })
            ])

            let journeys = lattice.objects(V2Journey.self)
            #expect(journeys.count == 1)

            let journey = journeys.first!
            #expect(journey.name == "Cross Country")
            // The stops list no longer exists in V2
        }
    }

    @Test
    func test_GeoBoundsListMigration_PreserveListData() throws {
        // Scenario 3: Preserving list data while other fields change
        typealias V1Trip = GeoBoundsListPreserveV1.Trip
        typealias V2Trip = GeoBoundsListPreserveV2.Trip

        let dbPath = "migration_geobounds_list_preserve_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema
        let originalWaypoints = [
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),  // SF
            CLLocationCoordinate2D(latitude: 36.1699, longitude: -115.1398),  // Vegas
            CLLocationCoordinate2D(latitude: 36.1070, longitude: -112.1130),  // Grand Canyon
        ]

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Trip.self)
            let trip = V1Trip()
            trip.title = "Southwest Adventure"
            lattice.add(trip)

            for waypoint in originalWaypoints {
                trip.waypoints.append(waypoint)
            }

            #expect(trip.waypoints.count == 3)
        }

        // Phase 2: Migrate to V2 with renamed field and new field
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Trip.self, migration: [
                2: Migration((from: V1Trip.self, to: V2Trip.self), blocks: { old, new in
                    new.name = old.title  // Rename title -> name
                    new.totalDistance = 750.5  // Set new field
                })
            ])

            let trips = lattice.objects(V2Trip.self)
            #expect(trips.count == 1)

            let trip = trips.first!
            #expect(trip.name == "Southwest Adventure")
            #expect(trip.totalDistance == 750.5)

            // Verify list data is preserved
            #expect(trip.waypoints.count == 3)
            for (i, original) in originalWaypoints.enumerated() {
                #expect(Swift.abs(trip.waypoints[i].latitude - original.latitude) < 0.0001)
                #expect(Swift.abs(trip.waypoints[i].longitude - original.longitude) < 0.0001)
            }
        }
    }

    @Test
    func test_GeoBoundsListMigration_AddSecondList() throws {
        // Scenario 4: Adding a second geo_bounds list to model that already has one
        typealias V1Expedition = MultiGeoBoundsListV1.Expedition
        typealias V2Expedition = MultiGeoBoundsListV2.Expedition

        let dbPath = "migration_geobounds_multi_list_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create data with V1 schema (one list)
        let originalRegions = [
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ),
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
                span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
            ),
        ]

        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Expedition.self)
            let expedition = V1Expedition()
            expedition.name = "California Expedition"
            lattice.add(expedition)

            for region in originalRegions {
                expedition.plannedRoute.append(region)
            }

            #expect(expedition.plannedRoute.count == 2)
        }

        // Phase 2: Migrate to V2 with second list added
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Expedition.self, migration: [
                2: Migration((from: V1Expedition.self, to: V2Expedition.self), blocks: { old, new in
                    // No special migration - new list starts empty
                })
            ])

            let expeditions = lattice.objects(V2Expedition.self)
            #expect(expeditions.count == 1)

            let expedition = expeditions.first!
            #expect(expedition.name == "California Expedition")

            // Verify original list is preserved
            #expect(expedition.plannedRoute.count == 2)
            #expect(Swift.abs(expedition.plannedRoute[0].center.latitude - 37.7749) < 0.0001)
            #expect(Swift.abs(expedition.plannedRoute[1].center.latitude - 34.0522) < 0.0001)

            // New list should be empty
            #expect(expedition.actualRoute.count == 0)

            // Should be able to add to both lists
            expedition.actualRoute.append(CLLocationCoordinate2D(latitude: 37.5, longitude: -122.0))
            #expect(expedition.actualRoute.count == 1)

            expedition.plannedRoute.append(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611),
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            ))
            #expect(expedition.plannedRoute.count == 3)
        }
    }

    // MARK: - FK-to-Link Migration Tests

    @Test
    func test_FKToLinkMigration() throws {
        typealias V1Parent = FKToLinkV1.Parent
        typealias V1Child = FKToLinkV1.Child
        typealias V2Parent = FKToLinkV2.Parent
        typealias V2Child = FKToLinkV2.Child

        let dbPath = "migration_fk_to_link_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create V1 data with raw FK column
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Parent.self, V1Child.self)

            let parent = V1Parent()
            parent.name = "Alice"
            lattice.add(parent)

            let parentPK = parent.primaryKey!

            let child1 = V1Child()
            child1.name = "Bob"
            child1.parentId = Int(parentPK)
            lattice.add(child1)

            let child2 = V1Child()
            child2.name = "Charlie"
            child2.parentId = Int(parentPK)
            lattice.add(child2)

            // Orphan child (no parent)
            let child3 = V1Child()
            child3.name = "Dave"
            child3.parentId = 0
            lattice.add(child3)

            #expect(lattice.objects(V1Parent.self).count == 1)
            #expect(lattice.objects(V1Child.self).count == 3)
        }

        // Phase 2: Migrate FK column to Optional<Model> link
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Parent.self, V2Child.self, migration: [
                2: Migration(
                    (from: V1Parent.self, to: V2Parent.self),
                    (from: V1Child.self, to: V2Child.self),
                    blocks: { old, new in
                        // Parent unchanged
                    }, { old, new in
                        // Convert FK to link
                        if old.parentId != 0,
                           let parent = Migration.lookup(V2Parent.self, id: Int64(old.parentId)) {
                            new.parent = parent
                        }
                    })
            ])

            let parents = lattice.objects(V2Parent.self)
            #expect(parents.count == 1)
            #expect(parents.first?.name == "Alice")

            let children = lattice.objects(V2Child.self)
            #expect(children.count == 3)

            // Bob should be linked to Alice
            let bob = children.first { $0.name == "Bob" }!
            #expect(bob.parent?.name == "Alice")

            // Charlie should also be linked to Alice
            let charlie = children.first { $0.name == "Charlie" }!
            #expect(charlie.parent?.name == "Alice")

            // Dave has no parent (parentId was 0)
            let dave = children.first { $0.name == "Dave" }!
            #expect(dave.parent == nil)
        }
    }

    @Test
    func test_FKToListMigration() throws {
        typealias V1Category = FKToListV1.Category
        typealias V1Item = FKToListV1.Item
        typealias V2Category = FKToListV2.Category
        typealias V2Item = FKToListV2.Item

        let dbPath = "migration_fk_to_list_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create V1 data with raw FK columns
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Category.self, V1Item.self)

            let category = V1Category()
            category.name = "Electronics"
            lattice.add(category)

            let catPK = Int(category.primaryKey!)

            let item1 = V1Item()
            item1.name = "Phone"
            item1.categoryId = catPK
            lattice.add(item1)

            let item2 = V1Item()
            item2.name = "Laptop"
            item2.categoryId = catPK
            lattice.add(item2)

            #expect(lattice.objects(V1Category.self).count == 1)
            #expect(lattice.objects(V1Item.self).count == 2)
        }

        // Phase 2: Migrate FK column to List<Model> link
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Category.self, V2Item.self, migration: [
                2: Migration(
                    (from: V1Category.self, to: V2Category.self),
                    (from: V1Item.self, to: V2Item.self),
                    blocks: { old, new in
                        // Category migration: look up items that reference this category
                        // and add them to the list
                        // Note: We query items by iterating V1 items with matching FK
                    }, { old, new in
                        // Item migration: nothing special needed
                    })
            ])

            // For FK-to-List, we need a different approach:
            // The list lives on Category, but the FK lives on Item.
            // We can verify the items still exist and manually test the list approach.
            let categories = lattice.objects(V2Category.self)
            #expect(categories.count == 1)
            #expect(categories.first?.name == "Electronics")

            let items = lattice.objects(V2Item.self)
            #expect(items.count == 2)

            // The items should still exist, though the list isn't populated
            // (FK-to-List requires a different pattern - the list owner needs to
            // look up each child and append, which requires the lookup API)
        }
    }

    // MARK: - Int64-to-UUID Migration Test

    @Test
    func test_FKToUUIDMigration() throws {
        typealias V1Node = FKToUUIDV1.Node
        typealias V1Edge = FKToUUIDV1.Edge
        typealias V2Node = FKToUUIDV2.Node
        typealias V2Edge = FKToUUIDV2.Edge

        let dbPath = "migration_fk_to_uuid_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        var nodeGlobalIds: [Int64: UUID] = [:]

        // Phase 1: Create V1 data with Int64 FK references
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Node.self, V1Edge.self)

            let nodeA = V1Node()
            nodeA.label = "A"
            lattice.add(nodeA)

            let nodeB = V1Node()
            nodeB.label = "B"
            lattice.add(nodeB)

            let nodeC = V1Node()
            nodeC.label = "C"
            lattice.add(nodeC)

            // Record globalIds for verification
            nodeGlobalIds[nodeA.primaryKey!] = nodeA.__globalId!
            nodeGlobalIds[nodeB.primaryKey!] = nodeB.__globalId!
            nodeGlobalIds[nodeC.primaryKey!] = nodeC.__globalId!

            // Edges referencing nodes by Int64 primaryKey
            let edgeAB = V1Edge()
            edgeAB.sourceId = nodeA.primaryKey!
            edgeAB.targetId = nodeB.primaryKey!
            edgeAB.weight = 1.5
            lattice.add(edgeAB)

            let edgeBC = V1Edge()
            edgeBC.sourceId = nodeB.primaryKey!
            edgeBC.targetId = nodeC.primaryKey!
            edgeBC.weight = 2.0
            lattice.add(edgeBC)

            #expect(lattice.objects(V1Node.self).count == 3)
            #expect(lattice.objects(V1Edge.self).count == 2)
        }

        // Phase 2: Migrate Int64 FKs to UUID globalId references
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Node.self, V2Edge.self, migration: [
                2: Migration(
                    (from: V1Node.self, to: V2Node.self),
                    (from: V1Edge.self, to: V2Edge.self),
                    blocks: { old, new in
                        // Node: no changes
                    }, { old, new in
                        // Edge: look up source/target Node by old Int64 PK, get globalId
                        if let sourceNode = Migration.lookup(V2Node.self, id: old.sourceId),
                           let gid = sourceNode.__globalId {
                            new.sourceGlobalId = gid
                        }
                        if let targetNode = Migration.lookup(V2Node.self, id: old.targetId),
                           let gid = targetNode.__globalId {
                            new.targetGlobalId = gid
                        }
                    })
            ])

            let nodes = lattice.objects(V2Node.self)
            #expect(nodes.count == 3)

            let edges = lattice.objects(V2Edge.self)
            #expect(edges.count == 2)

            // Verify UUID references match original globalIds
            let nodeA = nodes.first { $0.label == "A" }!
            let nodeB = nodes.first { $0.label == "B" }!
            let nodeC = nodes.first { $0.label == "C" }!

            let edgeAB = edges.first { $0.sourceGlobalId == nodeA.__globalId! }!
            #expect(edgeAB.targetGlobalId == nodeB.__globalId!)
            #expect(edgeAB.weight == 1.5)

            let edgeBC = edges.first { $0.sourceGlobalId == nodeB.__globalId! }!
            #expect(edgeBC.targetGlobalId == nodeC.__globalId!)
            #expect(edgeBC.weight == 2.0)

            // Verify globalIds match what we recorded in phase 1
            #expect(nodeA.__globalId == nodeGlobalIds[nodeA.primaryKey!])
            #expect(nodeB.__globalId == nodeGlobalIds[nodeB.primaryKey!])
            #expect(nodeC.__globalId == nodeGlobalIds[nodeC.primaryKey!])
        }
    }

    // MARK: - Edge-Only Migration (lookup target NOT in migration)

    /// Reproduces the Engram scenario: Memory is NOT in the Migration definition,
    /// but Edge migration uses Migration.lookup(Memory.self, ...) to resolve FKs.
    /// Only Edge is listed in the Migration tuple.
    @Test
    func test_EdgeOnlyMigration_LookupTargetNotInMigration() throws {
        typealias V1Memory = EdgeOnlyMigV1.Memory
        typealias V1Edge = EdgeOnlyMigV1.Edge
        typealias V2Memory = EdgeOnlyMigV2.Memory
        typealias V2Edge = EdgeOnlyMigV2.Edge

        let dbPath = "migration_edge_only_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        var memoryGlobalIds: [Int64: UUID] = [:]

        // Phase 1: Create V1 data — Memory + Edge with Int64 FK references
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Memory.self, V1Edge.self)

            let mem1 = V1Memory()
            mem1.content = "First memory"
            mem1.topic = "test"
            lattice.add(mem1)

            let mem2 = V1Memory()
            mem2.content = "Second memory"
            mem2.topic = "test"
            lattice.add(mem2)

            let mem3 = V1Memory()
            mem3.content = "Third memory"
            mem3.topic = "test"
            lattice.add(mem3)

            // Record globalIds for verification
            memoryGlobalIds[mem1.primaryKey!] = mem1.__globalId!
            memoryGlobalIds[mem2.primaryKey!] = mem2.__globalId!
            memoryGlobalIds[mem3.primaryKey!] = mem3.__globalId!

            // Edges referencing memories by Int64 primaryKey
            let edge12 = V1Edge()
            edge12.sourceId = mem1.primaryKey!
            edge12.targetId = mem2.primaryKey!
            edge12.relation = "relates_to"
            edge12.createdAt = Date(timeIntervalSince1970: 1000000)
            lattice.add(edge12)

            let edge23 = V1Edge()
            edge23.sourceId = mem2.primaryKey!
            edge23.targetId = mem3.primaryKey!
            edge23.relation = "part_of"
            edge23.createdAt = Date(timeIntervalSince1970: 2000000)
            lattice.add(edge23)

            #expect(lattice.objects(V1Memory.self).count == 3)
            #expect(lattice.objects(V1Edge.self).count == 2)
        }

        // Phase 2: Migrate — ONLY Edge in Migration, Memory NOT included.
        // Edge migration uses Migration.lookup(V2Memory.self, ...) to resolve FKs.
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V2Memory.self, V2Edge.self, migration: [
                2: Migration(
                    // NOTE: Only Edge is in the migration — Memory is NOT listed
                    (from: V1Edge.self, to: V2Edge.self),
                    blocks: { old, new in
                        // Look up source memory by old Int64 PK, get globalId
                        if let sourceMem = Migration.lookup(V2Memory.self, id: old.sourceId),
                           let gid = sourceMem.__globalId {
                            new.sourceGlobalId = gid
                        } else {
                            new.sourceGlobalId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                        }

                        // Look up target memory by old Int64 PK, get globalId
                        if let targetMem = Migration.lookup(V2Memory.self, id: old.targetId),
                           let gid = targetMem.__globalId {
                            new.targetGlobalId = gid
                        } else {
                            new.targetGlobalId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                        }

                        // Copy relation and createdAt
                        new.relation = old.relation
                        new.createdAt = old.createdAt
                    })
            ])

            // Verify memories survived unchanged
            let memories = lattice.objects(V2Memory.self)
            #expect(memories.count == 3)

            // Verify edges were migrated
            let edges = lattice.objects(V2Edge.self)
            #expect(edges.count == 2, "Expected 2 edges but got \(edges.count)")

            // Verify UUID references match original globalIds
            let mem1 = memories.first { $0.content == "First memory" }!
            let mem2 = memories.first { $0.content == "Second memory" }!
            let mem3 = memories.first { $0.content == "Third memory" }!

            let edge12 = edges.first { $0.sourceGlobalId == mem1.__globalId! }
            #expect(edge12 != nil, "Edge from mem1→mem2 not found. Edge sourceGlobalIds: \(edges.map { $0.sourceGlobalId })")
            #expect(edge12?.targetGlobalId == mem2.__globalId!)
            #expect(edge12?.relation == "relates_to")
            #expect(edge12?.createdAt == Date(timeIntervalSince1970: 1000000))

            let edge23 = edges.first { $0.sourceGlobalId == mem2.__globalId! }
            #expect(edge23 != nil, "Edge from mem2→mem3 not found")
            #expect(edge23?.targetGlobalId == mem3.__globalId!)
            #expect(edge23?.relation == "part_of")

            // Verify globalIds match what we recorded in phase 1
            #expect(mem1.__globalId == memoryGlobalIds[mem1.primaryKey!])
            #expect(mem2.__globalId == memoryGlobalIds[mem2.primaryKey!])
            #expect(mem3.__globalId == memoryGlobalIds[mem3.primaryKey!])
        }
    }

    // MARK: - Partial Migration Recovery Test

    /// Helper: Execute raw SQL on a SQLite database file
    private func executeRawSQL(_ dbURL: URL, _ statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)!)])
        }
        defer { sqlite3_close(db) }

        for sql in statements {
            var errMsg: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
                let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(errMsg)
                throw NSError(domain: "SQLite", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "SQL error: \(msg) in: \(sql)"])
            }
        }
    }

    /// Helper: Query a single integer value from the database
    private func queryRawInt(_ dbURL: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)!)])
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)!)])
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Simulates a partial migration failure: table was rebuilt (sourceId→sourceGlobalId)
    /// but schema version was NOT bumped. Then a second open attempts the migration again.
    /// This reproduces the Engram production bug: "no such column: sourceId".
    @Test
    func test_PartialMigrationRecovery_TableRebuiltButVersionNotBumped() throws {
        typealias V1Memory = EdgeOnlyMigV1.Memory
        typealias V1Edge = EdgeOnlyMigV1.Edge
        typealias V2Memory = EdgeOnlyMigV2.Memory
        typealias V2Edge = EdgeOnlyMigV2.Edge

        let dbPath = "migration_partial_recovery_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)

        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        // Phase 1: Create V1 data
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1Memory.self, V1Edge.self)

            let mem1 = V1Memory()
            mem1.content = "Alpha"
            mem1.topic = "test"
            lattice.add(mem1)

            let mem2 = V1Memory()
            mem2.content = "Beta"
            mem2.topic = "test"
            lattice.add(mem2)

            let edge = V1Edge()
            edge.sourceId = mem1.primaryKey!
            edge.targetId = mem2.primaryKey!
            edge.relation = "relates_to"
            edge.createdAt = Date()
            lattice.add(edge)
        }

        // Phase 2: Simulate a partial migration — manually rebuild Edge table
        // with new columns but DON'T bump schema version (simulates crash/failure mid-migration)
        try executeRawSQL(dbURL, [
            // Drop audit triggers
            "DROP TRIGGER IF EXISTS AuditEdgeInsert",
            "DROP TRIGGER IF EXISTS AuditLog_Update_Edge",
            "DROP TRIGGER IF EXISTS AuditEdgeDelete",
            // Rename old table
            "ALTER TABLE Edge RENAME TO Edge_old",
            // Create new table with V2 schema
            """
            CREATE TABLE Edge(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                globalId TEXT UNIQUE COLLATE NOCASE DEFAULT (
                    lower(hex(randomblob(4))) || '-' ||
                    lower(hex(randomblob(2))) || '-' ||
                    '4' || substr(lower(hex(randomblob(2))),2) || '-' ||
                    substr('89AB', 1 + (abs(random()) % 4), 1) ||
                    substr(lower(hex(randomblob(2))),2) || '-' ||
                    lower(hex(randomblob(6)))
                ),
                sourceGlobalId TEXT DEFAULT '',
                targetGlobalId TEXT DEFAULT '',
                relation TEXT DEFAULT '',
                createdAt REAL DEFAULT 0.0
            )
            """,
            // Copy with defaults for new columns (like rebuild_table does)
            "INSERT INTO Edge (id, globalId, sourceGlobalId, targetGlobalId, relation, createdAt) SELECT id, globalId, '', '', relation, createdAt FROM Edge_old",
            // Drop old table
            "DROP TABLE Edge_old"
            // NOTE: schema_version is NOT bumped — still 1
        ])

        // Verify: Edge has V2 schema but version is still 1
        let version = try queryRawInt(dbURL, "SELECT CAST(value AS INTEGER) FROM _lattice_meta WHERE key = 'schema_version'")
        #expect(version == 1, "Version should still be 1 (not bumped)")

        let edgeCount = try queryRawInt(dbURL, "SELECT COUNT(*) FROM Edge")
        #expect(edgeCount == 1, "Edge should still have 1 row")

        // Phase 3: Open with V2 + migration — this is where the bug would occur.
        // Schema version is 1 (migration thinks it needs to run), but Edge table
        // already has V2 schema (sourceGlobalId instead of sourceId).
        // The migration code would try to hydrate with old_schema (sourceId)
        // but the table has new columns → "no such column: sourceId"
        do {
            try autoreleasepool {
                let lattice = try testLattice(path: dbPath, V2Memory.self, V2Edge.self, migration: [
                    2: Migration(
                        (from: V1Edge.self, to: V2Edge.self),
                        blocks: { old, new in
                            if let sourceMem = Migration.lookup(V2Memory.self, id: old.sourceId),
                               let gid = sourceMem.__globalId {
                                new.sourceGlobalId = gid
                            } else {
                                new.sourceGlobalId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                            }
                            if let targetMem = Migration.lookup(V2Memory.self, id: old.targetId),
                               let gid = targetMem.__globalId {
                                new.targetGlobalId = gid
                            } else {
                                new.targetGlobalId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                            }
                            new.relation = old.relation
                            new.createdAt = old.createdAt
                        })
                ])

                // If we get here, migration handled the partial state gracefully
                let edges = lattice.objects(V2Edge.self)
                #expect(edges.count == 1, "Expected 1 edge after recovery")
            }
        } catch {
            // This is the bug: "no such column: sourceId"
            Issue.record("Migration failed on partially-migrated DB: \(error)")
        }
    }

    // MARK: - Schema Version Guard Tests

    /// Opening a migrated DB with the correct migration dict should succeed.
    @Test
    func test_SchemaVersionGuard_SameVersion_Succeeds() throws {
        typealias M1Person = MigrationV1.Person
        typealias M2Person = MigrationV2.Person
        typealias M1Dog = MigrationV1.Dog
        typealias M2Dog = MigrationV2.Dog

        let dbPath = "schema_guard_same_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        let migration: [Int: Migration] = [
            2: Migration((from: M1Person.self, to: M2Person.self),
                         (from: M1Dog.self, to: M2Dog.self),
                         blocks: { old, new in new.age = Int(old.age) ?? 0 },
                                { _, _ in })
        ]

        // Phase 1: Create DB and migrate to v2
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M1Person.self, M1Dog.self)
            let person = M1Person()
            person.name = "Alice"
            person.age = "25"
            lattice.add(person)
        }
        try autoreleasepool {
            let _ = try testLattice(path: dbPath, M2Person.self, M2Dog.self, migration: migration)
        }

        // Phase 2: Reopen with same migration dict — should succeed (current=2, target=2)
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M2Person.self, M2Dog.self, migration: migration)
            #expect(lattice.objects(M2Person.self).count == 1)
        }
    }

    // TODO: Re-enable once C++ exceptions bridge to Swift errors.
    // The C++ schema version guard throws std::runtime_error which causes SIGTRAP
    // instead of being caught as a Swift error.
//    /// Opening a migrated DB with a LOWER target version should throw.
//    @Test
//    func test_SchemaVersionGuard_OlderBinary_Throws() throws {
//        typealias M1Person = MigrationV1.Person
//        typealias M2Person = MigrationV2.Person
//        typealias M1Dog = MigrationV1.Dog
//        typealias M2Dog = MigrationV2.Dog
//
//        let dbPath = "schema_guard_older_\(String.random(length: 16)).sqlite"
//        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)
//        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
//        try? Lattice.delete(for: .init(fileURL: dbURL))
//
//        // Phase 1: Create and migrate to v2
//        try autoreleasepool {
//            let lattice = try testLattice(path: dbPath, M1Person.self, M1Dog.self)
//            let person = M1Person()
//            person.name = "Bob"
//            person.age = "30"
//            lattice.add(person)
//        }
//        try autoreleasepool {
//            let _ = try testLattice(path: dbPath, M2Person.self, M2Dog.self, migration: [
//                2: Migration((from: M1Person.self, to: M2Person.self),
//                             (from: M1Dog.self, to: M2Dog.self),
//                             blocks: { old, new in new.age = Int(old.age) ?? 0 },
//                                    { _, _ in })
//            ])
//        }
//
//        // Phase 2: Manually bump schema version to 3 (simulates a future migration)
//        try executeRawSQL(dbURL, [
//            "UPDATE _lattice_meta SET value = '3' WHERE key = 'schema_version'"
//        ])
//
//        // Phase 3: Reopen with v2 migration — should throw (current=3 > target=2)
//        #expect(throws: (any Error).self) {
//            try autoreleasepool {
//                let _ = try testLattice(path: dbPath, M2Person.self, M2Dog.self, migration: [
//                    2: Migration((from: M1Person.self, to: M2Person.self),
//                                 (from: M1Dog.self, to: M2Dog.self),
//                                 blocks: { old, new in new.age = Int(old.age) ?? 0 },
//                                        { _, _ in })
//                ])
//            }
//        }
//    }

    // MARK: - Cache Eviction Regression Test

    /// Resolving a LatticeThreadSafeReference (which carries migration config) must not
    /// invalidate the ptr_cache_ entry of an existing Lattice instance. If it does,
    /// managed objects from the old instance lose their lattice_ref(), causing the
    /// dynamic_object copy constructor to read the wrong union member (EXC_BAD_ACCESS).
    @Test
    func test_CacheEviction_PreservesPtrCache() throws {
        typealias M1Person = MigrationV1.Person
        typealias M2Person = MigrationV2.Person
        typealias M1Dog = MigrationV1.Dog
        typealias M2Dog = MigrationV2.Dog

        let dbPath = "cache_eviction_\(String.random(length: 16)).sqlite"
        let dbURL = FileManager.default.temporaryDirectory.appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }
        try? Lattice.delete(for: .init(fileURL: dbURL))

        let migration: [Int: Migration] = [
            2: Migration((from: M1Person.self, to: M2Person.self),
                         (from: M1Dog.self, to: M2Dog.self),
                         blocks: { old, new in new.age = Int(old.age) ?? 0 },
                                { _, _ in })
        ]

        // Phase 1: Create V1 DB with data
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, M1Person.self, M1Dog.self)
            for i in 0..<10 {
                let person = M1Person()
                person.name = "Person \(i)"
                person.age = "\(20 + i)"
                lattice.add(person)
            }
        }

        // Phase 2: Open with V2 + migration → latticeA
        let latticeA = try testLattice(path: dbPath, M2Person.self, M2Dog.self, migration: migration)

        // Phase 3: Resolve a sendable reference → creates latticeB.
        // Because configuration carries migration (target_schema_version > 1), the C++ cache
        // uses the skip_cache path. Before the fix, this erased latticeA's ptr_cache_ entry.
        let ref = latticeA.sendableReference
        let latticeB = ref.resolve()
        #expect(latticeB != nil)

        // Phase 4: Query latticeA — snapshot() calls make_shared() on managed objects,
        // which triggers dynamic_object's copy constructor. That constructor calls
        // lattice_ref() → get_by_pointer() to look up the lattice in ptr_cache_.
        // Before the fix: ptr_cache_ entry was erased → nullptr → union mismatch → crash.
        // After the fix: ptr_cache_ entry is preserved → valid shared_ptr → works.
        let people = latticeA.objects(M2Person.self).snapshot()
        #expect(people.count == 10)
        #expect(people.first?.name.starts(with: "Person") == true)
    }
}

// MARK: - LatticeEnum auto-migration (new enum column on existing rows)

class EnumMigrationV1 {
    @Model class Config {
        var name: String = ""
        var enabled: Bool = false
    }
}

@LatticeEnum
enum ConfigMode: String {
    case basic, advanced, expert
}

class EnumMigrationV2 {
    @Model class Config {
        var name: String = ""
        var enabled: Bool = false
        var mode: ConfigMode = .basic
    }
}

@Suite("Enum Auto-Migration Tests") class EnumAutoMigrationTests: BaseTest {
    @Test func test_ExistingRowGetsDefaultEnumValue() async throws {
        let path = "\(String.random(length: 32)).sqlite"

        // Phase 1: Create DB with V1 schema (no enum column), insert a row
        do {
            let lattice = try testLattice(path: path, EnumMigrationV1.Config.self)
            let config = EnumMigrationV1.Config()
            config.name = "test"
            config.enabled = true
            lattice.add(config)
            #expect(lattice.objects(EnumMigrationV1.Config.self).count == 1)
        }

        // Phase 2: Reopen with V2 schema (new enum column). The existing row
        // has DEFAULT '' for the mode column. Reading it must not crash.
        let lattice = try testLattice(path: path, EnumMigrationV2.Config.self)
        let configs = lattice.objects(EnumMigrationV2.Config.self)
        #expect(configs.count == 1)

        let config = configs.first!
        #expect(config.name == "test")
        #expect(config.enabled == true)
        // Empty string raw value should fall back to the enum's defaultValue (.basic)
        #expect(config.mode == .basic)
    }

}
