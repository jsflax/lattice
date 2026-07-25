# Lattice

[![CI](https://github.com/jsflax/lattice/actions/workflows/ci.yml/badge.svg)](https://github.com/jsflax/lattice/actions/workflows/ci.yml)
[![Docs](https://github.com/jsflax/lattice/actions/workflows/docs.yml/badge.svg)](https://jsflax.github.io/lattice/documentation/lattice/)

<!--
  Every Swift snippet in this file is compile-checked (and, where cheap, run)
  by Tests/LatticeTests/READMESnippetTests.swift — one test per section,
  named after the section heading. If you edit a snippet here, update the
  matching test (and vice versa). `swift test --filter READMESnippetTests`.
-->

A modern, type-safe Swift ORM framework built on SQLite with real-time synchronization and SwiftUI integration.

## Features

- 🎯 **Type-Safe Queries** - Compile-time query validation using Swift's type system
- 🔄 **Real-Time Sync** - WebSocket-based synchronization across devices
- 🔗 **IPC Sync** - Cross-process synchronization via Unix domain sockets
- 🎛️ **Filtered Sync** - Per-table upload filtering with predicate support
- 📱 **SwiftUI Integration** - Native reactive data binding with `@LatticeQuery` property wrapper
- 🎭 **Actor Isolation** - Built-in Swift concurrency support with actor-based isolation
- 🔗 **Relationships** - One-to-one, one-to-many, and inverse relationships
- 📦 **Embedded Models** - Store complex types as JSON within models
- 🔍 **Change Tracking** - Automatic audit logging for all database changes
- ⚡ **Performance** - SQLite with WAL mode, connection pooling, and optimized queries
- 🧩 **Macros** - Swift macros for automatic model code generation
- 🔀 **Polymorphic Queries** - Query across multiple model types via shared protocols (VirtualModel)
- 🔗 **Database Attachment** - Attach and query across multiple SQLite databases
- 🧮 **Vector Search** - Built-in ANN similarity search with sqlite-vec (L2, Cosine, L1 distances)
- 🌍 **Geospatial Queries** - R*Tree spatial indexing with bounding box and proximity search
- 📝 **Full-Text Search** - FTS5 indexing with porter tokenizer, type-safe query builder, and hybrid search

## Installation

### Swift Package Manager

Add Lattice to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jsflax/lattice.git", branch: "main")
]
```

## Quick Start

### 1. Define Your Models

```swift
import Lattice

@Model final class Person {
    var name: String
    var age: Int
    var email: String

    // Relationships
    var friend: Person?
    var pets: List<Pet>
}

@Model final class Pet {
    var name: String
    var breed: String
}
```

### 2. Initialize Lattice

```swift
// Default configuration: a database file in the documents directory
let lattice = try Lattice(Person.self, Pet.self)

// Custom file location
let config = Lattice.Configuration(
    fileURL: URL(fileURLWithPath: "/path/to/database.sqlite")
)
let lattice = try Lattice(Person.self, Pet.self, configuration: config)

// Fresh private in-memory database (tests, previews)
let scratch = try Lattice(Person.self, Pet.self,
                          configuration: .init(storage: .memory()))
```

Storage is controlled by `Configuration.storage`: `.file(URL)` for an on-disk
database, `.memory()` for a fresh private in-memory database, and
`.memory(named:)` for a shared in-memory database — handles opened with the
same name in one process share the database and observe each other's writes.

### 3. Create and Save Objects

```swift
let person = Person()
person.name = "Alice"
person.age = 30
person.email = "alice@example.com"

try lattice.add(person)
```

`add` throws: a failed insert (constraint violation, closed handle, I/O error)
surfaces as `LatticeError.addFailed`, and re-adding an already-managed object
throws `LatticeError.alreadyManaged`.

### 4. Query Data

```swift
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
```

### 5. Observe Changes

```swift
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
```

## Advanced Features

### Constraints and Uniqueness

```swift
@Model class User {
    @Unique()
    var username: String

    @Unique(compoundedWith: \Self.date, \.email, allowsUpsert: true)
    var sessionId: String

    var date: Date
    var email: String
}
```

### Embedded Models

Embedded models are value types stored as JSON inside the owning row. They
must be default-constructible, so give every property a default value:

```swift
struct Address: EmbeddedModel {
    var street: String = ""
    var city: String = ""
    var zipCode: String = ""
}

@Model class Company {
    var name: String
    var headquarters: Address?
}
```

### Relationships

```swift
@Model class Parent {
    var name: String
    var children: List<Child>
}

@Model class Child {
    var name: String
    var parent: Parent?
}
```

### Real-Time Synchronization

```swift
let config = Lattice.Configuration(
    fileURL: URL(fileURLWithPath: "/path/to/db.sqlite"),
    authorizationToken: "your-auth-token",
    wssEndpoint: URL(string: "wss://your-server.com/sync")
)

let lattice = try Lattice(Person.self, configuration: config)
// Changes are automatically synced via WebSocket
```

Track progress with `lattice.syncProgressStream` (an `AsyncStream` of
`SyncProgress` values — `for await progress in lattice.syncProgressStream`),
or `lattice.syncProgressPublisher` for Combine.

### IPC Sync

Synchronize databases across processes via Unix domain sockets. Both sides
reference a shared channel name — the socket path is auto-derived per
platform, and roles are negotiated at runtime: the first process to open a
channel becomes the server, later ones connect as clients. Set
`ipcTargets` on the configuration before opening the database:

```swift
// Hub process: opens the channel and serves filtered data
var filter = Lattice.SyncFilter()
filter.include(Person.self, where: { $0.age >= 18 })

var sourceConfig = Lattice.Configuration(fileURL: sourceURL)
sourceConfig.ipcTargets = [.init(channel: "adults", syncFilter: filter)]
let source = try Lattice(Person.self, configuration: sourceConfig)

// Spoke process: same channel name — connects and receives the filtered data
var targetConfig = Lattice.Configuration(fileURL: targetURL)
targetConfig.ipcTargets = [.init(channel: "adults")]
let target = try Lattice(Person.self, configuration: targetConfig)
// Sync is bidirectional — changes flow both ways
```

When the two processes don't share a HOME directory (e.g. a macOS app talking
to an iOS simulator), pass an explicit `socketPath:` to `IPCSyncTarget`
instead of relying on the derived path.

IPC and WSS compose for cloud relay — a database can receive changes via IPC and automatically forward them to the cloud via WSS:

```swift
// Relay process: receives from IPC, relays to cloud
var relayConfig = Lattice.Configuration(
    fileURL: relayURL,
    authorizationToken: token,
    wssEndpoint: URL(string: "wss://your-server.com/sync")
)
relayConfig.ipcTargets = [.init(channel: "adults")]
```

Per-synchronizer state (`_lattice_sync_state` table) tracks sync status independently per transport, preventing loops and enabling automatic relay.

### Filtered Sync

Control which rows are uploaded per table:

```swift
var filter = Lattice.SyncFilter()
filter.include(Person.self, where: { $0.age >= 18 })
filter.include(Pet.self) // all pets

let config = Lattice.Configuration(
    fileURL: url,
    authorizationToken: token,
    wssEndpoint: wssURL,
    syncFilter: filter
)
```

Only matching rows are uploaded. Incoming remote changes are always applied regardless of filter.

### Migrations

A table is identified by its model type's *name*, so schema versions are
declared as same-named models inside version namespaces:

```swift
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

let config = Lattice.Configuration(
    fileURL: url,
    migration: [
        2: Migration((from: SchemaV1.Person.self, to: SchemaV2.Person.self), blocks: { old, new in
            new.fullName = "\(old.firstName) \(old.lastName)"
        })
    ]
)
let lattice = try Lattice(SchemaV2.Person.self, configuration: config)
```

The variadic `Migration((from:to:), blocks:)` initializer uses parameter packs
(iOS 17+). On iOS 15/16 use the equivalent pack-free builder, available
everywhere:

```swift
let migration = Migration().add(from: SchemaV1.Person.self, to: SchemaV2.Person.self) { old, new in
    new.fullName = "\(old.firstName) \(old.lastName)"
}
```

### SwiftUI Integration

```swift
import SwiftUI
import Lattice

struct PersonListView: View {
    @LatticeQuery(
        predicate: { $0.age >= 18 },
        sort: \Person.name,
        order: .forward
    ) var adults: TableResults<Person>

    var body: some View {
        List(adults) { person in
            Text(person.name)
        }
    }
}
```

### Transactions

```swift
try lattice.transaction {
    let person1 = Person()
    person1.name = "Alice"
    try lattice.add(person1)

    let person2 = Person()
    person2.name = "Bob"
    try lattice.add(person2)

    // Both are saved atomically
}
```

If the block throws, the transaction is rolled back and the error is
rethrown — none of the block's writes are kept.

### Thread Safety

Managed objects and `Lattice` handles are confined to the context that
created them. To cross threads, capture `sendableReference`s and resolve them
on the other side:

```swift
// Create sendable references
let personRef = person.sendableReference
let latticeRef = lattice.sendableReference

// Pass to another thread/actor
Task.detached {
    guard let lattice = latticeRef.resolve(),
          let person = personRef.resolve(on: lattice) else { return }
    person.name = "Updated Name"
}
```

### Polymorphic Queries (VirtualModel)

Query across multiple model types that share a common protocol:

```swift
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

// Query across all POI types
let allPOIs = lattice.objects(POI.self)

// Filter works across all conforming types
let frenchPOIs = lattice.objects(POI.self).where {
    $0.country == "France"
}

// Results can be cast back to concrete types
for poi in frenchPOIs {
    if let museum = poi as? Museum {
        print("Museum: \(museum.name)")
    } else if let restaurant = poi as? Restaurant {
        print("Restaurant: \(restaurant.name)")
    }
}
```

### Database Attachment

Attach separate databases and query across them:

```swift
// Create two separate databases
var mainLattice = try Lattice(Restaurant.self, Person.self)
let museumsLattice = try Lattice(Museum.self)

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

// Detach when done — drops the attachment and rebuilds the merged schema
try mainLattice.detach(lattice: museumsLattice)
```

`attach` throws `LatticeError.attachFailed` on schema mismatch or alias
collision; `detach` throws `LatticeError.detachFailed`.

### Vector Search

Perform ANN (Approximate Nearest Neighbor) similarity search powered by [sqlite-vec](https://github.com/asg017/sqlite-vec). Each `Vector` property automatically gets a dedicated vec0 virtual table with triggers to keep it in sync.

```swift
@Model class Document {
    var title: String
    var category: String
    var embedding: FloatVector  // Vector<Float>, stored as BLOB + vec0 index
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

// Vector search across polymorphic types (federated across tables)
let similarPOIs = lattice.objects(POI.self)
    .nearest(to: locationEmbedding, on: \.embedding, limit: 10, distance: .cosine)
```

Supported distance metrics: `.l2` (Euclidean), `.cosine`, `.l1` (Manhattan).

### Geospatial Queries

Properties conforming to `GeoboundsProperty` (like `MKCoordinateRegion` and `CLLocationCoordinate2D`) are automatically indexed with an R\*Tree for efficient spatial queries.

```swift
import MapKit

@Model class Place {
    var name: String
    var category: String
    var location: CLLocationCoordinate2D
    var region: MKCoordinateRegion
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
```

### Full-Text Search

Mark `String` properties with `@FullText` to enable FTS5 full-text search with automatic indexing via porter tokenizer. Uses external content tables (no data duplication) with trigger-based sync.

```swift
@Model class Article {
    var title: String
    @FullText var content: String        // FTS5-indexed
    var embedding: FloatVector
}

// Basic search (terms implicitly ANDed)
let results = lattice.objects(Article.self)
    .matching("machine learning", on: \.content)

for match in results {
    print("\(match.object.title) — rank: \(match.distances["content"]!)")
}
```

Use the `TextQuery` type for explicit control over query semantics:

```swift
// All terms must match (AND)
.matching(.allOf("machine", "learning"), on: \.content)

// Any term can match (OR)
.matching(.anyOf("machine", "learning"), on: \.content)

// Exact phrase
.matching(.phrase("machine learning"), on: \.content)

// Prefix search
.matching(.prefix("mach"), on: \.content)

// Proximity — terms within N tokens of each other
.matching(.near("machine", "learning", distance: 2), on: \.content)

// Raw FTS5 syntax for advanced queries
.matching(.raw("(machine OR deep) AND learning"), on: \.content)
```

Full-text search composes with all other query types:

```swift
// FTS5 + WHERE filter
let filtered = lattice.objects(Article.self)
    .where { $0.title == "ML Advanced" }
    .matching("machine learning", on: \.content)

// Hybrid: FTS5 + vector similarity
let hybrid = lattice.objects(Article.self)
    .matching("learning", on: \.content)
    .nearest(to: queryVec, on: \.embedding, limit: 10, distance: .cosine)
```

FTS5 rank scores are negative (lower = better match) and accessible via `match.distances["columnName"]`.

### Bulk Operations

```swift
let people = (0..<1000).map { i in
    let person = Person()
    person.name = "Person \(i)"
    person.age = i
    return person
}

try lattice.add(contentsOf: people)
```

## Query DSL

Lattice supports a rich query syntax:

### Comparisons
```swift
.where { $0.age == 30 }
.where { $0.age != 30 }
.where { $0.age > 30 }
.where { $0.age >= 30 }
.where { $0.age < 30 }
.where { $0.age <= 30 }
```

### Logical Operators
```swift
.where { $0.name == "Alice" && $0.age > 25 }
.where { $0.name == "Alice" || $0.name == "Bob" }
.where { !($0.age < 18) }
```

### String Operations
```swift
.where { $0.name.contains("Ali") }
.where { $0.name.starts(with: "A") }
.where { $0.name.ends(with: "e") }
```

### Range Operations
```swift
.where { $0.age.contains(20...30) }   // BETWEEN 20 AND 30
```

### Embedded Properties
```swift
.where { $0.address.city == "New York" }
```

## Configuration Options

```swift
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
```

## Performance Tips

1. **Use Transactions** - Wrap multiple operations in `transaction {}` for better performance
2. **Batch Inserts** - Use `add(contentsOf:)` for bulk operations
3. **Indexes** - Use `@Unique()` macro to create indexes for frequently queried fields
4. **Limit Results** - Use `.snapshot(limit:)` when you don't need all results
5. **Sort in Database** - Use `.sortedBy()` instead of sorting in Swift

## Requirements

- Swift 6.3+ toolchain (`swift-tools-version: 6.3`)
- iOS 15.0+ / macOS 14.0+ / Linux (Ubuntu 24.04+)
- Xcode with a Swift 6.3 toolchain (Apple platforms)

### iOS 15/16 notes

The deployment floor is iOS 15. The full API surface is available on every
supported platform; three *convenience spellings* use variadic generics or
`SortDescriptor.keyPath` and therefore require iOS 17+, each with a portable
equivalent that works from iOS 15:

| iOS 17+ convenience | iOS 15+ portable equivalent |
|---|---|
| `Lattice(A.self, B.self, …)` beyond 6 model types (parameter packs) | Fixed-arity overloads up to 6 types, or `Lattice(for: [A.self, B.self, …])` |
| `Migration((from: V1.self, to: V2.self), blocks: …)` (parameter packs) | `Migration().add(from: V1.self, to: V2.self) { old, new in … }` |
| `sortedBy(SortDescriptor(\.age, order: .forward))` | `sortedBy(\.age, order: .forward)` |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

For bugs and feature requests, please create an issue on GitHub.
