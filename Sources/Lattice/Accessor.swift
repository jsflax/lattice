import Foundation
import SQLite3

public struct Accessor<T> where T: Property {
    public let columnId: Int32
    public let name: String
    public weak var lattice: Lattice?
    public weak var parent: (any Model)?
    private var unmanagedValue: T
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = T.defaultValue) where T: PrimitiveProperty {
        self.columnId = columnId
        self.name = name
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = nil) where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
        self.columnId = columnId
        self.name = name
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            let queryStatementString = "SELECT \(name) FROM \(type(of: parent).entityName) WHERE id = ?;"
            var queryStatement: OpaquePointer?
            
            defer {
                sqlite3_finalize(queryStatement)
            }
            if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
                // Bind the provided id to the statement.
                sqlite3_bind_int64(queryStatement, 1, primaryKey)
                
                if sqlite3_step(queryStatement) == SQLITE_ROW {
                    // Extract id, name, and age from the row.
                    return T.init(from: queryStatement, with: 0)
                } else {
                    print("No person found with id \(primaryKey).")
                }
            } else {
                print("SELECT statement could not be prepared.")
            }
            return unmanagedValue
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
            let updateStatementString = "UPDATE \(type(of: parent).entityName) SET \(name) = ? WHERE id = ?;"
            var updateStatement: OpaquePointer?
            
            if sqlite3_prepare_v2(lattice.db, updateStatementString, -1, &updateStatement, nil) == SQLITE_OK {
                newValue.encode(to: updateStatement, with: 1)
                sqlite3_bind_int64(updateStatement, 2, primaryKey)
                
                if sqlite3_step(updateStatement) == SQLITE_DONE {
                    print("Successfully updated person with id \(primaryKey) to name: \(newValue).")
                } else {
                    print("Could not update person with id \(primaryKey).")
                }
            } else {
                print("UPDATE statement could not be prepared.")
            }
            sqlite3_finalize(updateStatement)
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        value.encode(to: statement, with: columnId)
    }
}
//
//extension Accessor: Codable where T: Codable {
//    public init(from decoder: any Decoder) throws {
//        self.columnId = 0
//        self.name = ""
//        self.lattice = lattice
//        self.parent = parent
//        self.unmanagedValue = unmanagedValue
//    }
//    
//    public func encode(to encoder: any Encoder) throws {
//        
//    }
//}
//extension Accessor where T: PrimitiveProperty & Codable {
//    
//}
//
//extension Accessor where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
//    public var value: T {
//        get {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                return unmanagedValue
//            }
//            let queryStatementString = "SELECT \(name) FROM \(type(of: parent).entityName) WHERE id = ?;"
//            var queryStatement: OpaquePointer?
//            
//            defer {
//                sqlite3_finalize(queryStatement)
//            }
//            if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
//                // Bind the provided id to the statement.
//                sqlite3_bind_int64(queryStatement, 1, primaryKey)
//                
//                if sqlite3_step(queryStatement) == SQLITE_ROW {
//                    // Extract id, name, and age from the row.
//                    return try! JSONDecoder().decode(T.Wrapped.self, from: String(from: queryStatement, with: 0).data(using: .utf8)!) as! T
//                } else {
//                    print("No person found with id \(primaryKey).")
//                }
//            } else {
//                print("SELECT statement could not be prepared.")
//            }
//            return unmanagedValue
//        }
//        set {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                unmanagedValue = newValue
//                return
//            }
//            let updateStatementString = "UPDATE \(type(of: parent).entityName) SET \(name) = ? WHERE id = ?;"
//            var updateStatement: OpaquePointer?
//            
//            if sqlite3_prepare_v2(lattice.db, updateStatementString, -1, &updateStatement, nil) == SQLITE_OK {
//                if let newValue = (newValue as? Optional<T.Wrapped>) {
//                    let text = String(data: try! JSONEncoder().encode(newValue), encoding: .utf8)!
//                    sqlite3_bind_text(updateStatement, 1, (text as NSString).utf8String, -1, nil)
//                } else {
//                    sqlite3_bind_null(updateStatement, 1)
//                }
//                sqlite3_bind_int64(updateStatement, 2, primaryKey)
//                
//                if sqlite3_step(updateStatement) == SQLITE_DONE {
//                    print("Successfully updated person with id \(primaryKey) to name: \(newValue).")
//                } else {
//                    print("Could not update person with id \(primaryKey).")
//                }
//            } else {
//                print("UPDATE statement could not be prepared.")
//            }
//            sqlite3_finalize(updateStatement)
//        }
//    }
//    
//    
//    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
//        if let value = value as? Optional<T.Wrapped> {
//            let text = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
//            sqlite3_bind_text(statement, columnId, (text as NSString).utf8String, -1, nil)
//        } else {
//            sqlite3_bind_null(statement, columnId)
//        }
//    }
//}
