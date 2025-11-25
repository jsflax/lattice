import Foundation
import SQLite3
import Combine

public final class Results<Element>: Sequence where Element: Model {
    private let lattice: Lattice
    internal let whereStatement: Predicate<Element>?
    internal let sortStatement: SortDescriptor<Element>?
    private var countStatement: OpaquePointer?
    private var queryStatement: OpaquePointer?
    
    public final class Cursor: IteratorProtocol {
        private var queryStatement: OpaquePointer?
        private let lattice: Lattice
        
        package init(_ results: Results, limit: Int? = nil, offset: Int? = nil) {
            self.lattice = results.lattice
            let queryStatementString =
            String(format: "SELECT id FROM \(Element.entityName) %@ %@ %@ %@;",
                   results.whereStatement == nil ? "" : "WHERE \(results.whereStatement!(Query<Element>()).predicate)",
                   results.sortStatement == nil ? "" : "ORDER BY \(_name(for: results.sortStatement!.keyPath!)) \(results.sortStatement!.order == .forward ? "ASC" : "DESC")",
                   limit == nil ? "" : "LIMIT \(limit!)",
                   offset == nil ? "" : "OFFSET \(offset!)")
            if sqlite3_prepare_v2(results.lattice.dbPtr.readDb, queryStatementString, -1, &queryStatement, nil) != SQLITE_OK {
                if let errorMessage = sqlite3_errmsg(results.lattice.dbPtr.readDb) {
                    let errorString = String(cString: errorMessage)
                    print("Error during sqlite3_step: \(errorString)")
                } else {
                    print("Unknown error during sqlite3_step")
                }
                print("Failed to prepare SELECT query for table \(Element.entityName) with query: \(queryStatementString)")
                fatalError(queryStatementString)
            }
        }
        
        fileprivate var cache: [Int: Element] = [:]
        fileprivate var index = 0
        public func next() -> Element? {
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                index += 1
                let id = sqlite3_column_int64(queryStatement, 0)
                let newObject = lattice.newObject(Element.self, primaryKey: id)
    //            cache[index] = newObject
                return newObject
            }
            return nil
        }
        
        public var startIndex: Int = 0
        
        deinit {
            sqlite3_finalize(queryStatement)
        }
    }

            
    public func makeIterator() -> Cursor {
        Cursor(self)
    }
    
    public typealias SubSequence = Slice
    
    public class Slice: RandomAccessCollection {
        public var startIndex: Int = 0
        
        public var endIndex: Int
        private let cursor: Cursor
        public typealias Index = Int
        
        fileprivate init(cursor: Cursor, startIndex: Int, endIndex: Int) {
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.cursor = cursor
        }
        
        public subscript(bounds: Range<Int>) -> SubSequence {
            .init(cursor: cursor, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
        }
        
        private var cache: [Int: Element] = [:]
        public subscript(position: Int) -> Element {
            
            get {
                let localPosition = (endIndex - startIndex) - (endIndex - position)
                while cursor.index <= localPosition, let element = cursor.next() {
                    cache[cursor.index - 1] = element
                }
                if let element = cache[localPosition] {
                    return element
                } else {
                    fatalError()
                }
            }
        }
        
        public func index(after i: Int) -> Int {
            i + 1
        }
    }
    
    private var token: AnyCancellable?
    
    init(_ lattice: Lattice, whereStatement: Predicate<Element>? = nil, sortStatement: SortDescriptor<Element>? = nil) {
        self.lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        let countQuery = if let whereStatement {
            "SELECT COUNT(*) FROM \(Element.entityName) WHERE \(whereStatement(Query<Element>()).predicate);"
        } else {
            "SELECT COUNT(*) FROM \(Element.entityName);"
        }
        
        if sqlite3_prepare_v2(lattice.dbPtr.readDb, countQuery, -1, &countStatement, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare count query for table \(Element.entityName): \(countQuery)")
            print("Failed predicate: \(whereStatement?(Query<Element>()).predicate ?? "<unknown>")")
            fatalError()
        }
        
        let queryStatementString =
        String(format: "SELECT id FROM \(Element.entityName) %@ %@ LIMIT 1 OFFSET ?;",
               whereStatement == nil ? "" : "WHERE \(whereStatement!(Query<Element>()).predicate)",
               sortStatement == nil ? "" : "ORDER BY \(_name(for: sortStatement!.keyPath!)) \(sortStatement!.order == .forward ? "ASC" : "DESC")")
        if sqlite3_prepare_v2(lattice.dbPtr.readDb, queryStatementString, -1, &queryStatement, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare count query for table \(Element.entityName) with query: \(countQuery)")
            fatalError(countQuery)
        }
        
//        token = self.observe { change in
//            self.lastCount = nil
//        }
    }
    
    public subscript(index: Int) ->  Element {
//        let queryStatementString =
//        String(format: "SELECT * FROM \(Element.entityName) %@ %@ LIMIT 1 OFFSET \(index);",
//               whereStatement == nil ? "" : "WHERE \(whereStatement!(Query<Element>()).predicate)",
//               sortStatement == nil ? "" : "ORDER BY \(_name(for: sortStatement!.keyPath!)) \(sortStatement!.order == .forward ? "ASC" : "DESC")")
                
        sqlite3_bind_int(queryStatement, 1, Int32(index))
        defer { sqlite3_reset(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = sqlite3_column_int64(queryStatement, 0)
                return lattice.newObject(Element.self, primaryKey: id)
            }
//        } else {
//            print("SELECT statement could not be prepared.")
//        }
        
        fatalError()
    }
    
    public subscript(bounds: Range<Int>) -> Slice {
        return Slice.init(cursor: Cursor(self, limit: bounds.upperBound - bounds.lowerBound,
                                         offset: bounds.lowerBound),
                          startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Results<Element> {
        return Results(lattice, whereStatement: whereStatement, sortStatement: sortDescriptor)
    }
    
    public func `where`(_ query: @escaping @Sendable Predicate<Element>) -> Results<Element> {
        return Results(lattice, whereStatement: query)
    }
    
    public var startIndex: Int = 0
    
    deinit {
        sqlite3_finalize(countStatement)
        sqlite3_finalize(queryStatement)
        token?.cancel()
    }
    
    private var lastCount: Int?
    private var dynamicCount: Int {
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
            print("Failed to prepare count query for table \(Element.entityName)")
            fatalError()
        }
        sqlite3_reset(countStatement)
        lastCount = count
        return count
    }
    
    public var endIndex: Int {
        dynamicCount
    }
    
    public func index(after i: Int) -> Int {
        i + 1
    }

    public enum CollectionChange: Sendable {
        case insert(Int64)
        case delete(Int64)
    }
    
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        lattice.observe(Element.self, where: self.whereStatement) { change in
            observer(change)
        }
    }
    
    
//    public func first(where: ((Query<Element>) -> Query<Bool>)) -> T? {
//        let queryStmtString = """
//        SELECT id
//          FROM \(Element.entityName)
//         WHERE \(whereStatement!(Query<Element>()).predicate)
//         ORDER BY id   ASC
//         LIMIT 1;
//        """
//        var queryStatement: OpaquePointer?
//        defer { sqlite3_finalize(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStmtString, -1, &queryStatement, nil) == SQLITE_OK {
//            
//            if sqlite3_step(queryStatement) == SQLITE_ROW {
//                let id = sqlite3_column_int64(queryStatement, 0)
//                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
//                object._assign(lattice: lattice)
//                object.primaryKey = id
//                lattice.dbPtr.insertModelObserver(tableName: Element.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
//                return object
//            } else {
//                if let errorMessage = sqlite3_errmsg(lattice.db) {
//                    let errorString = String(cString: errorMessage)
//                    print("Error during sqlite3_step: \(errorString)")
//                } else {
//                    print("Unknown error during sqlite3_step")
//                }
//            }
//        }
//        
//        fatalError()
//    }
//    
//    public func last(where: ((Query<Element>) -> Query<Bool>)) -> T? {
//        let queryStmtString = """
//        SELECT id
//          FROM \(Element.entityName)
//         WHERE \(whereStatement!(Query<Element>()).predicate)
//         ORDER BY id DESC
//         LIMIT 1;
//        """
//        var queryStatement: OpaquePointer?
//        defer { sqlite3_finalize(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStmtString, -1, &queryStatement, nil) == SQLITE_OK {
//            
//            if sqlite3_step(queryStatement) == SQLITE_ROW {
//                let id = sqlite3_column_int64(queryStatement, 0)
//                let object = Element(isolation: #isolation) // Person(id: personId, name: name, age: age)
//                object._assign(lattice: lattice)
//                object.primaryKey = id
//                lattice.dbPtr.insertModelObserver(tableName: Element.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
//                return object
//            } else {
//                if let errorMessage = sqlite3_errmsg(lattice.db) {
//                    let errorString = String(cString: errorMessage)
//                    print("Error during sqlite3_step: \(errorString)")
//                } else {
//                    print("Unknown error during sqlite3_step")
//                }
//            }
//        }
//        
//        fatalError()
//    }
//    
    public func snapshot() -> [Element] {
        let queryStatementString =
        String(format: "SELECT id FROM \(Element.entityName) %@ %@;",
               whereStatement == nil ? "" : "WHERE \(whereStatement!(Query<Element>()).predicate)",
               sortStatement == nil ? "" : "ORDER BY \(_name(for: sortStatement!.keyPath!)) \(sortStatement!.order == .forward ? "ASC" : "DESC")")
        
        defer { sqlite3_reset(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            var objects = [Element]()
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                objects.append(lattice.newObject(Element.self, primaryKey: id))
            }
            return objects
        } else {
            print("SELECT statement could not be prepared.")
        }
                
        fatalError()
    }
}

@propertyWrapper public struct Relation<EnclosingType: Model, Element: Model> {
    public typealias Value = Results<Element>
    
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
    
    private let link: KeyPath<Element, EnclosingType?> & Sendable
    public init(link: KeyPath<Element, EnclosingType?> & Sendable) {
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


