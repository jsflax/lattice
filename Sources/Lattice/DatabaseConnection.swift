import Foundation
@preconcurrency import Combine
import SQLite3
import os.lock

private final class IsolationKeyBox {
    let key: IsolationKey
    init(_ key: IsolationKey) { self.key = key }
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

    let key = Unmanaged<IsolationKeyBox>.fromOpaque(pArg!).takeUnretainedValue().key
    guard let db = Lattice.latticeIsolationRegistrar[key]?.db else {
        return
    }

    guard tableNameStr == "AuditLog" else {
        return
    }
    let lattice = Lattice(db)
    guard let audit = lattice.object(AuditLog.self, primaryKey: rowId) /* ignore updates to the audit table */ else {
        return
    }

    db.appendToChangeBuffer(audit)
//    lattice.logger.debug("Hook callback at \(audit.timestamp.formatted())")
//    let keyPath = audit.changedFieldsNames?.compactMap({ $0 }).first!
//
//    let isolation = lattice.isolation
//    let tableName = audit.tableName, rowId = audit.rowId
//    lattice.triggerObservers(tableName: tableName, rowId: rowId, keyPath: keyPath, audit: audit, triggerAuditObservers: true)
//    lattice.logger.debug("SQLite Update Hook triggered: \(op) on database: \(dbNameStr), table: \(tableNameStr), row id: \(rowId)")
}

package struct IsolationKey: Hashable, Equatable {
    let isolationKey: ObjectIdentifier?
    let configuration: Lattice.Configuration
    weak var isolation: (any Actor)?
    
    init(isolation: (any Actor)?, configuration: Lattice.Configuration) {
        if let isolation = isolation {
            self.isolationKey = ObjectIdentifier(isolation)
        } else {
            self.isolationKey = nil
        }
        self.configuration = configuration
        self.isolation = isolation
    }
    
//        init(identifier: ObjectIdentifier?) {
//            self.isolationKey = identifier
//        }
    
    package func hash(into hasher: inout Hasher) {
        isolationKey.map { isolation in
            hasher.combine(isolation)
        }
        hasher.combine(configuration)
    }
    
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.isolationKey == rhs.isolationKey && lhs.configuration == rhs.configuration
    }
}

public final class SharedDBPointer: @unchecked Sendable {
    
    /// The underlying raw pointer
    var db: OpaquePointer?
    var readDb: OpaquePointer?
    let configuration: Lattice.Configuration
    var isolation: (any Actor)?
    var key: IsolationKey
    private var keyBox: IsolationKeyBox!
    private var keyUserData: UnsafeMutableRawPointer!
    var isSyncDisabled = false
    var modelTypes: [any Model.Type]
    var changeBuffer: [AuditLog] = []
    var isSynchronizer: Bool = false
    private var isFlushing: Bool = false
    package var observationRegistrar: [
        String: [
            Int64: [IsolationWeakRef]
        ]
    ] = [:]
    
    package var tableObservationRegistrar: [
        String: [
            ObjectIdentifier: (([AuditLog]) -> ())
        ]
    ] = [:]
    
    /// Initialize with an existing pointer.
    /// You must ensure `pointer` was allocated (and, if appropriate, initialized).
    init(isolation: isolated (any Actor)? = #isolation,
         configuration: Lattice.Configuration,
         for schema: [any Model.Type]) throws {
        self.configuration = configuration
        self.isolation = isolation
        self.key = IsolationKey(isolation: isolation, configuration: configuration)
        self.keyBox = IsolationKeyBox(self.key)
        self.keyUserData = Unmanaged.passRetained(self.keyBox).toOpaque()
        self.modelTypes = schema
        if sqlite3_open_v2(configuration.fileURL.path, &self.db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open database at path: \(configuration.fileURL.path)."])
        }
        if sqlite3_open_v2(configuration.fileURL.path, &self.readDb, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open database at path: \(configuration.fileURL.path)."])
        }

        // Register SQLite hooks, passing &keyUserData as user data pointer
        // The keyUserData property lives as long as this SharedDBPointer instance
        sqlite3_wal_hook(db, { ptr, _,_,_  in
            let key = Unmanaged<IsolationKeyBox>.fromOpaque(ptr!).takeUnretainedValue().key
            guard let db = Lattice.latticeIsolationRegistrar[key]?.db,
                !db.isFlushing else {
                return 0
            }
            db.flushChanges()
//            Lattice(db).logger.debug("Commited")
            return SQLITE_OK
        }, keyUserData)
        sqlite3_update_hook(db, updateHookCallback, keyUserData)
        sqlite3_create_function_v2(
            db,
            "sync_disabled",       // SQL name
            0,                     // number of args
            SQLITE_UTF8,
            keyUserData,                   // user data pointer
            { ctx, argc, argv in
                // called on each trigger fire
                let key = Unmanaged<IsolationKeyBox>.fromOpaque(sqlite3_user_data(ctx)).takeUnretainedValue().key
                guard let db = Lattice.latticeIsolationRegistrar[key]?.db else {
                    return
                }
                let cInt = db.isSyncDisabled ? 1 : 0
                sqlite3_result_int(ctx, Int32(cInt))
            },
            nil, nil, nil
        )
    }
    private let lock = NSLock()

    func appendToChangeBuffer(_ audit: AuditLog) {
        lock.withLock {
            changeBuffer.append(audit)
        }
    }

    func flushChanges() {
        lock.withLock {
            guard !changeBuffer.isEmpty else {
                return
            }
            let changeBuffer = changeBuffer
            self.changeBuffer.removeAll()
            let sendableEvents = changeBuffer.map(\.sendableReference)
            Task { [configuration] in
                await Self.publishEvents(sendableEvents, for: configuration)
            }
        }
    }
    
    static func publishEvents(_ events: [any SendableReference<AuditLog?>],
                              for configuration: Lattice.Configuration) async {
        let isolatedLattices = Lattice.latticeIsolationRegistrar.filter({ $0.key.configuration == configuration })
        for (isolationKey, dbRef) in isolatedLattices {
            Task {
                if let isolation = dbRef.db?.isolation {
                    await isolation.invoke { _ in
                        guard let db = dbRef.db else {
                            Lattice.latticeIsolationRegistrar.removeValue(forKey: isolationKey)
                            return
                        }
                        let lattice = Lattice(db)
                        var resolvedEvents: [AuditLog] = []

                        for event in events {
                            event.resolve(on: lattice).map {
                                resolvedEvents.append($0)
                            }
                        }
                        db.tableObservationRegistrar["AuditLog"]?.forEach { observer in
                            observer.value(resolvedEvents)
                        }
                        for auditLogEntry in resolvedEvents {
                            db.triggerTableObservers(tableName: auditLogEntry.tableName, audit: [auditLogEntry])
                            db.triggerKeyPathObservers(tableName: auditLogEntry.tableName,
                                                       rowId: auditLogEntry.rowId,
                                                       keyPath: auditLogEntry.changedFieldsNames?.compactMap({ $0 }).first!)
                        }
                    }
                } else {
                    guard let db = dbRef.db else {
                        Lattice.latticeIsolationRegistrar.removeValue(forKey: isolationKey)
                        return
                    }
                    let lattice = Lattice(db)
                    var resolvedEvents: [AuditLog] = []

                    for event in events {
                        event.resolve(on: lattice).map {
                            resolvedEvents.append($0)
                        }
                    }
                    db.tableObservationRegistrar["AuditLog"]?.forEach { observer in
                        observer.value(resolvedEvents)
                    }
                    for auditLogEntry in resolvedEvents {
                        db.triggerTableObservers(tableName: auditLogEntry.tableName, audit: [auditLogEntry])
                        db.triggerKeyPathObservers(tableName: auditLogEntry.tableName,
                                                   rowId: auditLogEntry.rowId,
                                                   keyPath: auditLogEntry.changedFieldsNames?.compactMap({ $0 }).first!)
                    }
                }
            }
        }
    }
    
    private let observerLock = OSAllocatedUnfairLock<Void>()

    func insertModelObserver(tableName: String, primaryKey: Int64,
                             _ observation: IsolationWeakRef) {
        observerLock.withLock {
            observationRegistrar[tableName, default: [:]][primaryKey, default: []].append(observation)
        }
    }
    
    public func removeModelObserver(tableName: String, primaryKey: Int64) {
        observerLock.withLock {
            observationRegistrar[tableName, default: [:]].removeValue(forKey: primaryKey)
        }
    }

    public func removeModelObserver(isolation: isolated (any Actor)? = #isolation,
                                    tableName: String, primaryKey: Int64) async {
        observerLock.withLock {
            observationRegistrar[tableName, default: [:]].removeValue(forKey: primaryKey)
        }
    }
    
    public func triggerAuditObservers(_ audit: [AuditLog]) {
        let isolatedLattices = Lattice.latticeIsolationRegistrar.filter({ $0.key.configuration == configuration })
        let ref = audit.map(\.sendableReference)
        for (isolationKey, dbRef) in isolatedLattices {
            Task {
                if let isolation = dbRef.db?.isolation {
                    await isolation.invoke { _ in
                        guard let db = dbRef.db else {
                            Lattice.latticeIsolationRegistrar.removeValue(forKey: isolationKey)
                            return
                        }
                        let lattice = Lattice(db)
                        let auditLogEntry = await ref.compactMap { $0.resolve(on: lattice) }
                        for observer in db.tableObservationRegistrar["AuditLog"] ?? [:] {
                            observer.value(auditLogEntry)
                        }
                    }
                } else {
                    guard let db = dbRef.db else {
                        Lattice.latticeIsolationRegistrar.removeValue(forKey: isolationKey)
                        return
                    }
                    let lattice = Lattice(db)
                    let auditLogEntry = await ref.compactMap { $0.resolve(on: lattice) }
                    for observer in db.tableObservationRegistrar["AuditLog"] ?? [:] {
                        observer.value(auditLogEntry)
                    }
                }
            }
        }
//        for observer in tableObservationRegistrar["AuditLog"] ?? [:] {
//            observer.value(audit)
//        }
    }
    
    public func triggerTableObservers(tableName: String, audit: [AuditLog]) {
        tableObservationRegistrar[tableName]?.forEach { (key, observer) in
            observer(audit)
        }
    }
    
    public func triggerKeyPathObservers(tableName: String,
                                        rowId: Int64,
                                        keyPath: String?) {
        // Copy observers under lock, then iterate outside lock to avoid holding lock during callbacks
        let observers = observerLock.withLock {
            observationRegistrar[tableName]?[rowId] ?? []
        }

        observers.forEach { ref in
            guard let model = ref.value else {
                return
            }

            model._objectWillChange_send()
            model._triggerObservers_send(keyPath: keyPath!)
        }
    }
    
    /// When the last `SharedPointer` instance goes away, deinit runs
    deinit {
        if let keyUserData {
            Unmanaged<IsolationKeyBox>.fromOpaque(keyUserData).release()
        }
        keyUserData = nil
        keyBox = nil
        // If you only stored a single T:
        sqlite3_close(db)
        sqlite3_close(readDb)
        Lattice.latticeIsolationRegistrar.removeValue(forKey: IsolationKey(isolation: isolation,
                                                                           configuration: configuration))
    }
}

public struct AsyncArray<Element>: AsyncSequence {
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(self)
    }
    
    private let array: Array<Element>
    init(_ array: Array<Element>) {
        self.array = array
    }
    public struct AsyncIterator: AsyncIteratorProtocol {
        private let asyncArray: AsyncArray<Element>
        private var index = 0
        public typealias Failure = Error

        @usableFromInline
        init(_ asyncArray: AsyncArray<Element>) {
            self.asyncArray = asyncArray
        }
        public func next() async throws -> Element? {
            fatalError()
        }
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws(Failure) -> Element? {
            defer { index += 1 }
            guard index < self.asyncArray.array.endIndex else {
                return nil
            }
            return self.asyncArray.array[index]
        }
    }
    
    var count: Int { array.count }
    
}
extension Array {
        
    @inlinable public func compactMap<ElementOfResult>(isolation: isolated (any Actor)? = #isolation,
                                                       _ transform: (isolated (any Actor)?, Element) async throws -> ElementOfResult?) async rethrows -> [ElementOfResult] {
        var transformedElements: [ElementOfResult] = []
        for element in self {
            if let transformed = try await transform(isolation, element) {
                transformedElements.append(transformed)
            }
        }
        return transformedElements
    }
}

//extension IndexingIterator {
//    func next(isolation: isolated (any Actor)? = #isolation) {
//        self.
//    }
//}

