# Modeling Data

The `@Model` macro family: persisted classes, relationships, constraints,
embedded values, enums, unions, and detached value mirrors.

## Models

`@Model` turns a final class into a persisted entity. A table is identified
by the model type's *name*; stored properties become columns.

```swift
@Model final class Person {
    var name: String
    var age: Int
    var email: String
}
```

Managed objects are reference types confined to the context that created
them; use `sendableReference` to cross threads (see
<doc:ObservationAndSwiftUI>).

## Relationships

Optional model references are one-to-one links; ``List`` properties are
one-to-many. Inverses are plain properties on the other side:

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

## Uniqueness and indexes

`@Unique()` creates a unique index; `@Unique(compoundedWith:)` spans
multiple columns, and `allowsUpsert: true` turns a conflicting insert into
an update. `@Indexed()` creates an ordinary non-unique index for frequently
filtered columns.

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

## Embedded models

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

Embedded properties participate in queries:
`.where { $0.headquarters.city == "New York" }`.

Reads are tolerant: a property read from empty or undecodable stored JSON
returns the type's default value (with an error log) instead of trapping.

## Enums

`@LatticeEnum` makes a `RawRepresentable` enum storable as a model field
and generates a `defaultValue` (the first case), so an unknown raw value
read during schema evolution resolves gracefully instead of trapping:

```swift
@LatticeEnum
enum ConfigMode: String {
    case basic, advanced, expert
}
```

## Unions

`@Union` stores a sum type as a model field. Cases may carry optional model
links, labeled value payloads, or nothing — and queries pattern-match over
them with ordinary `switch`/`case` syntax:

```swift
@Union enum FeedItem {
    case dog(Dog?)
    case note(name: String, date: Int)
    case empty
}

@Model final class Feed {
    var label: String = ""
    var item: FeedItem = .empty
}

let notes = lattice.objects(Feed.self).where { q in
    switch q.item {
    case .note(let name, _): return name == "hello"
    default: return false
    }
}
```

When every payload is a known value-leaf type (`String`, the integer
family, `Double`, `Float`, `Bool`, `Date`, `UUID`, `Data` — optionals
included), the macro also emits `Codable`/`Sendable` conformances so the
union participates in `@Detached` mirrors with zero boilerplate.
Class-payload unions get the query machinery and `Equatable`.

## Detached value mirrors

`@Detached` generates a `Sendable` value-type mirror of a model plus a
`detached()` method. The mirror is a true value copy — safe to send across
concurrency domains, encode as JSON, or hold after the database closes.
`List` properties mirror as plain arrays with their own synthesized
`Codable`.

```swift
@Model @Detached
final class Person {
    var name: String = ""
    var age: Int = 0
    var tags: [String] = []
}

let snapshot = person.detached()   // value copy, independent of later writes
```

Serialization of model graphs goes through `@Detached` — managed `List`
does not conform to `Codable`.

## Transient properties

`@Transient` marks a property that lives on the instance only and is never
persisted to a column.

## Polymorphic queries

Model types that share a protocol refining `VirtualModel` can be queried
together — filters and even federated vector search run across every
conforming table:

```swift
protocol POI: VirtualModel {
    var name: String { get }
    var country: String { get }
}

@Model class Restaurant: POI { /* … */ }
@Model class Museum: POI { /* … */ }

let frenchPOIs = lattice.objects(POI.self).where {
    $0.country == "France"
}
```

## Migrations

A table is identified by its model type's *name*, so schema versions are
declared as same-named models inside version namespaces, and migrations are
keyed by version number:

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

The variadic `Migration((from:to:), blocks:)` initializer uses parameter
packs (iOS 17+). On iOS 15/16 use the equivalent pack-free builder,
available everywhere:

```swift
let migration = Migration().add(from: SchemaV1.Person.self, to: SchemaV2.Person.self) { old, new in
    new.fullName = "\(old.firstName) \(old.lastName)"
}
```
