# Lattice - Swift ORM with Sync

Swift ORM built on SQLite with a C++ backend (LatticeCore). Uses Swift macros for compile-time code generation.

Swift 6.2+ / macOS 14+ / iOS 17+. C++ interop enabled on all targets.

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

Migration lives inside `Configuration`:
```swift
let config = Lattice.Configuration(fileURL: url, migration: [
    2: Migration((from: V1Person.self, to: V2Person.self), blocks: { old, new in
        new.fullName = "\(old.firstName) \(old.lastName)"
    })
])
let lattice = try Lattice(V2Person.self, configuration: config)
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
let lattice = try Lattice(MyModel.self, configuration: .init(isStoredInMemoryOnly: true))
```

Run tests: `swift test` or `swift test --filter testName`
