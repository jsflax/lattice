import Foundation
import SQLite3
import Combine

public protocol PersistableUnkeyedCollection {
    associatedtype Element: Property
}

private final class ManagedList<Element: Model>: Collection {
    private var lattice: Lattice
    private var parent: any Model
    private var countStatement: OpaquePointer?
    private var queryStatement: OpaquePointer?
    private var primaryKey: Int64
    private var parentGlobalId: String  // Store parent's globalId for link table queries
    private let name: String

    var tableName: String {
        let entityName = Element.entityName
        let parentEntityName = type(of: parent).entityName
        return "_\(parentEntityName)_\(entityName)_\(name)"
    }


    deinit {
        sqlite3_finalize(countStatement)
        sqlite3_finalize(queryStatement)
    }

    init(name: String, parent: any Model, lattice: Lattice, primaryKey: Int64) {
        self.lattice = lattice
        self.parent = parent
        self.primaryKey = primaryKey
        self.name = name

        // Get parent's globalId for link table queries
        self.parentGlobalId = parent.__globalId.uuidString.lowercased()

        // Link table uses globalIds (TEXT), so we need to quote the value
        let countQuery = "SELECT COUNT(*) FROM \(tableName) WHERE lhs = '\(parentGlobalId)';"

        if sqlite3_prepare_v2(lattice.db, countQuery, -1, &countStatement, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare count query for table \(Element.entityName)")
            fatalError()
        }

        // Query joins link table (by globalId) to child table to get child's local id
        // Order by link.rowid to preserve insertion order
        let queryStatementString = """
            SELECT e.id FROM \(Element.entityName) e
            INNER JOIN \(tableName) link ON link.rhs = e.globalId
            WHERE link.lhs = '\(parentGlobalId)'
            ORDER BY link.rowid
            LIMIT 1 OFFSET ?;
        """
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(lattice.db) {
                let errorString = String(cString: errorMessage)
                print("Error during sqlite3_step: \(errorString)")
            } else {
                print("Unknown error during sqlite3_step")
            }
            print("Failed to prepare query for table \(Element.entityName) with query: \(queryStatementString)")
            fatalError(queryStatementString)
        }
    }

    public subscript(index: Int) -> Element {
        get {
            defer { sqlite3_reset(queryStatement) }

            // Bind the offset
            sqlite3_bind_int(queryStatement, 1, Int32(index))

            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Get the child's local id from the JOIN result
                let id = Int64(sqlite3_column_int64(queryStatement, 0))
                return lattice.newObject(Element.self, primaryKey: id)
            } else {
                print(lattice.readError() ?? "Unknown")
            }

            fatalError()
        }
        set {
            if newValue.primaryKey == nil {
                lattice.add(newValue)
            }
            let rhsGlobalId = newValue.__globalId.uuidString.lowercased()
            // Update using globalIds
            let updateSQL = "UPDATE \(tableName) SET rhs = ? WHERE lhs = ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(lattice.db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (rhsGlobalId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (parentGlobalId as NSString).utf8String, -1, nil)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    print("Failed to update link in \(tableName)")
                }
            }
        }
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Results<Element> {
        return Results(lattice, whereStatement: nil, sortStatement: sortDescriptor)
    }
    
    public func `where`(_ query: @escaping Predicate<Element>) -> Results<Element> {
        return Results(lattice, whereStatement: query)
    }
    
    var startIndex: Int {
        0
    }
    
    public var endIndex: Int {
        count
    }
    
    
    public func observe(_ observer: @escaping @Sendable (Results<Element>.CollectionChange) -> Void) -> AnyCancellable {
        Results(lattice).observe(observer)
    }
    
    
    public func snapshot() -> [Element] {
        let queryStatementString = "SELECT id FROM \(Element.entityName)"
        defer { sqlite3_reset(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            var objects = [Element]()
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                let object = Element(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: lattice)
                object.primaryKey = id
                lattice.dbPtr.insertModelObserver(tableName: Element.entityName, primaryKey: id, object.weakCapture(isolation: lattice.isolation))
                objects.append(object)
            }
            return objects
        } else {
            print("SELECT statement could not be prepared.")
        }
                
        fatalError()
    }
    
    public func append(_ newElement: Element) {
        Optional<Element>._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newElement)
    }
    
    public func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
        lattice.add(contentsOf: newElements)
        for newElement in newElements {
            Optional<Element>._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newElement)
        }
    }
    
    public func remove(_ element: Element) {
        Optional<Element>._setNil(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, oldValue: element)
    }
    
    public func remove(at index: Int) -> Element {
        let element = self[index]
        remove(element)
        return element
    }
    
    public func removeAll() {
        // Use globalId for the WHERE clause
        let deleteSQL = "DELETE FROM \(tableName) WHERE lhs = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(lattice.db, deleteSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (parentGlobalId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) != SQLITE_DONE {
                if let errorMessage = lattice.readError() {
                    print("Error during sqlite3_step: \(errorMessage)")
                } else {
                    print("Unknown error")
                }
            }
        } else {
            print("ERROR: failed to prepare DELETE statement")
        }
    }
    
    func index(after i: Int) -> Int {
        i + 1
    }
    
    var count: Int {
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
//        sqlite3_finalize(countStatement)
        return count
    }
    
    public func first(where predicate: Predicate<Element>) -> Element? {
        // Table names
        let childTable = Element.entityName
        let linkTable  = tableName

        // Build the SQL WHERE fragment from your Swift predicate
        let filterSQL = predicate(Query<Element>()).predicate

        // Join child ↔ link on globalId = rhs, filter on lhs = parentGlobalId + your filter
        let sql = """
        SELECT c.*
          FROM \(childTable) AS c
          JOIN \(linkTable)   AS l
            ON c.globalId = l.rhs
         WHERE l.lhs = ?
           AND \(filterSQL)
         LIMIT 1;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(lattice.db, sql, -1, &stmt, nil) == SQLITE_OK else {
          print("⚠️ could not prepare first(where:)")
          return nil
        }

        // bind the parent's globalId as the lhs filter
        sqlite3_bind_text(stmt, 1, (parentGlobalId as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
          // no match
          return nil
        }

        // materialize the Element from the row
        let child = Element(isolation: #isolation)
        child.primaryKey = sqlite3_column_int64(stmt, 0)
        child._assign(lattice: lattice)
        return child
    }

    public func remove(where predicate: Predicate<Element>) {
        // 1) Table names
        let childTable  = Element.entityName
        let linkTable   = tableName

        // 2) Turn the Swift predicate into an SQL WHERE fragment:
        let filterSQL = predicate(Query<Element>()).predicate

        // 3) Delete from the link table where:
        //     • lhs = this parent's globalId
        //     • rhs IN (all child globalIds matching your filter)
        let sql = """
        DELETE FROM \(linkTable)
         WHERE lhs = ?
           AND rhs IN (
             SELECT globalId
               FROM \(childTable)
              WHERE \(filterSQL)
           );
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(lattice.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ Could not prepare delete(where:)", lattice.readError() ?? "unknown")
          return
        }

        // 4) Bind the parent's globalId:
        sqlite3_bind_text(stmt, 1, (parentGlobalId as NSString).utf8String, -1, nil)

        // 5) Execute the DELETE
        if sqlite3_step(stmt) != SQLITE_DONE {
          let err = String(cString: sqlite3_errmsg(lattice.db))
          print("⚠️ delete(where:) failed: \(err)")
          return
        }
    }
}

private class UnmanagedList<Element> {
    fileprivate var storage: Array<Element>
    
    init(storage: Array<Element>) {
        self.storage = storage
    }
}

public struct List<T>: MutableCollection, BidirectionalCollection, Property, ListProperty,
                       PersistableUnkeyedCollection, LinkProperty, Sendable, RandomAccessCollection where T: Model {
    public typealias ModelType = T
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
    public static var modelType: any Model.Type {
        T.self
    }
    
    public typealias DefaultValue = Array<T>
    
    private enum Storage: @unchecked Sendable {
        case unmanaged(UnmanagedList<T>)
        case managed(ManagedList<T>)
    }
    private let storage: Storage
    private init(_ storage: Storage) {
        self.storage = storage
    }
    public init() {
        self.storage = .unmanaged(UnmanagedList<T>(storage: []))
    }
    public static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> List<T> {
        return .init(.managed(ManagedList<T>(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)))
    }
    
    public static func _set(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: List<T>) {
        for model in newValue {
            Optional<T>._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: model)
        }
    }
    
    public var startIndex: Int = 0

    
    public func index(after i: Int) -> Int {
        i + 1
    }
    public func index(before i: Int) -> Int {
        i - 1
    }
    public enum CollectionChange {
        case insert(Int64)
        case delete(Int64)
    }
    
    public var endIndex: Int {
        switch storage {
        case .unmanaged(let unmanaged): unmanaged.storage.endIndex
        case .managed(let managed): managed.endIndex
        }
    }
    
    public subscript(position: Int) -> T {
        get {
            switch storage {
            case .unmanaged(let unmanaged): unmanaged.storage[position]
            case .managed(let managed): managed[position]
            }
        } set {
            switch storage {
            case .unmanaged(let unmanaged):
                unmanaged.storage[position] = newValue
            case .managed(let managed):
                managed[position] = newValue
            }
        }
    }
//    
//    public subscript(safe: Int) -> T? {
//        get {
//            switch storage {
//            case .unmanaged(let unmanaged): unmanaged.storage[safe]
//            case .managed(let managed): managed[safe]
//            }
//        } set {
//            switch storage {
//            case .unmanaged(let unmanaged):
//                unmanaged.storage[safe] = newValue
//            case .managed(let managed):
//                managed[safe] = newValue
//            }
//        }
//    }
    
    public func append(_ newElement: T) {
        switch storage {
        case .unmanaged(let unmanaged):
            unmanaged.storage.append(newElement)
        case .managed(let managed):
            managed.append(newElement)
        }
    }
    
    public func append<S: Sequence>(contentsOf newElements: S) where S.Element == T {
        switch storage {
        case .unmanaged(let unmanaged):
            unmanaged.storage.append(contentsOf: newElements)
        case .managed(let managed):
            managed.append(contentsOf: newElements)
        }
    }
    
    public func remove(_ element: Element) {
        switch storage {
        case .unmanaged(let unmanaged):
            guard let position = unmanaged.storage.firstIndex(of: element) else { return }
            unmanaged.storage.remove(at: position)
        case .managed(let managed):
            managed.remove(element)
        }
    }
    
    public func remove(at position: Int) -> T {
        switch storage {
        case .unmanaged(let unmanaged):
            let removedValue = unmanaged.storage.remove(at: position)
            return removedValue
        case .managed(let managed):
            let removedValue = managed.remove(at: position)
            return removedValue
        }
    }
    
    public func removeAll() {
        switch storage {
        case .unmanaged(let unmanaged):
            unmanaged.storage.removeAll()
        case .managed(let managed):
            managed.removeAll()
        }
    }
    
    public func first(where predicate: Predicate<Element>) -> Element? {
        switch storage {
        case .unmanaged(let unmanaged):
            // TODO: Unwind predicate into actual builtin filter
            fatalError()
        case .managed(let managed):
            managed.first(where: predicate)
        }
    }
    
    public func remove(where predicate: Predicate<Element>) {
        switch storage {
        case .unmanaged(let unmanaged):
            // TODO: Unwind predicate into actual builtin filter
            fatalError()
        case .managed(let managed):
            managed.remove(where: predicate)
        }
    }
    
    public func snapshot() -> [Element] {
        switch self.storage {
        case .unmanaged(let unmanaged):
            return unmanaged.storage
        case .managed(let managed):
            return managed.snapshot()
        }
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Results<Element> {
        switch self.storage {
        case .unmanaged(let unmanaged):
            fatalError()
        case .managed(let managed):
            managed.sortedBy(sortDescriptor)
        }
    }
}

extension List {
    public static func +(lhs: List, rhs: List) -> Array<Element> {
        lhs.map { $0 } + rhs.map { $0 }
    }
}

// MARK: Codable Support
extension List: Codable where Element: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let count = container.count else {
            self.storage = .unmanaged(UnmanagedList.init(storage: []))
            return
        }
        
        self.storage = .unmanaged(UnmanagedList.init(storage: try (0..<(container.count ?? 0)).map { _ in
            try container.decode(Element.self)
        }))
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: self.map(\.self))
    }
}


public typealias LatticeList = List

extension Lattice {
    public typealias List = LatticeList
}
