# Getting Started

Define models, open a database, write objects, and run your first
type-safe queries.

## Installation

Add Lattice to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jsflax/lattice.git", branch: "main")
]
```

Lattice requires a Swift 6.3 toolchain. See <doc:PlatformSupport> for
platform floors and CI tiers.

## Define your models

Annotate final classes with `@Model`. Stored properties become columns;
optional model references and `List` properties become relationships.

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

See <doc:ModelingData> for the full modeling surface — uniqueness,
indexes, embedded models, enums, unions, and value mirrors.

## Open a database

Pass every model type the database manages. Storage is controlled by
`Configuration.storage`: `.file(URL)` for an on-disk database, `.memory()`
for a fresh private in-memory database, and `.memory(named:)` for a shared
in-memory database — handles opened with the same name in one process share
the database and observe each other's writes.

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

## Create and save objects

`add` throws: a failed insert (constraint violation, closed handle, I/O
error) surfaces as ``LatticeError/addFailed(_:)``, and re-adding an
already-managed object throws ``LatticeError/alreadyManaged``.

```swift
let person = Person()
person.name = "Alice"
person.age = 30
person.email = "alice@example.com"

try lattice.add(person)
```

For bulk inserts, use `add(contentsOf:)` — it pre-checks every element and
throws before anything is inserted if one is already managed.

## Query data

Queries are validated at compile time against your model's properties:

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

Results are live: with no explicit sort they carry an implicit
`ORDER BY id ASC` (oldest-first), so iteration order is deterministic.

## Transactions

Group writes atomically. If the block throws, the transaction is rolled
back and the error is rethrown — none of the block's writes are kept.

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

## Next steps

- <doc:ModelingData> — the `@Model` family in depth.
- <doc:ObservationAndSwiftUI> — live updates, `@LatticeQuery`, and change
  streams.
- <doc:Sync> and <doc:IPC> — synchronization across devices and processes.
