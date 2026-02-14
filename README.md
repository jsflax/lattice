# Lattice

A modern, type-safe Swift ORM framework built on SQLite with real-time synchronization and SwiftUI integration.

## Features

- 🎯 **Type-Safe Queries** - Compile-time query validation using Swift's type system
- 🔄 **Real-Time Sync** - WebSocket-based synchronization across devices
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
// Initialize with default configuration (in-memory or default file)
let lattice = try Lattice(Person.self, Pet.self)

// Or with custom configuration
let config = Lattice.Configuration(
    fileURL: URL(fileURLWithPath: "/path/to/database.sqlite")
)
let lattice = try Lattice(Person.self, Pet.self, configuration: config)
```

### 3. Create and Save Objects

```swift
let person = Person()
person.name = "Alice"
person.age = 30
person.email = "alice@example.com"

lattice.add(person)
```

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
    .sortedBy(.init(\.age, order: .forward))
```

### 5. Observe Changes

```swift
let cancellable = lattice.objects(Person.self).observe { change in
    switch change {
    case .insert(let id):
        print("New person added with id: \(id)")
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

    @Unique(compoundedWith: \.date, \.email, allowsUpsert: true)
    var sessionId: String

    var date: Date
    var email: String
}
```

### Embedded Models

```swift
struct Address: EmbeddedModel {
    var street: String
    var city: String
    var zipCode: String
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
    wssEndpoint: URL(string: "wss://your-server.com/sync"),
    authorizationToken: "your-auth-token"
)

let lattice = try Lattice(Person.self, configuration: config)
// Changes are automatically synced via WebSocket
```

### SwiftUI Integration

```swift
import SwiftUI
import Lattice

struct PersonListView: View {
    @LatticeQuery(
        predicate: { $0.age >= 18 },
        sort: \.name,
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
lattice.transaction {
    let person1 = Person()
    person1.name = "Alice"
    lattice.add(person1)

    let person2 = Person()
    person2.name = "Bob"
    lattice.add(person2)

    // Both are saved atomically
}
```

### Thread Safety

```swift
// Create a sendable reference
let reference = person.sendableReference

// Pass to another thread/actor
Task.detached {
    let resolved = reference.resolve(on: lattice)
    resolved?.name = "Updated Name"
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
}

@Model class Museum: POI {
    var name: String
    var country: String
    var embedding: FloatVector
    var exhibitCount: Int
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
mainLattice.add(Restaurant(name: "Le Bernardin", country: "United States"))
museumsLattice.add(Museum(name: "The Louvre", country: "France"))

// Attach the second database to the first
mainLattice.attach(lattice: museumsLattice)

// Now query across both databases
let allPOIs = mainLattice.objects(POI.self)  // Returns restaurants AND museums
print(allPOIs.count)  // 2

// Filtering works across attached databases
let frenchPOIs = mainLattice.objects(POI.self).where {
    $0.country == "France"
}
```

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

// FTS5 across polymorphic types
let allDocs = lattice.objects(Searchable.self)
    .matching(.anyOf("swift", "rust"), on: \.content)
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

lattice.add(contentsOf: people)
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

### Collection Operations
```swift
.where { $0.tags.contains("swift") }
.where { $0.age.contains(20...30) }
```

### Embedded Properties
```swift
.where { $0.address.city == "New York" }
```

## Configuration Options

```swift
let config = Lattice.Configuration(
    fileURL: URL(fileURLWithPath: "/path/to/db.sqlite"),
    wssEndpoint: URL(string: "wss://sync-server.com"),
    authorizationToken: "token"
)
```

## Performance Tips

1. **Use Transactions** - Wrap multiple operations in `transaction {}` for better performance
2. **Batch Inserts** - Use `add(contentsOf:)` for bulk operations
3. **Indexes** - Use `@Unique()` macro to create indexes for frequently queried fields
4. **Limit Results** - Use `.snapshot(limit:)` when you don't need all results
5. **Sort in Database** - Use `.sortedBy()` instead of sorting in Swift

## Requirements

- Swift 6.2+
- iOS 17.0+ / macOS 14.0+
- Xcode 16.0+

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

For bugs and feature requests, please create an issue on GitHub.
