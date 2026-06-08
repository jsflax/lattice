#if canImport(os)
import os
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

#if canImport(Combine)
@preconcurrency import Combine
#endif

public struct _UncheckedSendable<T>: @unchecked Sendable {
    public let value: T
    
    public init(_ value: T) {
        self.value = value
    }
}
extension Logger {
    static let db = Logger(subsystem: "lattice.io", category: "db")
    static let sync = Logger(subsystem: "lattice.io", category: "sync")
}


public enum LatticeError: Error {
    case missingLatticeContext
    case transactionError(String)
    case syncReceiveFailed(String)
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

// NOTE: a `LatticeExecutor: SerialExecutor` used to live here. It was unused
// (zero references) and `SerialExecutor`/`ExecutorJob` are iOS 17+, so it was
// removed to support the iOS 15 deployment floor.

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
    #if canImport(os)
    private static let synchronizersLock = OSAllocatedUnfairLock<Void>()
    #else
    private static let synchronizersLock = UnfairLock(initialState: ())
    #endif
    
    public struct SyncConfiguration {
        
    }
    
    /// URLSession-backed sync transport that bridges to C++ generic_sync_transport
    internal final class WebsocketClient: @unchecked Sendable {
        private var webSocketTask: URLSessionWebSocketTask?
        private var currentState: lattice.transport_state = .closed
        private let session: URLSession
        private let delegateHandler: WebSocketDelegateHandler

        // Pointers to trigger C++ callbacks - set after generic_websocket_client is created
        private var cxxClientPtr: UnsafeMutableRawPointer?

        final class WebSocketDelegateHandler: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
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

        /// Creates the C++ generic_sync_transport that wraps this Swift client.
        /// Returns a raw pointer that C++ will take ownership of via unique_ptr.
        func createCxxClient() -> UnsafeMutableRawPointer {
            let clientPtr = Unmanaged.passRetained(self).toOpaque()

            let cxxClient = lattice.generic_sync_transport(
                clientPtr,
                // connect_fn
                { ptr, urlPtr, headersPtr in
                    guard let ptr = ptr, let urlPtr = urlPtr, let headersPtr = headersPtr else { return }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    let url = String(urlPtr.assumingMemoryBound(to: std.string.self).pointee)
                    let headers = headersPtr.assumingMemoryBound(to: lattice.HeadersMap.self).pointee
                    client.performConnect(url: url, headers: headers)
                },
                // disconnect_fn
                { ptr in
                    guard let ptr = ptr else { return }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    client.performDisconnect()
                },
                // state_fn
                { ptr in
                    guard let ptr = ptr else { return .closed }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    return client.currentState
                },
                // send_fn
                { ptr, messagePtr in
                    guard let ptr = ptr, let messagePtr = messagePtr else { return }
                    let client = Unmanaged<WebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                    let message = messagePtr.assumingMemoryBound(to: lattice.transport_message.self).pointee
                    client.performSend(message)
                }
            )

            // Allocate and store the C++ client so we can call trigger methods
            let cxxPtr = UnsafeMutablePointer<lattice.generic_sync_transport>.allocate(capacity: 1)
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
            webSocketTask?.maximumMessageSize = 128 * 1024 * 1024  // 128 MB (default is 1 MB)
            webSocketTask?.resume()
            // Try receiving immediately AND after open
//            startReceiving()
        }

        private func performDisconnect() {
            currentState = .closing
            // Nil out cxxClientPtr BEFORE the async cancel so that any delegate
            // callbacks (didCloseWith, didCompleteWithError) that fire after the
            // C++ synchronizer is destroyed become no-ops instead of use-after-free.
            cxxClientPtr = nil
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }

        private func performSend(_ message: lattice.transport_message) {
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
                    var cxxMessage = lattice.transport_message()
                    switch message {
                    case .string(let text):
                        cxxMessage = lattice.transport_message.from_string(std.string(text))
                    case .data(let data):
                        var vec = lattice.ByteVector()
                        for byte in data {
                            vec.push_back(byte)
                        }
                        cxxMessage = lattice.transport_message.from_binary(vec)
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
            ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_open()
        }

        private func triggerMessage(_ message: lattice.transport_message) {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_message(message)
        }

        private func triggerError(_ error: String) {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_error(std.string(error))
        }

        private func triggerClose(code: Int, reason: String) {
            guard let ptr = cxxClientPtr else { return }
            ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_close(Int32(code), std.string(reason))
        }

        deinit {
            // Note: Don't deallocate cxxClientPtr - C++ owns it via unique_ptr
            // The Swift WebsocketClient is kept alive by passRetained() and should be
            // released when C++ destroys the websocket_client (not implemented yet)
        }
    }

    /// Registers the Swift network factory with C++ layer. Called once on first Lattice init.
    /// On Apple platforms, uses URLSession WebSocket. On Linux, uses NIO-based WebSocketKit.
    private nonisolated(unsafe) static var networkFactoryRegistered = false
    private static func registerNetworkFactoryIfNeeded() {
        guard !networkFactoryRegistered else { return }
        networkFactoryRegistered = true

        lattice.register_generic_network_factory(
            nil,  // no user_data needed
            nil,  // http_fn - not implemented yet
            // websocket_fn
            { _ in
                #if os(Linux)
                let client = NIOWebsocketClient()
                #else
                let client = WebsocketClient()
                #endif
                return client.createCxxClient().assumingMemoryBound(to: lattice.sync_transport.self)
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
            self.scheduler = lattice.generic_scheduler(isolationPtr, { work, ptr in
                guard let isolation = ptr?.assumingMemoryBound(to: (any Actor)?.self) else {
                    lattice.generic_scheduler.execute_work(work)
                    return
                }
                if let isolation = isolation.pointee {
                    Task {
                        await isolation.invoke { actor in
                            lattice.generic_scheduler.execute_work(work)
                        }
                    }
                } else {
                    lattice.generic_scheduler.execute_work(work)
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
    
    // MARK: - SyncFilter

    /// Controls which tables and rows are uploaded during sync.
    ///
    /// Semantics:
    /// - `nil` (default on Configuration) → sync everything (backwards compatible)
    /// - `SyncFilter()` (empty) → sync nothing
    /// - `SyncFilter` with entries → whitelist: only listed tables, with optional per-row SQL predicates
    ///
    /// The filter is **upload-only** — it controls what leaves the device.
    /// Downloads from the server are always accepted unfiltered.
    public struct SyncFilter: Sendable, Equatable, Hashable {
        /// tableName → SQL WHERE clause (nil = all rows in that table)
        internal var entries: [String: String?] = [:]

        public init() {}

        /// Include all rows of this model type in the sync set.
        public mutating func include<T: Model>(_ type: T.Type) {
            entries.updateValue(nil, forKey: T.entityName)
        }

        /// Include only rows matching the predicate.
        public mutating func include<T: Model>(_ type: T.Type, where predicate: @Sendable (Query<T>) -> Query<Bool>) {
            entries[T.entityName] = predicate(Query<T>()).predicate
        }

        /// Remove this model type from the sync set.
        public mutating func exclude<T: Model>(_ type: T.Type) {
            entries.removeValue(forKey: T.entityName)
        }
    }

    /// IPC sync target. Each target creates a Unix domain socket channel for
    /// cross-process sync. The first process to open a channel becomes the
    /// server; subsequent processes connect as clients.
    public struct IPCSyncTarget: Sendable, Equatable, Hashable {
        /// Shared channel name. Both sides use the same name → same socket path.
        public var channel: String

        /// Optional upload filter for this IPC channel.
        public var syncFilter: SyncFilter?

        /// Optional explicit socket path. When set, bypasses the default
        /// platform-specific path resolution. Required when the two processes
        /// have different HOME directories (e.g. macOS app ↔ iOS simulator).
        public var socketPath: String?

        public init(channel: String, syncFilter: SyncFilter? = nil, socketPath: String? = nil) {
            self.channel = channel
            self.syncFilter = syncFilter
            self.socketPath = socketPath
        }
    }

    public struct Configuration: Sendable, Equatable, Hashable {
        public var isStoredInMemoryOnly: Bool = false
        public var fileURL: URL
        public var authorizationToken: String?
        public var wssEndpoint: URL?
        private var scheduler: Scheduler

        /// Schema migration definitions keyed by version number.
        /// Stored here so that `SendableReference.resolve(on:)` can reconstruct
        /// a `Lattice` with the correct target schema version.
        public var migration: [Int: Migration]?

        /// Read-only mode. When true:
        /// - Database is opened with SQLITE_OPEN_READONLY
        /// - No WAL mode (uses existing journal mode)
        /// - No table creation or schema changes
        /// - No sync, no change hooks
        /// Use this for bundled template databases in app resources.
        public var isReadOnly: Bool = false

        /// Filter controlling which tables/rows are uploaded during sync.
        /// `nil` (default) syncs everything. Empty filter syncs nothing.
        public var syncFilter: SyncFilter?

        /// IPC sync targets for cross-process database synchronization.
        public var ipcTargets: [IPCSyncTarget]?

        // MARK: Equatable / Hashable (migration excluded — closures aren't comparable)
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isStoredInMemoryOnly == rhs.isStoredInMemoryOnly &&
            lhs.fileURL == rhs.fileURL &&
            lhs.authorizationToken == rhs.authorizationToken &&
            lhs.wssEndpoint == rhs.wssEndpoint &&
            lhs.scheduler == rhs.scheduler &&
            lhs.isReadOnly == rhs.isReadOnly &&
            lhs.syncFilter == rhs.syncFilter &&
            lhs.ipcTargets == rhs.ipcTargets
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(isStoredInMemoryOnly)
            hasher.combine(fileURL)
            hasher.combine(authorizationToken)
            hasher.combine(wssEndpoint)
            hasher.combine(scheduler)
            hasher.combine(isReadOnly)
            hasher.combine(syncFilter)
            hasher.combine(ipcTargets)
        }

        public init(isStoredInMemoryOnly: Bool = false, fileURL: URL? = nil,
                    authorizationToken: String? = nil, wssEndpoint: URL? = nil,
                    isReadOnly: Bool = false, migration: [Int: Migration]? = nil,
                    syncFilter: SyncFilter? = nil) {
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
            self.migration = migration
            self.syncFilter = syncFilter
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
            if let syncFilter {
                var filterEntries = lattice.SyncFilterVector()
                for (tableName, whereClause) in syncFilter.entries {
                    var entry = lattice.sync_filter_entry()
                    entry.table_name = std.string(tableName)
                    if let whereClause {
                        entry.where_clause = lattice.string_to_optional(std.string(whereClause))
                    }
                    filterEntries.push_back(entry)
                }
                config.set_sync_filter(filterEntries)
            }
            if let ipcTargets, !ipcTargets.isEmpty {
                var targets = lattice.IPCTargetVector()
                for target in ipcTargets {
                    var ipcTarget = lattice.configuration.ipc_target()
                    ipcTarget.channel = std.string(target.channel)
                    if let socketPath = target.socketPath {
                        ipcTarget.socket_path = lattice.string_to_optional(std.string(socketPath))
                    }
                    if let filter = target.syncFilter {
                        var filterEntries = lattice.SyncFilterVector()
                        for (tableName, whereClause) in filter.entries {
                            var entry = lattice.sync_filter_entry()
                            entry.table_name = std.string(tableName)
                            if let whereClause {
                                entry.where_clause = lattice.string_to_optional(std.string(whereClause))
                            }
                            filterEntries.push_back(entry)
                        }
                        ipcTarget.sync_filter = lattice.sync_filter_to_optional(filterEntries)
                    }
                    targets.push_back(ipcTarget)
                }
                config.set_ipc_targets(targets)
            }
            // Propagate target schema version from migrations so that any new
            // connection (e.g., from attaching()) knows the DB may be at a
            // higher schema version than the default of 1.
            if let migration, let maxVersion = migration.keys.max() {
                config.target_schema_version = Int32(maxVersion)
            }
            return config
        }
    }
    
    
    
    public nonisolated(unsafe) static var defaultConfiguration: Configuration = .init()
    public let configuration: Configuration
    public let modelTypes: [any Model.Type]
//    private var synchronizer: Synchronizer?
    
    private var isSyncDisabled = false
    internal var logger = Logger.db

    /// Wait for background IVF vector index training to complete.
    /// Training starts automatically on open. Queries work during training
    /// (brute-force fallback), so this is only needed for benchmarks/tests.
    public func waitForVectorIndexTraining() async {
        await Task.detached { [backend] in
            backend.waitForVec0Training()
        }.value
    }

    /// Train IVF vector indexes synchronously. Call after bulk inserts to
    /// activate IVF search. Opens a separate DB connection for training.
    public func trainVectorIndexes() {
        backend.trainUntrainedVec0Tables()
    }

    /// Background task that trains IVF indexes on open. Await this in tests
    /// to ensure IVF is active before measuring performance.
    public internal(set) var vectorIndexTrainingTask: Task<Void, Never>?

    /// The boxed db backend (the single stored db handle). On iOS 16.4+/macOS the
    /// C++-interop `CxxBackend`; iOS 15 will use the pure-C `CBackend` (Phase 3).
    /// All neutral ORM operations route through this; the residual still-C++-only
    /// paths (table/object observers, sync callbacks, attach) reach the underlying
    /// foreign-reference type through the gated `cxxLattice` accessor below.
    let backend: any LatticeBackend

    /// The underlying C++ `swift_lattice`, for the still-C++-only call sites that
    /// have no neutral backend surface yet. Gated 16.4 (the future C backend
    /// returns nil from `asCxxLatticeRef`); on iOS 15 these call sites must route
    /// through CBackend instead (Phase 3 residual gating).
    @available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
    var cxxLattice: lattice.swift_lattice {
        backend.asCxxLatticeRef!.get()
    }

    /// The underlying C++ `swift_lattice_ref`. Same gating/caveat as `cxxLattice`.
    @available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
    var cxxLatticeRef: lattice.swift_lattice_ref {
        backend.asCxxLatticeRef!
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
    
    #if canImport(os)
    private static let cacheLock = OSAllocatedUnfairLock<Void>()
    #else
    private static let cacheLock = UnfairLock(initialState: ())
    #endif

    /// Cache key that uses the underlying impl_ pointer hash for stable identity
    private struct CacheKey: Hashable {
        let implHash: Int64

        init(_ ref: lattice.swift_lattice_ref) {
            self.implHash = ref.hash_value()
        }

        init(_ backend: any LatticeBackend) {
            self.implHash = backend.identityHash
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(implHash)
        }

        static func == (lhs: CacheKey, rhs: CacheKey) -> Bool {
            lhs.implHash == rhs.implHash
        }
    }

    private nonisolated(unsafe) static var cache: [CacheKey: Lattice] = [:]

    /// Context passed through void* for the row migration C function pointer callback.
    private final class _MigrationCtx: @unchecked Sendable {
        let migration: [Int: Migration]
        let targetVersion: Int
        init(_ m: [Int: Migration], _ v: Int) { migration = m; targetVersion = v }
    }

    internal init(isolation: isolated (any Actor)? = #isolation,
                  for schema: [any Model.Type],
                  configuration: Configuration = defaultConfiguration,
                  isSynchronizing: Bool) throws {
        // Register Swift network factory on first use
        Self.registerNetworkFactoryIfNeeded()

        self.isolation = isolation
        self.configuration = configuration

        // Discover all linked types from the provided schema
        let allTypes = Self.discoverAllTypes(from: schema)
        self.modelTypes = allTypes

        // Record the registered model types for polymorphic/virtual queries.
        // Set here (the designated init) so BOTH the array `init(for:)` and the
        // variadic `init<each M>` paths populate it — previously only the
        // variadic path did, leaving virtual queries broken via `init(for:)`.
        self.schema = SchemaCompat(modelTypes: schema)

        // Register all model types in the global registry for VirtualList type resolution
        for type in allTypes {
            ModelTypeRegistry.shared.register(type)
        }

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

        var error = lattice.cxx_error()
        let createdRef: lattice.swift_lattice_ref

        if let migration = configuration.migration {
            // Find the target version from migration dict (highest key)
            let targetVersion = migration.keys.max() ?? 1

            // Create swift_configuration with row migration callback
            var swiftConfig =  configuration.cxxConfiguration()//lattice.swift_configuration(configuration.cxxConfiguration())
            swiftConfig.target_schema_version = Int32(targetVersion)

            // Pre-populate migration schema pairs (no callback needed)
            for (version, migrationDef) in migration {
                for (tableName, schemas) in migrationDef.schemas {
                    swiftConfig.addMigrationSchema(version, std.string(tableName), schemas.from, schemas.to)
                }
            }

            // Set up the row migration callback using C function pointers
            // (same pattern as generic_scheduler — avoids block lifetime issues on Linux)
            let ctx = _MigrationCtx(migration, Int(targetVersion))
            let ctxRaw = Unmanaged.passRetained(ctx).toOpaque()

            swiftConfig.setRowMigrationCallback(ctxRaw, { tableName, rawCtx in
                guard let rawCtx, let tableName else { return }
                let migCtx = Unmanaged<_MigrationCtx>.fromOpaque(rawCtx).takeUnretainedValue()
                let entityName = String(cString: tableName)

                // Read old/new refs from thread-local storage (set by C++ before this callback)
                guard let oldRef = lattice.migrationGetOldRow(),
                      let newRef = lattice.migrationGetNewRow() else { return }

                if let currentMigration = migCtx.migration[migCtx.targetVersion] {
                    currentMigration._sendRow(entityName: entityName, oldRef, newRef)
                }
            }, { rawCtx in
                guard let rawCtx else { return }
                Unmanaged<_MigrationCtx>.fromOpaque(rawCtx).release()
            })

            createdRef = lattice.swift_lattice_ref.create(swiftConfig: swiftConfig,
                                                          schemas: cxxSchemas,
                                                          error: &error)
        } else {
            createdRef = lattice.swift_lattice_ref.create(swiftConfig: configuration.cxxConfiguration(), schemas: cxxSchemas, error: &error)
        }
        guard error.msg.empty() else {
            throw error
        }
        self.backend = CxxBackend(createdRef)
        let key = CacheKey(self.backend)
        let latticeInstance = self
        Self.cacheLock.withLockUnchecked { Self.cache[key] = latticeInstance }
    }

    // MARK: Public Inits
    public init(isolation: isolated (any Actor)? = #isolation,
                for schema: [any Model.Type],
                configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: schema, configuration: configuration, isSynchronizing: false)
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
    // Variadic (parameter-pack) convenience init — iOS 17+ (variadic generics).
    // For unbounded arity on iOS 17+. iOS 15 uses the fixed-arity overloads below
    // or `init(for: [Model.Type])`.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public init<each M: Model>(isolation: isolated (any Actor)? = #isolation,
                               _ modelTypes: repeat (each M).Type,
                               configuration: Configuration = defaultConfiguration) throws {
        var types = [any Model.Type]()
        for type in repeat each modelTypes {
            types.append(type)
        }
        try self.init(for: types, configuration: configuration)
        // schema is already set by the designated init (as a SchemaCompat).
    }

    // Fixed-arity convenience inits (no parameter packs) — available on all
    // deployment targets. They forward to `init(for:)`; for more types than
    // these cover, use `init(for: [Model.Type])`.
    public init<A: Model>(isolation: isolated (any Actor)? = #isolation, _ a: A.Type, configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [a], configuration: configuration)
    }
    public init<A: Model, B: Model>(isolation: isolated (any Actor)? = #isolation, _ a: A.Type, _ b: B.Type, configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [a, b], configuration: configuration)
    }
    public init<A: Model, B: Model, C: Model>(isolation: isolated (any Actor)? = #isolation, _ a: A.Type, _ b: B.Type, _ c: C.Type, configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [a, b, c], configuration: configuration)
    }
    public init<A: Model, B: Model, C: Model, D: Model>(isolation: isolated (any Actor)? = #isolation, _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [a, b, c, d], configuration: configuration)
    }
    public init<A: Model, B: Model, C: Model, D: Model, E: Model>(isolation: isolated (any Actor)? = #isolation, _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [a, b, c, d, e], configuration: configuration)
    }
    public init<A: Model, B: Model, C: Model, D: Model, E: Model, F: Model>(isolation: isolated (any Actor)? = #isolation, _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type, configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [a, b, c, d, e, f], configuration: configuration)
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

        // Explicitly close all SQLite connections for this path before unlinking
        // files. The C++ close() shuts down the read/write connections, cross-
        // process notifier, and synchronizer. Without this, SQLite warns
        // "vnode unlinked while in use" because the connection still has the
        // file mmap'd.
        let filePath = fileURL.path(percentEncoded: false)
        cacheLock.withLockUnchecked {
            for (key, value) in cache where value.configuration.fileURL.path(percentEncoded: false) == filePath {
                value.backend.close()
                cache.removeValue(forKey: key)
            }
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
        do { try backend.add(object._dynamicObject._ref) } catch { fatalError("\(error)") }
        // Register for cross-instance observation now that the object has a primaryKey
        object._registerIfNeeded()
    }

    public func add<T: Model>(_ object: borrowing T, preservingGlobalId globalId: UUID) {
        guard object.lattice == nil else {
            fatalError()
        }
        backend.addPreservingGlobalId(object._dynamicObject._ref, globalId: globalId)
        object._registerIfNeeded()
    }
    
    public func add<S: Sequence>(contentsOf newElements: S) where S.Element: Model {
        backend.addBulk(newElements.map { $0._dynamicObject._ref })
    }

    // MARK: Add/Delete for VirtualModel (existential)

    public func add(_ object: any VirtualModel) {
        guard let model = object as? any Model else {
            fatalError("VirtualModel type must also conform to Model")
        }
        guard model.lattice == nil else { fatalError() }
        try? backend.add(model._dynamicObject._ref)
        model._registerIfNeeded()
    }

    @discardableResult public func delete(_ object: any VirtualModel) -> Bool {
        guard let model = object as? any Model else {
            fatalError("VirtualModel type must also conform to Model")
        }
        return backend.remove(model._dynamicObject._ref)
    }

    func beginObserving<T: Model>(_ object: T) {
    }
    func finishObserving<T: Model>(_ object: T) {
    }
    
    public func object<T>(_ type: T.Type = T.self, primaryKey: Int64) -> T? where T: Model {
        return backend.object(primaryKey: primaryKey, table: type.entityName).map { T(dynamicObject: $0) }
    }
    
    public func object<T>(_ type: T.Type = T.self, globalId: UUID) -> T? where T: Model {
        return backend.objectByGlobalId(globalId.uuidString.lowercased(), table: type.entityName).map { T(dynamicObject: $0) }
    }
    
    public func objects<T>(_ type: T.Type = T.self) -> TableResults<T> where T: Model {
        TableResults(self)
    }
    
    // MARK: Delete
    @discardableResult public func delete<T: Model>(_ object: consuming T) -> Bool {
//        defer { object._dynamicObject = T.defaultCxxLatticeObject }
//        var dynamicObject = consume object._dynamicObject
        return backend.remove(object._dynamicObject._ref)
        
    }
    
    @discardableResult public func delete<T: Model>(_ modelType: T.Type = T.self,
                                                    where: ((Query<T>) -> Query<Bool>)? = nil) -> Bool {
        let whereClause: String? = `where`.map { $0(Query<T>()).predicate }
        return backend.deleteWhere(table: T.entityName, where: whereClause)
    }
    
    public func deleteHistory() {
        delete(AuditLog.self)
    }

    // MARK: Maintenance

    /// Slot-aware compaction: deletes only entries all synchronizers have confirmed.
    /// Safe during active sync. Returns entries deleted, or -1 if no slots exist.
    /// - Parameter staleThresholdSeconds: If > 0, evict slots inactive for this long.
    @discardableResult
    public func compactHistory(staleThresholdSeconds: Int64 = 0) -> Int64 {
        backend.safeCompactAuditLog(staleThresholdSeconds: staleThresholdSeconds)
    }

    /// Backdate all replication slots' last_active_at by the given number of seconds.
    /// Test-only: enables deterministic stale-slot eviction without wall-clock sleeps.
    public func backdateReplicationSlots(seconds: Int64) {
        backend.backdateReplicationSlots(seconds: seconds)
    }

    /// Nuclear compaction: deletes ALL history, regenerates snapshots, resets slots.
    /// Active synchronizers will re-sync all data.
    /// - Returns: Number of snapshot entries created.
    @discardableResult
    public func forceCompactHistory() -> Int64 {
        backend.forceCompactAuditLog()
    }

    /// Flushes WAL contents to the main database file and truncates the WAL.
    /// Called automatically on deinitialization but can be invoked explicitly
    /// to ensure durability or reduce WAL file size.
    public func checkpoint() {
        backend.checkpoint()
    }

    /// Drop and rebuild the vec0 index, purging orphan entries that bloat chunk storage.
    @discardableResult
    public func _vacuumVec0<T: Model, V>(_ model: T, for keyPath: KeyPath<T, V>) -> Int64 {
        let tableName = T.entityName
        let t = T.init(isolation: #isolation)
        _ = t[keyPath: keyPath]
        let column = t._lastKeyPathUsed
        return backend.vacuumVec0(table: tableName, column: column ?? "")
    }

    /// Rebuilds the database file, reclaiming disk space from deleted rows
    /// and eliminating fragmentation. Temporarily closes the read connection
    /// to obtain exclusive access.
    ///
    /// - Important: Requires exclusive database access. Will throw if another
    ///   process has the database open. Do not call during active queries.
    public func vacuum() {
        backend.vacuum()
    }

    /// Whether the sync WebSocket connection is currently active.
    public var isSyncConnected: Bool {
        backend.isSyncConnected()
    }

    /// Explicitly close all database connections and tear down the synchronizer.
    /// If a sibling instance exists for the same database, it will inherit sync responsibility.
    public func close() {
        backend.close()
    }

    // MARK: Sync Progress

    /// Aggregated sync progress across all synchronizers (WSS + IPC).
    public struct SyncProgress: Sendable {
        public let pendingUpload: Int
        public let totalUpload: Int
        public let acked: Int
        public let received: Int
        public var uploadFraction: Double { totalUpload > 0 ? Double(acked) / Double(totalUpload) : 1.0 }
        public var isUploading: Bool { pendingUpload > 0 }

        package init(pendingUpload: Int, totalUpload: Int, acked: Int, received: Int) {
            self.pendingUpload = pendingUpload
            self.totalUpload = totalUpload
            self.acked = acked
            self.received = received
        }
    }

    /// Register a callback for sync progress updates.
    /// The callback fires on the synchronizer's background thread — callers must
    /// dispatch to the appropriate actor/queue.
    ///
    /// Transparently works cross-process: if this process holds the WSS sync lock
    /// (is_sync_agent), the callback is registered on the in-process synchronizer.
    /// Otherwise, it observes AuditLog changes via Darwin notifications and derives
    /// progress from the count of unsynchronized entries.
    public func onSyncProgress(_ handler: @escaping @Sendable (SyncProgress) -> Void) {
        if backend.isSyncAgent() {
            // In-process path: register callback on synchronizer atomics
            let context = SyncProgressContext(handler)
            let contextPtr = Unmanaged.passRetained(context).toOpaque()
            cxxLattice.set_on_sync_progress(
                contextPtr,
                { ctx, pending, total, acked, received in
                    guard let ctx else { return }
                    let context = Unmanaged<SyncProgressContext>.fromOpaque(ctx).takeUnretainedValue()
                    context.callback(SyncProgress(
                        pendingUpload: Int(pending),
                        totalUpload: Int(total),
                        acked: Int(acked),
                        received: Int(received)
                    ))
                },
                { ctx in
                    guard let ctx else { return }
                    Unmanaged<SyncProgressContext>.fromOpaque(ctx).release()
                }
            )
        } else {
            // Cross-process path: observe AuditLog changes and derive progress
            // from the count of unsynchronized entries.
            _startPassiveSyncProgressObserver(handler)
        }
    }

    /// Register a callback for sync errors (connection failures, protocol errors, etc.).
    public func onSyncError(_ handler: @escaping @Sendable (String) -> Void) {
        let context = SyncErrorContext(handler)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        cxxLattice.set_on_sync_error(
            contextPtr,
            { ctx, errorPtr, len in
                guard let ctx, let errorPtr else { return }
                let error = String(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: errorPtr),
                    length: Int(len),
                    encoding: .utf8,
                    freeWhenDone: false
                ) ?? "unknown error"
                Unmanaged<SyncErrorContext>.fromOpaque(ctx).takeUnretainedValue().callback(error)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<SyncErrorContext>.fromOpaque(ctx).release()
            }
        )
    }

    /// Register a callback for sync connection state changes.
    public func onSyncStateChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        let context = SyncStateContext(handler)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        cxxLattice.set_on_sync_state_change(
            contextPtr,
            { ctx, connected in
                guard let ctx else { return }
                Unmanaged<SyncStateContext>.fromOpaque(ctx).takeUnretainedValue().callback(connected)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<SyncStateContext>.fromOpaque(ctx).release()
            }
        )
    }

    /// AsyncStream of sync progress updates. Yields on every progress change
    /// from the synchronizer's background thread.
    /// Termination: when the consumer cancels iteration, the callback is replaced
    /// with nil (clearing the C++ handler and releasing the context).
    ///
    /// Transparently works cross-process via AuditLog observation when
    /// this process is not the sync agent.
    public var syncProgressStream: AsyncStream<SyncProgress> {
        let cxx = cxxLattice
        let isSyncAgent = cxx.is_sync_agent()
        let modelTypes = self.modelTypes
        let configuration = self.configuration
        return AsyncStream { continuation in
            if isSyncAgent {
                // In-process path
                let context = SyncProgressContext { progress in
                    continuation.yield(progress)
                }
                let contextPtr = Unmanaged.passRetained(context).toOpaque()
                cxx.set_on_sync_progress(
                    contextPtr,
                    { ctx, pending, total, acked, received in
                        guard let ctx else { return }
                        let context = Unmanaged<SyncProgressContext>.fromOpaque(ctx).takeUnretainedValue()
                        context.callback(SyncProgress(
                            pendingUpload: Int(pending),
                            totalUpload: Int(total),
                            acked: Int(acked),
                            received: Int(received)
                        ))
                    },
                    { ctx in
                        guard let ctx else { return }
                        Unmanaged<SyncProgressContext>.fromOpaque(ctx).release()
                    }
                )

                continuation.onTermination = { _ in
                    cxx.set_on_sync_progress(nil, nil, nil)
                }
            } else {
                // Cross-process path: observe AuditLog changes via Darwin notifications
                let queryLattice = try! Lattice(for: modelTypes, configuration: configuration)
                let tableName = std.string(AuditLog.entityName)
                var previousPending = 0

                let context = TableObserverContext { _ in
                    // Batch contents are irrelevant — re-read pending count.
                    let pending = queryLattice.count(AuditLog.self, where: { $0.isSynchronized == false })
                    let diff = previousPending - pending
                    let acked = max(0, diff)
                    previousPending = pending
                    continuation.yield(SyncProgress(
                        pendingUpload: pending,
                        totalUpload: pending + acked,
                        acked: acked,
                        received: 0
                    ))
                }
                let contextPtr = Unmanaged.passRetained(context).toOpaque()

                let observerId = cxx.add_table_observer(
                    tableName,
                    contextPtr,
                    Lattice._tableObserverTrampoline,
                    Lattice._tableObserverDestroy
                )

                continuation.onTermination = { _ in
                    cxx.remove_table_observer(tableName, observerId)
                }
            }
        }
    }

    #if canImport(Combine)
    /// Combine publisher for sync progress updates.
    public var syncProgressPublisher: AnyPublisher<SyncProgress, Never> {
        let subject = PassthroughSubject<SyncProgress, Never>()
        onSyncProgress { progress in
            subject.send(progress)
        }
        return subject.eraseToAnyPublisher()
    }
    #endif

    // MARK: Sync Filter

    /// Update the sync filter at runtime, triggering reconciliation.
    /// Pass `nil` to clear the filter and sync everything.
    public func updateSyncFilter(_ filter: SyncFilter?) {
        if let filter {
            let params = filter.entries.map { SyncFilterParam(tableName: $0.key, whereClause: $0.value) }
            backend.updateSyncFilter(params)
        } else {
            backend.clearSyncFilter()
        }
    }

    public func count<T>(_ modelType: T.Type, where: ((Query<T>) -> Query<Bool>)? = nil) -> Int where T: Model {
        let whereClause: String? = `where`.map { $0(Query<T>()).predicate }
        return Int(backend.count(table: T.entityName, where: whereClause))
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

    /// One row's worth of metadata from a batched observer fire. Mirrors
    /// the C++ `change_event` tuple. Materialized once in the Swift
    /// trampoline from the parallel arrays the C bridge hands us.
    struct TableChange: Sendable {
        let operation: String
        let rowId: Int64
        let globalRowId: String
    }

    /// Context class to bridge Swift closures to C callbacks. The
    /// callback fires once per WAL flush with the batch of rows from
    /// that flush — a 3-row transaction is one fire of 3 entries, not
    /// 3 fires of 1. Single-row events are the degenerate case
    /// (count=1).
    private final class TableObserverContext {
        let callback: ([TableChange]) -> Void

        init(callback: @escaping ([TableChange]) -> Void) {
            self.callback = callback
        }
    }

    /// C trampoline shared by every Swift `add_table_observer`
    /// registration site. Unpacks the parallel C arrays once into
    /// `[TableChange]` and hands them to the Swift closure.
    ///
    /// Lifetime: the C++ bridge guarantees the array pointers are valid
    /// for the duration of this call (they reference vectors held on
    /// the dispatch stack); we copy the strings into Swift `String`s
    /// here so the resulting `TableChange` values are safe to capture
    /// by the consumer.
    private static let _tableObserverTrampoline:
        @convention(c) (UnsafeMutableRawPointer?,
                        UnsafePointer<UnsafePointer<CChar>?>?,
                        UnsafePointer<Int64>?,
                        UnsafePointer<UnsafePointer<CChar>?>?,
                        Int) -> Void = { contextPtr, ops, rowIds, gids, count in
        guard let contextPtr, count > 0,
              let ops, let rowIds, let gids else { return }
        let context = Unmanaged<TableObserverContext>.fromOpaque(contextPtr)
            .takeUnretainedValue()
        var changes: [TableChange] = []
        changes.reserveCapacity(count)
        for i in 0..<count {
            let op = ops[i].map { String(cString: $0) } ?? ""
            let gid = gids[i].map { String(cString: $0) } ?? ""
            changes.append(TableChange(operation: op, rowId: rowIds[i], globalRowId: gid))
        }
        context.callback(changes)
    }

    private static let _tableObserverDestroy:
        @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
        guard let ptr else { return }
        Unmanaged<TableObserverContext>.fromOpaque(ptr).release()
    }

    /// Context class for sync progress C callback bridge
    private final class SyncProgressContext: @unchecked Sendable {
        let callback: @Sendable (SyncProgress) -> Void

        init(_ callback: @escaping @Sendable (SyncProgress) -> Void) {
            self.callback = callback
        }
    }

    private final class SyncErrorContext: @unchecked Sendable {
        let callback: @Sendable (String) -> Void

        init(_ callback: @escaping @Sendable (String) -> Void) {
            self.callback = callback
        }
    }

    private final class SyncStateContext: @unchecked Sendable {
        let callback: @Sendable (Bool) -> Void

        init(_ callback: @escaping @Sendable (Bool) -> Void) {
            self.callback = callback
        }
    }

    /// Start a passive sync progress observer for cross-process use.
    /// Called when this process is NOT the sync agent. Uses the dedicated
    /// xproc idle hint callback (fires on the xproc background thread)
    /// instead of an AuditLog table observer, avoiding scheduler dispatch
    /// to MainActor and the thread pile-ups that caused.
    private func _startPassiveSyncProgressObserver(_ handler: @escaping @Sendable (SyncProgress) -> Void) {
        // nonisolated(unsafe) because the callback fires on the xproc background
        // thread, not on this actor. The closure only captures value types after
        // the first call (previousPending is mutated but only from the serial
        // xproc callback — no concurrent access).
        nonisolated(unsafe) var previousPending = 0
        let cxx = cxxLattice

        class XprocIdleContext {
            let callback: () -> Void
            init(_ callback: @escaping () -> Void) { self.callback = callback }
        }

        let context = XprocIdleContext { [cxx] in
            let pending = Int(cxx.pending_sync_entry_count())
            let diff = previousPending - pending
            let acked = max(0, diff)
            previousPending = pending
            handler(SyncProgress(
                pendingUpload: pending,
                totalUpload: pending + acked,
                acked: acked,
                received: 0
            ))
        }
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        cxxLattice.set_on_xproc_idle(
            contextPtr,
            { ctx in
                guard let ctx else { return }
                Unmanaged<XprocIdleContext>.fromOpaque(ctx).takeUnretainedValue().callback()
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<XprocIdleContext>.fromOpaque(ctx).release()
            }
        )
    }

    public func observe(_ block: @escaping ([AuditLog]) -> ()) -> AnyCancellable {
        let tableName = std.string(AuditLog.entityName)

        // Create context that holds the Swift closure. The C++ side
        // delivers batches per WAL flush; this public Swift API has
        // historically fired the block ONCE PER ROW with a one-element
        // array (the `[AuditLog]` shape was a misnomer — always
        // length 1). Preserve that contract by fanning the batch out
        // here: walk each change in commit order, resolve its
        // AuditLog row, fire `block([auditLog])` per row. Consumers
        // (e.g. CrossProcessTests c556cd2) that count callback fires
        // see the same N firings the per-row implementation gave.
        let context = TableObserverContext { [self] changes in
            // TEMP DIAGNOSTIC: write batch shape to a known file so we
            // can compare CLI vs Xcode runs.
            if let h = FileHandle(forWritingAtPath: "/tmp/lattice-observe-trace.log") {
                let line = "\(Date().timeIntervalSince1970): observe([AuditLog]) batch.size=\(changes.count): \(changes.map { "(\($0.operation),\($0.rowId))" }.joined(separator: ","))\n"
                try? h.seekToEnd()
                h.write(Data(line.utf8))
                try? h.close()
            }
            for change in changes {
                if let auditLog = self.object(AuditLog.self, primaryKey: change.rowId) {
                    block([auditLog])
                }
            }
        }

        // Prevent context from being deallocated.
        // shared_ptr<void> in C++ ensures context lives through in-flight callbacks.
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        let observerId = cxxLattice.add_table_observer(
            tableName,
            contextPtr,
            Lattice._tableObserverTrampoline,
            Lattice._tableObserverDestroy
        )

        // Create cancellable token — context release handled by C++ shared_ptr destroy
        let token = TableObservationToken(cxxLattice: cxxLattice, tableName: tableName, observerId: observerId)

        return AnyCancellable {
            token.cancel()
        }
    }

    public var changeStream: AsyncStream<[any SendableReference<AuditLog>]> {
        AsyncStream<[any SendableReference<AuditLog>]> { [cxxLattice, modelTypes, configuration] stream in
            let tableName = std.string(AuditLog.entityName)

            let log = Logger.sync

            // Create a single Lattice for all queries instead of one per notification.
            // Creating a Lattice runs ensure_tables() which acquires the WAL write lock
            // (via INSERT OR IGNORE). Doing this on every notification blocks the
            // synchronizer's scheduler thread and risks SQLITE_BUSY under load.
            // Strip sync config — queryLattice only reads AuditLog entries by PK.
            // Keeping ipcTargets/wssEndpoint would join sync channels, receive a
            // catchup of existing data, and generate spurious AuditLog entries that
            // fire observers before the real change arrives.
            var queryConfig = configuration
            queryConfig.ipcTargets = nil
            queryConfig.wssEndpoint = nil
            queryConfig.authorizationToken = nil
            let queryLattice = try! Lattice(for: modelTypes, configuration: queryConfig)

            let context = TableObserverContext { changes in
                // One yield per WAL flush, with all refs from this
                // batch. Wire-relay consumers (e.g. ClaudeCodeIRC's
                // RoomSyncServer.broadcastEntries) ship one frame per
                // yield — so a cascade delete (parent + N link-table
                // DELETEs from one transaction) reaches the peer as
                // one frame and applies atomically. See the
                // notify_changes_batched comment in LatticeCore for
                // the full rationale.
                let refs: [any SendableReference<AuditLog>] = changes.compactMap { c in
                    guard let auditLog = queryLattice.object(AuditLog.self, primaryKey: c.rowId) else {
                        log.warning("changeStream: no AuditLog for pk=\(c.rowId)")
                        return nil
                    }
                    log.debug("changeStream entry: table=\(auditLog.tableName) modelOp=\(auditLog.operation) modelRowId=\(auditLog.rowId)")
                    return auditLog.sendableReference
                }
                if !refs.isEmpty {
                    log.debug("changeStream yield: count=\(refs.count)")
                    stream.yield(refs)
                }
            }

            let contextPtr = Unmanaged.passRetained(context).toOpaque()

            let observerId = cxxLattice.add_table_observer(
                tableName,
                contextPtr,
                Lattice._tableObserverTrampoline,
                Lattice._tableObserverDestroy
            )

            stream.onTermination = { _ in
                cxxLattice.remove_table_observer(tableName, observerId)
            }
        }
    }

    @dynamicCallable struct UnsafeBlock: @unchecked Sendable {
        let block: (CollectionChange) -> ()
        
        func dynamicallyCall(withArguments args: [CollectionChange]) {
            args.forEach(block)
        }
    }
    
    func observe<T: Model>(_ modelType: T.Type, where: Query<Bool>? = nil,
                           block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        let tableName = std.string(T.entityName)
        
        let block = UnsafeBlock(block: block)

        // Capture a sendable reference once, rather than resolving on every
        // notification. Avoids creating a new Lattice (and running
        // ensure_tables()) per callback, which races with teardown under load.
        let ref = self.sendableReference

        let context = TableObserverContext { changes in
            // Walk the batch and dispatch one CollectionChange per row,
            // preserving input commit order. Same per-row semantics as
            // the legacy callback — just delivered in one fire instead
            // of N.
            Task.detached {
                guard let self = ref.resolve() else {
                    return
                }

                let isolation = self.isolation
                @Sendable func dispatch(_ change: CollectionChange) async {
                    if let isolation {
                        await isolation.invoke { _ in block(change) }
                    } else {
                        block(change)
                    }
                }

                for entry in changes {
                    let operation = entry.operation
                    let rowId = entry.rowId
                    switch operation {
                    case "INSERT":
                        if let `where` {
                            let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                            let auditResults = TableResults<AuditLog>(self).where({
                                $0.rowId == rowId && convertedQuery && $0.operation == .insert
                            })
                            if let _ = auditResults.first {
                                await dispatch(.insert(rowId))
                            }
                        } else {
                            if self.object(modelType, primaryKey: rowId) != nil {
                                await dispatch(.insert(rowId))
                            }
                        }
                    case "DELETE":
                        if let `where` {
                            let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                            let auditResults = TableResults<AuditLog>(self).where({
                                $0.rowId == rowId && convertedQuery && $0.operation == .delete
                            })
                            if let _ = auditResults.first {
                                await dispatch(.delete(rowId))
                            }
                        } else {
                            await dispatch(.delete(rowId))
                        }
                    case "UPDATE":
                        if rowId == 0 {
                            // Broadcast: internal table (link/list) change resolved to parent UPDATE.
                            // No specific row — fire unconditionally for all table-level observers.
                            await dispatch(.update(rowId))
                        } else if let `where` {
                            let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                            let auditResults = TableResults<AuditLog>(self).where({
                                $0.rowId == rowId && convertedQuery && $0.operation == .update
                            })
                            if let _ = auditResults.first {
                                await dispatch(.update(rowId))
                            }
                        } else {
                            if self.object(modelType, primaryKey: rowId) != nil {
                                await dispatch(.update(rowId))
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }

        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        let observerId = cxxLattice.add_table_observer(
            tableName,
            contextPtr,
            Lattice._tableObserverTrampoline,
            Lattice._tableObserverDestroy
        )

        let token = TableObservationToken(cxxLattice: cxxLattice, tableName: tableName, observerId: observerId)

        return AnyCancellable {
            token.cancel()
        }
    }
    
    public func observe<T: Model>(_ modelType: T.Type, where: LatticePredicate<T>? = nil,
                                  block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        observe(modelType, where: `where`?(Query()), block: block)
    }

    /// Observe structural changes on a link table (insert/delete/update rows in the link table itself).
    /// Used by List.observe and VirtualList.observe for add/remove/reorder notifications.
    static func observeLinkTable(_ linkTableName: String, cxxLattice: lattice.swift_lattice, block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        let tableName = std.string(linkTableName)

        let context = TableObserverContext { changes in
            // Walk batch synchronously, fire block per row in commit order.
            for entry in changes {
                switch entry.operation {
                case "INSERT":
                    block(.insert(entry.rowId))
                case "DELETE":
                    block(.delete(entry.rowId))
                case "UPDATE":
                    block(.update(entry.rowId))
                default:
                    break
                }
            }
        }

        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        let observerId = cxxLattice.add_table_observer(
            tableName,
            contextPtr,
            Lattice._tableObserverTrampoline,
            Lattice._tableObserverDestroy
        )

        let token = TableObservationToken(cxxLattice: cxxLattice, tableName: tableName, observerId: observerId)
        return AnyCancellable {
            token.cancel()
        }
    }

    public func beginTransaction(isolation: isolated (any Actor)? = #isolation) {
        // Start the transaction.
        backend.beginTransaction()
    }
    
    public func commitTransaction(isolation: isolated (any Actor)? = #isolation) {
        backend.commit()
    }
    
    public func transaction<T>(isolation: isolated (any Actor)? = #isolation,
                               _ block: () throws -> T) rethrows -> T {
        beginTransaction()
        let value = try block()
        commitTransaction()
        return value
    }
    
    public mutating func attach(lattice: Lattice) {
        backend.attach(lattice.backend)
        schema = schema?.merge(typeErased: lattice.schema!)
    }
    
    public func attaching(lattice: Lattice) -> Lattice {
        // Build a query-only config: strip IPC/WSS to avoid duplicate socket
        // bind and unnecessary sync on a connection used only for UNION ALL reads.
        var queryConfig = configuration
        queryConfig.ipcTargets = nil
        queryConfig.wssEndpoint = nil
        queryConfig.authorizationToken = nil
        queryConfig.syncFilter = nil
        let cxxConfig = queryConfig.cxxConfiguration()
        let newCxxLattice = LatticeCxx.swift_lattice_ref.create(swiftConfig: cxxConfig,
                                                                schemas: modelTypes.cxxSchema)!
        newCxxLattice.get().attach(lattice.cxxLattice)
        var newLattice = Lattice.init(ref: newCxxLattice)
        newLattice.schema = schema?.merge(typeErased: lattice.schema!)
        return newLattice
    }
}

typealias LatticeCxx = lattice

// The schema carries the registered model types so polymorphic/virtual queries
// (`objects(SomeVirtualModel.self)`) can discover which concrete types conform.
// It exposes the type list as a plain array (`modelTypeList`) so it works the
// same with or without parameter packs; `merge` combines two type lists. The
// previous pack-based `merge<each V>` requirement was removed (it forced an
// iOS 17 floor on the whole protocol).
protocol _Schema {
    var modelTypeList: [any Model.Type] { get }
    func merge(typeErased: _Schema) -> _Schema
    func _generateVirtualResults<T>(_ type: T.Type, on lattice: Lattice) -> VirtualResults<T>
}

extension _Schema {
    fileprivate func _generateVirtualResults<T>(matching modelTypes: [any Model.Type], _ type: T.Type, on lattice: Lattice) -> any VirtualResults<T> {
        var matchingTypes: [any Model.Type] = []
        for modelType in modelTypes {
            if modelType.init(isolation: #isolation) is T {
                matchingTypes.append(modelType)
            }
        }
        return _buildVirtualResults(from: matchingTypes, proto: type, lattice: lattice)
    }
}

// Array-backed schema — no parameter packs, so it works on every deployment
// target. This is what `Lattice` stores; both the array and variadic inits build
// it. (The pack `Schema<each M>` below is gated and effectively vestigial now.)
struct SchemaCompat: _Schema {
    let modelTypes: [any Model.Type]
    var modelTypeList: [any Model.Type] { modelTypes }
    func merge(typeErased: any _Schema) -> any _Schema {
        SchemaCompat(modelTypes: modelTypes + typeErased.modelTypeList)
    }
    func _generateVirtualResults<T>(_ type: T.Type, on lattice: Lattice) -> any VirtualResults<T> {
        _generateVirtualResults(matching: modelTypes, type, on: lattice)
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
package struct Schema<each M: Model>: _Schema {
    let modelTypes: (repeat (each M).Type)
    package init(_ modelTypes: repeat (each M).Type) {
        self.modelTypes = (repeat each modelTypes)
    }

    var modelTypeList: [any Model.Type] {
        var a: [any Model.Type] = []
        for t in repeat (each M).self { a.append(t) }
        return a
    }

    func merge(typeErased: any _Schema) -> any _Schema {
        SchemaCompat(modelTypes: modelTypeList + typeErased.modelTypeList)
    }

    package func _generateVirtualResults<T>(_ type: T.Type, on lattice: Lattice) -> any VirtualResults<T> {
        _generateVirtualResults(matching: modelTypeList, type, on: lattice)
    }
}

// Build VirtualResults outside of variadic generic context to avoid IRGen crash on Linux.
// Uses existential opening on `any Model.Type` instead of pack element archetypes.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
private func _makeInitialVirtualResults<M: Model, T>(
    _ modelType: M.Type, proto: T.Type, lattice: Lattice
) -> any VirtualResults<T> {
    _VirtualResults<M, T>(types: modelType, proto: proto, lattice: lattice)
}

private func _buildVirtualResults<T>(
    from types: [any Model.Type], proto: T.Type, lattice: Lattice
) -> any VirtualResults<T> {
    guard let first = types.first else { fatalError("No types conform to \(T.self)") }
    // iOS 17+: build the parameter-pack `_VirtualResults` (grown one type at a
    // time). iOS 15: build the array-backed `_VirtualResultsCompat` directly.
    if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
        var result = _makeInitialVirtualResults(first, proto: proto, lattice: lattice)
        for remaining in types.dropFirst() {
            result = result._addType(remaining)
        }
        return result
    } else {
        return _VirtualResultsCompat<T>(modelTypes: types, proto: proto, lattice: lattice)
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

extension Lattice {
    public enum LogLevel : Int32 {
        case off = 0,
        error = 1,
        warn = 2,
        info = 3,
        debug = 4
    };

    public static func setLogLevel(_ level: LogLevel) {
        lattice.set_log_level(lattice.log_level(rawValue: level.rawValue) ?? .off)
    }

    /// Direct log output to a file instead of stderr.
    /// Pass nil to revert to stderr. Caller owns the FILE* lifetime.
    public static func setLogFile(_ file: UnsafeMutablePointer<FILE>?) {
        lattice.set_log_file(file)
    }
    
    /// Direct log output to a file instead of stderr.
    /// Pass nil to revert to stderr. Caller owns the FILE* lifetime.
    public static func setLogFile(_ fileURL: URL) {
        let path = fileURL.path(percentEncoded: false)
        guard let cFilePointer = fopen(path, "w") else {
            print("Failed to open log file: \(path)")
            return
        }
        lattice.set_log_file(cFilePointer)
        print("Log file path: \(path)")
    }
}

extension lattice.cxx_error: Error {
    
}
