# Lattice - Swift ORM with Sync

Swift ORM built on SQLite with a C++ backend (LatticeCore). Uses Swift macros for compile-time code generation.

## Architecture Context

Use the memory MCP server (`recall` with project "Lattice") to load architecture details, file layouts, patterns, and prior decisions. Do not rely on stale inline documentation.

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

### Testing

Use `testLattice` helper or in-memory config:
```swift
let lattice = try testLattice(path: "\(String.random(length: 32)).sqlite", MyModel.self)
// or
let lattice = try Lattice(MyModel.self, configuration: .init(isStoredInMemoryOnly: true))
```

Run tests: `swift test` or `swift test --filter testName`
