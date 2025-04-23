import Foundation
import SQLite3

public protocol StaticString {
    static var string: String { get }
}

public protocol StaticInt32 {
    static var int32: Int32 { get }
}

public struct Accessor<T, SS, SI>: @unchecked Sendable where SS: StaticString, SI: StaticInt32 {
    public var columnId: Int32 {
        SI.int32
    }
    public var name: String {
        SS.string
    }
    public var lattice: Lattice?
    public weak var parent: (any Model)?
    private var unmanagedValue: T
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = T()) where T: ListProperty {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = T.defaultValue) where T: PrimitiveProperty {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
//    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
//                parent: (any Model)? = nil,
//                unmanagedValue: T = nil) where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
//        self.lattice = lattice
//        self.parent = parent
//        self.unmanagedValue = unmanagedValue
//    }
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = nil) where T: OptionalProtocol, T.Wrapped: Model {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public init<M: Model>(columnId: Int32, name: String, lattice: Lattice? = nil,
                          parent: (any Model)? = nil,
                          unmanagedValue: T = []) where T == Array<M> {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
}

extension Accessor where T: PrimitiveProperty {
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            return unmanagedValue
        }
        return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
    }
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            unmanagedValue = newValue
            return
        }
//            lattice.transaction {
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//            }
    }
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
//            lattice.transaction {
                T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//            }
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        value.encode(to: statement, with: columnId)
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
    }
}
//extension Accessor where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
//    public var value: T {
//        get {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                return unmanagedValue
//            }
////            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)
//            fatalError()
//        }
//        set {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                unmanagedValue = newValue
//                return
//            }
////            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//        }
//    }
//    
//    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
//        value.encode(to: statement, with: columnId)
//    }
//}

extension Accessor where T: EmbeddedModel {
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        unmanagedValue.encode(to: statement, with: columnId)
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
    }
}

extension Accessor where T: ListProperty & LinkProperty {
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            return unmanagedValue
        }
        return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
    }
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        fatalError()
//            }
    }
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)
        }
        set {
            fatalError()
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        // decrement the column id in an encode since this is skipped
        columnId -= 1
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
        T._set(name: name,
               parent: parent,
               lattice: lattice,
               primaryKey: primaryKey,
               newValue: unmanagedValue)
    }
}

extension Accessor where T: LinkProperty {
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            return unmanagedValue
        }
        return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
    }
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            unmanagedValue = newValue
            return
        }
//            lattice.transaction {
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//            }
    }
    
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        // decrement the column id in an encode since this is skipped
        columnId -= 1
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
        T._set(name: name,
               parent: parent,
               lattice: lattice,
               primaryKey: primaryKey,
               newValue: unmanagedValue)
    }
}

extension Accessor: Codable where T: Codable, T: PrimitiveProperty {
    public init(from decoder: any Decoder) throws {
        self.unmanagedValue = try decoder.singleValueContainer().decode(T.self)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
    }
}
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
