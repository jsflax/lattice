import SQLite3
import os
import Foundation
import LatticeSwiftCppBridge

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

extension UnsafeMutablePointer: @unchecked @retroactive Sendable {
}
extension UnsafeMutableRawPointer: @unchecked @retroactive Sendable {
}
extension lattice.swift_lattice: @unchecked @retroactive Sendable {
}

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
    
//    public var dbPtr: SharedDBPointer!
//    var db: OpaquePointer? {
//        dbPtr.db
//    }
    
    //    var observers: [AnyObject: () -> Void] = [:]
    private var ptr: SharedPointer<Lattice>?
    private static let synchronizersLock = OSAllocatedUnfairLock<Void>()
    nonisolated(unsafe) static var synchronizers: [URL: Synchronizer] = [:]
    
    public struct SyncConfiguration {
        
    }
    
    private struct Scheduler: Equatable, Hashable {
        let scheduler: lattice.SharedScheduler
        private var isolation: (any Actor)?
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isolation === rhs.isolation
        }
        
        func hash(into hasher: inout Hasher) {
            isolation.map {
                hasher.combine(ObjectIdentifier($0))
            }
        }
        private let isolationPtr: UnsafeMutablePointer<(any Actor)?>
        
        init(isolation: isolated (any Actor)? = #isolation) {
            self.isolation = isolation
            isolationPtr = UnsafeMutablePointer.allocate(capacity: 1)
            isolationPtr.initialize(to: self.isolation)
            self.scheduler = lattice.generic_scheduler(isolationPtr, { fn, ptr in
                guard let isolation = ptr?.assumingMemoryBound(to: (any Actor)?.self) else {
                    return fn.pointee()
                }
                if let isolation = isolation.pointee {
                    Task { [fn] in
                        await isolation.invoke { [fn] actor in
                            fn.pointee()
                        }
                    }
                } else {
                    fn.pointee()
                }
            }, { ptr in
                true
            }, { otherScheduler, ptr in
                guard let isolation = ptr?.assumingMemoryBound(to: (any Actor)?.self) else {
                    return false
                }
                return otherScheduler?.withMemoryRebound(to: lattice.generic_scheduler.self, capacity: 1) { pointer in
                    pointer.pointee.context_.assumingMemoryBound(to: (any Actor)?.self) == isolation
                } ?? false
            }, { ptr in
                return true
            }, { ptr in
                
            }).make_shared()
        }
    }
    
    public struct Configuration: Sendable, Equatable, Hashable {
        public var isStoredInMemoryOnly: Bool = false
        public var fileURL: URL
        public var authorizationToken: String?
        public var wssEndpoint: URL?
        private var scheduler: Scheduler
        
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
            self.scheduler = Scheduler()
        }
        
        fileprivate func cxxConfiguration(isolation: isolated (any Actor)? = #isolation) -> lattice.configuration {
            .init(std.string(self.fileURL.path()),
                  self.wssEndpoint.map {
                    std.string($0.absoluteString)
            } ?? std.string(),
                  authorizationToken.map { std.string($0) } ?? std.string(),
                  scheduler.scheduler)
        }
    }
    
    
    
    public nonisolated(unsafe) static var defaultConfiguration: Configuration = .init()
    public let configuration: Configuration
    public let modelTypes: [any Model.Type]
    private var synchronizer: Synchronizer?
    
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
//    internal init(_ db: SharedDBPointer) {
//        self.dbPtr = db
//        self.cxxLattice = lattice.swift_lattice()
//    }
    
    let cxxLatticeRef: lattice.swift_lattice_ref
    var cxxLattice: lattice.swift_lattice {
        cxxLatticeRef.get()
    }
    internal var isolation: (any Actor)?

    internal init(isolation: isolated (any Actor)? = #isolation,
                  for schema: [any Model.Type],
                  configuration: Configuration = defaultConfiguration,
                  isSynchronizing: Bool) throws {
        self.isolation = isolation
        self.configuration = configuration

        // Discover all linked types from the provided schema
        let allTypes = Self.discoverAllTypes(from: schema)
        self.modelTypes = allTypes

        // Build SchemaVector for C++
        var cxxSchemas = lattice.SchemaVector()
        for modelType in allTypes {
            let entry = lattice.swift_schema_entry(
                std.string(modelType.entityName),
                modelType.cxxPropertyDescriptor()
            )
            cxxSchemas.push_back(entry)
        }

        self.cxxLatticeRef = lattice.swift_lattice_ref.create(configuration.cxxConfiguration(), cxxSchemas)
    }
    
    public init(isolation: isolated (any Actor)? = #isolation,
                for schema: [any Model.Type], configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: schema, configuration: configuration, isSynchronizing: false)
    }
    
    public init(isolation: isolated (any Actor)? = #isolation,
                            _ modelTypes: any Model.Type..., configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: modelTypes, configuration: configuration)
    }

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

    /// Recursively discover all Model types linked from the given schema.
    private static func discoverAllTypes(from initialSchema: [any Model.Type]) -> [any Model.Type] {
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
    
    // MARK: Add
    public func add<T: Model>(_ object: T) {
        guard case var .unmanaged(o) = object._storage else {
            fatalError()
        }
        let managed = cxxLattice.add(consuming: o)
        object._storage = .managed(managed)
    }
    
    public func add<S: Sequence>(contentsOf newElements: S) where S.Element: Model {
        // Convert Swift models to C++ dynamic objects
        var cxxObjects = lattice.ModelVector()
        let schema = S.Element.cxxPropertyDescriptor()
        let tableName = std.string(S.Element.entityName)

        for element in newElements {
            precondition(element.primaryKey == nil, "Cannot add object that was already inserted into the database. Object already has primaryKey: \(element.primaryKey!)")

            guard case let .unmanaged(obj) = element._storage else {
                fatalError("Cannot bulk add managed objects")
            }
            cxxObjects.push_back(obj)
        }

        // Bulk insert via C++
        let managedObjects = cxxLattice.add_bulk(consuming: cxxObjects)
        // Update Swift models with their new storage
        var idx: Int = 0
        for element in newElements {
            element._storage = .managed(managedObjects[idx])
            element.primaryKey = managedObjects[idx].id()
            element.lattice = self
            element._didEncode()
            idx += 1
        }
    }
    
    internal func newObject<T: Model>(_ objectType: T.Type,
                                      primaryKey id: Int64,
                                      cxxObject: lattice.ManagedModel) -> T {
        if let isolation {
            return isolation.assumeIsolated { [configuration] isolation in
                let object = T(isolation: isolation)
                object._storage = .managed(cxxObject)
                object.primaryKey = id
                return _UncheckedSendable(object)
            }.value
        } else {
            let object = T(isolation: #isolation)
            object._storage = .managed(cxxObject)
            object.primaryKey = id
            return object
        }
    }
    
    func beginObserving<T: Model>(_ object: T) {
//        object.primaryKey.map {
//            dbPtr.insertModelObserver(tableName: T.entityName, primaryKey: $0, object.weakCapture(isolation: isolation))
//        }
    }
    func finishObserving<T: Model>(_ object: T) {
//        object.primaryKey.map {
//            dbPtr.removeModelObserver(tableName: T.entityName, primaryKey: $0)
//        }
    }
    
    public func object<T>(_ type: T.Type = T.self, primaryKey: Int64) -> T? where T: Model {
        let object = cxxLattice.object(primaryKey, std.string(type.entityName))
        if object.hasValue {
            return newObject(type, primaryKey: primaryKey, cxxObject: object.pointee)
        }
        return nil
    }
    
    internal func object<T>(_ type: T.Type = T.self, globalKey: UUID) -> T? where T: Model {
        let globalIdString = globalKey.uuidString.lowercased()
        if let object = cxxLattice.object_by_global_id(std.string(globalIdString), std.string(type.entityName)).value {
            return newObject(type, primaryKey: object.id(), cxxObject: object)
        }
        return nil
    }
    
    public func objects<T>(_ type: T.Type = T.self) -> Results<T> where T: Model {
        Results(self)
    }
    
    // MARK: Delete
    @discardableResult public func delete<T: Model>(_ object: consuming T) -> Bool {
        guard object.primaryKey != nil, case var .managed(o) = object._storage else { return false }
        object._storage = .unmanaged(o.source)
        return cxxLattice.remove(&o)
    }
    
    @discardableResult public func delete<T: Model>(_ modelType: T.Type = T.self,
                                                    where: ((Query<T>) -> Query<Bool>)? = nil) -> Bool {
        let whereClause: lattice.OptionalString = `where`.map { lattice.string_to_optional(std.string($0(Query<T>()).predicate)) } ?? .init()
        return cxxLattice.delete_where(std.string(T.entityName), whereClause)
    }
    
    public func deleteHistory() {
        delete(AuditLog.self)
    }
    
    public func count<T>(_ modelType: T.Type, where: ((Query<T>) -> Query<Bool>)? = nil) -> Int where T: Model {
        let whereClause: lattice.OptionalString = `where`.map { lattice.string_to_optional( std.string($0(Query<T>()).predicate)) } ?? lattice.OptionalString()
        return Int(cxxLattice.count(std.string(T.entityName), whereClause))
    }
    
    /// Holds observation state and cancels on deinit
    public final class TableObservationToken: Cancellable, @unchecked Sendable {
        private let cxxLattice: lattice.swift_lattice
        private let tableName: std.string
        private let observerId: UInt64
        private var isCancelled = false

        init(cxxLattice: lattice.swift_lattice, tableName: std.string, observerId: UInt64) {
            self.cxxLattice = cxxLattice
            self.tableName = tableName
            self.observerId = observerId
        }

        public func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            cxxLattice.remove_table_observer(tableName, observerId)
        }

        deinit {
            cancel()
        }
    }

    /// Context class to bridge Swift closures to C callbacks
    private final class TableObserverContext {
        let callback: (String, Int64, String) -> Void

        init(callback: @escaping (String, Int64, String) -> Void) {
            self.callback = callback
        }
    }

    public func observe(_ block: @escaping ([AuditLog]) -> ()) -> AnyCancellable {
        let tableName = std.string(AuditLog.entityName)

        // Create context that holds the Swift closure
        let context = TableObserverContext { [self] operation, rowId, globalRowId in
//            guard let self else { return }
            // Fetch the audit log entry
            if let auditLog = self.object(AuditLog.self, primaryKey: rowId) {
                block([auditLog])
            }
        }

        // Prevent context from being deallocated
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        // Register observer with C++ using C function pointer
        let observerId = cxxLattice.add_table_observer(
            tableName,
            contextPtr,
            { (contextPtr, operation, rowId, globalRowId) in
                guard let contextPtr else { return }
                let context = Unmanaged<TableObserverContext>.fromOpaque(contextPtr).takeUnretainedValue()
                context.callback(String(operation), rowId, String(globalRowId))
            }
        )

        // Create cancellable token
        let token = TableObservationToken(cxxLattice: cxxLattice, tableName: tableName, observerId: observerId)

        return AnyCancellable {
            token.cancel()
            // Release the retained context
            Unmanaged<TableObserverContext>.fromOpaque(contextPtr).release()
        }
    }

    public var changeStream: AsyncStream<[AuditLog]> {
        AsyncStream { [cxxLattice, modelTypes, configuration] stream in
            let tableName = std.string(AuditLog.entityName)

            let context = TableObserverContext { operation, rowId, globalRowId in
                autoreleasepool {
                    let lattice = try! Lattice(for: modelTypes, configuration: configuration)
                    if let auditLog = lattice.object(AuditLog.self, primaryKey: rowId) {
                        stream.yield([auditLog])
                    }
                }
            }

            let contextPtr = Unmanaged.passRetained(context).toOpaque()

            let observerId = cxxLattice.add_table_observer(
                tableName,
                contextPtr,
                { (contextPtr, operation, rowId, globalRowId) in
                    guard let contextPtr else { return }
                    let context = Unmanaged<TableObserverContext>.fromOpaque(contextPtr).takeUnretainedValue()
                    context.callback(String(operation), rowId, String(globalRowId))
                }
            )

            stream.onTermination = { _ in
                cxxLattice.remove_table_observer(tableName, observerId)
                Unmanaged<TableObserverContext>.fromOpaque(contextPtr).release()
            }
        }
    }

    public func observe<T: Model>(_ modelType: T.Type, where: Predicate<T>? = nil,
                                  block: @escaping (Results<T>.CollectionChange) -> ()) -> AnyCancellable {
        let tableName = std.string(T.entityName)

        let context = TableObserverContext { [self] operation, rowId, globalRowId in
            switch operation {
            case "INSERT":
                if let `where` {
                    let whereQuery = `where`(Query<T>())
                    let convertedQuery = whereQuery.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                    let auditResults = Results<AuditLog>(self).where({
                        $0.rowId == rowId && convertedQuery && $0.operation == .insert
                    })
                    if let _ = auditResults.first {
                        block(.insert(rowId))
                    }
                } else {
                    if self.object(modelType, primaryKey: rowId) != nil {
                        block(.insert(rowId))
                    }
                }
            case "DELETE":
                if let `where` {
                    let whereQuery = `where`(Query<T>())
                    let convertedQuery = whereQuery.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                    let auditResults = Results<AuditLog>(self).where({
                        $0.rowId == rowId && convertedQuery && $0.operation == .delete
                    })
                    if let _ = auditResults.first {
                        block(.delete(rowId))
                    }
                } else {
                    block(.delete(rowId))
                }
            case "UPDATE":
                // CollectionChange doesn't have an update case currently
                // Updates are tracked via individual object observation
                break
            default:
                break
            }
        }

        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        let observerId = cxxLattice.add_table_observer(
            tableName,
            contextPtr,
            { (contextPtr, operation, rowId, globalRowId) in
                guard let contextPtr else { return }
                let context = Unmanaged<TableObserverContext>.fromOpaque(contextPtr).takeUnretainedValue()
                context.callback(String(operation), rowId, String(globalRowId))
            }
        )

        let token = TableObservationToken(cxxLattice: cxxLattice, tableName: tableName, observerId: observerId)

        return AnyCancellable {
            token.cancel()
            Unmanaged<TableObserverContext>.fromOpaque(contextPtr).release()
        }
    }
    
    public func beginTransaction(isolation: isolated (any Actor)? = #isolation) {
        // Start the transaction.
        cxxLattice.begin_transaction()
    }
    
    public func commitTransaction(isolation: isolated (any Actor)? = #isolation) {
        cxxLattice.commit()
    }
    
    public func transaction<T>(isolation: isolated (any Actor)? = #isolation,
                               _ block: () throws -> T) rethrows -> T {
        beginTransaction()
        let value = try block()
        commitTransaction()
        return value
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
