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

//    /// Execute raw SQL for complex migrations.
//    public func executeSQL(_ sql: String) {
//        cxxContext.executeSQL(std.string(sql))
//    }

    /// Query using raw SQL for reading data.
//    public func querySQL(_ sql: String) -> [[String: ColumnValue]] {
//        cxxContext.querySQL(std.string(sql)).map { row in
//            var swiftRow: [String: ColumnValue] = [:]
//            for (key, value) in row {
//                swiftRow[String(key)] = ColumnValue(value)
//            }
//            return swiftRow
//        }
//    }
}

// MARK: - Column Value Wrapper

/// A type-safe wrapper for column values during migration.
//public struct ColumnValue: Sendable {
//    let cxxValue: lattice.column_value_t
//
//    init(_ cxx: lattice.column_value_t) {
//        self.cxxValue = cxx
//    }
//
//    /// Create a null value
//    public init() {
//        self.cxxValue = .init()
//    }
//
//    /// Create from a double
//    public init(_ value: Double) {
//        self.cxxValue = lattice.column_value_from_double(value)
//    }
//
//    /// Create from a string
//    public init(_ value: String) {
//        self.cxxValue = lattice.column_value_from_string(std.string(value))
//    }
//
//    /// Create from an integer
//    public init(_ value: Int64) {
//        self.cxxValue = lattice.column_value_from_int(value)
//    }
//
//    /// Create from a boolean
//    public init(_ value: Bool) {
//        self.cxxValue = lattice.column_value_from_int(value ? 1 : 0)
//    }
//
//    // MARK: - Value Accessors
//
//    /// Get as Double if this is a numeric value
//    public var doubleValue: Double? {
//        lattice.column_value_as_double(cxxValue)
//    }
//
//    /// Get as Int64 if this is an integer value
//    public var intValue: Int64? {
//        lattice.column_value_as_int(cxxValue)
//    }
//
//    /// Get as String if this is a text value
//    public var stringValue: String? {
//        lattice.column_value_as_string(cxxValue).map { String($0) }
//    }
//
//    /// Get as Bool if this is a boolean value
//    public var boolValue: Bool? {
//        intValue.map { $0 != 0 }
//    }
//
//    /// Check if this is null
//    public var isNull: Bool {
//        lattice.column_value_is_null(cxxValue)
//    }
//}

@dynamicMemberLookup
public final class DynamicObject {
    private var dynamicObject: CxxDynamicObjectRef

    internal init(_ dynamicObject: CxxDynamicObjectRef) {
        self.dynamicObject = dynamicObject
    }

    public subscript<T>(dynamicMember keyPath: String) -> T where T: CxxManaged {
        get {
            var storage = ModelStorage(_ref: dynamicObject)
            return T.getField(from: &storage, named: keyPath)
        }
        set {
            var storage = ModelStorage(_ref: dynamicObject)
            T.setField(on: &storage, named: keyPath, newValue)
            dynamicObject = storage._ref
        }
    }
}

// MARK: - Migration Block Type

internal protocol MigrationProtocol {
    func _sendRow(entityName: String, _ oldValue: CxxDynamicObjectRef, _ newValue: CxxDynamicObjectRef)
    var schemas: [String: (from: lattice.SwiftSchema, to: lattice.SwiftSchema)] { get }
}

public struct Migration : MigrationProtocol {
    private var typeErasedBlocks: [String: (CxxDynamicObjectRef, CxxDynamicObjectRef) -> ()] = [:]
    var schemas: [String: (from: lattice.SwiftSchema, to: lattice.SwiftSchema)] = [:]
    
    private static func unsafeTypeCast<T>(_ type: T.Type, value: CxxDynamicObjectRef) -> T where T: Model {
        type.init(dynamicObject: value)
    }
    
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
    
    internal func _sendRow(entityName: String, _ oldValue: CxxDynamicObjectRef, _ newValue: CxxDynamicObjectRef) {
        guard let block = typeErasedBlocks[entityName] else {
            preconditionFailure("Migration not set up correctly")
        }
        
        block(oldValue, newValue)
    }
}

/// A block that handles schema migration.
public typealias MigrationBlock = @Sendable (/* old, managed value */ DynamicObject,
                                             /* new, unmanaged value */ any Model) -> Void

public enum Deprecated {}
