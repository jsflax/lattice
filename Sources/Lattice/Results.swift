import Foundation
import SQLite3

public struct Results<T>: Collection where T: Model {
    private let lattice: Lattice
    private let whereStatement: Predicate<T>?
    
    init(_ lattice: Lattice, whereStatement: Predicate<T>? = nil) {
        self.lattice = lattice
        self.whereStatement = whereStatement
    }
    
    public subscript(index: Int) -> T {
        let queryStatementString = if let whereStatement {
            "SELECT * FROM \(T.entityName) WHERE \(whereStatement(Query<T>()).predicate) LIMIT 1 OFFSET \(index);"
        } else {
            "SELECT * FROM \(T.entityName) LIMIT 1 OFFSET \(index);"
        }
        var queryStatement: OpaquePointer?
        
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = T() // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice, statement: queryStatement)
                object.primaryKey = id
                Lattice.observationRegistrar[T.entityName, default: [:]][id, default: []].append(object.weakCapture)
                return object
            }
        } else {
            print("SELECT statement could not be prepared.")
        }
        
        fatalError()
    }
    
    
    public func `where`(_ query: @escaping Predicate<T>) -> Results<T> {
        return Results(lattice, whereStatement: query)
    }
    
    public var startIndex: Int = 0
    
    public var endIndex: Int {
        var count = 0
        let countQuery = if let whereStatement {
            "SELECT COUNT(*) FROM \(T.entityName) WHERE \(whereStatement(Query<T>()).predicate);"
        } else {
            "SELECT COUNT(*) FROM \(T.entityName);"
        }
        var countStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(lattice.db, countQuery, -1, &countStatement, nil) == SQLITE_OK {
            if sqlite3_step(countStatement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(countStatement, 0))
            }
        } else {
            print("Failed to prepare count query for table \(T.entityName)")
        }
        
        sqlite3_finalize(countStatement)
        return count
    }
    
    public func index(after i: Int) -> Int {
        i + 1
    }

    public enum CollectionChange {
        case insert(Int64)
        case delete(Int64)
    }
    
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        lattice.observe(T.self, where: self.whereStatement) { change in
            observer(change)
        }
    }
}

import Combine

public class ObservationCancellable<T: Model>: Cancellable, Identifiable {
    
    public var id: ObjectIdentifier!
    
    init() {
        id = ObjectIdentifier(self)
    }
    
    public func cancel() {
        Lattice.tableObservationRegistrar[T.entityName]?[id] = nil
    }
}
