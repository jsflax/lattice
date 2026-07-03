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

/// Context for performing data migrations when schema changes.
///
/// Use this to transform data during schema migrations, such as:
/// - Converting separate lat/lon columns into a geo_bounds type
/// - Renaming columns
/// - Transforming data formats
///
/// Example:
/// ```swift
/// let lattice = try Lattice(Place.self) { migration in
///     if migration.hasChanges(for: "Place") {
///         migration.enumerateObjects(table: "Place") { rowId, oldRow in
///             if let lat = oldRow["latitude"]?.doubleValue,
///                let lon = oldRow["longitude"]?.doubleValue {
///                 migration.setValue(table: "Place", rowId: rowId,
///                                   column: "location_minLat", value: lat)
///                 migration.setValue(table: "Place", rowId: rowId,
///                                   column: "location_maxLat", value: lat)
///                 migration.setValue(table: "Place", rowId: rowId,
///                                   column: "location_minLon", value: lon)
///                 migration.setValue(table: "Place", rowId: rowId,
///                                   column: "location_maxLon", value: lon)
///             }
///         }
///     }
/// }
/// ```
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
    /// Use `setValue` within the callback to set new column values.
    ///
    /// - Parameters:
    ///   - tableName: The table to enumerate
    ///   - callback: Called for each row with (rowId, oldRowData)
    public func enumerateObjects(table tableName: String,
                                 callback: @escaping (any Model, any Model) -> Void) {
        cxxContext.enumerateObjects(table: std.string(tableName)) { rowId, oldRow in
//            var swiftRow: [String: ColumnValue] = [:]
//            for (key, value) in oldRow {
//                swiftRow[String(key)] = ColumnValue(value)
//            }
//            callback(rowId, swiftRow)
        }
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

public enum Deprecated {}
