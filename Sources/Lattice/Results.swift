import Foundation
import SQLite3
import Combine

public final class Results<T>: Sequence where T: Model {
    private let lattice: Lattice
    internal let whereStatement: Predicate<T>?
    internal let sortStatement: SortDescriptor<T>?
    private var countStatement: OpaquePointer?
    private var queryStatement: OpaquePointer?
    
    public class Iterator: IteratorProtocol {
        private var queryStatement: OpaquePointer?
        private var lattice: Lattice
        
        deinit { sqlite3_finalize(queryStatement) }
        
        init(results: Results<T>) {
            let queryStatementString = String(format: "SELECT id FROM \(T.entityName) %@ %@;",
                   results.whereStatement == nil ? "" : "WHERE \(results.whereStatement!(Query<T>()).predicate)",
                   results.sortStatement == nil ? "" : "ORDER BY \(_name(for: results.sortStatement!.keyPath!)) \(results.sortStatement!.order == .forward ? "ASC" : "DESC")")
            guard sqlite3_prepare_v2(results.lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK else {
                fatalError()
            }
            self.lattice = results.lattice
        }
        
        public func next() -> T? {
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Bind the provided id to the statement.
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice)
                object.primaryKey = id
                lattice.dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
                return object
            }
            return nil
        }
    }
            
    public func makeIterator() -> Iterator {
        Iterator(results: self)
    }
    
    init(_ lattice: Lattice, whereStatement: Predicate<T>? = nil, sortStatement: SortDescriptor<T>? = nil) {
        self.lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        let countQuery = if let whereStatement {
            "SELECT COUNT(*) FROM \(T.entityName) WHERE \(whereStatement(Query<T>()).predicate);"
        } else {
            "SELECT COUNT(*) FROM \(T.entityName);"
        }
        
        if sqlite3_prepare_v2(lattice.db, countQuery, -1, &countStatement, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare count query for table \(T.entityName)")
            print("Failed predicate: \(whereStatement?(Query<T>()).predicate ?? "<unknown>")")
            fatalError()
        }
        
        let queryStatementString =
        String(format: "SELECT id FROM \(T.entityName) %@ %@ LIMIT 1 OFFSET ?;",
               whereStatement == nil ? "" : "WHERE \(whereStatement!(Query<T>()).predicate)",
               sortStatement == nil ? "" : "ORDER BY \(_name(for: sortStatement!.keyPath!)) \(sortStatement!.order == .forward ? "ASC" : "DESC")")
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare count query for table \(T.entityName) with query: \(countQuery)")
            fatalError(countQuery)
        }
    }
    
    public subscript(index: Int) -> T {
//        let queryStatementString =
//        String(format: "SELECT * FROM \(T.entityName) %@ %@ LIMIT 1 OFFSET \(index);",
//               whereStatement == nil ? "" : "WHERE \(whereStatement!(Query<T>()).predicate)",
//               sortStatement == nil ? "" : "ORDER BY \(_name(for: sortStatement!.keyPath!)) \(sortStatement!.order == .forward ? "ASC" : "DESC")")
                
        sqlite3_bind_int(queryStatement, 1, Int32(index))
        defer { sqlite3_reset(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice)
                object.primaryKey = id
                lattice.dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
                return object
            }
//        } else {
//            print("SELECT statement could not be prepared.")
//        }
        
        fatalError()
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<T>) -> Results<T> {
        return Results(lattice, whereStatement: whereStatement, sortStatement: sortDescriptor)
    }
    
    public func `where`(_ query: @escaping @Sendable Predicate<T>) -> Results<T> {
        return Results(lattice, whereStatement: query)
    }
    
    public var startIndex: Int = 0
    
    deinit {
        sqlite3_finalize(countStatement)
        sqlite3_finalize(queryStatement)
    }
    
    public var endIndex: Int {
        var count = 0
        
        if sqlite3_step(countStatement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(countStatement, 0))
        } else {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare count query for table \(T.entityName)")
            fatalError()
        }
        sqlite3_reset(countStatement)
//        sqlite3_finalize(countStatement)
        return count
    }
    
    public func index(after i: Int) -> Int {
        i + 1
    }

    public enum CollectionChange: Sendable {
        case insert(Int64)
        case delete(Int64)
    }
    
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        lattice.observe(T.self, where: self.whereStatement) { change in
            observer(change)
        }
    }
    
    
    public func first(where: ((Query<T>) -> Query<Bool>)) -> T? {
        let queryStmtString = """
        SELECT id
          FROM \(T.entityName)
         WHERE \(whereStatement!(Query<T>()).predicate)
         ORDER BY id   ASC
         LIMIT 1;
        """
        var queryStatement: OpaquePointer?
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStmtString, -1, &queryStatement, nil) == SQLITE_OK {
            
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice)
                object.primaryKey = id
                lattice.dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
                return object
            } else {
                if let errorMessage = sqlite3_errmsg(lattice.db) {
                    let errorString = String(cString: errorMessage)
                    print("Error during sqlite3_step: \(errorString)")
                } else {
                    print("Unknown error during sqlite3_step")
                }
            }
        }
        
        fatalError()
    }
    
    public func last(where: ((Query<T>) -> Query<Bool>)) -> T? {
        let queryStmtString = """
        SELECT id
          FROM \(T.entityName)
         WHERE \(whereStatement!(Query<T>()).predicate)
         ORDER BY id DESC
         LIMIT 1;
        """
        var queryStatement: OpaquePointer?
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStmtString, -1, &queryStatement, nil) == SQLITE_OK {
            
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice)
                object.primaryKey = id
                lattice.dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
                return object
            } else {
                if let errorMessage = sqlite3_errmsg(lattice.db) {
                    let errorString = String(cString: errorMessage)
                    print("Error during sqlite3_step: \(errorString)")
                } else {
                    print("Unknown error during sqlite3_step")
                }
            }
        }
        
        fatalError()
    }
    
    public func snapshot() -> [T] {
        let queryStatementString =
        String(format: "SELECT id FROM \(T.entityName) %@ %@;",
               whereStatement == nil ? "" : "WHERE \(whereStatement!(Query<T>()).predicate)",
               sortStatement == nil ? "" : "ORDER BY \(_name(for: sortStatement!.keyPath!)) \(sortStatement!.order == .forward ? "ASC" : "DESC")")
        
        defer { sqlite3_reset(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            var objects = [T]()
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice)
                object.primaryKey = id
                lattice.dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
                objects.append(object)
            }
            return objects
        } else {
            print("SELECT statement could not be prepared.")
        }
                
        fatalError()
    }
}

@propertyWrapper public struct Relation<EnclosingType: Model, T: Model> {
    public typealias Value = Results<T>
    
    public static subscript(
        _enclosingInstance instance: EnclosingType,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingType, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingType, Self>
    ) -> Value {
        get {
            guard let lattice = instance.lattice, let primaryKey = instance.primaryKey else {
                fatalError("Cannot use @Relation on an instance that is not yet inserted into the database")
            }
            let link = instance[keyPath: storageKeyPath].link
            
            return Results(lattice, whereStatement: {
                $0[dynamicMember: link].primaryKey == primaryKey
            })
        }
        set {
            
        }
    }
    
    @available(*, unavailable,
                message: "@Relation can only be applied to models")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }
    
    private let link: KeyPath<T, EnclosingType?> & Sendable
    public init(link: KeyPath<T, EnclosingType?> & Sendable) {
        self.link = link
    }
}

//@propertyWrapper public struct InverseRelation<EnclosingType: Model, Parent: Model> {
//    public typealias Value = Results<Parent>
//    
//    public static subscript(
//        _enclosingInstance instance: EnclosingType,
//        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingType, Value>,
//        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingType, Self>
//    ) -> Value {
//        get {
//            guard let lattice = instance.lattice, let primaryKey = instance.primaryKey else {
//                fatalError("Cannot use @Relation on an instance that is not yet inserted into the database")
//            }
//            let link = instance[keyPath: storageKeyPath].link
//            
//            return Results(lattice, whereStatement: {
//                $0.primaryKey.in($0[dynamicMember: link])
//            })
//        }
//        set {
//            
//        }
//    }
//    
//    @available(*, unavailable,
//                message: "@Relation can only be applied to models")
//    public var wrappedValue: Value {
//        get { fatalError() }
//        set { fatalError() }
//    }
//    
//    private let link: KeyPath<Parent, Array<EnclosingType>> & Sendable
//    public init(link: KeyPath<Parent, Array<EnclosingType>> & Sendable) {
//        self.link = link
//    }
//}

extension Results: RandomAccessCollection {
}


