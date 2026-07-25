# Lattice - Swift ORM with Sync

Swift ORM built on SQLite with a C++ backend (LatticeCore). Uses Swift macros for compile-time code generation.

Swift 6.3+ toolchain / macOS 14+ / iOS 15+ / Linux (Ubuntu 24.04+). C++ interop enabled on all targets.

## Architecture

- **LatticeCore** (local dep at `../LatticeCore`): C++ SQLite backend, schema management, sync, audit log
- **Lattice** (`Sources/Lattice/`): Swift API — models, queries, results, migrations, SwiftUI integration
- **LatticeMacros** (`Sources/LatticeMacros/`): `@Model` macro + attribute macros (`@Unique`, `@Transient`, `@FullText`, `@Indexed`)
- **LatticeServerKit** (`Sources/LatticeServerKit/`): Vapor integration with OAuth/JWT auth

Use the memory MCP server (`recall` with project "Lattice") for deeper architecture details and prior decisions.

## Coding Rules

### SQL First, Swift Last

Priority order for implementing features:
1. **SQL** - Do it in a query if possible
2. **C++ (LatticeCore)** - If SQL alone can't do it, add C++ code
3. **Swift** - Only for type-safe API, macros, and UI integration

SQLite is extremely optimized - let it do the work. C++ runs once per query; Swift per-object is N times slower.

```swift
// WRONG: Filter/sort/count in Swift
let expensive = results.filter { $0.cost > 1000 }
let sorted = results.snapshot().sorted { $0.name < $1.name }
let count = Array(results).count

// RIGHT: Push to SQL
let cheap = results.where { $0.cost > 1000 }
let sorted = results.sortedBy(.init(\.name, order: .forward))
let count = results.count
```

### Key APIs

Models use the `@Model` macro. Property attributes: `@Unique`, `@Unique(compoundedWith:)`, `@Indexed`, `@Transient`, `@FullText`.

```swift
@Model final class Person {
    @Indexed var name: String = ""
    @Unique var email: String = ""
    var age: Int = 0
    var dog: Dog?          // Optional<Model> = link (one-to-one)
    var tags: [String] = [] // embedded array
}
```

Lattice init — variadic parameter pack for model types:
```swift
let lattice = try Lattice(Person.self, Dog.self, configuration: .init(fileURL: url))
```

Migration lives inside `Configuration`. A table is identified by its model
type's *name*, so schema versions are same-named models in version namespaces
(NOT differently-named types like `V1Person`/`V2Person` — those would be
different tables):
```swift
enum SchemaV1 { @Model class Person { var firstName: String; var lastName: String } }
enum SchemaV2 { @Model class Person { var fullName: String } }

let config = Lattice.Configuration(fileURL: url, migration: [
    2: Migration((from: SchemaV1.Person.self, to: SchemaV2.Person.self), blocks: { old, new in
        new.fullName = "\(old.firstName) \(old.lastName)"
    })
])
let lattice = try Lattice(SchemaV2.Person.self, configuration: config)
```

### Testing

Tests use a `BaseTest` class with a `testLattice` helper that writes to temp dir and cleans up:
```swift
class MyTests: BaseTest {
    @Test func testSomething() async throws {
        let lattice = try testLattice(MyModel.self)
        // or with migration:
        let lattice = try testLattice(V2Model.self, migration: [2: Migration(...)])
    }
}
```

In-memory alternative (no BaseTest needed):
```swift
let lattice = try Lattice(MyModel.self, configuration: .init(storage: .memory()))
```
`.memory()` is a fresh private database; `.memory(named:)` shares one
same-process database across handles opened with the same name.

Run tests: `swift test` or `swift test --filter testName`

### Sync

WSS sync connects to a WebSocket relay server:
```swift
let config = Lattice.Configuration(
    fileURL: url,
    authorizationToken: token,
    wssEndpoint: URL(string: "wss://server/sync"))
```

IPC sync connects databases across processes via Unix domain sockets. Roles
are negotiated at runtime (first process to open a channel serves; later ones
connect). `ipcTargets` is a mutable property, not an initializer parameter:
```swift
// Hub process (serves filtered data)
var filter = Lattice.SyncFilter()
filter.include(Memory.self, where: { $0.isPrivate == false })

var sourceConfig = Lattice.Configuration(fileURL: memoryURL)
sourceConfig.ipcTargets = [.init(channel: "synced", syncFilter: filter)]

// Spoke process (same channel name, plus WSS to cloud)
var targetConfig = Lattice.Configuration(
    fileURL: syncedURL,
    authorizationToken: token,
    wssEndpoint: wssURL)
targetConfig.ipcTargets = [.init(channel: "synced")]
```

IPC + WSS compose for cloud relay: `source →IPC→ target →WSS→ server`. Per-synchronizer state (`_lattice_sync_state` table) tracks sync status independently per transport, enabling automatic relay without loop prevention logic.
