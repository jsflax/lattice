import Foundation
import LatticeSwiftCppBridge

// MARK: - Migration Types

/// Describes schema changes for a single table during migration.
public struct TableChanges: Sendable {
    /// The name of the table with changes
    public let tableName: String
    /// Columns being added to the schema
    public let addedColumns: [String]
    /// Columns being removed from the schema
    public let removedColumns: [String]
    /// Columns whose type is changing
    public let changedColumns: [String]

    /// Returns true if there are any schema changes
    public var hasChanges: Bool {
        !addedColumns.isEmpty || !removedColumns.isEmpty || !changedColumns.isEmpty
    }

    init(_ cxx: lattice.swift_table_changes) {
        self.tableName = String(cxx.table_name)
        self.addedColumns = cxx.added_columns.map { String($0) }
        self.removedColumns = cxx.removed_columns.map { String($0) }
        self.changedColumns = cxx.changed_columns.map { String($0) }
    }
}

// MARK: - ColumnValue

/// `std::unordered_map<std::string, column_value_t>` (the core's
/// `migration_row`) imports without collection conformances; declaring
/// `CxxSequence` here derives iteration from the imported begin()/end(),
/// letting `enumerateObjects` walk rows without copying through C++.
extension lattice.migration_row: CxxSequence {}

/// A single SQL value crossing the migration boundary — the Swift face of the
/// core's `column_value_t` variant (NULL / INTEGER / REAL / TEXT / BLOB).
///
/// This shape is the alignment target for the 1.1 unified-open C ABI's
/// `lattice_column_value_t` (latticecore docs/design-unified-open.md §3):
/// one case per SQLite storage class, BLOB-capable by construction.
public enum ColumnValue: Equatable, Sendable {
    case null
    case int64(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// The integer payload, or nil for any other kind.
    public var int64Value: Int64? {
        if case .int64(let v) = self { return v }
        return nil
    }

    /// The floating-point payload. Follows SQLite numeric affinity: an
    /// INTEGER-stored value in a REAL-declared column surfaces as `.int64`,
    /// so this accessor also widens `.int64` to `Double`.
    public var doubleValue: Double? {
        switch self {
        case .real(let v): return v
        case .int64(let v): return Double(v)
        default: return nil
        }
    }

    /// The text payload, or nil for any other kind.
    public var stringValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    /// The blob payload, or nil for any other kind.
    public var dataValue: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension ColumnValue {
    /// Marshal from the C++ `column_value_t` variant. Discrimination goes
    /// through `std::variant::index()` — the bridge's `column_value_as_int` /
    /// `column_value_as_double` helpers COERCE across the numeric kinds
    /// (truncating doubles, widening ints), so probe order alone would
    /// misclassify one of them. Alternative order is pinned by the core's
    /// `column_value_t` declaration (types.hpp): nullptr, int64, double,
    /// string, blob.
    init(_ cxx: lattice.column_value_t) {
        switch cxx.index() {
        case 1:
            let v = lattice.column_value_as_int(cxx)
            // numericCast: C++ int64_t imports as Int on Linux, Int64 on Darwin.
            self = v.__convertToBool() ? .int64(numericCast(v.pointee)) : .null
        case 2:
            let v = lattice.column_value_as_double(cxx)
            self = v.__convertToBool() ? .real(v.pointee) : .null
        case 3:
            let v = lattice.column_value_as_string(cxx)
            self = v.__convertToBool() ? .text(String(v.pointee)) : .null
        case 4:
            let v = lattice.column_value_as_blob(cxx)
            guard v.__convertToBool() else {
                self = .null
                return
            }
            // Direct C++ member calls ONLY (size()/operator[]): on Linux this
            // vector specialization's Collection conformance dispatches count
            // through a NULL protocol witness (SIGSEGV) — Data.init(_:) AND
            // Collection.map both crash. Do not "simplify" this loop.
            let vec = v.pointee
            let count: Int = numericCast(vec.size())
            var data = Data(capacity: count)
            var i = 0
            while i < count {
                data.append(vec[numericCast(i)])
                i += 1
            }
            self = .blob(data)
        default:
            // 0 = std::nullptr_t (SQL NULL); anything else is unreachable
            // today — degrade to NULL rather than trap if the core grows an
            // alternative.
            self = .null
        }
    }

    /// Marshal to the C++ `column_value_t` variant.
    var cxxValue: lattice.column_value_t {
        switch self {
        case .null:
            // std::variant imports into Swift with no initializers and the
            // bridge exposes no explicit null constructor — obtain SQL NULL by
            // asking an empty union_value for a missing field, which returns
            // nullptr (the variant's first alternative, i.e. SQL NULL).
            return lattice.union_value().field_as_column_value(std.string(""))
        case .int64(let v):
            // numericCast: see init(_:) — int64_t width differs per platform.
            return lattice.column_value_from_int(numericCast(v))
        case .real(let v):
            return lattice.column_value_from_double(v)
        case .text(let v):
            return lattice.column_value_from_string(std.string(v))
        case .blob(let v):
            // Element-wise push_back, matching the repo idiom (see
            // Data.setUnmanaged) — the sequence-taking ByteVector initializer
            // rides the same interop surface as the Linux NULL-witness crash.
            var vec = lattice.ByteVector()
            for byte in v { vec.push_back(byte) }
            return lattice.column_value_from_blob(vec)
        }
    }
}

/// Context for performing data migrations when schema changes.
///
/// Use this to transform data during schema migrations, such as:
/// - Converting separate lat/lon columns into a geo_bounds type
/// - Renaming columns
/// - Transforming data formats
///
/// Example:
/// ```swift
/// if migration.hasChanges(for: "Place") {
///     migration.enumerateObjects(table: "Place") { rowId, oldRow in
///         if let lat = oldRow["latitude"]?.doubleValue,
///            let lon = oldRow["longitude"]?.doubleValue {
///             migration.setValue(table: "Place", rowId: rowId,
///                                column: "location_minLat", value: .real(lat))
///             migration.setValue(table: "Place", rowId: rowId,
///                                column: "location_maxLat", value: .real(lat))
///             migration.setValue(table: "Place", rowId: rowId,
///                                column: "location_minLon", value: .real(lon))
///             migration.setValue(table: "Place", rowId: rowId,
///                                column: "location_maxLon", value: .real(lon))
///         }
///     }
/// }
/// ```
///
/// NOTE (1.0): `MigrationContext` is not yet reachable from a public `Lattice`
/// open — the block-based open rides the 1.1 unified-open ABI work
/// (latticecore docs/design-unified-open.md). The versioned `[Int: Migration]`
/// dictionary on `Configuration` is the wired 1.0 migration path. This type's
/// `(rowId, [String: ColumnValue])` shape is frozen now because the 1.1 C ABI
/// migration array is specified against it.
// MigrationContext wraps the C++ `swift_migration_context_ref`, which — like
// the rest of the *_ref handle family — is a foreign reference on iOS 16.4+
// and a copyable value type below the floor. Its mutable state (the wrapped
// context pointer and the queued row updates) lives behind a shared_ptr in
// C++, so value-path copies alias the same queue and the methods import
// non-mutating. It is never instantiated on the core CRUD path.
public final class MigrationContext: @unchecked Sendable {
    let cxxContext: lattice.swift_migration_context_ref

    init(_ ctx: lattice.swift_migration_context_ref) {
        self.cxxContext = ctx
    }

    // MARK: - Schema Change Information

    /// Get all pending schema changes across all tables
    public func pendingChanges() -> [TableChanges] {
        cxxContext.pendingChanges().map { TableChanges($0) }
    }

    /// Check if a specific table has schema changes
    public func hasChanges(for tableName: String) -> Bool {
        cxxContext.hasChanges(for: std.string(tableName))
    }

    /// Get schema changes for a specific table
    public func changes(for tableName: String) -> TableChanges {
        TableChanges(cxxContext.changes(for: std.string(tableName)))
    }

    // MARK: - Data Migration

    /// Enumerate all existing rows in a table for data transformation.
    ///
    /// Call this to iterate over existing data and transform it as needed.
    /// Use `setValue` within the callback to stage new column values; staged
    /// values are applied after auto-migration adds/removes columns.
    ///
    /// - Parameters:
    ///   - tableName: The table to enumerate
    ///   - callback: Called once per row with the row's `id` and the full old
    ///     row as column-name → ``ColumnValue`` (includes columns being
    ///     removed; BLOB columns surface as `.blob`).
    public func enumerateObjects(table tableName: String,
                                 callback: @escaping (Int64, [String: ColumnValue]) -> Void) {
        cxxContext.enumerateObjects(table: std.string(tableName)) { rowId, oldRow in
            var swiftRow: [String: ColumnValue] = [:]
            for pair in oldRow {
                swiftRow[String(pair.first)] = ColumnValue(pair.second)
            }
            callback(numericCast(rowId), swiftRow)
        }
    }

    /// Stage a value for one row/column, applied after auto-migration.
    /// Call from within an `enumerateObjects` callback.
    public func setValue(table tableName: String, rowId: Int64,
                         column: String, value: ColumnValue) {
        cxxContext.setRowValue(table: std.string(tableName),
                               rowId: numericCast(rowId),
                               column: std.string(column),
                               value: value.cxxValue)
    }

    // MARK: - Helper Operations

    /// Rename a property (copies values from old column to new column name).
    public func renameProperty(table tableName: String, from oldName: String, to newName: String) {
        cxxContext.renameProperty(table: std.string(tableName),
                                  from: std.string(oldName),
                                  to: std.string(newName))
    }

    /// Delete all objects in a table.
    public func deleteAll(table tableName: String) {
        cxxContext.deleteAll(table: std.string(tableName))
    }

}

// NOTE: `DynamicObject` now lives in `Dynamic/DynamicObject.swift` — it is the
// public, schema-driven `@dynamicMemberLookup` type for the dynamic (no
// compile-time `@Model` types) query API. The previous internal definition here
// (a typed `<T: CxxManaged>` accessor used only by the unused `MigrationBlock`
// typealias below) had no live callers and was superseded.

// MARK: - Migration Block Type

internal protocol MigrationProtocol {
    func _sendRow(entityName: String, _ oldValue: CxxDynamicObjectRef, _ newValue: CxxDynamicObjectRef)
    var schemas: [String: (from: lattice.SwiftSchema, to: lattice.SwiftSchema)] { get }
}

public struct Migration : MigrationProtocol, @unchecked Sendable {
    private var typeErasedBlocks: [String: (CxxDynamicObjectRef, CxxDynamicObjectRef) -> ()] = [:]
    var schemas: [String: (from: lattice.SwiftSchema, to: lattice.SwiftSchema)] = [:]
    
    private static func unsafeTypeCast<T>(_ type: T.Type, value: CxxDynamicObjectRef) -> T where T: Model {
        type.init(dynamicObject: value)
    }
    
    // Variadic (parameter-pack) registration — iOS 17+ (variadic generics).
    // iOS 15 uses `init()` + the pack-free `.add(from:to:)` builder below, which
    // is available on all deployment targets and is the portable migration API.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public init<each M1: Model, each M2: Model>
    (_ fromTos: repeat (from: (each M1).Type, to: (each M2).Type),
    blocks: repeat @escaping (each M1, each M2) -> ()) {
        for (fromTo, block) in repeat (each fromTos, each blocks) {
            schemas[fromTo.to.entityName] = (
                from: fromTo.from.cxxPropertyDescriptor(),
                to: fromTo.to.cxxPropertyDescriptor(),
            )
            typeErasedBlocks[fromTo.to.entityName] = { t1, t2 in

                block(Self.unsafeTypeCast(fromTo.from, value: t1),
                      Self.unsafeTypeCast(fromTo.to, value: t2))
            }
        }
    }

    /// Creates an empty migration. Chain `.add(from:to:)` to register per-pair
    /// transforms. Works on all deployment targets.
    public init() {}

    /// Registers a migration transform for one `From` → `To` pair, returning the
    /// migration for chaining. Pack-free equivalent of the variadic initializer:
    /// `Migration().add(from: V1.self, to: V2.self) { old, new in … }`.
    public func add<From: Model, To: Model>(from: From.Type, to: To.Type, _ block: @escaping (From, To) -> ()) -> Self {
        var copy = self
        copy.schemas[to.entityName] = (
            from: from.cxxPropertyDescriptor(),
            to: to.cxxPropertyDescriptor()
        )
        copy.typeErasedBlocks[to.entityName] = { t1, t2 in
            block(Self.unsafeTypeCast(from, value: t1),
                  Self.unsafeTypeCast(to, value: t2))
        }
        return copy
    }
    
    internal func _sendRow(entityName: String, _ oldValue: CxxDynamicObjectRef, _ newValue: CxxDynamicObjectRef) {
        guard let block = typeErasedBlocks[entityName] else {
            preconditionFailure("Migration not set up correctly")
        }
        
        block(oldValue, newValue)
    }
}

// MARK: - Migration Lookup

extension Migration {
    /// Look up an existing object by primary key during a migration callback.
    /// Only valid inside a migration block. Returns nil if not found.
    ///
    /// Use this to resolve foreign key values to link objects when migrating
    /// from a raw FK column to an `Optional<Model>` link property:
    /// ```swift
    /// Migration((from: V1Child.self, to: V2Child.self), blocks: { old, new in
    ///     if let parent = Migration.lookup(V2Parent.self, id: old.parentId) {
    ///         new.parent = parent
    ///     }
    /// })
    /// ```
    public static func lookup<T: Model>(_ type: T.Type, id: Int64) -> T? {
        // `_optRef` normalizes the lookup result, which imports as a non-optional
        // value (empty when absent) below the FRT floor.
        guard lattice.migrationLookup(table: std.string(T.entityName), primaryKey: id),
              let ref = _optRef(lattice.migrationTakeLookupResult()) else {
            return nil
        }
        return T(dynamicObject: ref)
    }

    /// Look up an existing object by globalId during a migration callback.
    /// Only valid inside a migration block. Returns nil if not found.
    public static func lookup<T: Model>(_ type: T.Type, globalId: String) -> T? {
        guard lattice.migrationLookupByGlobalId(table: std.string(T.entityName), globalId: std.string(globalId)),
              let ref = _optRef(lattice.migrationTakeLookupResult()) else {
            return nil
        }
        return T(dynamicObject: ref)
    }

    /// All children whose single-link `link` property points at `parent`,
    /// hydrated from the current database state. Only valid inside a
    /// migration block. The inverse of `lookup` — use it for FK-to-List
    /// backfills, appending the children to the new parent row's `List`:
    /// ```swift
    /// Migration((from: V3.Model.self, to: Model.self), blocks: { old, new in
    ///     let signals = Migration.children(Signal.self, of: old, via: \.model)
    ///     for signal in signals { new.signals.append(signal) }
    /// })
    /// ```
    /// `parent` is typically the OLD-schema snapshot model (e.g. `V3.Model`)
    /// while `link` targets the CURRENT model type — only the parent's
    /// globalId is read from it; table and property names come from the
    /// keypath's types, which share entityName with their snapshots.
    public static func children<C: Model, L: Model>(_ type: C.Type,
                                                    of parent: some Model,
                                                    via link: KeyPath<C, L?>) -> [C] {
        guard let parentGid = parent.globalId else { return [] }
        let count = lattice.migrationLookupBacklinks(
            childTable: std.string(C.entityName),
            parentTable: std.string(L.entityName),
            linkProperty: std.string(_name(for: link)),
            parentGlobalId: std.string(parentGid.uuidString))
        return (0..<count).compactMap { index in
            // `_optRef` normalizes the result, which imports as a non-optional
            // value (empty when absent) below the FRT floor (same as `lookup`).
            guard let ref = _optRef(lattice.migrationTakeBacklinkResult(at: index)) else { return nil }
            return C(dynamicObject: ref)
        }
    }
}

/// A block that handles schema migration.
public typealias MigrationBlock = @Sendable (/* old, managed value */ DynamicObject,
                                             /* new, unmanaged value */ any Model) -> Void
