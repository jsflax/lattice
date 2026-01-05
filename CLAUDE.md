# Lattice - Swift ORM with Sync

## Overview
Lattice is a Swift-based Object-Relational Mapping (ORM) library built on SQLite with built-in sync capabilities. It uses Swift macros for compile-time code generation and provides a Realm-like API.

**Current Architecture**: Swift frontend with C++ backend (LatticeCpp) for core database operations.

---

## ⚠️ CRITICAL: Coding Rules for AI Agents

### The Core Principle: SQL First, Swift Last

**Priority order for implementing features:**
1. **SQL** - Do it in a query if possible
2. **C++ (LatticeCpp)** - If SQL alone can't do it, add C++ code
3. **Swift** - Only for type-safe API, macros, and UI integration

**Why:**
- SQLite is extremely optimized - let it do the work
- C++ runs once per query; Swift per-object is N times slower
- Fetching 1000 objects to filter 10 in Swift is wrong; filter in SQL

**Example - Filtering:**
```swift
// WRONG: Filter in Swift (fetches ALL objects, filters in memory)
let results = lattice.objects(Trip.self)
let expensive = results.filter { $0.cost > 1000 }  // O(n) Swift iterations

// RIGHT: Filter in SQL (database does the work)
let cheap = results.where { $0.cost > 1000 }  // WHERE clause, O(1) Swift
```

**Example - Counting:**
```swift
// WRONG: Count in Swift
let count = Array(lattice.objects(Trip.self)).count  // Fetches all objects

// RIGHT: Count in SQL
let count = lattice.objects(Trip.self).count  // SELECT COUNT(*) via C++
```

**Example - Sorting:**
```swift
// WRONG: Sort in Swift
let sorted = lattice.objects(Trip.self).snapshot().sorted { $0.name < $1.name }

// RIGHT: Sort in SQL
let sorted = lattice.objects(Trip.self).sortedBy(.init(\.name, order: .forward))
```

**Example - Pagination:**
```swift
// WRONG: Fetch all then slice
let all = lattice.objects(Trip.self).snapshot()
let page = Array(all[10..<20])

// RIGHT: Let SQL paginate (LIMIT/OFFSET)
let page = lattice.objects(Trip.self).snapshot(limit: 10, offset: 10)
```

### When to Add C++ Code

Add to LatticeCpp when you need:
- New SQL query patterns (JOINs, subqueries, aggregates)
- New SQLite extensions (FTS, R*Tree, vec0)
- Complex multi-step operations that should be atomic
- Performance-critical paths

**Example - Combined Proximity Query:**
Instead of fetching all objects and computing distances in Swift, we added `combinedNearestQuery()` to C++ which:
- Joins main table with vec0 virtual table
- Filters by R*Tree bounds
- Computes distances in SQL
- Returns only the K nearest results

### When to Add Swift Code

Keep in Swift:
- Type-safe API wrappers around C++ calls
- Macro-generated code for @Model
- Observer delivery to correct isolation context
- Hydrating C++ results into Swift model instances

---

## Deep Architecture Understanding

### Rule 1: Lattice is a Struct with Shared C++ State

```swift
// Lattice wraps a C++ reference - NOT an actor
public struct Lattice {
    let cxxLatticeRef: lattice.swift_lattice_ref  // Shared C++ connection
    var cxxLattice: lattice.swift_lattice { cxxLatticeRef.get() }
}
```

**Implications:**
- Database operations are **synchronous** (no await needed)
- Multiple Swift `Lattice` instances can share the same C++ connection (cached by path)
- `isolation` is captured for **observer callbacks only**, not execution context
- Copies of Lattice all point to same underlying database

### Rule 2: Results are LIVE Queries

Every access to `Results<T>` fetches fresh from database:

```swift
let results = lattice.objects(Trip.self)
print(results.count)   // Calls C++ count() - hits database
print(results.count)   // Calls C++ count() AGAIN - another database hit

for trip in results {  // Fetches in batches of 100 (Cursor pattern)
    print(trip.name)
}
```

**Implications:**
- Don't iterate the same Results multiple times without caching
- Use `snapshot()` if you need a stable array: `let trips = results.snapshot()`
- Batch iteration is already optimized (100-item batches via Cursor)
- `endIndex` is expensive (calls count)

### Rule 3: The KeyPath Tracking Trick

Query DSL works by tracking last accessed property:

```swift
// How it works internally:
let query = Query<Trip>()
let predicate: Query<Bool> = query.name == "Costa Rica"
// Accessing query.name sets trip._lastKeyPathUsed = "name"
// Then == builds predicate string: "name = 'Costa Rica'"
```

**Implications:**
- Every @Model has `_lastKeyPathUsed: String?` (macro-generated)
- Query closures access properties to capture their names
- This is why `$0.name == "X"` works - it's not a real keypath

### Rule 4: Schema Discovery is Recursive

Only pass root types - linked types discovered automatically:

```swift
// Trip has: var destinations: List<Destination>
// Destination has: var activities: List<Activity>

let lattice = try Lattice(Trip.self)
// Automatically discovers: [Trip, Destination, Activity]
```

### Rule 5: C++ Type Mapping

| Swift Type | C++ Managed Type | SQL Storage |
|------------|------------------|-------------|
| `String` | `ManagedString` | TEXT |
| `Int`, `Int64` | `ManagedInt` | INTEGER |
| `Bool` | `ManagedBool` | INTEGER (0/1) |
| `Float` | `ManagedFloat` | REAL |
| `Double` | `ManagedDouble` | REAL |
| `Date` | `ManagedDate` | REAL (timeInterval) |
| `UUID` | `ManagedString` | TEXT |
| `Data` | `ManagedData` | BLOB |
| `Vector<Float>` | `ManagedData` | BLOB + vec0 table |
| `[String]` | `ManagedStringList` | TEXT (JSON) |
| `[String: String]` | `ManagedStringMap` | TEXT (JSON) |
| `Optional<Model>` | Link column | INTEGER (FK) |
| `List<Model>` | Junction table | Separate table |
| `Geobounds` | 4 columns | REAL × 4 + R*Tree |

### Rule 6: Results Hierarchy

```
Results<Element> (protocol)
├── TableResults<T: Model>           - Single table queries
├── _VirtualResults<each M, Element> - Polymorphic UNION queries
├── TableNearestResults<T: Model>    - Proximity search
└── _VirtualNearestResults<each M, T> - Polymorphic proximity
```

**Execution path:**
1. Swift builds WHERE/ORDER BY as strings
2. Swift encodes constraints (vectors, bounds) as structured data
3. Swift calls C++ function with table name + constraints
4. **C++ generates and executes SQL** ← work happens here
5. C++ returns `vector<dynamic_object>` or distance results
6. Swift wraps results in Model types

### Rule 7: VirtualModel / Polymorphic Queries

```swift
protocol POI: VirtualModel {
    var name: String { get }
}

@Model class Restaurant: POI { ... }
@Model class Museum: POI { ... }

// C++ executes UNION ALL with optimized pagination
let allPOIs = lattice.objects(POI.self)
```

**SQL generated by C++:**
```sql
SELECT * FROM (
    SELECT * FROM (SELECT 'Restaurant' AS _type, * FROM Restaurant
                   WHERE ... ORDER BY name LIMIT 30)
    UNION ALL
    SELECT * FROM (SELECT 'Museum' AS _type, * FROM Museum
                   WHERE ... ORDER BY name LIMIT 30)
)
ORDER BY name LIMIT 10 OFFSET 20
```

### Rule 8: Testing Patterns

**Always use testLattice helper:**
```swift
@Test func test_Something() throws {
    let lattice = try testLattice(path: "\(String.random(length: 32)).sqlite",
                                  MyModel.self)
}
```

**For fast in-memory tests:**
```swift
let lattice = try Lattice(MyModel.self,
                          configuration: .init(isStoredInMemoryOnly: true))
```

---

## File-Specific Guidelines

### Lattice.swift (~1100 lines)
- Entry point, Configuration, WebSocket, observers
- **Don't add query logic here** - delegate to C++ or Results

### Model.swift
- Protocol definition, macro declarations
- `cxxPropertyDescriptor()` builds schema for C++
- **Extend for new property types**

### Results/*.swift
- TableResults: Single-table → C++ `objects()`
- VirtualResults: UNION → C++ `union_objects()`
- NearestResults: Proximity → C++ `combinedNearestQuery()`
- **Add new query methods here**

### Accessor.swift (~700 lines)
- CxxManaged conformances for type bridging
- **Add new type support here**

### LatticeCpp (external)
- **Add new SQL patterns here**
- Optimize queries with proper indexing
- Keep Swift layer thin

---

## Project Structure

```
Lattice/
├── Sources/
│   ├── Lattice/              # Swift ORM API (delegates to C++ backend)
│   ├── LatticeMacros/        # Swift macro implementations (@Model, @Property, etc.)
│   └── LatticeServerKit/     # Server-side sync infrastructure
├── Tests/
│   └── LatticeTests/         # Unit tests
└── Package.swift             # References LatticeCpp as local dependency
```

**Related**: LatticeCpp at `/Users/jason/Documents/LatticeCpp/` - Core C++ implementation

## Key Architecture Decisions

### 1. **C++ Backend Integration**
- Core database operations delegated to `LatticeCpp` via Swift-C++ interop
- `swift_lattice_ref` wrapper uses `SWIFT_SHARED_REFERENCE` for memory management
- `swift_dynamic_object` for type-erased model storage from Swift
- `managed<swift_dynamic_object>` (aliased as `ManagedModel`) for managed objects
- Schemas passed from Swift to C++ at init time for table creation

### 2. **Struct-Based Design (Not Actor)**
- `Lattice` is a **struct**, not an actor
- Wraps `swift_lattice_ref` which holds `shared_ptr<swift_lattice>`
- Connection caching by config path in C++ layer
- Isolation tracking is for **notification delivery**, not execution context

### 3. **Macro-Based Property System**
- `@Model` macro generates schema metadata and property accessors
- Properties use `Accessor<T>` wrappers for change tracking
- `CxxManaged` protocol for Swift ↔ C++ value conversion
- All macros in `Sources/LatticeMacros/LatticeMacros.swift`

### 4. **Schema Management**
- Schemas built in Swift via `Model.cxxPropertyDescriptor()`
- Passed to C++ as `SchemaVector` at `Lattice` init time
- Tables created by C++ `create_model_table_public()`
- `id` and `globalId` filtered out in Swift (auto-added by C++)
- `discoverAllTypes(from:)` recursively finds linked Model types

### 5. **Results (Live Queries)**
- `Results<T>` always fetches fresh data from database
- `endIndex` calls C++ `count()` method
- Subscript/iteration calls C++ `objects()` with limit/offset
- No caching - queries are "live"

### 6. **Reserved Property Names**
- `id` and `globalId` are reserved (auto-generated by Lattice)
- Macro validation prevents users from using these names
- Filtered out in `cxxPropertyDescriptor()` to avoid duplicate columns

### 7. **VirtualModel (Polymorphic Queries)**
- `VirtualModel` protocol enables querying across multiple model types
- Models conforming to a shared protocol can be queried together
- Uses UNION ALL queries under the hood with optimized pagination
- Type-safe: `lattice.objects(POI.self)` returns `VirtualResults<POI>`
- Results hydrate back to concrete types (Restaurant, Museum, etc.)
- Implementation uses variadic generics with compile-time type building
- Key files: `VirtualModel.swift`, `Schema` struct in `Lattice.swift`

### 8. **Database Attachment**
- `lattice.attach(lattice:)` attaches another database file
- Uses SQLite's `ATTACH DATABASE` with automatic alias generation
- Creates TEMP VIEWs to hide the alias prefix for transparent querying
- Attached tables participate in VirtualModel/polymorphic queries
- Both read and write connections are attached
- Implementation in C++: `swift_lattice::attach()`

### 9. **Vector Search**
- Built on sqlite-vec extension for ANN (Approximate Nearest Neighbor) search
- Each Vector property gets a vec0 virtual table: `_{Table}_{column}_vec`
- Triggers auto-sync vectors from main table to vec0
- Supports L2 (Euclidean), Cosine, and L1 (Manhattan) distance metrics
- `Results.nearest(to:on:limit:distance:)` API for similarity search
- Federated vector search for VirtualModel queries (queries each vec0, merges results)

## Current State

### Completed Features
- ✅ Basic CRUD operations via C++ backend
- ✅ Query DSL with type-safe predicates
- ✅ Relationships (links, link lists)
- ✅ Embedded models
- ✅ Observable results (table-level and AuditLog)
- ✅ Automatic schema discovery from root types
- ✅ Schema passing to C++ at init
- ✅ Table creation in C++ layer
- ✅ Vector search with sqlite-vec (L2, Cosine, L1 distances)
- ✅ VirtualModel / Polymorphic queries with variadic generics
- ✅ Database attachment (ATTACH DATABASE with TEMP VIEWs)
- ✅ UNION queries with optimized pagination
- ✅ Federated vector search across VirtualModel types
- ✅ Geobounds with R*Tree spatial indexing
- ✅ Chainable NearestResults API (vector + geo + bounds)
- ✅ Combined proximity queries (multiple constraints)
- ✅ Schema migration system with row callbacks
- ✅ Unique constraints with upsert support
- ✅ WebSocket sync client with scheduler injection
- ✅ ThreadSafeReference for cross-isolation passing

### Pending Work
- ⏳ AuditLog compaction (reduce sync payload size)
- ⏳ Full sync server implementation

## Swift-C++ Interop

### Key Types
```
Swift                          C++
─────                          ───
Lattice                   →    swift_lattice_ref (wrapper)
                          →    swift_lattice (inherits lattice_db)
Model (protocol)          →    swift_dynamic_object
ManagedModel              →    managed<swift_dynamic_object>
lattice.SchemaVector      →    std::vector<swift_schema_entry>
lattice.SwiftSchema       →    std::unordered_map<string, property_descriptor>
```

### Memory Management
- `swift_lattice_ref` uses `SWIFT_SHARED_REFERENCE` with retain/release
- Internal `shared_ptr<swift_lattice>` cached by config path
- `ref_count_` starts at 0 (Swift calls retain on creation)

### Union Query Implementation
```cpp
// C++ generates optimized UNION ALL with pagination
query_union_rows(table_names, where_clause, order_by, limit, offset)

// Generates SQL like:
SELECT * FROM (
    SELECT * FROM (SELECT 'Restaurant' AS _type, * FROM Restaurant
                   WHERE ... ORDER BY name LIMIT 30)  -- inner_limit = offset + limit
    UNION ALL
    SELECT * FROM (SELECT 'Museum' AS _type, * FROM Museum
                   WHERE ... ORDER BY name LIMIT 30)
)
ORDER BY name LIMIT 10 OFFSET 20
```

### Database Attachment (C++)
```cpp
void swift_lattice::attach(swift_lattice& other) {
    // ATTACH DATABASE 'path' AS "alias"
    // Create TEMP VIEWs for each table to hide alias prefix
    // Attaches to both read and write connections
}
```

## Testing

Run tests:
```bash
swift test                              # All tests
swift test --filter test_Basic          # Specific test
swift test --filter testLattice_ResultsQuery
```

### Test Utilities
- `testLattice(path:types...)` - Creates temporary database with fresh schema
- Always use temporary DB in tests to avoid schema conflicts

## Important Notes

### Database Schema
- Tables created by C++ `create_model_table()` at init
- Every table gets `id INTEGER PRIMARY KEY` and `globalId TEXT UNIQUE`
- Audit triggers created for sync/observation
- WAL mode for concurrent access

### Isolation & Threading
- Isolation captured via `isolated (any Actor)? = #isolation` parameter
- Used for dispatching observer notifications to correct context

### Sync Protocol
- Client-side: `AuditLog` tracks changes, uploads via `Synchronizer`
- Server-side: `LatticeServerKit` receives changes, broadcasts to other clients
- Conflict resolution: Last-write-wins (timestamp-based)

## Common Patterns

### Defining a Model
```swift
@Model
public class Trip {
    public var name: String
    public var days: Int
    public var destinations: List<Destination>

    init(name: String, days: Int) {
        self.name = name
        self.days = days
    }
}
```

### Using Lattice
```swift
let lattice = try Lattice(Trip.self)  // Auto-discovers linked types

let trip = Trip(name: "Costa Rica", days: 10)
lattice.add(trip)

let trips = lattice.objects(Trip.self)
for trip in trips {
    print(trip.name)
}
```

### Observing Changes
```swift
let results = lattice.objects(Trip.self)
let token = results.observe { change in
    // Called on specified isolation
}
```

### Polymorphic Queries (VirtualModel)
```swift
// Define protocol extending VirtualModel
protocol POI: VirtualModel {
    var name: String { get }
    var country: String { get }
}

@Model class Restaurant: POI { ... }
@Model class Museum: POI { ... }

// Query across all conforming types
let allPOIs = lattice.objects(POI.self)
let frenchPOIs = lattice.objects(POI.self).where { $0.country == "France" }

// Cast back to concrete type
if let museum = frenchPOIs.first as? Museum { ... }
```

### Database Attachment
```swift
var lattice1 = try Lattice(Restaurant.self)
let lattice2 = try Lattice(Museum.self)

lattice1.attach(lattice: lattice2)

// Now lattice1 can query both Restaurant and Museum
let allPOIs = lattice1.objects(POI.self)  // Queries across both DBs
```

### Vector Search
```swift
// Single model vector search
let similar = lattice.objects(Document.self)
    .nearest(to: queryVector, on: \.embedding, limit: 10, distance: .cosine)

// With filtering
let filtered = lattice.objects(Document.self)
    .where { $0.category == "science" }
    .nearest(to: queryVector, on: \.embedding, limit: 10)

// Polymorphic vector search (federated across tables)
let similarPOIs = lattice.objects(POI.self)
    .nearest(to: locationVector, on: \.embedding, limit: 10)
```
