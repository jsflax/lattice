# ``Lattice``

A modern, type-safe Swift ORM built on SQLite, with real-time
synchronization, cross-process sync, and SwiftUI integration.

## Overview

Lattice stores Swift classes annotated with the `@Model` macro in SQLite and
layers a complete data stack on top:

- **Type-safe queries** — compile-time-validated predicates
  (`.where { $0.age >= 18 }`), sorting, string and range operations, and
  queries over embedded properties.
- **Live results** — ``TableResults`` collections stay current as the
  database changes, with generation-consistent reads: everything one render
  batch sees comes from a single database snapshot.
- **Real-time sync** — WebSocket-based synchronization across devices, with
  per-table filtered upload. See <doc:Sync>.
- **Cross-process sync** — databases in different processes synchronize over
  Unix domain sockets, composable with cloud sync for relay topologies. See
  <doc:IPC>.
- **SwiftUI integration** — the ``LatticeQuery`` property wrapper binds live
  query results directly into a view. See <doc:ObservationAndSwiftUI>.
- **Search** — FTS5 full-text search, ANN vector similarity search
  (sqlite-vec), and R\*Tree geospatial queries, all composable with ordinary
  filters.

```swift
import Lattice

@Model final class Person {
    var name: String
    var age: Int
}

let lattice = try Lattice(Person.self)

let person = Person()
person.name = "Alice"
person.age = 30
try lattice.add(person)

let adults = lattice.objects(Person.self).where { $0.age >= 18 }
```

Upgrading from 0.10.x? Several core signatures changed in 1.0 — the `add`
family and `attach`/`detach` throw, `Configuration.storage` replaces
`isStoredInMemoryOnly`, and `changeStream` is a throwing stream. The
repository's `MIGRATION-1.0.md` is the complete one-line-per-change ledger;
the `CHANGELOG.md` 1.0.0 section carries the same pointers in prose.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:PlatformSupport>

### Defining your data

- <doc:ModelingData>

### Observation

- <doc:ObservationAndSwiftUI>

### Synchronization

- <doc:Sync>
- <doc:IPC>
