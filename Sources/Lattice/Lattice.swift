import SQLite3
import Foundation

@attached(accessor, names: arbitrary)
public macro Property() = #externalMacro(module: "LatticeMacros",
                                          type: "ModelMacro")

extension OpaquePointer: @unchecked @retroactive Sendable {}

// Assuming your model macro handles persistence, mapping, etc.
@Model class AuditLog {
    enum Operation: String, LatticeEnum, Codable {
        case insert = "INSERT", update = "UPDATE", delete = "DELETE"
    }
    
    /// Name of the affected table, e.g., "Person"
    var tableName: String
    /// Operation type: "INSERT", "UPDATE", "DELETE", etc.
    var operation: Operation = .insert
    /// The id of the record that was affected in the target table
    var rowId: Int64
    /// JSON string containing the changed fields (if any)
    var changedFields: [String: AnyProperty]
    /// Timestamp for when the change occurred
    var timestamp: Date
}

// Define callback function for update hook.
// This function must match the expected C function pointer signature.
private func updateHookCallback(
    pArg: UnsafeMutableRawPointer?,
    operation: Int32,
    databaseName: UnsafePointer<Int8>?,
    tableName: UnsafePointer<Int8>?,
    rowId: sqlite3_int64
) {
    // Map the operation code to a human-readable string.
    let op: String
    switch operation {
    case SQLITE_INSERT:
        op = "INSERT"
    case SQLITE_DELETE:
        op = "DELETE"
    case SQLITE_UPDATE:
        op = "UPDATE"
    default:
        op = "UNKNOWN"
    }
    
    let dbNameStr = databaseName.map { String(cString: $0) } ?? "unknown"
    let tableNameStr = tableName.map { String(cString: $0) } ?? "unknown"
    let lattice = pArg?.assumingMemoryBound(to: Lattice.self).pointee

    guard tableNameStr == "AuditLog", let lattice else {
        return
    }
    guard let audit = lattice.object(AuditLog.self, primaryKey: rowId) else {
        return
    }
    print(audit.timestamp)
    Lattice.observationRegistrar[audit.tableName]?[Int64(audit.rowId)]?.forEach {
        guard let model = $0() else {
            return
        }
        model._objectWillChange_send()
        let keyPath = audit.changedFields.first(where: { $0.value.kind != .null })!.key
        model._triggerObservers_send(keyPath: keyPath)
    }
    Lattice.tableObservationRegistrar[audit.tableName]?.forEach { observer in
        observer.value(audit)
    }
    print("SQLite Update Hook triggered: \(op) on database: \(dbNameStr), table: \(tableNameStr), row id: \(rowId)")
}

import Combine

//class LatticeSubscriber<T>: Subscription {
//    func request(_ demand: Subscribers.Demand) {
//        
//    }
//    
//    func cancel() {
//        
//    }
//}

extension Model {
    var weakCapture: (() -> Self?) {
        return { [weak self] in
            return self
        }
    }
}

public class Lattice {
    var db: OpaquePointer?
//    var observers: [AnyObject: () -> Void] = [:]
    private let ptr: UnsafeMutablePointer<Lattice>
    public nonisolated(unsafe) static var observationRegistrar: [
        String: [
            Int64: [() -> (any Model)?]
        ]
    ] = [:]
    nonisolated(unsafe) static var tableObservationRegistrar: [
        String: [
            ObjectIdentifier: ((AuditLog) -> ())
        ]
    ] = [:]
    
    func count<T>(_ modelType: T.Type, where: Predicate<T>? = nil) -> Int where T: Model {
        var count = 0
        let whereStatement = `where`?(Query<T>()).predicate
        let countQuery = if let whereStatement {
            "SELECT COUNT(*) FROM \(T.entityName) WHERE \(whereStatement);"
        } else {
            "SELECT COUNT(*) FROM \(T.entityName);"
        }
        var countStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, countQuery, -1, &countStatement, nil) == SQLITE_OK {
            if sqlite3_step(countStatement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(countStatement, 0))
            }
        } else {
            print("Failed to prepare count query for table \(T.entityName)")
        }
        
        sqlite3_finalize(countStatement)
        return count
    }
    
    public func observe<T: Model>(_ modelType: T.Type, where: Predicate<T>? = nil,
                                  block: @escaping (Results<T>.CollectionChange) -> ()) -> AnyCancellable {
        let cancellable = ObservationCancellable<T>()
        Self.tableObservationRegistrar[T.entityName, default: [:]][cancellable.id] = { auditLog in
            switch auditLog.operation {
            case .insert:
                if let `where` {
                    if let row = Results<AuditLog>(self).where({
                        $0.rowId == auditLog.rowId && `where`(Query<T>(isAuditing: true)).convertKeyPathsToEmbedded(rootPath: "changedFields") && $0.operation == .insert
                    }).first {
                        block(.insert(auditLog.rowId))
                    }
                } else {
                    if let object = self.object(modelType, primaryKey: auditLog.rowId) {
                        block(.insert(object.primaryKey!))
                    }
                }
            case .delete:
                if let `where` {
                    if let row = Results<AuditLog>(self).where({
                        $0.rowId == auditLog.rowId && `where`(Query<T>()).convertKeyPathsToEmbedded(rootPath: "changedFields") && $0.operation == .delete
                    }).first {
                        block(.delete(row.rowId))
                    }
                } else {
                    if let row = Results<AuditLog>(self).first {
                        block(.delete(row.rowId))
                    }
                }
            case .update: break
            }
        }
        return AnyCancellable(cancellable)
    }
    
    init(_ modelTypes: any Model.Type...) throws {
        let fileURL = try FileManager.default
            .url(for: .documentDirectory,
                 in: .userDomainMask,
                 appropriateFor: nil,
                 create: false)
            .appendingPathComponent("test.sqlite")
        
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open database."])
        }
        // Register the update hook to listen for changes.
        if sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil) != SQLITE_OK {
            print("Error enabling foreign keys.")
        }
//        var this = self
        ptr = UnsafeMutablePointer<Lattice>.allocate(capacity: 1)
        ptr.pointee = self

        sqlite3_update_hook(db, updateHookCallback, ptr)
        let auditTableSQL = """
        CREATE TABLE IF NOT EXISTS AuditLog(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tableName TEXT,
            operation TEXT,
            rowId INTEGER,
            changedFields TEXT,
            timestamp REAL DEFAULT (unixepoch())
        );
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, auditTableSQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("Audit table created successfully.")
            } else {
                print("Could not create Audit table.")
            }
        } else {
            print("CREATE TABLE statement could not be prepared.")
        }
        sqlite3_finalize(statement)
        for type in modelTypes {
            createTable(type)
        }
    }
    
    func printHello() {
        print("hello")
    }
    
    deinit {
        sqlite3_close(db)
        ptr.deallocate()
    }
    
    private func createTable(_ modelType: any Model.Type) {
        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS \(modelType.entityName)(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                \(modelType.properties.map { "\($0.0) \($0.1.sqlType)" }.joined(separator: ",\n"))
            );
            """
        let createAuditTriggerSQL = """
        CREATE TRIGGER AuditLog_Update_\(modelType.entityName) AFTER UPDATE ON \(modelType.entityName)
        WHEN (\(modelType.properties.map { "OLD.\($0.0) IS NOT NEW.\($0.0)" }.joined(separator: " OR ")))
        BEGIN
            INSERT INTO AuditLog (tableName, operation, rowId, changedFields, timestamp)
            VALUES (
                '\(modelType.entityName)',
                'UPDATE',
                OLD.id,
                json_object(
                    \(modelType.properties.map {
                        "'\($0.0)', CASE WHEN OLD.\($0.0) IS NOT NEW.\($0.0) THEN NEW.\($0.0) ELSE NULL END"
                    }.joined(separator: ","))
                ),
                unixepoch()
            );
        END;    
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableSQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("Person table created successfully.")
            } else {
                print("Could not create Person table.")
            }
        } else {
            print("CREATE TABLE statement could not be prepared.")
        }
        executeStatement(createAuditTriggerSQL)
        // Trigger for insertions
        executeStatement("""
        CREATE TRIGGER Audit\(modelType.entityName)Insert AFTER INSERT ON \(modelType.entityName)
        BEGIN
          INSERT INTO AuditLog (tableName, operation, rowId, changedFields, timestamp)
          VALUES (
            '\(modelType.entityName)',
            'INSERT',
            NEW.id,
            json_object(
                \(modelType.properties.map {
                    "'\($0.0)', NEW.\($0.0)"
                }.joined(separator: ","))
            ),
            CURRENT_TIMESTAMP
          );
        END;
        """)
        // Trigger for deletions
        executeStatement("""
        CREATE TRIGGER Audit\(modelType.entityName)Delete AFTER DELETE ON \(modelType.entityName)
        BEGIN
         INSERT INTO AuditLog (tableName, operation, rowId, changedFields, timestamp)
         VALUES (
           '\(modelType.entityName)',
           'DELETE',
           OLD.id,
            json_object(
                \(modelType.properties.map {
                    "'\($0.0)', OLD.\($0.0)"
                }.joined(separator: ","))
            ),
           CURRENT_TIMESTAMP
         );
        END;
        """)
    }
    
    private func executeStatement(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("Statement executed successfully.")
            } else {
                print("Statement could not be executed.")
            }
        }
        sqlite3_finalize(statement)
    }
    
    func add<T: Model>(_ object: T) {
        let insertStatementString = "INSERT INTO \(T.entityName) (\(T.properties.map(\.0).joined(separator: ", "))) VALUES (\(T.properties.map { _ in "?" }.joined(separator: ", ")));"
        var insertStatement: OpaquePointer?
        
        defer {
            sqlite3_finalize(insertStatement)
        }
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            object._assign(lattice: self, statement: insertStatement)
            object._encode(statement: insertStatement)
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                // Retrieve the last inserted rowid.
                let id = sqlite3_last_insert_rowid(db)
                Self.observationRegistrar[T.entityName, default: [:]][id, default: []].append(object.weakCapture)
                print("Successfully inserted person: \(object). New id: \(id)")
                object.primaryKey = id
            } else {
                print("Could not insert person: \(object).")
            }
        } else {
            print("INSERT statement could not be prepared.")
        }
    }
    
    func insertPerson(name: String, age: Int32) -> Int32? {
        let insertStatementString = "INSERT INTO Person (name, age) VALUES (?, ?);"
        var insertStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_int(insertStatement, 2, age)
            
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                // Retrieve the last inserted rowid.
                let id = sqlite3_last_insert_rowid(db)
                sqlite3_finalize(insertStatement)
                print("Successfully inserted person: \(name), Age: \(age). New id: \(id)")
                return Int32(id)
            } else {
                print("Could not insert person: \(name).")
            }
        } else {
            print("INSERT statement could not be prepared.")
        }
        sqlite3_finalize(insertStatement)
        return nil
    }
    
    func updatePerson(id: Int32, newName: String, newAge: Int32) {
        let updateStatementString = "UPDATE Person SET name = ?, age = ? WHERE id = ?;"
        var updateStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateStatementString, -1, &updateStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(updateStatement, 1, (newName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(updateStatement, 2, newAge)
            sqlite3_bind_int(updateStatement, 3, id)
            
            if sqlite3_step(updateStatement) == SQLITE_DONE {
                print("Successfully updated person with id \(id) to name: \(newName), age: \(newAge).")
            } else {
                print("Could not update person with id \(id).")
            }
        } else {
            print("UPDATE statement could not be prepared.")
        }
        sqlite3_finalize(updateStatement)
    }
    
    public func object<T>(_ type: T.Type = T.self, primaryKey: Int64) -> T? where T: Model {
        let queryStatementString = "SELECT * FROM \(T.entityName) WHERE id = ?;"
        var queryStatement: OpaquePointer?
        
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            sqlite3_bind_int64(queryStatement, 1, primaryKey)
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                print( sqlite3_column_int(queryStatement, 2))
                let object = T() // Person(id: personId, name: name, age: age)
                object._assign(lattice: self, statement: queryStatement)
                object.primaryKey = id
                Self.observationRegistrar[T.entityName, default: [:]][id, default: []].append(object.weakCapture)
                return object
            }
        } else {
            print("SELECT statement could not be prepared.")
        }
        
        return nil
    }
    
    public func objects<T>(_ type: T.Type = T.self) -> Results<T> where T: Model {
        Results(self)
//        let queryStatementString = "SELECT * FROM \(T.entityName);"
//        var queryStatement: OpaquePointer?
//        
//        defer { sqlite3_finalize(queryStatement) }
//        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
//            // Bind the provided id to the statement.
//            var objects: [T] = []
//            while sqlite3_step(queryStatement) == SQLITE_ROW {
//                // Extract id, name, and age from the row.
//                let id = sqlite3_column_int64(queryStatement, 0)
//                let object = T() // Person(id: personId, name: name, age: age)
//                object._assign(lattice: self, statement: queryStatement)
//                object.primaryKey = id
//                objects.append(object)
//                Self.observationRegistrar[T.entityName, default: [:]][id, default: []].append(object)
//            }
//            return objects
//        } else {
//            print("SELECT statement could not be prepared.")
//        }
//        
//        return []
    }
    
    public func delete<T: Model>(_ object: T) -> Bool {
        guard object.primaryKey != nil else { return false }
        // Construct the DELETE query using the model's entityName.
        let deleteStatementString = "DELETE FROM \(T.entityName) WHERE id = ?;"
        var deleteStatement: OpaquePointer?
        
        // Ensure that resources are cleaned up using defer.
        defer { sqlite3_finalize(deleteStatement) }
        
        // Prepare the DELETE statement.
        if sqlite3_prepare_v2(db, deleteStatementString, -1, &deleteStatement, nil) == SQLITE_OK {
            // Bind the primary key value from the object. We use sqlite3_bind_int64
            // assuming primaryKey is stored as an Int64 (or Int32 convertible to Int64).
            sqlite3_bind_int64(deleteStatement, 1, object.primaryKey!)
            
            // Execute the statement. SQLITE_DONE indicates the deletion was successful.
            if sqlite3_step(deleteStatement) == SQLITE_DONE {
                print("Successfully deleted row with id \(object.primaryKey).")
                object.primaryKey = nil
                object.lattice = nil
                return true
            } else {
                print("Could not delete row with id \(object.primaryKey).")
                return false
            }
        } else {
            print("DELETE statement could not be prepared.")
            return false
        }
    }
    
    @discardableResult public func delete<T: Model>(_ modelType: T.Type = T.self, where: ((Query<T>) -> Query<Bool>)? = nil) -> Bool {
        let deleteStatementString = if let `where` {
            // Construct the DELETE query using the model's entityName.
            "DELETE FROM \(T.entityName) WHERE \(`where`(Query<T>()).predicate);"
        } else {
            "DELETE FROM \(T.entityName);"
        }
        // Construct the DELETE query using the model's entityName.
        var deleteStatement: OpaquePointer?
        
        // Ensure that resources are cleaned up using defer.
        defer { sqlite3_finalize(deleteStatement) }
        
        // Prepare the DELETE statement.
        if sqlite3_prepare_v2(db, deleteStatementString, -1, &deleteStatement, nil) == SQLITE_OK {
            // Bind the primary key value from the object. We use sqlite3_bind_int64
            // assuming primaryKey is stored as an Int64 (or Int32 convertible to Int64).
//            sqlite3_bind_int64(deleteStatement, 1, object.primaryKey!)
            
            // Execute the statement. SQLITE_DONE indicates the deletion was successful.
            if sqlite3_step(deleteStatement) == SQLITE_DONE {
                print("Successfully deleted rows.")
                return true
            } else {
                print("Could not delete rows.")
                return false
            }
        } else {
            print("DELETE statement could not be prepared.")
            return false
        }
    }
    
    public func deleteHistory() {
        delete(AuditLog.self)
    }
}

import SwiftUI

@Model final class Person: @unchecked Sendable {
    var name: String
    var age: Int
}


struct TestView: View {
    @Bindable var person: Person
    
    var body: some View {
        VStack {
            Text("Age: \(person.age)")
        }.padding()
        Button("Increment Age") {
            person.age += 1
        }
    }
}

#Preview {
    let lattice = try! Lattice(Person.self)
    let person = {
        var person = Person()
        lattice.add(person)
        Task {
            while true {
                try await Task.sleep(for: .seconds(2))
                person.age += 1
            }
        }
        return person
    }()
    TestView(person: lattice.object(primaryKey: person.primaryKey!)!)
}
