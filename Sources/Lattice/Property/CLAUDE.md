# Sources/Lattice/Property - Property Type System

## Overview
This directory contains the property type system that bridges Swift types to SQLite storage. Each supported type has a `LatticeProperty` conformance that defines how it's stored and retrieved.

## Files

### Property.swift
- **`LatticeProperty` protocol** - Core protocol for all persistable types
  - `static var type: PropertyType` - SQLite type (integer, text, real, blob)
  - `static func toDatabase(_:)` - Convert Swift value → SQLite value
  - `static func fromDatabase(_:)` - Convert SQLite value → Swift value
  - `static var sqlType: String` - SQL type declaration

- **`PropertyType` enum** - Maps to SQLite types
  - `.integer` - INTEGER
  - `.text` - TEXT
  - `.real` - REAL
  - `.blob` - BLOB

### PrimitiveProperty.swift
Conformances for basic Swift types:
- **Numeric**: Int, Int8, Int16, Int32, Int64, UInt, UInt8, UInt16, UInt32, UInt64, Float, Double
- **String**: String
- **Bool**: Bool (stored as INTEGER 0/1)
- **Date**: Date (stored as REAL, Unix timestamp)
- **Data**: Data (stored as BLOB)
- **UUID**: UUID (stored as TEXT)

All primitive types conform to `LatticeProperty` and handle:
- NULL handling for Optional<T>
- Type conversion to/from SQLite C API types
- SQL type declarations for CREATE TABLE

### LinkProperty.swift
- **`LinkProperty` protocol** - For types that reference other models
  - Extends `LatticeProperty`
  - Adds `static var modelType: any Model.Type` - Returns linked model type
  - Used by automatic schema discovery to find relationships

- **Conformances**:
  - `Optional<Model>` - To-one relationship (nullable foreign key)
  - `Array<Model>` (via extension) - Marker for to-many (actual impl in List.swift)

**Key Insight**: This protocol is what enables automatic schema discovery. When scanning a model's properties, Lattice checks if each property type conforms to `LinkProperty`, and if so, extracts the `modelType` to recursively discover linked types.

### ListProperty.swift
- Likely handles `List<T>` property type (though actual List type is in `../List.swift`)
- May contain serialization logic for lists
- **TODO**: Verify contents and update this doc

## Type Mapping

| Swift Type | SQLite Type | Storage Format |
|------------|-------------|----------------|
| Int, Int64, etc. | INTEGER | Native integer |
| String | TEXT | UTF-8 text |
| Double, Float | REAL | Floating point |
| Bool | INTEGER | 0 (false) or 1 (true) |
| Date | REAL | Unix timestamp (seconds since epoch) |
| Data | BLOB | Raw bytes |
| UUID | TEXT | String representation |
| Optional<T> | Same as T | NULL if nil |
| Model | INTEGER | Foreign key (id of linked object) |
| List<Model> | N/A | Separate junction table |

## How Properties Work

### 1. Model Definition
```swift
@Model
class Trip {
    @Property var name: String
    @Property var days: Int
    @Property var startDate: Date
}
```

### 2. Macro Expansion
The `@Property` macro wraps each field in an `Accessor<T>`:
```swift
class Trip {
    var name: Accessor<String>
    var days: Accessor<Int>
    var startDate: Accessor<Date>
}
```

### 3. Property Registration
The `@Model` macro generates schema metadata:
```swift
extension Trip {
    static var properties: [(String, any LatticeProperty.Type)] {
        [
            ("name", String.self),
            ("days", Int.self),
            ("startDate", Date.self)
        ]
    }
}
```

### 4. Table Creation
When creating tables, Lattice uses `LatticeProperty.sqlType`:
```sql
CREATE TABLE Trip (
    id INTEGER PRIMARY KEY,
    globalId TEXT UNIQUE,
    name TEXT,
    days INTEGER,
    startDate REAL
)
```

### 5. Value Storage
When writing values, Lattice uses `LatticeProperty.toDatabase(_:)`:
```swift
// User code
trip.name = "Costa Rica"

// Internally
let sqlValue = String.toDatabase("Costa Rica")  // Returns string as-is
sqlite3_bind_text(statement, index, sqlValue, ...)
```

### 6. Value Retrieval
When reading values, Lattice uses `LatticeProperty.fromDatabase(_:)`:
```swift
// Reading from SQLite
let columnValue = sqlite3_column_text(statement, index)
let swiftValue = String.fromDatabase(columnValue)  // Returns String

// User code sees
let name = trip.name  // "Costa Rica"
```

## Relationships

### To-One (Optional<Model>)
```swift
@Model
class Trip {
    @Property var destination: Destination?
}
```

**Storage**:
- Column: `destination INTEGER` (foreign key)
- NULL if no link
- References `Destination.id` when set

**Schema Discovery**:
- `Optional<Destination>` conforms to `LinkProperty`
- `modelType` returns `Destination.self`
- Lattice auto-discovers `Destination` schema

### To-Many (List<Model>)
```swift
@Model
class Trip {
    @Property var destinations: List<Destination>
}
```

**Storage**:
- Not stored in Trip table
- Separate junction/relationship table
- Managed by `List<T>` type in `../List.swift`

**Schema Discovery**:
- `List<Destination>` conforms to `LinkProperty`
- `modelType` returns `Destination.self`
- Lattice auto-discovers `Destination` schema

## EmbeddedModel Handling

EmbeddedModel types (like `MKCoordinateRegion`) are serialized as JSON/BLOB:
```swift
extension MKCoordinateRegion: EmbeddedModel {
    // Conforms to Codable
}

// In model
@Model
class Destination {
    @Property var region: MKCoordinateRegion
}

// Storage
CREATE TABLE Destination (
    ...
    region BLOB  -- JSON-encoded MKCoordinateRegion
)
```

**Current Issue**: EmbeddedModel properties require default values even when set in init. See TODO in todo list.

## Adding New Property Types

To add support for a new type:

1. Conform to `LatticeProperty`:
```swift
extension MyCustomType: LatticeProperty {
    static var type: PropertyType { .text }  // or .integer, .real, .blob
    
    static var sqlType: String { "TEXT" }
    
    static func toDatabase(_ value: MyCustomType) -> Any {
        // Convert to SQLite-compatible type (String, Int, Double, Data)
        return value.stringRepresentation
    }
    
    static func fromDatabase(_ value: Any) -> MyCustomType {
        // Convert from SQLite type back to Swift type
        guard let str = value as? String else { fatalError() }
        return MyCustomType(str)
    }
}
```

2. If it's a model reference, also conform to `LinkProperty`:
```swift
extension MyCustomType: LinkProperty {
    static var modelType: any Model.Type {
        return LinkedModelType.self
    }
}
```

## Important Notes

### Optional Handling
- Lattice automatically handles Optional<T> where T: LatticeProperty
- NULL in database becomes nil in Swift
- nil in Swift becomes NULL in database
- No extra code needed in LatticeProperty conformance

### Type Safety
- Property types are checked at compile time via macros
- Invalid types produce compile errors
- No runtime type checking needed

### Performance
- Conversion functions are called frequently (every read/write)
- Keep `toDatabase` and `fromDatabase` simple and fast
- Complex types may want to cache conversions

## Future Improvements

1. **Enum Support** - Better native enum handling (currently requires LatticeEnum protocol)
2. **Custom Codable** - Support any Codable type as EmbeddedModel automatically
3. **Relationships** - More efficient relationship queries without loading full objects
