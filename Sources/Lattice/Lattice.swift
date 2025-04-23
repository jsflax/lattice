import SQLite3
import os
import Foundation

extension OpaquePointer: @unchecked @retroactive Sendable {}

extension Actor {
    
    package func invoke<Ret>(_ operation: @Sendable (isolated Self) throws -> Ret) rethrows -> Ret {
        try operation(self)
    }
    
    package func invoke<Ret>(_ operation: @Sendable (isolated Self) async throws -> Ret) async rethrows -> Ret {
        try await operation(self)
    }
    
    func invoke<V, Ret>(_ value: V, _ operation: @Sendable (isolated Self, V) async throws -> Ret) async rethrows -> Ret {
        try await operation(self, value)
    }
}

@preconcurrency import Combine

//class LatticeSubscriber<T>: Subscription {
//    func request(_ demand: Subscribers.Demand) {
//
//    }
//
//    func cancel() {
//
//    }
//}
extension Logger {
    static let db = Logger(subsystem: "lattice.io",
                           category: "db")
    static let sync = Logger(subsystem: "lattice.io",
                             category: "sync")
}


public enum LatticeError: Error {
    case missingLatticeContext
    case transactionError(String)
}

public struct IsolationWeakRef: @unchecked Sendable {
    var isolation: (any Actor)?
    weak var value: (any Model)?
}

extension Model {
    func weakCapture(isolation: (any Actor)? = #isolation) -> IsolationWeakRef {
        IsolationWeakRef(isolation: isolation, value: self)
    }
}

final class LatticeExecutor: SerialExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
}

//public actor LatticeObservationRegistrar {
//    private var observationRegistrar: [
//        String: [
//            Int64: [IsolationWeakRef]
//        ]
//    ] = [:]
//    
//    public subscript (tableName: String) -> [Int64: [IsolationWeakRef]]? {
//        get {
//            observationRegistrar[tableName]
//        } set {
//            observationRegistrar[tableName] = newValue
//        }
//    }
//    
//    private func _triggerObservers(for tableName: String, primaryKey: Int64, with keyPath: String) {
//        observationRegistrar[tableName]?[primaryKey]?.forEach { ref in
//            Task {
//                if let isolation = ref.isolation {
//                    
//                    await ref.isolation!.invoke { _ in
//                        guard let model = ref.value else {
//                            return
//                        }
//                        
//                        model._objectWillChange_send()
//                        model._triggerObservers_send(keyPath: keyPath)
//                    }
//                } else {
//                    guard let model = ref.value else {
//                        return
//                    }
//                    
//                    model._objectWillChange_send()
//                    model._triggerObservers_send(keyPath: keyPath)
//                }
//            }
//        }
//    }
//    
//    nonisolated func triggerObservers(for tableName: String, primaryKey: Int64, with keyPath: String) {
//        Task {
//            await _triggerObservers(for: tableName, primaryKey: primaryKey, with: keyPath)
//        }
//    }
//    
//    func observers(forTableName tableName: String, primaryKey: Int64) -> [IsolationWeakRef] {
//        observationRegistrar[tableName, default: [:]][primaryKey, default: []]
//    }
//    
//    private func _insertObserver(tableName: String, primaryKey: Int64,
//                                 _ observation: IsolationWeakRef) {
//        observationRegistrar[tableName, default: [:]][primaryKey, default: []].append(observation)
//    }
//    public nonisolated func insertObserver(tableName: String, primaryKey: Int64,
//                                           _ observation: IsolationWeakRef) {
//        Task {
//            await _insertObserver(tableName: tableName, primaryKey: primaryKey, observation)
//        }
//    }
//    private func _removeObserver(tableName: String, primaryKey: Int64) {
//        observationRegistrar[tableName, default: [:]][primaryKey] = nil
//    }
//    public nonisolated func removeObserver(tableName: String, primaryKey: Int64) {
//        Task {
//            await _removeObserver(tableName: tableName, primaryKey: primaryKey)
//        }
//    }
//    public var count: Int {
//        observationRegistrar.count
//    }
//}

public struct Lattice {
    /// A simple Swift “shared_ptr” wrapper for an UnsafeMutablePointer<T>
    private final class SharedPointer<T> {
        /// The underlying raw pointer
        let pointer: UnsafeMutablePointer<T>

        /// Initialize with an existing pointer.
        /// You must ensure `pointer` was allocated (and, if appropriate, initialized).
        init(pointer: UnsafeMutablePointer<T>) {
            self.pointer = pointer
        }

        /// Convenience init that allocates space for one T and
        /// initializes it from a value.
        convenience init(_ value: T) {
            let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
            ptr.initialize(to: value)
            self.init(pointer: ptr)
        }

        /// Access the pointee
        var pointee: T {
            get { pointer.pointee }
            set { pointer.pointee = newValue }
        }

        /// When the last `SharedPointer` instance goes away, deinit runs
        deinit {
            // If you only stored a single T:
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
    }
    
    public let dbPtr: SharedDBPointer
    var db: OpaquePointer? {
        dbPtr.db
    }
    
    //    var observers: [AnyObject: () -> Void] = [:]
    private var ptr: SharedPointer<Lattice>?
    nonisolated(unsafe) static var synchronizers: [URL: Synchronizer] = [:]
    
    public struct Configuration: Sendable, Equatable, Hashable {
        public var isStoredInMemoryOnly: Bool = false
        public var fileURL: URL
        public var authorizationToken: String?
        public var wssEndpoint: URL?
        
        public init(isStoredInMemoryOnly: Bool = false, fileURL: URL? = nil,
                      authorizationToken: String? = nil, wssEndpoint: URL? = nil) {
            self.isStoredInMemoryOnly = isStoredInMemoryOnly
            let fileURL = if isStoredInMemoryOnly {
                URL(fileURLWithPath: ":memory:")
            } else {
                if let fileURL = fileURL {
                    fileURL
                } else {
                    try! FileManager.default
                        .url(for: .documentDirectory,
                             in: .userDomainMask,
                             appropriateFor: nil,
                             create: false)
                        .appendingPathComponent("lattice\(wssEndpoint != nil ? "_ws" : "").sqlite")
                }
            }
            self.fileURL = fileURL
            self.authorizationToken = authorizationToken
            self.wssEndpoint = wssEndpoint
        }
    }
    
    internal var isolation: (any Actor)? {
        dbPtr.isolation
    }
    
    public nonisolated(unsafe) static var defaultConfiguration: Configuration = .init()
    public var configuration: Configuration {
        dbPtr.configuration
    }
    var modelTypes: [any Model.Type] {
        self.dbPtr.modelTypes
    }
    private var synchronizer: Synchronizer?
    package struct WeakRef: @unchecked Sendable {
        weak var db: SharedDBPointer?
    }
    private nonisolated(unsafe) static var _latticeIsolationRegistrar: [IsolationKey: WeakRef] = [:]
    private static let lock = NSLock()

    package static var latticeIsolationRegistrar: [IsolationKey: WeakRef] {
        get {
            lock.withLock {
                _latticeIsolationRegistrar
            }
        }
        set {
            lock.withLock {
                _latticeIsolationRegistrar = newValue
            }
        }
    }
    private var isSyncDisabled = false
    internal let logger = Logger.db
    
//    deinit {
//        defer { print("Lattice deinit") }
////        ptr = nil
//        Self.latticeIsolationRegistrar.removeAll(where: {
//            $0.lattice == nil
//        })
//        Self.latticeIsolationRegistrar.filter {
//            $0.lattice?.isolation === isolation
//        }
//    }
//    
    internal init(_ db: SharedDBPointer) {
        self.dbPtr = db
    }
    
    internal init(isolation: isolated (any Actor)? = #isolation,
                  for schema: [any Model.Type],
                  configuration: Configuration = defaultConfiguration,
                  isSynchronizing: Bool) throws {
        if let db = Self.latticeIsolationRegistrar[IsolationKey(isolation: isolation, configuration: configuration)]?.db {
            self.init(db)
            return
        } else {
            self.init(try SharedDBPointer(configuration: configuration, for: schema))
            Self.latticeIsolationRegistrar[IsolationKey(isolation: isolation, configuration: configuration)] = WeakRef(db: dbPtr)
            // Register the update hook to listen for changes.
            if sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil) != SQLITE_OK {
                logger.error("Error enabling foreign keys.")
            }
            if sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) != SQLITE_OK {
                logger.error("Error enabling foreign keys.")
            }
            // After opening:
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;",      nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size = 50000;",    nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size = 300000000;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA temp_store = MEMORY;",   nil, nil, nil)
            sqlite3_exec(db, "ANALYZE;",                      nil, nil, nil)
            logger.debug("Running SQLite version: \(SQLITE_VERSION)")
            
            //        var this = self
            
            transaction {
                let auditTableSQL = """
                CREATE TABLE IF NOT EXISTS AuditLog(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    globalId TEXT UNIQUE COLLATE NOCASE DEFAULT (
                    lower(hex(randomblob(4)))   || '-' ||
                    lower(hex(randomblob(2)))   || '-' ||
                    '4' || substr(lower(hex(randomblob(2))),2) || '-' ||
                    substr('89AB', 1 + (abs(random()) % 4), 1) ||
                      substr(lower(hex(randomblob(2))),2)     || '-' ||
                    lower(hex(randomblob(6)))
                    ),
                    tableName TEXT,
                    operation TEXT,
                    rowId INTEGER,
                    globalRowId TEXT,
                    changedFields TEXT,
                    changedFieldsNames TEXT,
                    isFromRemote INTEGER DEFAULT 0,
                    isSynchronized INTEGER DEFAULT 0,
                    timestamp INTEGER DEFAULT (CAST(ROUND((julianday('now') - 2440587.5)*86400000) As INTEGER))
                );
                """
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, auditTableSQL, -1, &statement, nil) == SQLITE_OK {
                    if sqlite3_step(statement) == SQLITE_DONE {
                        logger.debug("Audit table created successfully.")
                    } else {
                        logger.debug("Could not create Audit table.")
                    }
                } else {
                    logger.debug("CREATE TABLE statement could not be prepared.")
                }
                sqlite3_finalize(statement)
                executeStatement("""
                CREATE TABLE IF NOT EXISTS _SyncControl (
                  id       INTEGER PRIMARY KEY CHECK(id=1),
                  disabled INTEGER NOT NULL DEFAULT 0
                );   
                """)
                executeStatement("""
                INSERT OR IGNORE INTO _SyncControl(id, disabled) VALUES(1, 0);
                """)
                for type in schema {
                    createTable(type)
                }
            }
            sqlite3_busy_timeout(db, 5000)
            // A simple global we flip on/off around your sync pass.
            // Register the function:
            
            if !isSynchronizing, Self.synchronizers[configuration.fileURL] == nil {
                Self.synchronizers[configuration.fileURL] = Synchronizer(modelTypes: modelTypes, configuration: configuration)
            }
        }
    }
    
    public init(isolation: isolated (any Actor)? = #isolation,
                for schema: [any Model.Type], configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: schema, configuration: configuration, isSynchronizing: false)
    }
    
    public init(isolation: isolated (any Actor)? = #isolation,
                            _ modelTypes: any Model.Type..., configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: modelTypes, configuration: configuration)
    }
//        if let cachedIsolation = Self.latticeIsolationRegistrar.first(where: { isolation === $0.lattice?.isolation })?.lattice,
//           cachedIsolation.configuration == configuration {
//            self.dbPtr = cachedIsolation.dbPtr
//            self.ptr = cachedIsolation.ptr
//            // still cache self so that we can transfer ownership if needed
//            Self.latticeIsolationRegistrar.append(WeakRef(lattice: self))
//            return
//        }
        
//        logger.debug("\(fileURL.path)")
        
//        ptr = SharedPointer(self)
        

    enum Error: Swift.Error {
        case databaseError(String)
    }
    
    public static func delete(for configuration: Configuration = defaultConfiguration) throws {
        let latticeSHMURL: URL
        let latticeWALURL: URL
        
        let fileURL = if configuration.isStoredInMemoryOnly {
            throw Error.databaseError("Cannot delete in-memory database")
        } else {
            configuration.fileURL
        }
        latticeSHMURL = fileURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
        latticeWALURL = fileURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: latticeSHMURL)
        try FileManager.default.removeItem(at: latticeWALURL)
    }
    
    private func createBasicTable(_ modelType: any Model.Type) {
        let primitiveProperties = modelType.properties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let constraints = modelType.constraints
        let constraintsString = if constraints.isEmpty {
            ""
        } else {
            constraints.map {
                "UNIQUE(\($0.columns.joined(separator: ",")))"
            }.joined(separator: ",\n")
        }

        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS \(modelType.entityName)(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                globalId TEXT UNIQUE COLLATE NOCASE DEFAULT (
                lower(hex(randomblob(4)))   || '-' ||
                lower(hex(randomblob(2)))   || '-' ||
                '4' || substr(lower(hex(randomblob(2))),2) || '-' ||
                substr('89AB', 1 + (abs(random()) % 4), 1) ||
                  substr(lower(hex(randomblob(2))),2)     || '-' ||
                lower(hex(randomblob(6)))
                ),
                \(primitiveProperties.map { "\($0.0) \($0.1.sqlType)" }.joined(separator: ",\n"))
                \(constraintsString.isEmpty ? "" : ",\n" + constraintsString)
            );
            """
        
        let createAuditTriggerSQL = """
        CREATE TRIGGER AuditLog_Update_\(modelType.entityName) AFTER UPDATE ON \(modelType.entityName)
        WHEN ((sync_disabled() = 0) AND (\(primitiveProperties.map { "OLD.\($0.0) IS NOT NEW.\($0.0)" }.joined(separator: " OR "))))
        BEGIN
            INSERT INTO AuditLog (tableName, operation, rowId, globalRowId, changedFields, changedFieldsNames, timestamp)
            VALUES (
                '\(modelType.entityName)',
                'UPDATE',
                OLD.id,
                OLD.globalId,
                json_object(
                    \(primitiveProperties.map {
                        "'\($0.0)', CASE WHEN OLD.\($0.0) IS NOT NEW.\($0.0) THEN NEW.\($0.0) ELSE NULL END"
                    }.joined(separator: ","))
                ),
                json_array(
                    \(primitiveProperties.map {
                        "CASE WHEN OLD.\($0.0) IS NOT NEW.\($0.0) THEN '\($0.0)' ELSE NULL END"
                    }.joined(separator: ","))
                ),
                ((CAST(ROUND((julianday('now') - 2440587.5)*86400000) As INTEGER)))
            );
        END;    
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableSQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                logger.debug("\(modelType.entityName) table created successfully.")
            } else {
                fatalError(self.readError() ?? "Unknown")
            }
        } else {
            logger.debug("CREATE TABLE statement could not be prepared.")
        }
        executeStatement(createAuditTriggerSQL)
        // Trigger for insertions
        executeStatement("""
        CREATE TRIGGER Audit\(modelType.entityName)Insert AFTER INSERT ON \(modelType.entityName)
          WHEN ( sync_disabled() = 0 )
        BEGIN
          INSERT INTO AuditLog (tableName, operation, rowId, globalRowId, changedFields, changedFieldsNames, timestamp)
          VALUES (
            '\(modelType.entityName)',
            'INSERT',
            NEW.id,
            NEW.globalId,
            json_object(
                \(primitiveProperties.map {
            "'\($0.0)', NEW.\($0.0)"
                }.joined(separator: ","))
            ),
            json_array(
                \(primitiveProperties.map {
            "'\($0.0)'"
                }.joined(separator: ","))
            ),
            ((CAST(ROUND((julianday('now') - 2440587.5)*86400000) As INTEGER)))
          );
        END;
        """)
        // Trigger for deletions
        executeStatement("""
        CREATE TRIGGER Audit\(modelType.entityName)Delete AFTER DELETE ON \(modelType.entityName)
          WHEN ( sync_disabled() = 0 )
        BEGIN
         INSERT INTO AuditLog (tableName, operation, rowId, globalRowId, changedFields, changedFieldsNames, timestamp)
         VALUES (
           '\(modelType.entityName)',
           'DELETE',
            OLD.id,
            OLD.globalId,
            json_object(
                \(primitiveProperties.map {
            "'\($0.0)', OLD.\($0.0)"
                }.joined(separator: ","))
            ),
            json_array(
                \(primitiveProperties.map {
            "'\($0.0)'"
                }.joined(separator: ","))
            ),
           ((CAST(ROUND((julianday('now') - 2440587.5)*86400000) As INTEGER)))
         );
        END;
        """)
        let linkProperties = modelType.properties.compactMap {
            if let primitiveType = $0.1 as? (any LinkProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        for linkProperty in linkProperties {
            self.createLinkTable(name: linkProperty.0, lhs: modelType, rhs: linkProperty.1.modelType)
        }
    }
    
    private func createLinkTable(name: String, lhs: any Model.Type, rhs: any Model.Type) {
        executeStatement("""
          CREATE TABLE IF NOT EXISTS _\(lhs.entityName)_\(rhs.entityName)_\(name)(
            lhs        INTEGER NOT NULL
              REFERENCES \(lhs.entityName)(id) ON DELETE CASCADE,
            rhs INTEGER NOT NULL
              REFERENCES \(rhs.entityName)(id) ON DELETE CASCADE,
            PRIMARY KEY(lhs, rhs)
          );
        """)
    }
    
    /// Check whether a table already exists in the database.
    private func tableExists(_ name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    
    private func sqlLiteral(for value: some PrimitiveProperty) -> Any {
        guard let value = value as? CVarArg else {
            return "NULL"
        }
        return withVaList([value]) { ptr in
            let raw = sqlite3_vmprintf("%Q", ptr)
            defer { sqlite3_free(raw) }
            let returnValue = String(cString: raw!)
            return returnValue
        }
        
        //        let sql = "SELECT QUOTE(?)"
        //        var stmt: OpaquePointer?
        //        defer { sqlite3_finalize(stmt) }
        //        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "NULL" }
        //        value.encode(to: stmt, with: 0)
        //        guard sqlite3_step(stmt) == SQLITE_ROW else {
        //            return "NULL"
        //        }
        //        let retVal = type(of: value).init(from: stmt, with: 0)
        //        return retVal
    }
    
    private func migrateTable(_ modelType: any Model.Type) {
        let tableName = modelType.entityName
        
        // 2a. Read existing columns and their types.
        let pragma = "PRAGMA table_info(\(tableName));"
        var stmt: OpaquePointer?
        var existing: [String: String] = [:]
        if sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let type = String(cString: sqlite3_column_text(stmt, 2))
                existing[name] = type.uppercased()
            }
        }
        sqlite3_finalize(stmt)
        
        let primitiveProperties: [(String, any PrimitiveProperty.Type)] = modelType.properties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let linkProperties: [(String, any LinkProperty.Type)] = modelType.properties.compactMap {
            if let primitiveType = $0.1 as? (any LinkProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        // 2b. Build the “model” schema dictionary.
        var modelCols: Dictionary<String, String?> = Dictionary(
            uniqueKeysWithValues: primitiveProperties.map {
                ($0.0, $0.1.sqlType.uppercased())
            }
        )
        //        for linkProperty in linkProperties {
        //            modelCols[linkProperty.0] = nil
        //        }
        linkProperties.forEach {
            if existing[$0.0] == nil {
                createLinkTable(name: $0.0, lhs: modelType, rhs: $0.1.modelType)
            }
        }
        // 2c. Figure out which columns were added, removed, or changed.
        let added   = modelCols.keys.filter    { existing[$0] == nil }
        let removed = existing.keys.filter     { modelCols[$0] == nil }
        let changed = modelCols.filter { key, newType in
            if let oldType = existing[key], oldType != newType {
                return true
            }
            return false
        }.map(\.key)
        
        // 2d. Simply add brand-new columns in place.
        for col in added {
            let type = modelCols[col]!
            guard let property = modelType.properties.first(where: { $0.0 == col }) else {
                continue
            }
            if let property = property.1 as? (any PrimitiveProperty.Type) {
                executeStatement("ALTER TABLE \(tableName) ADD COLUMN \(col) \(type!) DEFAULT \(sqlLiteral(for: property.defaultValue));")
            } else if let propertyType = property.1 as? LinkProperty.Type {
                createLinkTable(name: property.0, lhs: modelType, rhs: propertyType.modelType)
            } else {
                executeStatement("ALTER TABLE \(tableName) ADD COLUMN \(col) \(type);")
            }
        }
        
        // 2e. If any columns were removed or changed, rebuild the table.
        // 5) If only removed columns (and you’re on SQLite ≥3.35.0), drop them in place
        if !removed.isEmpty, changed.isEmpty {
            for col in removed {
                executeStatement("ALTER TABLE \(tableName) DROP COLUMN \(col);")
            }
            return
        }
        
        if !removed.isEmpty || !changed.isEmpty {
            let tmp = tableName + "_old"
            // 1) Rename the existing table out of the way
            executeStatement("ALTER TABLE \(tableName) RENAME TO \(tmp);")
            // 2) Create the new, correct table + triggers
            createBasicTable(modelType)
            
            // 3) Figure out exactly which columns to copy
            //    Always keep the primary key (id), plus any columns
            //    whose name/type still match the model.
            let keep = existing.keys.filter { colName in
                // keep 'id' no matter what
                if colName == "id" { return true }
                // keep other columns only if they still exist in your model *and* types match
                return modelCols[colName] != nil
                && modelCols[colName]! == existing[colName]!
            }
            let cols = keep.joined(separator: ", ")
            
            if !keep.isEmpty {
                // 4) Copy the data across
                executeStatement("""
                    INSERT INTO \(tableName) (\(cols))
                      SELECT \(cols) FROM \(tmp);
                    """)
            }
            
            // 5) Drop the old table (and its triggers)
            executeStatement("DROP TABLE \(tmp);")
        }
    }
    
    private func createTable(_ modelType: any Model.Type) {
        if tableExists(modelType.entityName) {
            migrateTable(modelType)
        } else {
            createBasicTable(modelType)
        }
    }
    
    private func executeStatement(_ sql: String, bindArgs: any PrimitiveProperty...) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (idx, arg) in bindArgs.enumerated() {
                arg.encode(to: statement, with: Int32(idx))
            }
            if sqlite3_step(statement) == SQLITE_DONE {
                logger.debug("Statement executed successfully.")
            } else {
                fatalError(readError() ?? "Unknown failure")
            }
        }
        sqlite3_finalize(statement)
    }
    
    // MARK: Add
    public func add<T: Model>(_ object: T) {
        let primitiveProperties = T.properties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        
        let insertStatementString = """
        INSERT INTO \(T.entityName) (\(primitiveProperties.map(\.0).joined(separator: ", "))) VALUES (\(primitiveProperties.map { _ in "?" }.joined(separator: ", ")))
        \(T.constraints.isEmpty ? "" : T.constraints.filter { $0.allowsUpsert }.map({
            """
            ON CONFLICT(\($0.columns.joined(separator: ","))) DO UPDATE SET \(primitiveProperties.map({
                $0.0 + " = excluded.\($0.0)"
            }).joined(separator: ","))
            """
        }).joined(separator: ","));
        """
        var insertStatement: OpaquePointer?
        
        defer {
            sqlite3_finalize(insertStatement)
        }
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            object._assign(lattice: self)
            object._encode(statement: insertStatement)
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                // Retrieve the last inserted rowid.
                let id = sqlite3_last_insert_rowid(db)
                dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: isolation))
//                logger.debug("Successfully inserted \(T.entityName). New id: \(id)")
                object.primaryKey = id
                object._didEncode()
            } else {
                logger.debug("Could not insert \(T.entityName).")
                if let errorMessage = sqlite3_errmsg(db) {
                    let errorString = String(cString: errorMessage)
                    logger.debug("Error during sqlite3_step: \(errorString)")
                } else {
                    logger.debug("Unknown error during sqlite3_step")
                }
                //                fatalError()
            }
        } else {
            logger.debug("INSERT statement could not be prepared.")
        }
    }
    
    private func addAuditEntry(_ object: AuditLog) {
        let primitiveProperties = AuditLog.properties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let insertStatementString = "INSERT INTO \(AuditLog.entityName) (globalId, \(primitiveProperties.map(\.0).joined(separator: ", "))) VALUES ('\(object.__globalId.uuidString.lowercased())', \(primitiveProperties.map { _ in "?" }.joined(separator: ", ")));"
        var insertStatement: OpaquePointer?
        
        defer {
            sqlite3_finalize(insertStatement)
        }
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            object._encode(statement: insertStatement)
            object._assign(lattice: self)
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                // Retrieve the last inserted rowid.
//                logger.debug("Successfully inserted \(AuditLog.entityName).")
                let id = sqlite3_last_insert_rowid(db)
                dbPtr.insertModelObserver(tableName: AuditLog.entityName, primaryKey: id, object.weakCapture(isolation: isolation))
//                logger.debug("Successfully inserted object: \(AuditLog.entityName). New id: \(id)")
                object.primaryKey = id
                object._didEncode()
            } else {
                logger.debug("Could not insert object: \(AuditLog.entityName).")
                if let errorMessage = sqlite3_errmsg(db) {
                    let errorString = String(cString: errorMessage)
                    logger.debug("Error during sqlite3_step: \(errorString)")
                } else {
                    logger.debug("Unknown error during sqlite3_step")
                }
                //                fatalError()
            }
        } else {
            logger.debug("INSERT statement could not be prepared.")
        }
    }
    
    public func add<S: Sequence>(contentsOf newElements: S) where S.Element: Model {
        // 1) Figure out which properties are "primitive" (i.e. go into columns)
        let primitives: [(String, PrimitiveProperty.Type)] =
        S.Element.properties.compactMap { name, type in
            guard let p = type as? PrimitiveProperty.Type else { return nil }
            return (name, p)
        }
        
        // 2) Build the SQL with exactly N columns and N placeholders
        let columnList      = primitives.map(\.0).joined(separator: ", ")
        let placeholderList = primitives.map { _ in "?" }.joined(separator: ", ")
        let sql = """
          INSERT INTO \(S.Element.entityName)
            (\(columnList))
          VALUES
            (\(placeholderList))
          \(S.Element.constraints.isEmpty ? "" : S.Element.constraints.filter { $0.allowsUpsert }.map({
              """
              ON CONFLICT(\($0.columns.joined(separator: ","))) DO UPDATE SET \(primitives.map({
                  $0.0 + " = excluded.\($0.0)"
              }).joined(separator: ","))
              """
          }).joined(separator: ","));
          """
        
        // 3) Prepare once
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            logger.debug("🔴 failed to prepare bulk‐insert: \(err)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        
        // 4) Loop and insert each element
        for element in newElements {
            // 4a) Populate bindings
            element._assign(lattice: self)
            element._encode(statement: stmt)
            
            // 4b) Execute
            if sqlite3_step(stmt) == SQLITE_DONE {
                let newId = sqlite3_last_insert_rowid(db)
                element.primaryKey = newId
                
                // register observation, call didEncode, etc.
                dbPtr.insertModelObserver(
                    tableName: S.Element.entityName,
                    primaryKey: newId,
                    element.weakCapture(isolation: isolation)
                )
                element._didEncode()
                logger.debug("✅ inserted \(S.Element.entityName)(id: \(newId))")
            } else {
                let err = String(cString: sqlite3_errmsg(db))
                logger.debug("🔴 could not insert \(S.Element.entityName): \(err)")
            }
            
            // 4c) Reset for next loop
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }
    
    func updatePerson(id: Int32, newName: String, newAge: Int32) {
        let updateStatementString = "UPDATE Person SET name = ?, age = ? WHERE id = ?;"
        var updateStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateStatementString, -1, &updateStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(updateStatement, 1, (newName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(updateStatement, 2, newAge)
            sqlite3_bind_int(updateStatement, 3, id)
            
            if sqlite3_step(updateStatement) == SQLITE_DONE {
                logger.debug("Successfully updated person with id \(id) to name: \(newName), age: \(newAge).")
            } else {
                logger.debug("Could not update person with id \(id).")
            }
        } else {
            logger.debug("UPDATE statement could not be prepared.")
        }
        sqlite3_finalize(updateStatement)
    }
    
    public func object<T>(_ type: T.Type = T.self, primaryKey: Int64) -> T? where T: Model {
        let queryStatementString = "SELECT id FROM \(T.entityName) WHERE id = ?;"
        var queryStatement: OpaquePointer?
        
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            sqlite3_bind_int64(queryStatement, 1, primaryKey)
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                //                logger.debug( sqlite3_column_int(queryStatement, 2))
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: self)
                object.primaryKey = id
                dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: isolation))
                return object
            }
        } else {
            logger.debug("SELECT statement could not be prepared.")
        }
        
        return nil
    }
    
    internal func object<T>(_ type: T.Type = T.self, globalKey: UUID) -> T? where T: Model {
        let queryStatementString = "SELECT id FROM \(T.entityName) WHERE globalId = ?;"
        var queryStatement: OpaquePointer?
        
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            globalKey.uuidString.lowercased().encode(to: queryStatement, with: 1)
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                let id = sqlite3_column_int64(queryStatement, 0)
                //                logger.debug( sqlite3_column_int(queryStatement, 2))
                let object = T(isolation: #isolation) // Person(id: personId, name: name, age: age)
                object._assign(lattice: self)
                object.primaryKey = id
                dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: isolation))
                return object
            }
        } else {
            logger.debug("SELECT statement could not be prepared.")
        }
        
        return nil
    }
    
    public func objects<T>(_ type: T.Type = T.self) -> Results<T> where T: Model {
        Results(self)
    }
    
    // MARK: Delete
    @discardableResult public func delete<T: Model>(_ object: consuming T) -> Bool {
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
                logger.debug("Successfully deleted row with id \(object.primaryKey ?? -1).")
                object.primaryKey = nil
                object.lattice = nil
                return true
            } else {
                logger.debug("❌ Could not delete row with id \(object.primaryKey ?? -1).")
                return false
            }
        } else {
            logger.debug("DELETE statement could not be prepared: \(self.readError() ?? "Unknown")")
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
                logger.debug("Successfully deleted rows.")
                return true
            } else {
                logger.debug("Could not delete rows.")
                return false
            }
        } else {
            logger.debug("DELETE statement could not be prepared.")
            return false
        }
    }
    
    public func deleteHistory() {
        delete(AuditLog.self)
    }
    
    public func count<T>(_ modelType: T.Type, where: ((Query<T>) -> Query<Bool>)? = nil) -> Int where T: Model {
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
            logger.debug("Failed to prepare count query for table \(T.entityName)")
        }
        
        sqlite3_finalize(countStatement)
        return count
    }
    
    public class ObservationCancellable<T: Model>: Cancellable, Identifiable {
        
        public var id: ObjectIdentifier!
        private weak var dbPtr: SharedDBPointer?
        
        init(_ dbPtr: SharedDBPointer) {
            id = ObjectIdentifier(self)
            self.dbPtr = dbPtr
        }
        
        public func cancel() {
            dbPtr?.tableObservationRegistrar[T.entityName]?[id] = nil
        }
    }
    
    public func observe(_ block: @escaping ([AuditLog]) -> ()) -> AnyCancellable {
        class AnyCancellableGroup: Cancellable, Identifiable {
            var storage: [AnyCancellable] = []
            func cancel() {
                storage.forEach { $0.cancel() }
            }
        }
        let cancellable = ObservationCancellable<AuditLog>(dbPtr)
        dbPtr.tableObservationRegistrar[AuditLog.entityName, default: [:]][cancellable.id] = { auditLog in
            block(auditLog)
        }
        return AnyCancellable(cancellable)
    }
    
    private func _observe(_ block: @escaping @Sendable @isolated(any) ([ModelThreadSafeReference<AuditLog>]) async -> ()) -> AnyCancellable {
        class AnyCancellableGroup: Cancellable, Identifiable {
            var storage: [AnyCancellable] = []
            func cancel() {
                storage.forEach { $0.cancel() }
            }
        }
        let cancellable = ObservationCancellable<AuditLog>(dbPtr)
        dbPtr.tableObservationRegistrar[AuditLog.entityName, default: [:]][cancellable.id] = { auditLog in
            Task { [ref = auditLog.map(\.sendableReference)] in
                await block(ref)
            }
        }
        return AnyCancellable(cancellable)
    }
    
    public var changeStream: AsyncStream<[AuditLog]> {
        AsyncStream { stream in
            let token = _observe { [modelTypes, configuration] changes in
                let lattice = try! Lattice(for: modelTypes, configuration: configuration)
                var resolvedChanges: [AuditLog] = []
                for change in changes {
                    change.resolve(on: lattice).map {
                        resolvedChanges.append($0)
                    }
                }
                stream.yield(resolvedChanges)
            }
            stream.onTermination = { _ in
                token.cancel()
            }
        }
    }
//    public func observe(
//        block: @escaping ([AuditLog]) async -> ()
//    ) -> AnyCancellable {
//        class AnyCancellableGroup: Cancellable, Identifiable {
//            var storage: [AnyCancellable] = []
//            func cancel() {
//                storage.forEach { $0.cancel() }
//            }
//        }
//        let cancellable = ObservationCancellable<AuditLog>(dbPtr)
//        dbPtr.tableObservationRegistrar[AuditLog.entityName, default: [:]][cancellable.id] = { [modelTypes = self.modelTypes, configuration = self.configuration, isolation = self.isolation] auditLog in
//            Task {
//                await block(auditLog)
//            }
//        }
//        return AnyCancellable(cancellable)
//    }
    
    public func observe<T: Model>(_ modelType: T.Type, where: Predicate<T>? = nil,
                                  block: @escaping (Results<T>.CollectionChange) -> ()) -> AnyCancellable {
        let cancellable = ObservationCancellable<T>(dbPtr)
        dbPtr.tableObservationRegistrar[T.entityName, default: [:]][cancellable.id] = { auditLog in
            for auditLog in auditLog {
                let operation = auditLog.operation
                let rowId = auditLog.rowId
                switch operation {
                case .insert:
                    if let `where` {
                        if let row = Results<AuditLog>(self).where({
                            $0.rowId == rowId && `where`(Query<T>()).convertKeyPathsToEmbedded(rootPath: "changedFields") && $0.operation == .insert
                        }).first {
                            block(.insert(rowId))
                        }
                    } else {
                        if let object = self.object(modelType, primaryKey: rowId) {
                            block(.insert(object.primaryKey!))
                        }
                    }
                case .delete:
                    if let `where` {
                        if let row = Results<AuditLog>(self).where({
                            $0.rowId == rowId && `where`(Query<T>()).convertKeyPathsToEmbedded(rootPath: "changedFields") && $0.operation == .delete
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
        }
        return AnyCancellable(cancellable)
    }
    
    func readError() -> String? {
        if let errorMessage = sqlite3_errmsg(db) {
            let errorString = String(cString: errorMessage)
            return errorString
        }
        return nil
    }
    
    public func beginTransaction() {
        // Start the transaction.
        if sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) != SQLITE_OK {
            logger.debug("Error beginning transaction")
            if let errorMessage = sqlite3_errmsg(db) {
                let errorString = String(cString: errorMessage)
                logger.debug("Error during sqlite3_step: \(errorString)")
            } else {
                logger.debug("Unknown error during sqlite3_step")
            }
            fatalError()
        }
    }
    
    public func commitTransaction() {
        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(db) {
                let errorString = String(cString: errorMessage)
                logger.debug("Error during sqlite3_step: \(errorString)")
            } else {
                logger.debug("Unknown error during sqlite3_step")
            }
            fatalError()
        } else {
            logger.debug("Transaction committed successfully")
        }
    }
    
    public func transaction<T>(isolation: isolated (any Actor)? = #isolation,
                               _ block: () throws -> T) rethrows -> T {
        // Start the transaction.
        var rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        while rc != SQLITE_OK {
            if rc == SQLITE_BUSY {
//                logger.debug("🔒 database is busy (locked by another connection)")
                rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            } else if rc == SQLITE_LOCKED {
                logger.debug("🔒 database is locked by this connection")
                rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            } else if rc != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                logger.debug("❌ SQLite error: \(err)")
                fatalError()
            }
        }
        
        do {
            let value = try block()
            // If all statements succeed, commit the transaction.
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                if let errorMessage = sqlite3_errmsg(db) {
                    let errorString = String(cString: errorMessage)
                    throw LatticeError.transactionError(errorString)
                } else {
                    throw LatticeError.transactionError("Unknown error during sqlite3_step")
                }
                
            } else {
                logger.debug("Transaction committed successfully")
            }
            return value
        } catch {
            logger.debug("Error inserting data; rolling back transaction")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            fatalError(error.localizedDescription)
        }
    }
    
    public func applyInstructions(from auditLog: [AuditLog]) {
        logger.debug("🧦 \(configuration.fileURL) Applying \(auditLog.count) instructions")
        var committedEvents: [AuditLog] = []
        dbPtr.isSyncDisabled = true
        defer {
            
        }
        transaction {

            executeStatement("""
            UPDATE _SyncControl SET disabled = 1 WHERE id=1; 
            """)
            defer {
                executeStatement("""
                UPDATE _SyncControl SET disabled = 0 WHERE id=1;
                """)
            }
            for auditLogEntry in auditLog where count(AuditLog.self, where: { $0.__globalId == auditLogEntry.__globalId
            }) == 0 {
                let (sql, params) = auditLogEntry.generateInstruction()
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    defer { sqlite3_finalize(stmt) }
                    logger.debug("⚠️ prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                    continue
                }
                defer { sqlite3_finalize(stmt) }
                
                // Bind each parameter using its own `encode` method.
                for (idx, param) in params.enumerated() {
                    // SQLite parameters are 1‑based, so use idx+1
                    param.encode(to: stmt, with: Int32(idx + 1))
                }
                
                // Execute
                if sqlite3_step(stmt) != SQLITE_DONE {
                    logger.debug("⚠️ exec failed: \(String(cString: sqlite3_errmsg(self.db)))")
                }
                auditLogEntry.isFromRemote = true
                auditLogEntry.isSynchronized = true
                addAuditEntry(auditLogEntry)
                committedEvents.append(auditLogEntry)
            }
        }
        dbPtr.isSyncDisabled = false
//        Task { [configuration, sendableEvents = committedEvents.map(\.sendableReference)] in
//            await SharedDBPointer.publishEvents(sendableEvents, for: configuration)
//        }
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

struct IsolatedModel {
    
}
