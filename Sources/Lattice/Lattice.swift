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

public struct _UncheckedSendable<T>: @unchecked Sendable {
    public let value: T
    
    public init(_ value: T) {
        self.value = value
    }
}
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
    private static let synchronizersLock = OSAllocatedUnfairLock<Void>()
    nonisolated(unsafe) static var synchronizers: [URL: Synchronizer] = [:]
    
    public struct SyncConfiguration {
        
    }
    
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
    public var modelTypes: [any Model.Type] {
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
        print("🔷 Lattice.init START for \(configuration.fileURL)")
        let cacheKey = IsolationKey(isolation: isolation, configuration: configuration)
        if let db = Self.latticeIsolationRegistrar[cacheKey]?.db {
            print("🔷 Lattice.init CACHE HIT")
            self.init(db)
            return
        } else {
            print("🔷 Lattice.init CACHE MISS - creating new")
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
                    timestamp REAL DEFAULT (unixepoch('subsec'))
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
                    logger.error("CREATE TABLE statement could not be prepared.")
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

                // Discover all linked Model types recursively
                print("🔷 discoverAllTypes START")
                let completeSchema = discoverAllTypes(from: schema)
                print("🔷 discoverAllTypes END - found \(completeSchema.count) types")

                // Update modelTypes in SharedDBPointer to include all discovered types
                dbPtr.modelTypes = completeSchema

                print("🔷 createTable START")
                for modelType in completeSchema {
                    print("🔷 createTable for \(modelType.entityName)")
                    createTable(modelType)
                }
                print("🔷 createTable END")
            }
            sqlite3_busy_timeout(db, 5000)

            print("🔷 Synchronizer check START")
            Self.synchronizersLock.withLock { [modelTypes] in
                if !isSynchronizing, Self.synchronizers[configuration.fileURL] == nil {
                    print("🔷 Creating Synchronizer")
                    Self.synchronizers[configuration.fileURL] = Synchronizer(modelTypes: UncheckedSendable(modelTypes), configuration: configuration)
                }
            }
            print("🔷 Lattice.init END")
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

        // Filter out globalId from primitiveProperties since it's defined explicitly above
        let userPrimitiveProperties = primitiveProperties.filter { $0.0 != "globalId" }
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
                )\(userPrimitiveProperties.isEmpty ? "" : ",")
                \(userPrimitiveProperties.map { "\($0.0) \($0.1.sqlType)" }.joined(separator: ",\n"))
                \(constraintsString.isEmpty ? "" : ",\n" + constraintsString)
            );
            """
        
        // Use userPrimitiveProperties (without globalId) since generateInstruction adds globalId separately
        let createAuditTriggerSQL = """
        CREATE TRIGGER AuditLog_Update_\(modelType.entityName) AFTER UPDATE ON \(modelType.entityName)
        WHEN ((sync_disabled() = 0) AND (\(userPrimitiveProperties.map { "OLD.\($0.0) IS NOT NEW.\($0.0)" }.joined(separator: " OR "))))
        BEGIN
            INSERT INTO AuditLog (tableName, operation, rowId, globalRowId, changedFields, changedFieldsNames, timestamp)
            VALUES (
                '\(modelType.entityName)',
                'UPDATE',
                OLD.id,
                OLD.globalId,
                json_object(
                    \(userPrimitiveProperties.map {
                        "'\($0.0)', json_object('kind', \($0.1.anyPropertyKind.rawValue), 'value', CASE WHEN OLD.\($0.0) IS NOT NEW.\($0.0) THEN NEW.\($0.0) ELSE NULL END)"
                    }.joined(separator: ","))
                ),
                json_array(
                    \(userPrimitiveProperties.map {
                        "CASE WHEN OLD.\($0.0) IS NOT NEW.\($0.0) THEN '\($0.0)' ELSE NULL END"
                    }.joined(separator: ","))
                ),
                unixepoch('subsec')
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
        // Trigger for insertions (use userPrimitiveProperties - globalId is added by generateInstruction)
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
                \(userPrimitiveProperties.map {
            "'\($0.0)', json_object('kind', \($0.1.anyPropertyKind.rawValue), 'value', NEW.\($0.0))"
                }.joined(separator: ","))
            ),
            json_array(
                \(userPrimitiveProperties.map {
            "'\($0.0)'"
                }.joined(separator: ","))
            ),
            unixepoch('subsec')
          );
        END;
        """)
        // Trigger for deletions (use userPrimitiveProperties - globalId is added by generateInstruction)
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
                \(userPrimitiveProperties.map {
            "'\($0.0)', json_object('kind', \($0.1.anyPropertyKind.rawValue), 'value', OLD.\($0.0))"
                }.joined(separator: ","))
            ),
            json_array(
                \(userPrimitiveProperties.map {
            "'\($0.0)'"
                }.joined(separator: ","))
            ),
            unixepoch('subsec')
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
        let linkTableName = "_\(lhs.entityName)_\(rhs.entityName)_\(name)"

        // Create link table using globalIds (TEXT) for sync-friendly references
        // This allows links to sync without ID translation between clients
        executeStatement("""
          CREATE TABLE IF NOT EXISTS \(linkTableName)(
            lhs TEXT NOT NULL,
            rhs TEXT NOT NULL,
            globalId TEXT UNIQUE COLLATE NOCASE DEFAULT (
              lower(hex(randomblob(4)))   || '-' ||
              lower(hex(randomblob(2)))   || '-' ||
              '4' || substr(lower(hex(randomblob(2))),2) || '-' ||
              substr('89AB', 1 + (abs(random()) % 4), 1) ||
                substr(lower(hex(randomblob(2))),2)     || '-' ||
              lower(hex(randomblob(6)))
            ),
            PRIMARY KEY(lhs, rhs)
          );
        """)

        // Create INSERT trigger for link table
        // lhs and rhs are already globalIds, so we just store them directly
        executeStatement("""
        CREATE TRIGGER IF NOT EXISTS Audit\(linkTableName)Insert AFTER INSERT ON \(linkTableName)
          WHEN ( sync_disabled() = 0 )
        BEGIN
          INSERT INTO AuditLog (tableName, operation, rowId, globalRowId, changedFields, changedFieldsNames, timestamp)
          VALUES (
            '\(linkTableName)',
            'INSERT',
            0,
            NEW.globalId,
            json_object(
                'lhs', json_object('kind', 2, 'value', NEW.lhs),
                'rhs', json_object('kind', 2, 'value', NEW.rhs)
            ),
            json_array('lhs', 'rhs'),
            unixepoch('subsec')
          );
        END;
        """)

        // Create DELETE trigger for link table
        executeStatement("""
        CREATE TRIGGER IF NOT EXISTS Audit\(linkTableName)Delete AFTER DELETE ON \(linkTableName)
          WHEN ( sync_disabled() = 0 )
        BEGIN
          INSERT INTO AuditLog (tableName, operation, rowId, globalRowId, changedFields, changedFieldsNames, timestamp)
          VALUES (
            '\(linkTableName)',
            'DELETE',
            0,
            OLD.globalId,
            json_object(
                'lhs', json_object('kind', 2, 'value', OLD.lhs),
                'rhs', json_object('kind', 2, 'value', OLD.rhs)
            ),
            json_array('lhs', 'rhs'),
            unixepoch('subsec')
          );
        END;
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

        var primitiveProperties: [(String, any PrimitiveProperty.Type)] = modelType.properties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        // id is handled separately (not from model properties); globalId now comes from model properties
        primitiveProperties.append(("id", Int64.self))
        existing["id"] = "BIGINT"
        existing["globalId"] = "TEXT"
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

    /// Recursively discover all Model types linked from the given schema.
    private func discoverAllTypes(from initialSchema: [any Model.Type]) -> [any Model.Type] {
        var discoveredTypes = Set<ObjectIdentifier>()
        var typesToProcess = initialSchema
        var completeSchema: [any Model.Type] = []

        while !typesToProcess.isEmpty {
            let currentType = typesToProcess.removeFirst()
            let typeId = ObjectIdentifier(currentType)

            // Skip if already processed
            guard !discoveredTypes.contains(typeId) else {
                continue
            }

            // Mark as discovered and add to result
            discoveredTypes.insert(typeId)
            completeSchema.append(currentType)

            // Find all LinkProperty types in this Model's properties
            for (_, propertyType) in currentType.properties {
                if let linkPropertyType = propertyType as? any LinkProperty.Type {
                    let linkedModelType = linkPropertyType.modelType
                    let linkedTypeId = ObjectIdentifier(linkedModelType)

                    // Add to processing queue if not already discovered
                    if !discoveredTypes.contains(linkedTypeId) {
                        typesToProcess.append(linkedModelType)
                    }
                }
            }
        }

        return completeSchema
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
        precondition(object.primaryKey == nil, "Cannot add object that was already inserted into the database. Object already has primaryKey: \(object.primaryKey!)")

        let primitiveProperties = T.properties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        
        // Exclude globalId from upsert SET clause - we want to preserve the original globalId on conflict
        let upsertProperties = primitiveProperties.filter { $0.0 != "globalId" }
        let conflictClause = T.constraints.isEmpty ? "" : T.constraints.filter { $0.allowsUpsert }.map({
            "ON CONFLICT(\($0.columns.joined(separator: ","))) DO UPDATE SET \(upsertProperties.map({ $0.0 + " = excluded.\($0.0)" }).joined(separator: ","))"
        }).joined(separator: " ")
        let insertStatementString = "INSERT INTO \(T.entityName) (\(primitiveProperties.map(\.0).joined(separator: ", "))) VALUES (\(primitiveProperties.map { _ in "?" }.joined(separator: ", "))) \(conflictClause);"
        var insertStatement: OpaquePointer?
        
        defer {
            sqlite3_finalize(insertStatement)
        }
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            object._encode(statement: insertStatement)
            object._assign(lattice: self)
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
            let error = readError() ?? "<unknown_error>"
            print("❌ INSERT failed for \(T.entityName): \(error)")
            print("   SQL: \(insertStatementString)")
            logger.error("INSERT statement could not be prepared.: \(error)")
            preconditionFailure("INSERT statement could not be prepared. Check the logs for more information.")
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
        // Exclude globalId from upsert SET clause - we want to preserve the original globalId on conflict
        let upsertPrimitives = primitives.filter { $0.0 != "globalId" }
        let columnList      = primitives.map(\.0).joined(separator: ", ")
        let placeholderList = primitives.map { _ in "?" }.joined(separator: ", ")
        let sql = """
          INSERT INTO \(S.Element.entityName)
            (\(columnList))
          VALUES
            (\(placeholderList))
          \(S.Element.constraints.isEmpty ? "" : S.Element.constraints.filter { $0.allowsUpsert }.map({
              """
              ON CONFLICT(\($0.columns.joined(separator: ","))) DO UPDATE SET \(upsertPrimitives.map({
                  $0.0 + " = excluded.\($0.0)"
              }).joined(separator: ","))
              """
          }).joined(separator: ","));
          """
        
        // 3) Prepare once
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            logger.debug("🔴 failed to prepare bulk‐insert: \(err)")
            return
        }
        
        // 4) Loop and insert each element
        for element in newElements {
            precondition(element.primaryKey == nil, "Cannot add object that was already inserted into the database. Object already has primaryKey: \(element.primaryKey!)")

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
    
    internal func newObject<T: Model>(_ objectType: T.Type, primaryKey id: Int64) -> T {
        if let isolation {
            return isolation.assumeIsolated { [configuration] isolation in
                let object = T(isolation: isolation)
                guard let weakDb = Lattice.latticeIsolationRegistrar[IsolationKey(isolation: isolation, configuration: configuration)], let dbPtr = weakDb.db else {
                    fatalError()
                }
                object._assign(lattice: Lattice(dbPtr))
                object.primaryKey = id
                
                dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: isolation))
                return _UncheckedSendable(object)
            }.value
        } else {
            let object = T(isolation: #isolation)
            object._assign(lattice: self)
            object.primaryKey = id
            
//            dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: id, object.weakCapture(isolation: isolation))
            return object
        }
    }
    
    func beginObserving<T: Model>(_ object: T) {
        object.primaryKey.map {
            dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: $0, object.weakCapture(isolation: isolation))
        }
    }
    func finishObserving<T: Model>(_ object: T) {
        object.primaryKey.map {
            dbPtr.removeModelObserver(tableName: T.entityName, primaryKey: $0)
        }
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
                return newObject(T.self, primaryKey: id)
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
                return newObject(T.self, primaryKey: id)
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
                autoreleasepool {
                    let lattice = try! Lattice(for: modelTypes, configuration: configuration)
                    var resolvedChanges: [AuditLog] = []
                    for change in changes {
                        change.resolve(on: lattice).map {
                            resolvedChanges.append($0)
                        }
                    }
                    stream.yield(resolvedChanges)
                }
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
                            $0.rowId == rowId && `where`(Query<T>()).convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: true) && $0.operation == .insert
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
                            $0.rowId == rowId && `where`(Query<T>()).convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: true) && $0.operation == .delete
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
    
    private func checkedLeakedStatements() {
        var pStmt: OpaquePointer?
        while ((pStmt = sqlite3_next_stmt(db, pStmt)) != nil) {
            let sql = sqlite3_sql(pStmt)
            print("Leaked statement: \(pStmt) — \(String(cString: sql!))")
        }
    }
    
    public func beginTransaction(isolation: isolated (any Actor)? = #isolation) {
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
                if sqlite3_get_autocommit(db) == 1 {
                    rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
                } else {
                    break
                }
            }
        }
        
    }
    
    public func commitTransaction(isolation: isolated (any Actor)? = #isolation) {
        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(db) {
                let errorString = String(cString: errorMessage)
                logger.debug("Error during sqlite3_step: \(errorString)")
            } else {
                logger.debug("Unknown error during sqlite3_step")
            }
//            fatalError()
        } else {
            logger.debug("Transaction committed successfully")
        }
    }
    
    public func transaction<T>(isolation: isolated (any Actor)? = #isolation,
                               _ block: () throws -> T) rethrows -> T {
        // Start the transaction.
        beginTransaction()
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

//@dynamicCallable public struct BlockIsolated {
//    private let block: @isolated(any) () -> Void
//    public init(isolation: isolated (any Actor)? = #isolation,
//                _ block: @escaping @isolated(any) () -> Void) {
//        self.block = block
//    }
//    
//    public func dynamicallyCall(withArguments arguments: [Any]) {
//        block()
//    }
//}
