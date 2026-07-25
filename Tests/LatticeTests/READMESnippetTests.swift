// READMESnippetTests.swift
//
// Compile-checks (and, where cheap, runs) every Swift code snippet in
// README.md — the guard against README rot. One test (or compile-only
// function) per README section, named after the section heading.
//
// KEEP IN SYNC BY CONSTRUCTION: the README's header comment points here; if
// you edit a snippet in README.md, update the matching test below (and vice
// versa). Lines that must differ from the README to be runnable (temp paths
// instead of "/path/to/db.sqlite", unique IPC channel names, seed data) are
// marked [test-only].
//
// Models are nested inside the suite class (the codebase's namespacing
// pattern for test models): the @Model macro emits `extension <Type>` at file
// scope, so top-level models named like ones elsewhere in the test target
// (Person, Parent, Document, ...) would collide. Nesting qualifies the
// generated extensions (`extension READMESnippetTests.Person`) while test
// bodies still read identically to the README.

import Foundation
import Testing
import Lattice
#if canImport(MapKit)
import MapKit
#endif

@Suite("README Snippet Tests")
class READMESnippetTests: BaseTest {

    // MARK: README § Quick Start / 1. Define Your Models

    @Model final class Person {
        var name: String
        var age: Int
        var email: String

        // Relationships
        var friend: Person?
        var pets: List<READMESnippetTests.Pet>  // README: List<Pet> — [test-only] qualified for the nested namespace
    }

    @Model final class Pet {
        var name: String
        var breed: String
    }

    // MARK: README § Advanced Features / Constraints and Uniqueness

    @Model class User {
        @Unique()
        var username: String

        @Unique(compoundedWith: \Self.date, \.email, allowsUpsert: true)
        var sessionId: String

        var date: Date
        var email: String
    }

    // MARK: README § Advanced Features / Embedded Models

    struct Address: EmbeddedModel {
        var street: String = ""
        var city: String = ""
        var zipCode: String = ""
    }

    @Model class Company {
        var name: String
        var headquarters: READMESnippetTests.Address?  // README: Address? — [test-only] qualified for the nested namespace
    }

    // MARK: README § Advanced Features / Relationships

    @Model class Parent {
        var name: String
        var children: List<READMESnippetTests.Child>  // README: List<Child> — [test-only] qualified for the nested namespace
    }

    @Model class Child {
        var name: String
        var parent: READMESnippetTests.Parent?  // README: Parent? — [test-only] qualified for the nested namespace
    }

    // MARK: README § Advanced Features / Migrations
    // (SchemaV1/SchemaV2 are declared at file scope below the suite — the
    // README's version-namespace pattern, kept out of the class so the inner
    // models nest exactly one level deep like the README shows.)

    // MARK: README § Advanced Features / Polymorphic Queries (VirtualModel)

    // Define a protocol for shared properties
    protocol POI: VirtualModel {
        var name: String { get }
        var country: String { get }
        var embedding: FloatVector { get }
    }

    // Models conform to the protocol
    @Model class Restaurant: POI {
        var name: String
        var country: String
        var embedding: FloatVector
        var cuisineType: String

        init(name: String = "", country: String = "", cuisineType: String = "") {
            self.name = name
            self.country = country
            self.cuisineType = cuisineType
        }
    }

    @Model class Museum: POI {
        var name: String
        var country: String
        var embedding: FloatVector
        var exhibitCount: Int

        init(name: String = "", country: String = "", exhibitCount: Int = 0) {
            self.name = name
            self.country = country
            self.exhibitCount = exhibitCount
        }
    }

    // MARK: README § Advanced Features / Vector Search

    @Model class Document {
        var title: String
        var category: String
        var embedding: FloatVector  // Vector<Float>, stored as BLOB + vec0 index
    }

    // [test-only] Stand-in for the README's app-provided embedding function.
    private func generateEmbedding(_ text: String) -> FloatVector {
        FloatVector([Float(text.count % 7), 0.5, 1.0])
    }

    // MARK: README § Advanced Features / Geospatial Queries

    #if canImport(MapKit)
    @Model class Place {
        var name: String
        var category: String
        var location: CLLocationCoordinate2D
        var region: MKCoordinateRegion
    }
    #endif

    // MARK: README § Advanced Features / Full-Text Search

    @Model class Article {
        var title: String
        @FullText var content: String        // FTS5-indexed
        var embedding: FloatVector
    }

    // MARK: README § Query DSL
    // [test-only] The DSL section's fragments are written against an
    // unspecified model; Post carries every property they mention.

    @Model class Post {
        var name: String
        var age: Int
        var address: READMESnippetTests.Address?  // [test-only] qualified for the nested namespace
    }

    // Convenience: fresh private in-memory database for run-tested snippets.
    // [test-only]
    private func memoryLattice(_ types: any Model.Type...) throws -> Lattice {
        try Lattice(for: types, configuration: .init(storage: .memory()))
    }

    // MARK: README § Quick Start / 2. Initialize Lattice

    /// Compile-only: the default-configuration spelling writes into the
    /// documents directory and the custom spelling uses a literal path.
    private func compileOnly_initializeLattice() throws {
        // Default configuration: a database file in the documents directory
        let lattice = try Lattice(Person.self, Pet.self)

        // Custom file location
        let config = Lattice.Configuration(
            fileURL: URL(fileURLWithPath: "/path/to/database.sqlite")
        )
        let lattice2 = try Lattice(Person.self, Pet.self, configuration: config)

        _ = (lattice, lattice2)
    }

    @Test func test_QuickStart_InitializeLattice_Memory() throws {
        // Fresh private in-memory database (tests, previews)
        let scratch = try Lattice(Person.self, Pet.self,
                                  configuration: .init(storage: .memory()))
        #expect(scratch.objects(Person.self).count == 0)
    }

    // MARK: README § Quick Start / 3. Create and Save Objects

    @Test func test_QuickStart_CreateAndSaveObjects() throws {
        let lattice = try memoryLattice(Person.self, Pet.self)  // [test-only]

        let person = Person()
        person.name = "Alice"
        person.age = 30
        person.email = "alice@example.com"

        try lattice.add(person)

        #expect(lattice.objects(Person.self).count == 1)
    }

    // MARK: README § Quick Start / 4. Query Data

    @Test func test_QuickStart_QueryData() throws {
        let lattice = try memoryLattice(Person.self, Pet.self)  // [test-only]
        for (name, age) in [("Alice", 30), ("Bob", 26), ("Eve", 12)] {  // [test-only]
            let p = Person()
            p.name = name
            p.age = age
            try lattice.add(p)
        }

        // Get all persons
        let allPersons = lattice.objects(Person.self)

        // Filter with type-safe queries
        let adults = lattice.objects(Person.self).where {
            $0.age >= 18
        }

        // Complex queries
        let results = lattice.objects(Person.self).where {
            ($0.name == "Alice" || $0.name == "Bob") && $0.age > 25
        }

        // Sort results
        let sorted = lattice.objects(Person.self)
            .sortedBy(\.age, order: .forward)

        #expect(allPersons.count == 3)
        #expect(adults.count == 2)
        #expect(results.count == 2)
        #expect(sorted.first?.age == 12)
    }

    // MARK: README § Quick Start / 5. Observe Changes

    @Test func test_QuickStart_ObserveChanges() throws {
        let lattice = try memoryLattice(Person.self, Pet.self)  // [test-only]

        let cancellable = lattice.objects(Person.self).observe { change in
            switch change {
            case .insert(let id):
                print("New person added with id: \(id)")
            case .update(let id):
                print("Person updated: \(id)")
            case .delete(let id):
                print("Person deleted: \(id)")
            }
        }

        try lattice.add(Person())  // [test-only] exercise the observer path
        withExtendedLifetime(cancellable) {}
    }

    // MARK: README § Advanced Features / Constraints and Uniqueness

    @Test func test_ConstraintsAndUniqueness() throws {
        let lattice = try memoryLattice(User.self)  // [test-only]
        let user = User()
        user.username = "alice"
        user.sessionId = "s-1"
        user.date = Date()
        user.email = "alice@example.com"
        try lattice.add(user)
        #expect(lattice.objects(User.self).count == 1)
    }

    // MARK: README § Advanced Features / Embedded Models

    @Test func test_EmbeddedModels() throws {
        let lattice = try memoryLattice(Company.self)  // [test-only]
        let company = Company()
        company.name = "Acme"
        company.headquarters = Address(street: "1 Main St", city: "Springfield", zipCode: "12345")
        try lattice.add(company)
        #expect(lattice.objects(Company.self).first?.headquarters?.city == "Springfield")
    }

    // MARK: README § Advanced Features / Relationships

    @Test func test_Relationships() throws {
        let lattice = try memoryLattice(Parent.self, Child.self)  // [test-only]
        let parent = Parent()
        parent.name = "Pat"
        let child = Child()
        child.name = "Chris"
        try lattice.add(parent)
        parent.children.append(child)
        #expect(lattice.objects(Parent.self).first?.children.count == 1)
    }

    // MARK: README § Advanced Features / Real-Time Synchronization

    @Test func test_RealTimeSynchronization_Configuration() throws {
        let config = Lattice.Configuration(
            fileURL: URL(fileURLWithPath: "/path/to/db.sqlite"),
            authorizationToken: "your-auth-token",
            wssEndpoint: URL(string: "wss://your-server.com/sync")
        )
        #expect(config.wssEndpoint != nil)
        // Opening the Lattice (which starts the sync transport) is
        // compile-checked below without dialing the endpoint. [test-only]
    }

    /// Compile-only: opening a synced lattice + iterating sync progress.
    private func compileOnly_realTimeSynchronization(config: Lattice.Configuration) async throws {
        let lattice = try Lattice(Person.self, configuration: config)
        // Changes are automatically synced via WebSocket

        for await progress in lattice.syncProgressStream {
            _ = progress.uploadFraction
        }
    }

    // MARK: README § Advanced Features / IPC Sync

    @Test func test_IPCSync() throws {
        // [test-only] Temp databases + a unique channel name; the README uses
        // "adults" and app-chosen file URLs.
        let tmp = FileManager.default.temporaryDirectory
        let suffix = String.random(length: 8)
        let sourceURL = tmp.appending(path: "readme_ipc_source_\(suffix).sqlite")
        let targetURL = tmp.appending(path: "readme_ipc_target_\(suffix).sqlite")
        let channel = "readme-adults-\(suffix)"
        defer {
            try? Lattice.delete(for: .init(fileURL: sourceURL))
            try? Lattice.delete(for: .init(fileURL: targetURL))
        }

        // Hub process: opens the channel and serves filtered data
        var filter = Lattice.SyncFilter()
        filter.include(Person.self, where: { $0.age >= 18 })

        var sourceConfig = Lattice.Configuration(fileURL: sourceURL)
        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let source = try Lattice(Person.self, configuration: sourceConfig)

        // Spoke process: same channel name — connects and receives the filtered data
        var targetConfig = Lattice.Configuration(fileURL: targetURL)
        targetConfig.ipcTargets = [.init(channel: channel)]
        let target = try Lattice(Person.self, configuration: targetConfig)
        // Sync is bidirectional — changes flow both ways

        #expect(source.objects(Person.self).count == 0)
        #expect(target.objects(Person.self).count == 0)
    }

    @Test func test_IPCCloudRelay_Configuration() throws {
        let relayURL = FileManager.default.temporaryDirectory
            .appending(path: "readme_relay_\(String.random(length: 8)).sqlite")  // [test-only]
        let token = "token"  // [test-only]

        // Relay process: receives from IPC, relays to cloud
        var relayConfig = Lattice.Configuration(
            fileURL: relayURL,
            authorizationToken: token,
            wssEndpoint: URL(string: "wss://your-server.com/sync")
        )
        relayConfig.ipcTargets = [.init(channel: "adults")]

        #expect(relayConfig.ipcTargets?.count == 1)
    }

    // MARK: README § Advanced Features / Filtered Sync

    @Test func test_FilteredSync() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "readme_filtered_\(String.random(length: 8)).sqlite")  // [test-only]
        let token = "token"  // [test-only]
        let wssURL = URL(string: "wss://your-server.com/sync")  // [test-only]

        var filter = Lattice.SyncFilter()
        filter.include(Person.self, where: { $0.age >= 18 })
        filter.include(Pet.self) // all pets

        let config = Lattice.Configuration(
            fileURL: url,
            authorizationToken: token,
            wssEndpoint: wssURL,
            syncFilter: filter
        )

        #expect(config.syncFilter != nil)
    }

    // MARK: README § Advanced Features / Migrations

    @Test func test_Migrations() throws {
        let path = "readme_migration_\(String.random(length: 8)).sqlite"  // [test-only]
        let url = FileManager.default.temporaryDirectory.appending(path: path)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }  // [test-only]

        do {  // [test-only] seed a v1 database
            let v1 = try Lattice(SchemaV1.Person.self, configuration: .init(fileURL: url))
            let p = SchemaV1.Person()
            p.firstName = "Ada"
            p.lastName = "Lovelace"
            try v1.add(p)
        }

        let config = Lattice.Configuration(
            fileURL: url,
            migration: [
                2: Migration((from: SchemaV1.Person.self, to: SchemaV2.Person.self), blocks: { old, new in
                    new.fullName = "\(old.firstName) \(old.lastName)"
                })
            ]
        )
        let lattice = try Lattice(SchemaV2.Person.self, configuration: config)

        #expect(lattice.objects(SchemaV2.Person.self).first?.fullName == "Ada Lovelace")
    }

    @Test func test_Migrations_PortableBuilder() throws {
        // iOS 15/16 spelling — pack-free builder, available everywhere
        let migration = Migration().add(from: SchemaV1.Person.self, to: SchemaV2.Person.self) { old, new in
            new.fullName = "\(old.firstName) \(old.lastName)"
        }
        _ = migration
    }

    // MARK: README § Advanced Features / Transactions

    @Test func test_Transactions() throws {
        let lattice = try memoryLattice(Person.self, Pet.self)  // [test-only]

        try lattice.transaction {
            let person1 = Person()
            person1.name = "Alice"
            try lattice.add(person1)

            let person2 = Person()
            person2.name = "Bob"
            try lattice.add(person2)

            // Both are saved atomically
        }

        #expect(lattice.objects(Person.self).count == 2)
    }

    // MARK: README § Advanced Features / Thread Safety

    @Test func test_ThreadSafety() async throws {
        let lattice = try testLattice(Person.self, Pet.self)  // [test-only] file-backed so a second handle can resolve
        let person = Person()
        person.name = "Alice"
        try lattice.add(person)

        // Create sendable references
        let personRef = person.sendableReference
        let latticeRef = lattice.sendableReference

        // Pass to another thread/actor
        let task = Task.detached {  // [test-only] the README discards the task
            guard let lattice = latticeRef.resolve(),
                  let person = personRef.resolve(on: lattice) else { return }
            person.name = "Updated Name"
        }
        await task.value  // [test-only]

        #expect(lattice.objects(Person.self).first?.name == "Updated Name")
    }

    // MARK: README § Advanced Features / Polymorphic Queries (VirtualModel)

    @Test func test_PolymorphicQueries() throws {
        let lattice = try memoryLattice(Restaurant.self, Museum.self)  // [test-only]
        try lattice.add(Restaurant(name: "Le Bernardin", country: "France"))   // [test-only]
        try lattice.add(Museum(name: "The Louvre", country: "France"))         // [test-only]

        // Query across all POI types
        let allPOIs = lattice.objects(POI.self)

        // Filter works across all conforming types
        let frenchPOIs = lattice.objects(POI.self).where {
            $0.country == "France"
        }

        // Results can be cast back to concrete types
        var seen = [String]()  // [test-only]
        for poi in frenchPOIs {
            if let museum = poi as? Museum {
                print("Museum: \(museum.name)")
                seen.append("museum")  // [test-only]
            } else if let restaurant = poi as? Restaurant {
                print("Restaurant: \(restaurant.name)")
                seen.append("restaurant")  // [test-only]
            }
        }

        #expect(allPOIs.count == 2)
        #expect(seen.sorted() == ["museum", "restaurant"])
    }

    // MARK: README § Advanced Features / Database Attachment

    @Test func test_DatabaseAttachment() throws {
        // Create two separate databases
        var mainLattice = try testLattice(Restaurant.self, Person.self)  // [test-only] temp files, not documents dir
        let museumsLattice = try testLattice(Museum.self)                // [test-only]

        // Add data to each
        try mainLattice.add(Restaurant(name: "Le Bernardin", country: "United States"))
        try museumsLattice.add(Museum(name: "The Louvre", country: "France"))

        // Attach the second database to the first
        try mainLattice.attach(lattice: museumsLattice)

        // Now query across both databases
        let allPOIs = mainLattice.objects(POI.self)  // Returns restaurants AND museums
        print(allPOIs.count)  // 2

        // Filtering works across attached databases
        let frenchPOIs = mainLattice.objects(POI.self).where {
            $0.country == "France"
        }

        #expect(allPOIs.count == 2)
        #expect(frenchPOIs.count == 1)

        // Detach when done — drops the attachment and rebuilds the merged schema
        try mainLattice.detach(lattice: museumsLattice)

        #expect(mainLattice.objects(POI.self).count == 1)
    }

    // MARK: README § Advanced Features / Vector Search

    @Test func test_VectorSearch() throws {
        let lattice = try memoryLattice(Document.self)  // [test-only]
        for (title, category) in [("Neural nets", "science"), ("Pasta", "cooking")] {  // [test-only]
            let d = Document()
            d.title = title
            d.category = category
            d.embedding = generateEmbedding(title)
            try lattice.add(d)
        }

        // Find the 10 most similar documents (cosine distance)
        let query: FloatVector = generateEmbedding("search query")

        let similar = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 10, distance: .cosine)

        for match in similar {
            print("\(match.object.title) - distance: \(match.distance)")
        }

        // Combine vector search with SQL filtering
        let filtered = lattice.objects(Document.self)
            .where { $0.category == "science" }
            .nearest(to: query, on: \.embedding, limit: 10, distance: .l2)

        #expect(similar.count == 2)
        #expect(filtered.count == 1)
    }

    @Test func test_VectorSearch_Polymorphic() throws {
        let lattice = try memoryLattice(Restaurant.self, Museum.self)  // [test-only]
        let restaurant = Restaurant(name: "Chez Panisse", country: "United States")  // [test-only]
        restaurant.embedding = generateEmbedding("chez")                             // [test-only]
        try lattice.add(restaurant)                                                  // [test-only]
        let locationEmbedding = generateEmbedding("berkeley")                        // [test-only]

        // Vector search across polymorphic types (federated across tables)
        let similarPOIs = lattice.objects(POI.self)
            .nearest(to: locationEmbedding, on: \.embedding, limit: 10, distance: .cosine)

        #expect(similarPOIs.count == 1)
    }

    // MARK: README § Advanced Features / Geospatial Queries

    #if canImport(MapKit)
    @Test func test_GeospatialQueries() throws {
        let lattice = try memoryLattice(Place.self)  // [test-only]
        for (name, category, lat, lon) in [  // [test-only]
            ("Blue Bottle", "cafe", 37.7763, -122.4233),
            ("Ferry Building", "market", 37.7955, -122.3937),
            ("LA Cafe", "cafe", 34.0522, -118.2437),
        ] {
            let p = Place()
            p.name = name
            p.category = category
            p.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            try lattice.add(p)
        }

        // Find places within a bounding box (uses R*Tree index)
        let sfPlaces = lattice.objects(Place.self)
            .withinBounds(\.location, minLat: 37.7, maxLat: 37.8, minLon: -122.5, maxLon: -122.4)

        // Combine with filters
        let sfCafes = lattice.objects(Place.self)
            .where { $0.category == "cafe" }
            .withinBounds(\.location, minLat: 37.7, maxLat: 37.8, minLon: -122.5, maxLon: -122.4)

        // Proximity search — find nearest places within a radius, sorted by distance
        let nearby = lattice.objects(Place.self)
            .nearest(to: (latitude: 37.7749, longitude: -122.4194),
                     on: \.location, maxDistance: 5, unit: .kilometers,
                     limit: 20, sortedByDistance: true)

        for match in nearby {
            print("\(match.object.name) — \(match.distance) km away")
        }

        #expect(sfPlaces.count == 1)
        #expect(sfCafes.count == 1)
        #expect(nearby.count >= 1)
    }
    #endif

    // MARK: README § Advanced Features / Full-Text Search

    @Test func test_FullTextSearch() throws {
        let lattice = try memoryLattice(Article.self)  // [test-only]
        for (title, content) in [  // [test-only]
            ("ML Intro", "Introduction to machine learning and neural networks"),
            ("ML Advanced", "Advanced machine learning techniques in Swift and Rust"),
            ("Cooking", "How to cook pasta"),
        ] {
            let a = Article()
            a.title = title
            a.content = content
            a.embedding = generateEmbedding(title)
            try lattice.add(a)
        }

        // Basic search (terms implicitly ANDed)
        let results = lattice.objects(Article.self)
            .matching("machine learning", on: \.content)

        for match in results {
            print("\(match.object.title) — rank: \(match.distances["content"]!)")
        }

        #expect(results.count == 2)

        // TextQuery variants
        #expect(lattice.objects(Article.self)
            .matching(.allOf("machine", "learning"), on: \.content).count == 2)
        #expect(lattice.objects(Article.self)
            .matching(.anyOf("machine", "pasta"), on: \.content).count == 3)
        #expect(lattice.objects(Article.self)
            .matching(.phrase("machine learning"), on: \.content).count == 2)
        #expect(lattice.objects(Article.self)
            .matching(.prefix("mach"), on: \.content).count == 2)
        #expect(lattice.objects(Article.self)
            .matching(.near("machine", "learning", distance: 2), on: \.content).count == 2)
        #expect(lattice.objects(Article.self)
            .matching(.raw("(machine OR deep) AND learning"), on: \.content).count == 2)

        // FTS5 + WHERE filter
        let filtered = lattice.objects(Article.self)
            .where { $0.title == "ML Advanced" }
            .matching("machine learning", on: \.content)

        #expect(filtered.count == 1)

        // Hybrid: FTS5 + vector similarity
        let queryVec = generateEmbedding("machine learning")  // [test-only]
        let hybrid = lattice.objects(Article.self)
            .matching("learning", on: \.content)
            .nearest(to: queryVec, on: \.embedding, limit: 10, distance: .cosine)

        #expect(hybrid.count >= 1)
    }

    // MARK: README § Advanced Features / Bulk Operations

    @Test func test_BulkOperations() throws {
        let lattice = try memoryLattice(Person.self, Pet.self)  // [test-only]

        let people = (0..<1000).map { i in
            let person = Person()
            person.name = "Person \(i)"
            person.age = i
            return person
        }

        try lattice.add(contentsOf: people)

        #expect(lattice.objects(Person.self).count == 1000)
    }

    // MARK: README § Query DSL

    @Test func test_QueryDSL() throws {
        let lattice = try memoryLattice(Post.self)  // [test-only]
        let post = Post()  // [test-only]
        post.name = "Alice"
        post.age = 30
        post.address = Address(street: "5th Ave", city: "New York", zipCode: "10001")
        try lattice.add(post)

        let posts = lattice.objects(Post.self)

        // Comparisons
        #expect(posts.where { $0.age == 30 }.count == 1)
        #expect(posts.where { $0.age != 30 }.count == 0)
        #expect(posts.where { $0.age > 30 }.count == 0)
        #expect(posts.where { $0.age >= 30 }.count == 1)
        #expect(posts.where { $0.age < 30 }.count == 0)
        #expect(posts.where { $0.age <= 30 }.count == 1)

        // Logical operators
        #expect(posts.where { $0.name == "Alice" && $0.age > 25 }.count == 1)
        #expect(posts.where { $0.name == "Alice" || $0.name == "Bob" }.count == 1)
        #expect(posts.where { !($0.age < 18) }.count == 1)

        // String operations
        #expect(posts.where { $0.name.contains("Ali") }.count == 1)
        #expect(posts.where { $0.name.starts(with: "A") }.count == 1)
        #expect(posts.where { $0.name.ends(with: "e") }.count == 1)

        // Range operations
        #expect(posts.where { $0.age.contains(20...30) }.count == 1)   // BETWEEN 20 AND 30

        // Embedded properties
        #expect(posts.where { $0.address.city == "New York" }.count == 1)
    }

    // MARK: README § Configuration Options

    @Test func test_ConfigurationOptions() throws {
        var config = Lattice.Configuration(
            storage: .file(URL(fileURLWithPath: "/path/to/db.sqlite")),  // or .memory() / .memory(named:)
            authorizationToken: "token",
            wssEndpoint: URL(string: "wss://sync-server.com"),
            isReadOnly: false,          // open with SQLITE_OPEN_READONLY (bundled template databases)
            migration: nil,             // versioned [Int: Migration] schema migrations
            syncFilter: nil,            // upload whitelist (see Filtered Sync)
            busyTimeoutMs: 30_000,      // statement-level SQLite busy timeout
            syncTuning: nil             // sync transport knobs (chunk size, backoff, …)
        )
        config.ipcTargets = [.init(channel: "my-channel")]  // cross-process sync (see IPC Sync)
        config.resultsTuning = .init()  // live-results cache/read-generation knobs

        #expect(config.ipcTargets?.count == 1)
    }

    // MARK: README § Performance Tips

    @Test func test_PerformanceTips() throws {
        let lattice = try memoryLattice(Person.self, Pet.self)  // [test-only]
        try lattice.add(Person())  // [test-only]

        // 4. Limit Results — use .snapshot(limit:) when you don't need all results
        let firstTen = lattice.objects(Person.self).snapshot(limit: 10)
        // 5. Sort in Database — use .sortedBy() instead of sorting in Swift
        let sorted = lattice.objects(Person.self).sortedBy(\.age, order: .forward)

        #expect(firstTen.count == 1)
        #expect(sorted.count == 1)
    }
}

// MARK: README § Advanced Features / Migrations (version namespaces)

enum SchemaV1 {
    @Model class Person {
        var firstName: String
        var lastName: String
    }
}

enum SchemaV2 {
    @Model class Person {
        var fullName: String
    }
}
