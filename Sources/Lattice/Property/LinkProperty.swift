import Foundation
import SQLite3

public protocol LinkProperty {
    associatedtype ModelType: Model
    
    static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self
    static func _set(name: String,
                     parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Self)
    static var modelType: any Model.Type { get }
}

extension Array: Property where Element: Property {
    public typealias DefaultValue = Self
}

extension Array: LinkProperty where Element: Model {
    public static var modelType: any Model.Type {
        Element.self
    }
    
    public typealias ModelType = Element
    public static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Array<Element> {
        let entityName = Element.entityName
        let parentEntityName = type(of: parent).entityName
        let tableName = "_\(parentEntityName)_\(entityName)_\(name)"
        let queryStatementString = "SELECT rhs FROM \(tableName) WHERE lhs = ?;"
        var queryStatement: OpaquePointer?
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            sqlite3_bind_int64(queryStatement, 1, primaryKey)
            var elements: [Element] = []
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let t = Element.init(isolation: #isolation)
                t.primaryKey = Int64(sqlite3_column_int64(queryStatement, 0))
                lattice.dbPtr.insertModelObserver(tableName: Element.entityName, primaryKey: t.primaryKey!, t.weakCapture(isolation: #isolation))
                t._assign(lattice: lattice)
                elements.append(t)
            }
            return elements
        }
        fatalError()
    }
    
    public static func _set(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Array<Element>) {
        newValue.difference(from: _get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)).forEach {
            switch $0 {
            case .insert(offset: let offset, element: let element, associatedWith: let associatedWith):
                Optional<Element>._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: element)
            case .remove(offset: let offset, element: let element, associatedWith: let associatedWith):
                Optional<Element>._setNil(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, oldValue: element)
            }
        }
    }
    
    public func `where`(_ query: @escaping Predicate<Element>) -> Results<Element> {
        return Results(first!.lattice!, whereStatement: query)
    }
}

extension Optional: LinkProperty where Wrapped: Model {
    public typealias ModelType = Wrapped
    public static var modelType: any Model.Type { Wrapped.self }
    public static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self {
        let entityName = Wrapped.entityName
        let parentEntityName = type(of: parent).entityName
        let tableName = "_\(parentEntityName)_\(entityName)_\(name)"
        let queryStatementString = "SELECT rhs FROM \(tableName) WHERE lhs = ?;"
        var queryStatement: OpaquePointer?
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            sqlite3_bind_int64(queryStatement, 1, primaryKey)
            
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let t = Wrapped.init(isolation: #isolation)
                t.primaryKey = Int64(sqlite3_column_int64(queryStatement, 0))
                lattice.dbPtr.insertModelObserver(tableName: Wrapped.entityName, primaryKey: t.primaryKey!, t.weakCapture(isolation: #isolation))
                t._assign(lattice: lattice)
                return t
            } else {
                print("No field \(name) found on \(type(of: parent).entityName) with id \(primaryKey).")
                return nil
            }
        }
        fatalError()
    }
    
    public static func _setNil(name: String,
                               parent: some Model, lattice: Lattice, primaryKey: Int64, oldValue: Self) {
        // 1) Figure out the join table name
        let entityName       = Wrapped.entityName
        let parentEntityName = type(of: parent).entityName
        let tableName        = "_\(parentEntityName)_\(entityName)_\(name)"
        
        func delete(rhsPrimaryKey: Int64) {
            let deleteSQL = "DELETE FROM \(tableName) WHERE lhs = ? AND rhs = ?;"
            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(lattice.db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(deleteStmt, 1, primaryKey)
                sqlite3_bind_int64(deleteStmt, 2, rhsPrimaryKey)
                if sqlite3_step(deleteStmt) != SQLITE_DONE {
                    print("Failed to delete existing link in \(tableName)")
                }
            } else {
                print("Could not prepare DELETE from \(tableName): : \(lattice.readError() ?? "Unknown")")
            }
            sqlite3_finalize(deleteStmt)
        }
        
        // 2) Delete any existing link for this parent
        if let rhsPrimaryKey = oldValue?.primaryKey {
            delete(rhsPrimaryKey: rhsPrimaryKey)
        }
    }
    
    public static func _set(name: String,
                            parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Self) {
        // 1) Figure out the join table name
        let entityName       = Wrapped.entityName
        let parentEntityName = type(of: parent).entityName
        let tableName        = "_\(parentEntityName)_\(entityName)_\(name)"
        
        func delete(rhsPrimaryKey: Int64) {
            let deleteSQL = "DELETE FROM \(tableName) WHERE lhs = ? AND rhs = ?;"
            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(lattice.db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(deleteStmt, 1, primaryKey)
                sqlite3_bind_int64(deleteStmt, 2, rhsPrimaryKey)
                if sqlite3_step(deleteStmt) != SQLITE_DONE {
                    print("Failed to delete existing link in \(tableName)")
                }
            } else {
                print("❌", "Could not prepare DELETE from \(tableName): \(lattice.readError() ?? "Unknown")")
            }
            sqlite3_finalize(deleteStmt)
        }
        
        // 2) Delete any existing link for this parent
        if let rhsPrimaryKey = newValue?.primaryKey {
            delete(rhsPrimaryKey: rhsPrimaryKey)
        } else if newValue == nil, let rhsPrimaryKey = _get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)?.primaryKey {
            delete(rhsPrimaryKey: rhsPrimaryKey)
        }
        
        // 3) If newValue != nil, insert the new link
        if let linked = newValue {
            if linked.primaryKey == nil {
                lattice.add(linked)
            }
            guard let rhsId = linked.primaryKey else {
                print("Cannot create link for \(entityName) – it has no primaryKey")
                fatalError()
            }
            
            let insertSQL = "INSERT INTO \(tableName) (lhs, rhs) VALUES (?, ?);"
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(lattice.db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(insertStmt, 1, primaryKey)
                sqlite3_bind_int64(insertStmt, 2, rhsId)
                if sqlite3_step(insertStmt) != SQLITE_DONE {
                    print("Failed to insert link into \(tableName)")
                }
            } else {
                print("Could not prepare INSERT into \(tableName): : \(lattice.readError() ?? "Unknown")")
            }
            sqlite3_finalize(insertStmt)
        }
    }
}
