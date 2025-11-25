# Lattice

A modern, type-safe Swift ORM framework built on SQLite with real-time synchronization and SwiftUI integration.

## Features

- 🎯 **Type-Safe Queries** - Compile-time query validation using Swift's type system
- 🔄 **Real-Time Sync** - WebSocket-based synchronization across devices
- 📱 **SwiftUI Integration** - Native reactive data binding with `@Query` property wrapper
- 🎭 **Actor Isolation** - Built-in Swift concurrency support with actor-based isolation
- 🔗 **Relationships** - One-to-one, one-to-many, and inverse relationships
- 📦 **Embedded Models** - Store complex types as JSON within models
- 🔍 **Change Tracking** - Automatic audit logging for all database changes
- ⚡ **Performance** - SQLite with WAL mode, connection pooling, and optimized queries
- 🧩 **Macros** - Swift macros for automatic model code generation

## Installation

### Swift Package Manager

Add Lattice to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/Lattice.git", from: "1.0.0")
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

    @Relation(link: \Child.parent)
    var children: Results<Child>
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
    @Query(
        predicate: { $0.age >= 18 },
        sortBy: [.init(\.name, order: .forward)]
    ) var adults: Results<Person>

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
// Create thread-safe reference
let reference = person.threadSafeReference()

// Pass to another thread/actor
Task.detached {
    let threadSafePerson = reference.resolve(on: lattice)
    threadSafePerson?.name = "Updated Name"
}
```

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
.where { $0.age.in(20...30) }
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
4. **Limit Results** - Use `.limit()` when you don't need all results
5. **Sort in Database** - Use `.sortedBy()` instead of sorting in Swift

## Requirements

- Swift 5.9+
- iOS 17.0+ / macOS 14.0+
- Xcode 15.0+

## License

[Your License Here]

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

For bugs and feature requests, please create an issue on GitHub.
