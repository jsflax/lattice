# Plan: Swift-C++ Accessor Bridge

## Goal
Replace direct SQLite calls in Swift `Accessor` with calls to C++ `managed<T>` types via Swift-C++ interop.

## Current State
- `ManagedString` has `CxxManagedType` conformance (get/set)
- `String` has `CxxManaged` + `CxxListManaged` conformance
- `Int` has partial `CxxListManaged` conformance
- `Optional<Model>` has `CxxManaged` conformance

## Tasks

### 1. C++ ManagedType Protocol Conformances (in Accessor.swift)

Each C++ managed type needs Swift extension with `CxxManagedType`:

| C++ Type | SwiftType | Status |
|----------|-----------|--------|
| `ManagedString` | `String` | Done |
| `ManagedInt` | `Int` | TODO |
| `ManagedDouble` | `Double` | TODO |
| `ManagedBool` | `Bool` | TODO |
| `ManagedLink` | `Optional<Model>` | TODO |
| `ManagedStringList` | `[String]` | TODO |
| `ManagedIntList` | `[Int]` | TODO |
| `ManagedLinkList` | `[Model]` | TODO |

**Template for each:**
```swift
extension lattice.ManagedXxx: CxxManagedType {
    public func get() -> SwiftType {
        return SwiftType(self.detach())
    }

    public mutating func set(_ newValue: SwiftType) {
        self.set_value(CxxType(newValue))
    }
}
```

### 2. Swift Type CxxManaged Conformances (in Accessor.swift)

| Swift Type | CxxManagedSpecialization | CxxManagedListType | Status |
|------------|-------------------------|-------------------|--------|
| `String` | `ManagedString` | `ManagedStringList` | Done |
| `Int` | `ManagedInt` | `ManagedIntList` | Partial |
| `Double` | `ManagedDouble` | `ManagedDoubleList`? | TODO |
| `Bool` | `ManagedBool` | N/A | TODO |
| `Float` | `ManagedDouble` | N/A | TODO |
| `Date` | ? | N/A | TODO |
| `Data` | ? | N/A | TODO |
| `UUID` | `ManagedString` | N/A | TODO |
| `Optional<Model>` | `ManagedLink` | N/A | Done |
| `Array<Model>` | `ManagedLinkList` | N/A | TODO |

### 3. C++ Side Additions Needed

Check if these exist in C++:
- [ ] `ManagedDoubleList` - may need to add
- [ ] `ManagedBoolList` - may need to add (if needed)

### 4. Accessor Updates

The `Accessor` generic already has:
- `T.CxxManagedSpecialization` for the managed type
- `managedValue: T.CxxManagedSpecialization?` storage

Need to update:
- [ ] `bind()` method to create the `managedValue` from C++
- [ ] Wire up `get()`/`set()` to use `managedValue` when bound
- [ ] Handle the case where model is managed (has C++ backing) vs unmanaged

### 5. Integration Points

- [ ] When `Lattice.add()` is called, need to get back `managed<swift_dynamic_object>` from C++
- [ ] Model needs to store reference to C++ managed object
- [ ] Each property accessor needs to get its `managed<T>` field from the C++ object

## Questions to Resolve

1. **How does Model get its C++ managed object?**
   - Option A: Model stores `managed<swift_dynamic_object>*`
   - Option B: Model stores just the row ID and table name, accessors query C++

2. **Should primitive lists be supported?**
   - Swift has `[String]`, `[Int]` stored as JSON
   - C++ now has `managed<std::vector<T>>` for primitives
   - Need `ManagedStringList`, `ManagedIntList` exposed to Swift

3. **Date/Data/UUID handling?**
   - These don't have direct C++ equivalents
   - May need to keep Swift-side SQLite for these, or add C++ support

## Execution Order

1. Add remaining `CxxManagedType` conformances for primitives (Int, Double, Bool)
2. Add `CxxManaged` conformances for primitives (Double, Bool, Float)
3. Test with simple model (String + Int properties only)
4. Add link support (ManagedLink conformance)
5. Add list support (ManagedLinkList, ManagedStringList, ManagedIntList)
6. Handle remaining types (Date, Data, UUID)
