import SQLite3
import os
import Foundation
@_exported import LatticeSwiftCppBridge
@_exported import LatticeSwiftModule

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

extension UnsafeMutablePointer: @unchecked @retroactive Sendable {
}
extension UnsafeMutableRawPointer: @unchecked @retroactive Sendable {
}
extension lattice.swift_lattice: @unchecked @retroactive Sendable {
}
extension lattice.swift_lattice_ref: Hashable, Equatable, @unchecked @retroactive Sendable {
    public var hashValue: Int {
        Int(self.hash_value())
    }
    
    public static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}

public struct Lattice {
    private static let synchronizersLock = OSAllocatedUnfairLock<Void>()
    
    public struct SyncConfiguration {
        
    }
    
    /// URLSession-backed websocket client that bridges to C++ generic_websocket_client
    internal final class WebsocketClient {
        private var webSocketTask: URLSessionWebSocketTask?
        private var currentState: lattice.websocket_state = .closed
        private let session: URLSession
        private let delegateHandler: WebSocketDelegateHandler

        // Pointers to trigger C++ callbacks - set after generic_websocket_client is created
        private var cxxClientPtr: UnsafeMutableRawPointer?

        final class WebSocketDelegateHandler: NSObject, URLSessionWebSocketDelegate {
            weak var client: WebsocketClient?

            func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                            didOpenWithProtocol protocol: String?) {
                client?.handleOpen()
            }

            func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
                let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                client?.handleClose(code: Int(closeCode.rawValue), reason: reasonString)
            }

            func urlSession(_ session: URLSession,
                            task: URLSessionTask,
                            didCompleteWithError error: (any Swift.Error)?) {
                if let error = error {
                    client?.handleError(error.localizedDescription)
                }
            }
        }

        init() {
            delegateHandler = WebSocketDelegateHandler()
            session = URLSession(configuration: .default, delegate: delegateHandler, delegateQueue: nil)
            delegateHandler.client = self
        }

        /// Creates the C++ generic_websocket_client that wraps this Swift client.
        /// Returns a raw pointer that C++ will take ownership of via unique_ptr.
        func createCxxClient() -> UnsafeMutableRawPointer {
            let clientPtr = Unmanaged.passRetained(self).toOpaque()

            let cxxClient = lattice.generic_websocket_client(
                clientPtr,
                // connect_block
                { ptr, url, headers in
                    guard let ptr = ptr else { return }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    client.performConnect(url: String(url), headers: headers)
                },
                // disconnect_block
                { ptr in
                    guard let ptr = ptr else { return }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    client.performDisconnect()
                },
                // state_block
                { ptr in
                    guard let ptr = ptr else { return .closed }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    return client.currentState
                },
                // send_block
                { ptr, message in
                    guard let ptr = ptr else { return }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    client.performSend(message)
                }
            )

            // Allocate and store the C++ client so we can call trigger methods
            let cxxPtr = UnsafeMutablePointer<lattice.generic_websocket_client>.allocate(capacity: 1)
            cxxPtr.initialize(to: cxxClient)
            self.cxxClientPtr = UnsafeMutableRawPointer(cxxPtr)

            // Return as websocket_client* for unique_ptr
            return UnsafeMutableRawPointer(cxxPtr)
        }

        private func performConnect(url urlString: String, headers: lattice.HeadersMap) {
            guard let url = URL(string: urlString) else {
                triggerError("Invalid URL: \(urlString)")
                return
            }

            var request = URLRequest(url: url)
            headers.forEach { (keyValuePair) in
                let key = keyValuePair.first
                let value = keyValuePair.second
                request.setValue(String(value), forHTTPHeaderField: String(key))
            }

            currentState = .connecting
            webSocketTask = session.webSocketTask(with: request)
            webSocketTask?.resume()
            // Try receiving immediately AND after open
//            startReceiving()
        }

        private func performDisconnect() {
            currentState = .closing
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }

        private func performSend(_ message: lattice.websocket_message) {
            guard let task = webSocketTask else { return }

            let wsMessage: URLSessionWebSocketTask.Message
            if message.msg_type == .text {
                wsMessage = .string(String(message.as_string()))
            } else {
                let data = Data(message.data)
                wsMessage = .data(data)
            }

            task.send(wsMessage) { [weak self] error in
                if let error = error {
                    self?.triggerError(error.localizedDescription)
                }
            }
        }

        private func startReceiving() {
            webSocketTask?.receive { [weak self] result in
                guard let self = self else {
                    return
                }
                switch result {
                case .success(let message):
                    var cxxMessage = lattice.websocket_message()
                    switch message {
                    case .string(let text):
                        cxxMessage = lattice.websocket_message.from_string(std.string(text))
                    case .data(let data):
                        var vec = lattice.ByteVector()
                        for byte in data {
                            vec.push_back(byte)
                        }
                        cxxMessage = lattice.websocket_message.from_binary(vec)
                    @unknown default:
                        break
                    }
                    self.triggerMessage(cxxMessage)
                    self.startReceiving()

                case .failure(let error):
                    self.triggerError(error.localizedDescription)
                }
            }
        }

        private func handleOpen() {
            currentState = .open
            startReceiving()  // Also try receiving here
            triggerOpen()
        }

        private func handleClose(code: Int, reason: String) {
            currentState = .closed
            webSocketTask = nil
            triggerClose(code: code, reason: reason)
        }

        private func handleError(_ error: String) {
            triggerError(error)
        }

        // MARK: - C++ trigger methods

        private func triggerOpen() {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_websocket_client.self).pointee.trigger_on_open()
        }

        private func triggerMessage(_ message: lattice.websocket_message) {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_websocket_client.self).pointee.trigger_on_message(message)
        }

        private func triggerError(_ error: String) {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_websocket_client.self).pointee.trigger_on_error(std.string(error))
        }

        private func triggerClose(code: Int, reason: String) {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_websocket_client.self).pointee.trigger_on_close(Int32(code), std.string(reason))
        }

        deinit {
            // Note: Don't deallocate cxxClientPtr - C++ owns it via unique_ptr
            // The Swift WebsocketClient is kept alive by passRetained() and should be
            // released when C++ destroys the websocket_client (not implemented yet)
        }
    }

    /// Registers the Swift network factory with C++ layer. Called once on first Lattice init.
    private nonisolated(unsafe) static var networkFactoryRegistered = false
    private static func registerNetworkFactoryIfNeeded() {
        guard !networkFactoryRegistered else { return }
        networkFactoryRegistered = true

        lattice.register_generic_network_factory(
            nil,  // no user_data needed
            nil,  // http_block - not implemented yet
            // websocket_block
            { _ in
                let client = WebsocketClient()
                return client.createCxxClient().assumingMemoryBound(to: lattice.websocket_client.self)
            },
            nil   // destroy_fn
        )
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
                    let function = _UncheckedSendable(fn.pointee)
                    Task {
                        await isolation.invoke { actor in
                            function.value()
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
                    // Compare the actual actor instances, not the pointer addresses.
                    // Each Scheduler allocates its own isolationPtr, so we need to dereference
                    // and compare the actors using identity (===).
                    let otherIsolation = pointer.pointee.context_.assumingMemoryBound(to: (any Actor)?.self)
                    let ourActor = isolation.pointee
                    let otherActor = otherIsolation.pointee
                    // Both nil means same (no isolation)
                    if ourActor == nil && otherActor == nil { return true }
                    // One nil, one non-nil means different
                    guard let our = ourActor, let other = otherActor else { return false }
                    // Compare actor identity
                    return our === other
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

        /// Read-only mode. When true:
        /// - Database is opened with SQLITE_OPEN_READONLY
        /// - No WAL mode (uses existing journal mode)
        /// - No table creation or schema changes
        /// - No sync, no change hooks
        /// Use this for bundled template databases in app resources.
        public var isReadOnly: Bool = false

        public init(isStoredInMemoryOnly: Bool = false, fileURL: URL? = nil,
                    authorizationToken: String? = nil, wssEndpoint: URL? = nil,
                    isReadOnly: Bool = false) {
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
            self.isReadOnly = isReadOnly
        }

        fileprivate func cxxConfiguration(isolation: isolated (any Actor)? = #isolation) -> lattice.swift_configuration {
            // Create a scheduler for the current isolation context.
            // This ensures different isolation contexts get different cache keys in C++.
            let currentScheduler = Scheduler(isolation: isolation)
            var config: lattice.swift_configuration
            if isStoredInMemoryOnly {
                config = .init(std.string(":memory:"),
                      self.wssEndpoint.map {
                    std.string($0.absoluteString)
                } ?? std.string(),
                      authorizationToken.map { std.string($0) } ?? std.string(),
                      currentScheduler.scheduler)
            } else {
                config = .init(std.string(self.fileURL.path(percentEncoded: false)),
                      self.wssEndpoint.map {
                    std.string($0.absoluteString)
                } ?? std.string(),
                      authorizationToken.map { std.string($0) } ?? std.string(),
                      currentScheduler.scheduler)
            }
            config.read_only = isReadOnly
            return config
        }
    }
    
    
    
    public nonisolated(unsafe) static var defaultConfiguration: Configuration = .init()
    public let configuration: Configuration
    public let modelTypes: [any Model.Type]
//    private var synchronizer: Synchronizer?
    
    private var isSyncDisabled = false
    internal var logger = Logger.db

    let cxxLatticeRef: lattice.swift_lattice_ref
    var cxxLattice: lattice.swift_lattice {
        cxxLatticeRef.get()
    }
    internal var isolation: (any Actor)?

    internal init(isolation: isolated (any Actor)? = #isolation,
                  ref: lattice.swift_lattice_ref) {
        self = Self.cacheLock.withLockUnchecked {
            let key = CacheKey(ref)
            if let cached = Self.cache[key] {
                return cached
            }
            // Fallback: look up by path if hash lookup fails
            // This can happen when C++ creates a new impl for the same path
            let refPath = String(ref.path())
            if let cached = Self.cache.values.first(where: { $0.configuration.fileURL.path(percentEncoded: false) == refPath }) {
                return cached
            }
            // Debug: print cache state
            print("[Lattice Cache Debug]")
            print("  Looking for hash: \(key.implHash), path: \(refPath)")
            print("  Cache has \(Self.cache.count) entries:")
            for (k, v) in Self.cache {
                print("    hash: \(k.implHash), path: \(v.configuration.fileURL.path(percentEncoded: false))")
            }
            preconditionFailure("Lattice not found in cache for ref with hash \(key.implHash), path: \(refPath)")
        }
    }
    
    private static let cacheLock = OSAllocatedUnfairLock<Void>()

    /// Cache key that uses the underlying impl_ pointer hash for stable identity
    private struct CacheKey: Hashable {
        let implHash: Int64

        init(_ ref: lattice.swift_lattice_ref) {
            self.implHash = ref.hash_value()
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(implHash)
        }

        static func == (lhs: CacheKey, rhs: CacheKey) -> Bool {
            lhs.implHash == rhs.implHash
        }
    }

    private nonisolated(unsafe) static var cache: [CacheKey: Lattice] = [:]
    
    internal init(isolation: isolated (any Actor)? = #isolation,
                  for schema: [any Model.Type],
                  configuration: Configuration = defaultConfiguration,
                  isSynchronizing: Bool,
                  migration: [Int: Migration]? = nil) throws {
        // Register Swift network factory on first use
        Self.registerNetworkFactoryIfNeeded()

        self.isolation = isolation
        self.configuration = configuration

        // Discover all linked types from the provided schema
        let allTypes = Self.discoverAllTypes(from: schema)
        self.modelTypes = allTypes

        // Build SchemaVector for C++
        var cxxSchemas = lattice.SchemaVector()
        for modelType in allTypes {
            // Convert Swift constraints to C++ constraints
            var cxxConstraints = lattice.ConstraintVector()
            for constraint in modelType.constraints {
                var cols = lattice.StringVector()
                for col in constraint.columns {
                    cols.push_back(std.string(col))
                }
                let cxxConstraint = lattice.swift_constraint(cols, constraint.allowsUpsert)
                cxxConstraints.push_back(cxxConstraint)
            }

            let entry = lattice.swift_schema_entry(
                std.string(modelType.entityName),
                modelType.cxxPropertyDescriptor(),
                cxxConstraints
            )
            cxxSchemas.push_back(entry)
        }

        if let migration {
            // Find the target version from migration dict (highest key)
            let targetVersion = migration.keys.max() ?? 1

            // Create swift_configuration with row migration callback
            var swiftConfig =  configuration.cxxConfiguration()//lattice.swift_configuration(configuration.cxxConfiguration())
            swiftConfig.target_schema_version = Int32(targetVersion)

            swiftConfig.setGetOldAndNewSchemaForVersionBlock { tableName, versionNumber in
                if let currentMigration = migration[versionNumber] {
                    if let (from, to) = currentMigration.schemas[String(tableName)] {
                        return lattice.to_optional(lattice.swift_configuration.SchemaPair(from: from, to: to))
                    }
                }
                return .init()
            }
            
            // Set up the row migration callback
            swiftConfig.setRowMigrationBlock({ tableName, oldRefPtr, newRefPtr in
                guard let oldRefPtr = oldRefPtr, let newRefPtr = newRefPtr else { return }
                let entityName = String(tableName)

                // C++ owns these refs - don't retain/release (C++ creates and deletes them)

                // Find the migration for this version and call _sendRow
                if let currentMigration = migration[targetVersion] {
                    currentMigration._sendRow(entityName: entityName, oldRefPtr, newRefPtr)
                }
            })

            self.cxxLatticeRef = lattice.swift_lattice_ref.create(swiftConfig: swiftConfig, schemas: cxxSchemas)
        } else {
            self.cxxLatticeRef = lattice.swift_lattice_ref.create(swiftConfig: configuration.cxxConfiguration(), schemas: cxxSchemas)
        }
        let key = CacheKey(self.cxxLatticeRef)
        let latticeInstance = self
        Self.cacheLock.withLockUnchecked { Self.cache[key] = latticeInstance }
    }

    // MARK: Public Inits
    public init(isolation: isolated (any Actor)? = #isolation,
                for schema: [any Model.Type],
                configuration: Configuration = defaultConfiguration,
                migration: [Int: Migration]? = nil) throws {
        try self.init(for: schema, configuration: configuration, isSynchronizing: false, migration: migration)
    }

    internal var schema: _Schema?

//    /// Initialize Lattice with model types.
//    ///
//    /// - Parameters:
//    ///   - modelTypes: The model types to register
//    ///   - configuration: Database configuration
//    public init<each M: Model>(isolation: isolated (any Actor)? = #isolation,
//                               _ modelTypes: repeat (each M).Type,
//                               configuration: Configuration = defaultConfiguration,
//                               migration: [Int: Migration]? = nil) throws {
//        var types = [any Model.Type]()
//        for type in repeat each modelTypes {
//            types.append(type)
//        }
//        try self.init(for: types, configuration: configuration, migration: migration)
//        self.schema = Schema(repeat each modelTypes)
//    }

    /// Initialize Lattice with model types and a migration block.
    ///
    /// The migration block is called when schema changes are detected, allowing you
    /// to transform data during migration.
    ///
    /// Example:
    /// ```swift
    /// // Migrate separate lat/lon fields to CLLocationCoordinate2D
    /// let lattice = try Lattice(Place.self, configuration: config) { migration in
    ///     if migration.hasChanges(for: "Place") {
    ///         migration.enumerateObjects(table: "Place") { rowId, oldRow in
    ///             if let lat = oldRow["latitude"]?.doubleValue,
    ///                let lon = oldRow["longitude"]?.doubleValue {
    ///                 migration.setValue(table: "Place", rowId: rowId,
    ///                                   column: "location_minLat", value: lat)
    ///                 migration.setValue(table: "Place", rowId: rowId,
    ///                                   column: "location_maxLat", value: lat)
    ///                 migration.setValue(table: "Place", rowId: rowId,
    ///                                   column: "location_minLon", value: lon)
    ///                 migration.setValue(table: "Place", rowId: rowId,
    ///                                   column: "location_maxLon", value: lon)
    ///             }
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - modelTypes: The model types to register
    ///   - configuration: Database configuration
    ///   - migration: Block called when schema changes are detected
    public init<each M: Model>(isolation: isolated (any Actor)? = #isolation,
                               _ modelTypes: repeat (each M).Type,
                               configuration: Configuration = defaultConfiguration,
                               migration: [Int: Migration]? = nil) throws {
        var types = [any Model.Type]()
        for type in repeat each modelTypes {
            types.append(type)
        }
        try self.init(for: types, configuration: configuration, migration: migration)
        self.schema = Schema(repeat each modelTypes)
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
    public func add<T: Model>(_ object: borrowing T) {
        guard object.lattice == nil else {
            fatalError()
        }
        var copy = object._dynamicObject._ref // Break exclusive access
        cxxLattice.add(&copy.shared().pointee)
        object._dynamicObject._ref = copy
        // Register for cross-instance observation now that the object has a primaryKey
        object._registerIfNeeded()
    }
    
    public func add<S: Sequence>(contentsOf newElements: S) where S.Element: Model {
        // Bulk insert via C++
        var cxxObjects = lattice.DynamicObjectRefPtrVector()
        for element in newElements {
            lattice.push_dynamic_object_ref(&cxxObjects, element._dynamicObject._ref)
        }

        cxxLattice.add_bulk(&cxxObjects)
    }

    func beginObserving<T: Model>(_ object: T) {
    }
    func finishObserving<T: Model>(_ object: T) {
    }
    
    public func object<T>(_ type: T.Type = T.self, primaryKey: Int64) -> T? where T: Model {
        let object = cxxLattice.object(primaryKey, std.string(type.entityName))
        if object.hasValue {
            return T(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(object.pointee).make_shared()))
        }
        return nil
    }
    
    internal func object<T>(_ type: T.Type = T.self, globalKey: UUID) -> T? where T: Model {
        let globalIdString = globalKey.uuidString.lowercased()
        if let object = cxxLattice.object_by_global_id(std.string(globalIdString), std.string(type.entityName)).value {
            return T(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(object.pointee).make_shared()))
        }
        return nil
    }
    
    public func objects<T>(_ type: T.Type = T.self) -> TableResults<T> where T: Model {
        TableResults(self)
    }
    
    // MARK: Delete
    @discardableResult public func delete<T: Model>(_ object: consuming T) -> Bool {
//        defer { object._dynamicObject = T.defaultCxxLatticeObject }
//        var dynamicObject = consume object._dynamicObject
        return cxxLattice.remove(object._dynamicObject._ref)
        
    }
    
    @discardableResult public func delete<T: Model>(_ modelType: T.Type = T.self,
                                                    where: ((Query<T>) -> Query<Bool>)? = nil) -> Bool {
        let whereClause: lattice.OptionalString = `where`.map { lattice.string_to_optional(std.string($0(Query<T>()).predicate)) } ?? .init()
        return cxxLattice.delete_where(std.string(T.entityName), whereClause)
    }
    
    public func deleteHistory() {
        delete(AuditLog.self)
    }

    // MARK: Maintenance

    /// Compacts the audit log by replacing all history with INSERT snapshots
    /// of the current state. Reduces sync payload size while preserving the
    /// ability to sync current data.
    /// - Returns: Number of snapshot entries created.
    @discardableResult
    public func compactHistory() -> Int64 {
        cxxLattice.compact_audit_log()
    }

    /// Flushes WAL contents to the main database file and truncates the WAL.
    /// Called automatically on deinitialization but can be invoked explicitly
    /// to ensure durability or reduce WAL file size.
    public func checkpoint() {
        cxxLattice.checkpoint()
    }

    /// Rebuilds the database file, reclaiming disk space from deleted rows
    /// and eliminating fragmentation. Temporarily closes the read connection
    /// to obtain exclusive access.
    ///
    /// - Important: Requires exclusive database access. Will throw if another
    ///   process has the database open. Do not call during active queries.
    public func vacuum() {
        cxxLattice.vacuum()
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

    public var changeStream: AsyncStream<[any SendableReference<AuditLog>]> {
        AsyncStream<[any SendableReference<AuditLog>]> { [cxxLattice, modelTypes, configuration] stream in
            let tableName = std.string(AuditLog.entityName)

            let context = TableObserverContext { operation, rowId, globalRowId in
                autoreleasepool {
                    let lattice = try! Lattice(for: modelTypes, configuration: configuration)
                    if let auditLog = lattice.object(AuditLog.self, primaryKey: rowId)?.sendableReference as? any SendableReference<AuditLog> {
//                        let refs: [any SendableReference<AuditLog>] = [auditLog]
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

    func observe<T: Model>(_ modelType: T.Type, where: Query<Bool>? = nil,
                           block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        let tableName = std.string(T.entityName)

        let context = TableObserverContext { [self] operation, rowId, globalRowId in
            switch operation {
            case "INSERT":
                if let `where` {
                    let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                    let auditResults = TableResults<AuditLog>(self).where({
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
                    let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                    let auditResults = TableResults<AuditLog>(self).where({
                        $0.rowId == rowId && convertedQuery && $0.operation == .delete
                    })
                    if let _ = auditResults.first {
                        block(.delete(rowId))
                    }
                } else {
                    block(.delete(rowId))
                }
            case "UPDATE":
                if let `where` {
                    let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                    let auditResults = TableResults<AuditLog>(self).where({
                        $0.rowId == rowId && convertedQuery && $0.operation == .update
                    })
                    if let _ = auditResults.first {
                        block(.update(rowId))
                    }
                } else {
                    if self.object(modelType, primaryKey: rowId) != nil {
                        block(.update(rowId))
                    }
                }
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
    
    public func observe<T: Model>(_ modelType: T.Type, where: LatticePredicate<T>? = nil,
                                  block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        observe(modelType, where: `where`?(Query()), block: block)
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
    
    public mutating func attach(lattice: Lattice) {
        cxxLattice.attach(lattice.cxxLattice)
        schema = schema?.merge(typeErased: lattice.schema!)
    }
    
    public func attaching(lattice: Lattice) -> Lattice {
        let newCxxLattice = LatticeCxx.swift_lattice_ref.create(swiftConfig: configuration.cxxConfiguration(),
                                                                schemas: modelTypes.cxxSchema)!
        newCxxLattice.get().attach(lattice.cxxLattice)
        var newLattice = Lattice.init(ref: newCxxLattice)
        newLattice.schema = schema?.merge(typeErased: lattice.schema!)
        return newLattice
    }
}

typealias LatticeCxx = lattice

protocol _Schema {
    func merge(typeErased: _Schema) -> _Schema
    func merge<each V: Model>(other: Schema<repeat each V>) -> _Schema
    func _generateVirtualResults<T>(_ type: T.Type, on lattice: Lattice) -> VirtualResults<T>
}

package struct Schema<each M: Model>: _Schema {
    let modelTypes: (repeat (each M).Type)
    package init(_ modelTypes: repeat (each M).Type) {
        self.modelTypes = (repeat each modelTypes)
    }
    
    func addType<T: Model>(_ type: T.Type) -> _Schema {
        Schema<repeat each M, T>(repeat each self.modelTypes, type)
    }
    
    func merge(typeErased: any _Schema) -> any _Schema {
        typeErased.merge(other: self)
    }
    
    func merge<each V: Model>(other: Schema<repeat each V>) -> _Schema {
        Schema<repeat (each M), repeat each V>.init(repeat each self.modelTypes, repeat each other.modelTypes)
    }
    
    package func _generateVirtualResults<T>(_ type: T.Type, on lattice: Lattice) -> any VirtualResults<T> {
//        build(lattice: lattice, proto: type)
//        virtualSchemaBuilder(for: type, on: lattice) {
            var virtualResults: (any VirtualResults<T>)!
            for modelType in repeat each modelTypes {
                if virtualResults == nil {
                    if modelType.init(isolation: #isolation) is T {
                        virtualResults = _VirtualResults.init(types: modelType, proto: type, lattice: lattice)
                    }
                } else {
                    if modelType.init(isolation: #isolation) is T {
                        virtualResults = virtualResults._addType(modelType)
                    }
                }
            }
        return virtualResults!
//        }
//        _VirtualResults<(), T>.self
//        var virtualResults: (any VirtualResults).Type!
//        for modelType in repeat each modelTypes {
//            if virtualResults == nil {
//                virtualResults = add(modelType, with: type)
//            } else {
//                add(modelType, to: virtualResults, with: type)
//            }
//        }
    }
}

extension Array where Element == any Model.Type {
    var cxxSchema: lattice.SchemaVector {
        // Build SchemaVector for C++
        var cxxSchemas = lattice.SchemaVector()
        for modelType in self {
            // Convert Swift constraints to C++ constraints
            var cxxConstraints = lattice.ConstraintVector()
            for constraint in modelType.constraints {
                var cols = lattice.StringVector()
                for col in constraint.columns {
                    cols.push_back(std.string(col))
                }
                let cxxConstraint = lattice.swift_constraint(cols, constraint.allowsUpsert)
                cxxConstraints.push_back(cxxConstraint)
            }

            let entry = lattice.swift_schema_entry(
                std.string(modelType.entityName),
                modelType.cxxPropertyDescriptor(),
                cxxConstraints
            )
            cxxSchemas.push_back(entry)
        }
        return cxxSchemas
    }
}
