# Sources/Lattice - Core ORM Implementation

## Overview
This directory contains the core Lattice ORM implementation. All database operations, model management, querying, and sync coordination happen here.

## Key Files

### Core Database Layer
- **Lattice.swift** - Main entry point, database initialization, table creation
  - `Lattice` struct wraps `SharedDBPointer` (shared DB connection)
  - `latticeIsolationRegistrar` - Caches database instances per isolation context
  - `discoverAllTypes(from:)` - Automatic schema discovery (lines 684-715)
  - Table creation logic (lines 344-346)
  
- **DatabaseConnection.swift** - SQLite connection management
  - Wrapper around raw SQLite3 C API
  - Prepared statement caching
  - Transaction support

- **LatticeActor.swift** - Actor-isolated database operations
  - Experimental: Not currently used
  - May be relevant for future isolation improvements

### Model System
- **Model.swift** - Base protocol for all models
  - `Model` protocol defines requirements for types that can be persisted
  - Schema metadata (`properties`, `tableName`)
  - Object lifecycle hooks
  
- **EmbeddedModel.swift** - Models that exist only within parent objects
  - Cannot be queried directly
  - Always part of another model
  - Examples: Coordinates, DateRange

- **Accessor.swift** - Property wrapper for change tracking
  - All `@Property` fields become `Accessor<T>`
  - Intercepts reads/writes to track changes
  - Stores values in model's backing storage
  - **Important**: Non-optional EmbeddedModel/LatticeEnum require default values (TODO: fix this)

### Collections & Relationships
- **List.swift** - Ordered collection of models (one-to-many relationships)
  - Similar to `Array` but persisted
  - Lazy loading from database
  - Observable changes
  
- **LinkProperty.swift** - Protocol for link types
  - Implemented by `Optional<Model>` and `List<Model>`
  - Provides `modelType` for schema discovery
  - Used by automatic schema discovery

### Query System
- **Query.swift** - Type-safe query DSL
  - `Query<T>` represents a database query
  - Predicate building (`.where()`, `.sorted()`, `.limit()`)
  - Executed lazily via `Results<T>`
  
- **Results.swift** - Query results container
  - Live results that update automatically
  - Observable via `observe(_:)`
  - Efficient iteration (doesn't load all into memory)
  
- **Cursor.swift** - Low-level result iteration
  - Wraps SQLite statement cursor
  - Deserializes rows into models
  - Used internally by `Results<T>`

### Change Tracking & Sync
- **AuditLog.swift** - Mutation tracking for sync
  - Every insert/update/delete creates audit entry
  - Records: operation, table, rowId, globalRowId, changedFields
  - Timestamps for conflict resolution
  - **TODO**: Implement compaction to reduce payload size
  
- **Sync.swift** - Synchronization coordinator
  - `Synchronizer` actor manages sync lifecycle
  - Polls server for remote changes
  - Uploads local changes from AuditLog
  - Conflict resolution (last-write-wins)
  
- **ThreadSafeReference.swift** - Cross-isolation object passing
  - `ModelThreadSafeReference<T>` allows passing model references across actors
  - Resolves back to live object in target isolation context
  - Similar to Realm's ThreadSafeReference

### SwiftUI Integration
- **SwiftUI.swift** - SwiftUI helpers
  - Property wrappers for observing Lattice objects in views
  - May include `@ObservedResults` or similar

## Property Subdirectory
See `Property/CLAUDE.md` for details on property type implementations:
- `PrimitiveProperty.swift` - Int, String, Bool, Date, etc.
- `LinkProperty.swift` - Model references and lists
- `Property.swift` - Base property protocol

## Architectural Patterns

### Isolation Pattern
```swift
// Isolation is captured but Lattice itself is NOT an actor
let lattice = try Lattice(Trip.self)  // Captures #isolation implicitly

// Database operations happen synchronously (writes to SQLite)
lattice.add(trip)

// Observers are notified on captured isolation context
results.observe { trips in
    // This runs on the isolation where Lattice was created
    // Typically MainActor for UI updates
}
```

### Schema Discovery
```swift
// Old way (manual)
let lattice = try Lattice(Trip.self, Destination.self, TransportLeg.self)

// New way (automatic)
let lattice = try Lattice(Trip.self)  // Discovers Destination, TransportLeg via links

// How it works:
// 1. discoverAllTypes(from:) starts with [Trip.self]
// 2. Inspects Trip.properties for LinkProperty types
// 3. Extracts linked model types (Destination, TransportLeg)
// 4. Recursively processes those types
// 5. Returns complete schema
```

### Change Tracking Flow
```
User modifies property
    ↓
Accessor<T>.set() called
    ↓
Updates in-memory value
    ↓
Marks field as changed
    ↓
On transaction commit:
    ↓
AuditLog entry created
    ↓
Synchronizer picks up change
    ↓
Uploads to server
```

## Common Operations

### Add/Update/Delete
```swift
// Add
let trip = Trip(name: "Costa Rica")
lattice.add(trip)  // INSERT INTO Trip ...

// Update
lattice.write {
    trip.name = "Costa Rica Adventure"  // UPDATE Trip SET name = ...
}

// Delete
lattice.delete(trip)  // DELETE FROM Trip WHERE id = ...
```

### Querying
```swift
// All objects
let all = lattice.objects(Trip.self)

// Filtered
let filtered = lattice.objects(Trip.self)
    .where { $0.days > 5 }
    .sorted(by: \.name)

// Access results
for trip in filtered {
    print(trip.name)
}
```

### Observation
```swift
let results = lattice.objects(Trip.self)
let token = results.observe { trips in
    updateUI(trips)
}
// Token must be retained, observation stops when token is deallocated
```

## Important Notes

### Testing
- Always use `testLattice(path:types...)` helper in tests
- Creates temporary database with random filename
- Ensures fresh schema without conflicts
- Example: `Tests/LatticeTests/PropertyTests.swift:22-40`

### Reserved Names
- Never use `id` or `globalId` as property names
- These are auto-generated by Lattice
- Macro will emit diagnostic error at compile time
- See `LatticeMacros.swift:366-378`

### SQLite Pragmas
- `foreign_keys = ON` - Enforces referential integrity
- `journal_mode = WAL` - Write-Ahead Logging for concurrency
- `cache_size = 50000` - Large cache for performance
- `mmap_size = 300000000` - Memory-mapped I/O
- `temp_store = MEMORY` - Temp tables in RAM

## Future Improvements

### Planned
1. **AuditLog Compaction** - Reduce sync payload by:
   - Coalescing multiple changes to same field
   - Removing DELETE entries for re-created objects
   - Squashing intermediate states

2. **Accessor Init Fix** - Allow non-optional EmbeddedModel without default:
   ```swift
   @Model
   class Trip {
       var region: MKCoordinateRegion  // Currently requires = .init()
   }
   ```

3. **Type Inference** - Infer property types from defaults:
   ```swift
   @Property var days = 5  // Should infer Int without explicit annotation
   ```

### C++ Port Considerations
- Current Swift design maps well to C++ with macros
- `Accessor<T>` → `managed<T>` (like realm-cpp)
- `LATTICE_SCHEMA(Trip, name, days)` macro pattern
- Scheduler injection for cross-platform concurrency
