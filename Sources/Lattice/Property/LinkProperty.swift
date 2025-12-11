import Foundation
import SQLite3

public protocol LinkProperty {
    associatedtype ModelType: Model
    
    static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self
    static func _set(name: String,
                     parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Self)
    static var modelType: any Model.Type { get }
}

extension Array: SchemaProperty where Element: SchemaProperty {
    public typealias DefaultValue = Self
    public static var defaultValue: Array<Element> { [] }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Array: LinkProperty where Element: Model {
    public static var modelType: any Model.Type {
        Element.self
    }

    public typealias ModelType = Element
    public static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Array<Element> {
//        let entityName = Element.entityName
//        let parentEntityName = type(of: parent).entityName
//        let tableName = "_\(parentEntityName)_\(entityName)_\(name)"
//
//        // Get parent's globalId for the query
//        let parentGlobalId = parent.__globalId
//
//        // Link table now stores globalIds, so we JOIN to get child objects
//        let queryStatementString = """
//            SELECT e.id FROM \(entityName) e
//            INNER JOIN \(tableName) link ON link.rhs = e.globalId
//            WHERE link.lhs = ?;
//        """
//        var queryStatement: OpaquePointer?
//        defer { sqlite3_finalize(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
//            // Bind parent's globalId (TEXT)
//            sqlite3_bind_text(queryStatement, 1, (parentGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//            var elements: [Element] = []
//            while sqlite3_step(queryStatement) == SQLITE_ROW {
//                elements.append(lattice.newObject(Element.self, primaryKey: Int64(sqlite3_column_int64(queryStatement, 0))))
//            }
//            return elements
//        }
        fatalError()
    }

    public static func _set(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Array<Element>) {
//        newValue.difference(from: _get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)).forEach {
//            switch $0 {
//            case .insert(offset: let offset, element: let element, associatedWith: let associatedWith):
//                Optional<Element>._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: element)
//            case .remove(offset: let offset, element: let element, associatedWith: let associatedWith):
//                Optional<Element>._setNil(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, oldValue: element)
//            }
//        }
    }

    public func `where`(_ query: @escaping Predicate<Element>) -> Results<Element> {
        return Results(first!.lattice!, whereStatement: query)
    }
}

extension Optional: LinkProperty where Wrapped: Model {
    public typealias ModelType = Wrapped
    public static var modelType: any Model.Type { Wrapped.self }

    public static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self {
//        let entityName = Wrapped.entityName
//        let parentEntityName = type(of: parent).entityName
//        let tableName = "_\(parentEntityName)_\(entityName)_\(name)"
//
//        // Get parent's globalId for the query
//        let parentGlobalId = parent.__globalId
//
//        // Link table now stores globalIds, so we JOIN to get the child object
//        let queryStatementString = """
//            SELECT e.id FROM \(entityName) e
//            INNER JOIN \(tableName) link ON link.rhs = e.globalId
//            WHERE link.lhs = ?;
//        """
//        var queryStatement: OpaquePointer?
//        defer { sqlite3_finalize(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
//            // Bind parent's globalId (TEXT)
//            sqlite3_bind_text(queryStatement, 1, (parentGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//
//            if sqlite3_step(queryStatement) == SQLITE_ROW {
//                let t = Wrapped.init(isolation: #isolation)
//                t.primaryKey = Int64(sqlite3_column_int64(queryStatement, 0))
//                lattice.dbPtr.insertModelObserver(tableName: Wrapped.entityName, primaryKey: t.primaryKey!, t.weakCapture(isolation: #isolation))
//                t._assign(lattice: lattice)
//                return t
//            } else {
//                return nil
//            }
//        }
        fatalError()
    }

    public static func _setNil(name: String,
                               parent: some Model, lattice: Lattice, primaryKey: Int64, oldValue: Self) {
//        // 1) Figure out the join table name
//        let entityName       = Wrapped.entityName
//        let parentEntityName = type(of: parent).entityName
//        let tableName        = "_\(parentEntityName)_\(entityName)_\(name)"
//
//        // Get parent's globalId
//        let parentGlobalId = parent.__globalId
//
//        func delete(rhsGlobalId: UUID) {
//            let deleteSQL = "DELETE FROM \(tableName) WHERE lhs = ? AND rhs = ?;"
//            var deleteStmt: OpaquePointer?
//            if sqlite3_prepare_v2(lattice.db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
//                sqlite3_bind_text(deleteStmt, 1, (parentGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//                sqlite3_bind_text(deleteStmt, 2, (rhsGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//                if sqlite3_step(deleteStmt) != SQLITE_DONE {
//                    print("Failed to delete existing link in \(tableName)")
//                }
//            } else {
//                print("Could not prepare DELETE from \(tableName): \(lattice.readError() ?? "Unknown")")
//            }
//            sqlite3_finalize(deleteStmt)
//        }
//
//        // 2) Delete any existing link for this parent
//        if let rhsGlobalId = oldValue.map({ $0.__globalId }) {
//            delete(rhsGlobalId: rhsGlobalId)
//        }
    }

    public static func _set(name: String,
                            parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Self) {
//        // 1) Figure out the join table name
//        let entityName       = Wrapped.entityName
//        let parentEntityName = type(of: parent).entityName
//        let tableName        = "_\(parentEntityName)_\(entityName)_\(name)"
//
//        // Get parent's globalId
//        let parentGlobalId = parent.__globalId
//
//        func delete(rhsGlobalId: UUID) {
//            let deleteSQL = "DELETE FROM \(tableName) WHERE lhs = ? AND rhs = ?;"
//            var deleteStmt: OpaquePointer?
//            if sqlite3_prepare_v2(lattice.db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
//                sqlite3_bind_text(deleteStmt, 1, (parentGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//                sqlite3_bind_text(deleteStmt, 2, (rhsGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//                sqlite3_step(deleteStmt)
//            }
//            sqlite3_finalize(deleteStmt)
//        }
//
//        // 2) Delete any existing link for this parent (if replacing)
//        if let rhsGlobalId = newValue?.__globalId {
//            delete(rhsGlobalId: rhsGlobalId)
//        } else if newValue == nil, let rhsGlobalId = _get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)?.__globalId {
//            delete(rhsGlobalId: rhsGlobalId)
//        }
//
//        // 3) If newValue != nil, insert the new link using globalIds
//        if let linked = newValue {
//            if linked.primaryKey == nil {
//                lattice.add(linked)
//            }
//            let rhsGlobalId = linked.__globalId
//
//            let insertSQL = "INSERT INTO \(tableName) (lhs, rhs) VALUES (?, ?);"
//            var insertStmt: OpaquePointer?
//            if sqlite3_prepare_v2(lattice.db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
//                sqlite3_bind_text(insertStmt, 1, (parentGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//                sqlite3_bind_text(insertStmt, 2, (rhsGlobalId.uuidString.lowercased() as NSString).utf8String, -1, nil)
//                sqlite3_step(insertStmt)
//            }
//            sqlite3_finalize(insertStmt)
//        }
    }
}
