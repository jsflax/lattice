# Sources/LatticeMacros - Swift Macro Implementations

## Overview
This directory contains all Swift macro implementations used by Lattice. Macros run at compile-time to generate boilerplate code for models, properties, and serialization.

## File Structure
- **LatticeMacros.swift** - All macro implementations in single file
- **Plugin entry point** - Exports macros as compiler plugin

## Macros Implemented

### @Model
**Purpose**: Marks a class as a Lattice model and generates required boilerplate

**Attached Macros**:
- `MemberMacro` - Validates property names, adds conformances
- `MemberAttributeMacro` - Adds `@Property` to all stored properties
- `ExtensionMacro` - Generates schema metadata and property accessors

**Generated Code**:
```swift
// Input
@Model
class Trip {
    var name: String
    var days: Int
}

// Macro generates:
extension Trip {
    static var tableName: String { "Trip" }
    
    static var properties: [(String, any LatticeProperty.Type)] {
        [("name", String.self), ("days", Int.self)]
    }
    
    // Accessor wrappers for each property
    var _name: Accessor<String>
    var _days: Accessor<Int>
}

extension Trip: Model { /* conformance */ }
extension Trip: Observable { /* observation support */ }
```

**Validation** (Lines 366-378):
- Checks for reserved property names (`id`, `globalId`)
- Emits diagnostic error with line number if found
- Error message: "Property name 'X' is reserved by Lattice..."

### @Property
**Purpose**: Marks a property for persistence (usually auto-added by @Model)

**Implementation**:
- Simple marker macro
- Primarily used by @Model to identify which properties to persist
- Can be manually added to override @Model's auto-detection

### @Codable
**Purpose**: Generates Codable conformance for models (JSON export/import)

**Generated Code** (Lines 309-359):
```swift
// Input
@Model
@Codable
class Trip {
    var name: String
    var globalId: UUID
}

// Generates:
extension Trip: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case globalId
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.globalId = try container.decode(UUID.self, forKey: .globalId)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(globalId, forKey: .globalId)
    }
}
```

**Features**:
- Handles primitives, arrays, dictionaries
- Automatically includes `globalId`
- Supports EmbeddedModel properties
- Nested encoding/decoding

## Key Implementation Details

### Reserved Name Checking
Located in `ModelMacro.expansion(of:providingMembersOf:in:)` (lines 366-378):

```swift
for binding in variableDecl.bindings {
    if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
        let propertyName = pattern.identifier.text
        if propertyName == "id" || propertyName == "globalId" {
            context.diagnose(Diagnostic(
                node: Syntax(pattern.identifier),
                message: MacroError.message("...")
            ))
            return []
        }
    }
}
```

**Important**: Uses `SwiftDiagnostics` to attach error to specific identifier, providing precise line numbers in Xcode.

### Private(set) Support
The macro preserves access control modifiers:
```swift
// Input
@Model
class Trip {
    public private(set) var id: UUID
}

// Macro generates wrapper that preserves modifiers
public private(set) var _id: Accessor<UUID>
```

### Accessor Generation Pattern
For each property:
1. Extract property name, type, and access modifiers
2. Generate `Accessor<Type>` wrapper with same modifiers  
3. Create computed property that delegates to accessor
4. Register property in static `properties` array

## Error Handling

### MacroError Enum (Lines 130-147)
Conforms to `DiagnosticMessage` for proper compiler integration:
```swift
enum MacroError: Error, DiagnosticMessage {
    case message(String)
    
    var severity: DiagnosticSeverity { .error }
    var message: String { /* error text */ }
    var diagnosticID: MessageID { 
        MessageID(domain: "Lattice", id: "MacroError") 
    }
}
```

**Usage**: Throw or diagnose with `context.diagnose(Diagnostic(node:message:))`

## Macro Expansion Strategy

### Attached vs Freestanding
All Lattice macros are **attached**:
- `@Model` - Attached to class/struct declaration
- `@Property` - Attached to variable declaration
- `@Codable` - Attached to type declaration

No freestanding macros currently (e.g., `#lattice_query(...)`)

### Multi-Phase Expansion
1. **MemberAttributeMacro** - Adds @Property to properties
2. **MemberMacro** - Validates and potentially adds members
3. **ExtensionMacro** - Generates extensions with conformances

Order matters! Attribute macros run first, then member macros, then extensions.

## Testing Macros

Macros can be tested via:
```swift
import MacroTesting

@Test
func testModelMacro() {
    assertMacro {
        """
        @Model
        class Trip {
            var name: String
        }
        """
    } expansion: {
        """
        class Trip {
            var name: String
        }
        
        extension Trip {
            static var properties: [(String, any LatticeProperty.Type)] {
                [("name", String.self)]
            }
        }
        """
    }
}
```

## Common Issues

### "Property name 'id' is reserved"
**Cause**: User defined a property named `id` or `globalId`
**Solution**: Rename to `identifier`, `uniqueId`, or similar
**Location**: Diagnostic points to exact property declaration

### "Accessor must be initialized"
**Cause**: Non-optional EmbeddedModel or LatticeEnum without default value
**Current Workaround**: Provide default value (e.g., `= .init()`)
**TODO**: Fix Accessor to handle this automatically

### "Type does not conform to LatticeProperty"
**Cause**: Property type doesn't have LatticeProperty conformance
**Solution**: Add conformance or use supported type
**Hint**: Check `Property/PrimitiveProperty.swift` for supported types

## Future Improvements

### Planned Features
1. **Type Inference** - Infer property type from default value:
   ```swift
   @Property var days = 5  // Should infer Int
   ```
   Currently requires explicit type annotation.

2. **Better Diagnostics** - More helpful error messages:
   - Suggest alternatives for unsupported types
   - Detect circular relationships
   - Warn about performance issues (e.g., large embedded models)

3. **Relationship Macros** - Specialized macros for relationships:
   ```swift
   @ToOne var destination: Destination?
   @ToMany var activities: [Activity]
   ```

### C++ Port Considerations
Swift macros won't work in C++. Similar functionality requires:
- C preprocessor macros (limited)
- Template metaprogramming (complex)
- External code generator (most practical)

Realm C++ uses preprocessor macros (`REALM_SCHEMA`) with template magic. Lattice C++ could follow same pattern.

## Dependencies

### SwiftSyntax
- Used for parsing and generating Swift code
- Provides AST node types (DeclSyntax, TypeSyntax, etc.)
- Version must match Swift toolchain

### SwiftDiagnostics
- Provides diagnostic system for errors/warnings
- Enables precise error locations (line numbers)
- Integrates with Xcode/LSP

### SwiftCompilerPlugin
- Registers macros with Swift compiler
- Entry point for macro plugin

## Debugging Macros

### View Macro Expansions
In Xcode: Right-click on macro → Expand Macro

### Print Debugging
```swift
// In macro implementation
print("DEBUG: Processing property \(propertyName)")
// Output appears in build log
```

### Breakpoints
1. Run tests with macro plugin attached
2. Set breakpoint in macro implementation
3. Step through expansion logic

## Architecture Notes

### Why Single File?
All macros in one file for simplicity. Could be split into:
- `ModelMacro.swift`
- `PropertyMacro.swift`
- `CodableMacro.swift`

But current size (~500 lines) is manageable.

### Macro Performance
Macros run at compile-time, so performance matters:
- Keep expansions simple
- Avoid complex computations
- Cache when possible (though usually not necessary)

### Generated Code Size
Each @Model class generates ~50-100 lines of code. Not a concern for normal usage, but avoid macros on hundreds of types.
