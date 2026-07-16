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
    /// attach() failed — repeat attach of the same database is NOT an error
    /// (idempotent); this carries schema mismatches, alias collisions with a
    /// different path, and closed-handle attaches. Catchable: the C++
    /// exception no longer crosses the interop boundary.
    case attachFailed(String)
    case detachFailed(String)
    /// `add` was called with an object that is already managed by a Lattice.
    /// Re-adding is a state error, not a programmer invariant — callers can
    /// race a sync insert or double-fire a save path — so it throws instead
    /// of trapping. Catch and treat as "already persisted".
    case alreadyManaged
    /// The backend rejected an insert (constraint violation, closed handle,
    /// I/O failure). Carries the underlying database message.
    case addFailed(String)
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
// The db is reached exclusively through swift_lattice_ref (a foreign reference
// on iOS 16.4+, a copyable value type below the floor) — Swift never names the
// underlying swift_lattice FRT.
extension lattice.swift_lattice_ref: Hashable, Equatable, @unchecked @retroactive Sendable {
    public var hashValue: Int {
        Int(self.hash_value())
    }

    public static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}

public struct Lattice {
    // UnfairLock back-deploys (os_unfair_lock, iOS 10+); OSAllocatedUnfairLock
    // would force an iOS-16 floor. Same primitive underneath.
    private static let synchronizersLock = UnfairLock(initialState: ())
    
    public struct SyncConfiguration {
        
    }
    
    /// URLSession-backed sync transport that bridges to C++ generic_sync_transport
    internal final class WebsocketClient: @unchecked Sendable {
        private var webSocketTask: URLSessionWebSocketTask?
        private var currentState: lattice.transport_state = .closed
        // Recreated per connect attempt — see performConnect.
        private var session: URLSession
        private let delegateHandler: WebSocketDelegateHandler

        // Pointers to trigger C++ callbacks - set after generic_websocket_client is created
        private var cxxClientPtr: UnsafeMutableRawPointer?

        final class WebSocketDelegateHandler: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
            weak var client: WebsocketClient?

            // The handler is shared across the per-attempt sessions (see
            // performConnect). Events from an invalidated PREVIOUS session —
            // its task's cancellation fires didComplete(NSURLErrorCancelled)
            // — must not tear down the CURRENT attempt: without this guard the
            // cancel of attempt N-1 error-looped attempt N forever.
            private func isCurrent(_ session: URLSession) -> Bool {
                client?.session === session
            }

            func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                            didOpenWithProtocol protocol: String?) {
                guard isCurrent(session) else { return }
                client?.handleOpen()
            }

            func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
                guard isCurrent(session) else { return }
                let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                client?.handleClose(code: Int(closeCode.rawValue), reason: reasonString)
            }

            func urlSession(_ session: URLSession,
                            task: URLSessionTask,
                            didCompleteWithError error: (any Swift.Error)?) {
                guard isCurrent(session) else { return }
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

            // Fresh ephemeral session per attempt. URLSession caches auth
            // state per protection space: after ONE 401 response (e.g. the
            // server's boot window while litestream restores the auth DB),
            // CFNetwork stopped sending our manually-set Authorization header
            // on every subsequent task in the same session — so a daemon that
            // ever saw a 401 reconnected anonymously FOREVER (production:
            // hours of 60s-cadence 401s while the same token passed via curl).
            // An ephemeral config also drops cookies/credential caches.
            session.finishTasksAndInvalidate()
            session = URLSession(configuration: .ephemeral, delegate: delegateHandler, delegateQueue: nil)

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
        /// Where the database lives (1.0 item E2, replaces `isStoredInMemoryOnly`).
        public enum Storage: Sendable, Equatable, Hashable {
            /// On-disk database at the given file URL.
            case file(URL)
            /// Same-process in-memory database. Handles opened with the SAME
            /// name share one database (and cross-notify); distinct names are
            /// fully isolated. Backed by a shared-cache SQLite URI
            /// (`file:<name>?mode=memory&cache=shared`).
            case memory(named: String)
            /// A fresh, private in-memory database (unique name per call —
            /// two configurations built with `.memory()` never share).
            public static func memory() -> Storage { .memory(named: UUID().uuidString) }
        }

        public var storage: Storage

        /// The exact path/URI handed to the C++ core — also the key the
        /// attach/detach bookkeeping shares with the core's own path-keyed
        /// attachment table. Memory names are percent-encoded so characters
        /// that would terminate the SQLite URI path ('?', '#', '%', ' ')
        /// cannot silently turn a memory database into an on-disk file or
        /// collide two distinct names.
        internal var canonicalPath: String {
            switch storage {
            case .file(let url):
                return url.path
            case .memory(let name):
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
                return "file:\(encoded)?mode=memory&cache=shared"
            }
        }

        /// The on-disk location for `.file` storage. For in-memory storage the
        /// getter returns the legacy `:memory:` placeholder URL; setting this
        /// switches the configuration to `.file` storage.
        public var fileURL: URL {
            get {
                switch storage {
                case .file(let url): return url
                case .memory: return URL(fileURLWithPath: ":memory:")
                }
            }
            set { storage = .file(newValue) }
        }
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

        /// Statement-level SQLite busy timeout in milliseconds, applied to all
        /// connections of this database. Headless/server processes can keep the
        /// default (30s); interactive apps that write on the main thread should
        /// set a small value (e.g. 5000) so a stuck writer can't hang the UI.
        public var busyTimeoutMs: Int = 30_000

        /// Sync tuning knobs (1.0 item I2), forwarded into every synchronizer
        /// this database creates (WSS and IPC). Every field is optional: nil
        /// keeps the core default — this surface never re-states a default, so
        /// core-side default changes apply everywhere at once. Values that
        /// would break the synchronizer are IGNORED (the knob keeps its core
        /// default): `chunkSize <= 0` (would permanently stall uploads),
        /// `baseDelaySeconds`/`maxDelaySeconds <= 0` (reconnect hot loop), and
        /// negative windows/intervals. `0` remains meaningful where it means
        /// "disabled": `maxReconnectAttempts` (unlimited), `uploadCoalesceMs`
        /// (legacy immediate dispatch), checkpoint intervals (off).
        public struct SyncTuning: Sendable, Equatable, Hashable {
            /// Max events per sync message (core default 1000).
            public var chunkSize: Int?
            /// 0 = unlimited (core default).
            public var maxReconnectAttempts: Int?
            public var baseDelaySeconds: Double?
            public var maxDelaySeconds: Double?
            /// A connection must stay open at least this long before a drop
            /// resets the reconnect backoff (flapping-endpoint guard).
            public var stableConnectionMs: Int?
            /// Upload-tick coalescing window; 0 = legacy immediate dispatch.
            public var uploadCoalesceMs: Int?
            /// Periodic WAL maintenance cadences; require uploadCoalesceMs > 0.
            public var checkpointPassiveIntervalMs: Int?
            public var checkpointTruncateIntervalMs: Int?
            /// Incremental upload cursor (core default true).
            public var useUploadFloor: Bool?

            public init(chunkSize: Int? = nil,
                        maxReconnectAttempts: Int? = nil,
                        baseDelaySeconds: Double? = nil,
                        maxDelaySeconds: Double? = nil,
                        stableConnectionMs: Int? = nil,
                        uploadCoalesceMs: Int? = nil,
                        checkpointPassiveIntervalMs: Int? = nil,
                        checkpointTruncateIntervalMs: Int? = nil,
                        useUploadFloor: Bool? = nil) {
                self.chunkSize = chunkSize
                self.maxReconnectAttempts = maxReconnectAttempts
                self.baseDelaySeconds = baseDelaySeconds
                self.maxDelaySeconds = maxDelaySeconds
                self.stableConnectionMs = stableConnectionMs
                self.uploadCoalesceMs = uploadCoalesceMs
                self.checkpointPassiveIntervalMs = checkpointPassiveIntervalMs
                self.checkpointTruncateIntervalMs = checkpointTruncateIntervalMs
                self.useUploadFloor = useUploadFloor
            }
        }

        /// nil = all core defaults.
        public var syncTuning: SyncTuning?

        /// Live-results tuning knobs (item A §1.7): shape/page cache bounds
        /// active from Commit 1; belt/TTL/keeper knobs consumed by later
        /// commits (see `ResultsTuning`).
        public var resultsTuning: ResultsTuning = .init()

        // MARK: Equatable / Hashable (migration excluded — closures aren't comparable)
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.storage == rhs.storage &&
            lhs.authorizationToken == rhs.authorizationToken &&
            lhs.wssEndpoint == rhs.wssEndpoint &&
            lhs.scheduler == rhs.scheduler &&
            lhs.isReadOnly == rhs.isReadOnly &&
            lhs.syncFilter == rhs.syncFilter &&
            lhs.ipcTargets == rhs.ipcTargets &&
            lhs.busyTimeoutMs == rhs.busyTimeoutMs &&
            lhs.syncTuning == rhs.syncTuning &&
            lhs.resultsTuning == rhs.resultsTuning
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(storage)
            hasher.combine(authorizationToken)
            hasher.combine(wssEndpoint)
            hasher.combine(scheduler)
            hasher.combine(isReadOnly)
            hasher.combine(syncFilter)
            hasher.combine(ipcTargets)
            hasher.combine(busyTimeoutMs)
            hasher.combine(syncTuning)
            hasher.combine(resultsTuning)
        }

        /// Directory for the default (unnamed) database file: the user
        /// documents directory, falling back to the current working directory
        /// where none exists (headless Linux daemons, some sandboxed utility
        /// processes). A missing documents directory is an environment
        /// condition, not a programmer error — it must not trap.
        private static func defaultDatabaseDirectory() -> URL {
            do {
                return try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: false)
            } catch {
                Logger.db.warning("Configuration: no documents directory (\(String(describing: error))) — falling back to the current working directory")
                return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            }
        }

        public init(storage: Storage? = nil, fileURL: URL? = nil,
                    authorizationToken: String? = nil, wssEndpoint: URL? = nil,
                    isReadOnly: Bool = false, migration: [Int: Migration]? = nil,
                    syncFilter: SyncFilter? = nil, busyTimeoutMs: Int = 30_000,
                    syncTuning: SyncTuning? = nil) {
            // storage wins; fileURL is the long-standing convenience spelling;
            // neither → the default documents-directory database.
            self.storage = storage ?? .file(fileURL ?? Self.defaultDatabaseDirectory()
                .appendingPathComponent("lattice\(wssEndpoint != nil ? "_ws" : "").sqlite"))
            self.authorizationToken = authorizationToken
            self.wssEndpoint = wssEndpoint
            self.scheduler = Scheduler()
            self.isReadOnly = isReadOnly
            self.migration = migration
            self.syncFilter = syncFilter
            self.busyTimeoutMs = busyTimeoutMs
            self.syncTuning = syncTuning
        }

        internal func cxxConfiguration(isolation: isolated (any Actor)? = #isolation) -> lattice.swift_configuration {
            // Create a scheduler for the current isolation context.
            // This ensures different isolation contexts get different cache keys in C++.
            let currentScheduler = Scheduler(isolation: isolation)
            let path = canonicalPath
            var config: lattice.swift_configuration = .init(
                std.string(path),
                self.wssEndpoint.map { std.string($0.absoluteString) } ?? std.string(),
                authorizationToken.map { std.string($0) } ?? std.string(),
                currentScheduler.scheduler)
            config.read_only = isReadOnly
            config.busy_timeout_ms = Int32(busyTimeoutMs)
            if let t = syncTuning {
                if let v = t.chunkSize { config.set_sync_chunk_size(Int64(v)) }
                if let v = t.maxReconnectAttempts { config.set_sync_max_reconnect_attempts(Int32(v)) }
                if let v = t.baseDelaySeconds { config.set_sync_base_delay_seconds(v) }
                if let v = t.maxDelaySeconds { config.set_sync_max_delay_seconds(v) }
                if let v = t.stableConnectionMs { config.set_sync_stable_connection_ms(Int64(v)) }
                if let v = t.uploadCoalesceMs { config.set_sync_upload_coalesce_ms(Int32(v)) }
                if let v = t.checkpointPassiveIntervalMs { config.set_sync_checkpoint_passive_interval_ms(Int32(v)) }
                if let v = t.checkpointTruncateIntervalMs { config.set_sync_checkpoint_truncate_interval_ms(Int32(v)) }
                if let v = t.useUploadFloor { config.set_sync_use_upload_floor(v) }
            }
            if let syncFilter {
                config.set_sync_filter(_makeCxxSyncFilter(Array(syncFilter.entries)))
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
                        ipcTarget.sync_filter = lattice.sync_filter_to_optional(_makeCxxSyncFilter(Array(filter.entries)))
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

    /// The boxed db backend (the single stored db handle), a `CxxBackend` on
    /// every OS. Neutral ORM operations route through it; the paths that drive
    /// the C++ surface directly (observers, nearest queries, attach) use
    /// `cxxLatticeRef` below.
    let backend: any LatticeBackend

    /// The underlying C++ `swift_lattice_ref` — a foreign reference on
    /// iOS 16.4+, a copyable value type over the same shared db below the floor.
    var cxxLatticeRef: lattice.swift_lattice_ref {
        backend.asCxxLatticeRef!
    }
    internal var isolation: (any Actor)?
    public var _isolation: (any Actor)? { isolation }
    
    /// Resolve the Lattice wrapper for a C++ ref arriving through a trampoline
    /// (observer/sync callbacks, `Model.lattice`). Returns nil when the
    /// instance has been released — late callbacks for a dead Lattice are
    /// dropped by callers, never resurrected. (The old path-based fallback
    /// could hand back a DIFFERENT instance for the same file — the
    /// zero-schema "ghost instance" bug class — and the preconditionFailure
    /// it backstopped crashed the process whenever a trampoline outlived its
    /// Lattice. Both are replaced by nil.)
    internal init?(isolation: isolated (any Actor)? = #isolation,
                   ref: lattice.swift_lattice_ref) {
        let resurrected: Lattice? = Self.cacheLock.withLockUnchecked {
            let key = CacheKey(ref)
            if let entry = Self.cache[key] {
                if let lattice = entry.resurrect() { return lattice }
                Self.cache.removeValue(forKey: key)  // expired entry
            }
            return nil
        }
        guard let resurrected else { return nil }
        self = resurrected
    }

    /// Direct construction from an existing backend — bypasses the cache
    /// lookup. Does NOT register in the cache (callers that need trampoline
    /// resolution register explicitly; the resurrect path must not re-enter
    /// the non-recursive cache lock).
    internal init(backend: any LatticeBackend,
                  configuration: Configuration,
                  modelTypes: [any Model.Type],
                  schema: _Schema?,
                  isolation: (any Actor)?) {
        self.backend = backend
        self.configuration = configuration
        self.modelTypes = modelTypes
        self.schema = schema
        self.isolation = isolation
    }
    
    private static let cacheLock = UnfairLock(initialState: ())

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

    /// Weak-value cache entry: enough to rebuild a Lattice wrapper for
    /// trampolines while the backend is alive, without pinning it. When the
    /// last user-held Lattice copy releases its backend, the C++ impl closes
    /// (sockets, scheduler threads) and the entry expires — the old strong
    /// cache kept every instance alive for the life of the process.
    private final class WeakCacheEntry {
        weak var backend: (any LatticeBackend)?
        let configuration: Configuration
        let modelTypes: [any Model.Type]
        let schema: _Schema?
        let isolation: (any Actor)?

        init(_ lattice: Lattice) {
            self.backend = lattice.backend
            self.configuration = lattice.configuration
            self.modelTypes = lattice.modelTypes
            self.schema = lattice.schema
            self.isolation = lattice.isolation
        }

        func resurrect() -> Lattice? {
            guard let backend else { return nil }
            return Lattice(backend: backend, configuration: configuration,
                           modelTypes: modelTypes, schema: schema, isolation: isolation)
        }
    }

    private nonisolated(unsafe) static var cache: [CacheKey: WeakCacheEntry] = [:]

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

                // Read old/new refs from thread-local storage (set by C++ before
                // this callback). `_optRef` normalizes the value-path import
                // (non-optional, empty when absent) to a Swift optional.
                guard let oldRef = _optRef(lattice.migrationGetOldRow()),
                      let newRef = _optRef(lattice.migrationGetNewRow()) else { return }

                // Dispatch to the Migration for the version step the bridge is
                // currently walking — NOT the final target. A v1→v3 walk fires
                // v2 tables' rows first; dispatching those into migration[3]
                // (which has no blocks for them) would preconditionFailure.
                let stepVersion = Int(lattice.migrationGetCurrentVersion())
                if let currentMigration = migCtx.migration[stepVersion] {
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
        // The single db-handle construction site: the swift_lattice_ref from
        // `create` (a foreign reference on iOS 16.4+, a copyable value type
        // below the floor) is boxed into the one stored backend.
        self.backend = CxxBackend(createdRef)
        // Item A §1.7/§3: forward the per-Lattice read-generation tunables to
        // the core pool at open (plain atomic stores). `keeperPoolSize`
        // documents the core pool capacity (no per-instance setter in 1.0);
        // the absolute age cap keeps its core default (§3.2(b)).
        let resultsTuning = configuration.resultsTuning
        self.backend.setReadGenerationTTLMs(Int64((resultsTuning.generationTTLSeconds * 1000).rounded()))
        self.backend.setWALKeeperEvictionThresholdBytes(Int64(resultsTuning.walKeeperEvictionThresholdBytes))
        let key = CacheKey(self.backend)
        let entry = WeakCacheEntry(self)
        Self.cacheLock.withLockUnchecked { Self.cache[key] = entry }
    }

    // MARK: Public Inits
    public init(isolation: isolated (any Actor)? = #isolation,
                for schema: [any Model.Type],
                configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: schema, configuration: configuration, isSynchronizing: false)
    }

    internal var schema: _Schema?
    /// The schema as it was BEFORE any attach — detach rebuilds from this,
    /// preserving the original (possibly pack-based) schema semantics.
    internal var baseSchema: _Schema?
    /// (canonical attached path, schema) per attachment. Keyed by PATH to
    /// mirror the C++ side's path-keyed attachment table: any handle over the
    /// same database — including one reopened later — can detach it, and a
    /// repeat attach cannot double-book.
    internal var attachedSchemas: [(String, any _Schema)] = []

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

    /// Open with no model types (e.g. a SwiftUI environment placeholder). This
    /// non-variadic overload is available on ALL deployment targets — without it,
    /// the zero-argument `Lattice(configuration:)` call binds to the variadic
    /// `init<each M>` (empty pack), which is iOS 17+ (parameter packs).
    public init(isolation: isolated (any Actor)? = #isolation,
                configuration: Configuration = defaultConfiguration) throws {
        try self.init(for: [], configuration: configuration)
    }

    enum Error: Swift.Error {
        case databaseError(String)
    }
    
    public static func delete(for configuration: Configuration = defaultConfiguration) throws {
        let latticeSHMURL: URL
        let latticeWALURL: URL

        guard case .file(let fileURL) = configuration.storage else {
            throw Error.databaseError("Cannot delete in-memory database")
        }

        // Explicitly close all SQLite connections for this path before unlinking
        // files. The C++ close() shuts down the read/write connections, cross-
        // process notifier, and synchronizer. Without this, SQLite warns
        // "vnode unlinked while in use" because the connection still has the
        // file mmap'd.
        let filePath = fileURL.path
        // Item A §4.6: generations/coordinators ride the same close — tear
        // down every same-path coordinator before the backends close.
        GenerationCoordinatorRegistry.evictAll(path: filePath)
        cacheLock.withLockUnchecked {
            for (key, entry) in cache where entry.configuration.fileURL.path == filePath {
                entry.backend?.close()
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
    ///
    /// Explicit registrations win: a transitively-discovered type whose
    /// entityName is already covered is skipped. Versioned snapshot models
    /// (e.g. `V1.Foo`) share entityNames with their current classes, and a
    /// snapshot's link property can resolve to the CURRENT class — without
    /// the entityName guard that pulls the current schema into a lattice
    /// that explicitly registered the snapshot, leaving two competing
    /// schemas for one table (wrong unique indexes, upsert prepare errors).
    private static func discoverAllTypes(from initialSchema: [any Model.Type]) -> [any Model.Type] {
        var discoveredTypes = Set<ObjectIdentifier>()
        var coveredEntityNames = Set<String>()
        var completeSchema: [any Model.Type] = []
        var typesToProcess: [any Model.Type] = []

        func enqueueLinkedTypes(of type: any Model.Type) {
            for (_, propertyType) in type.properties {
                if let linkPropertyType = propertyType as? any LinkProperty.Type {
                    typesToProcess.append(linkPropertyType.modelType)
                }
            }
        }

        // Explicit registrations first — they own their entityNames.
        for type in initialSchema {
            let typeId = ObjectIdentifier(type)
            guard !discoveredTypes.contains(typeId) else { continue }
            discoveredTypes.insert(typeId)
            coveredEntityNames.insert(type.entityName)
            completeSchema.append(type)
        }
        for type in completeSchema {
            enqueueLinkedTypes(of: type)
        }

        // Transitive discovery: skip any type whose table is already covered.
        // Versioned snapshot models (e.g. `V1.Foo`) share entityNames with
        // their current classes, and a snapshot's link property can resolve
        // to the CURRENT class — without this guard that pulls the current
        // schema into a lattice that explicitly registered the snapshot,
        // leaving two competing schemas for one table (wrong unique indexes,
        // upsert prepare failures).
        while !typesToProcess.isEmpty {
            let currentType = typesToProcess.removeFirst()
            let typeId = ObjectIdentifier(currentType)
            guard !discoveredTypes.contains(typeId),
                  !coveredEntityNames.contains(currentType.entityName) else { continue }
            discoveredTypes.insert(typeId)
            coveredEntityNames.insert(currentType.entityName)
            completeSchema.append(currentType)
            enqueueLinkedTypes(of: currentType)
        }

        return completeSchema
    }
    
    // MARK: Add

    /// Item A §1.3 Layer 1 (Commit 1): every Swift write path bumps the
    /// generation coordinator's epoch directly, synchronously, AFTER the
    /// backend write returns — same-handle read-your-writes with zero core
    /// dependency (§1.3 Layer 1). The bump fans out to every same-path
    /// coordinator in this process, walking attach links. Cross-handle
    /// writers that never pass through these Swift paths (sync-applied
    /// chunks, second handles) are covered by Layer 2 — the synchronous
    /// core invalidation hook (§2.3), delivered inline on the writer's
    /// thread and fanned per path across core instances (see
    /// GenerationCoordinator). The Layer-1 bump therefore double-bumps with
    /// the hook for local writes, which is harmless (minting is per access,
    /// not per bump) and keeps RYW exact even where a storage's hook
    /// delivery is conditional.
    private func _noteWrite(tables: [String]?) {
        GenerationCoordinatorRegistry.noteWrite(path: backend.path, tables: tables)
    }

    /// Inserts an unmanaged object.
    /// - Throws: `LatticeError.alreadyManaged` if the object is already
    ///   managed by a Lattice; `LatticeError.addFailed` if the backend
    ///   rejects the insert (constraint violation, closed handle, I/O).
    public func add<T: Model>(_ object: borrowing T) throws {
        guard !object.isManaged else {
            throw LatticeError.alreadyManaged
        }
        try backend.add(object._dynamicObject._ref)
        _noteWrite(tables: [T.entityName])
        // Register for cross-instance observation now that the object has a primaryKey
        object._registerIfNeeded()
    }

    /// Inserts an unmanaged object, preserving the given globalId.
    /// - Throws: `LatticeError.alreadyManaged` if the object is already
    ///   managed by a Lattice. The backend bridge exposes no failure signal
    ///   for this path today; the `throws` is for contract stability.
    public func add<T: Model>(_ object: borrowing T, preservingGlobalId globalId: UUID) throws {
        guard !object.isManaged else {
            throw LatticeError.alreadyManaged
        }
        try backend.addPreservingGlobalId(object._dynamicObject._ref, globalId: globalId)
        _noteWrite(tables: [T.entityName])
        object._registerIfNeeded()
    }

    /// Bulk-inserts unmanaged objects.
    /// - Throws: `LatticeError.alreadyManaged` if any element is already
    ///   managed by a Lattice (checked up front — nothing is inserted). The
    ///   backend bridge exposes no failure signal for the bulk path today;
    ///   the `throws` is for contract stability.
    public func add<S: Sequence>(contentsOf newElements: S) throws where S.Element: Model {
        let refs = try newElements.map { element -> any ObjectBackend in
            guard !element.isManaged else {
                throw LatticeError.alreadyManaged
            }
            return element._dynamicObject._ref
        }
        try backend.addBulk(refs)
        _noteWrite(tables: [S.Element.entityName])
    }

    // MARK: Add/Delete for VirtualModel (existential)

    /// Inserts an unmanaged virtual-model object.
    /// - Throws: `LatticeError.alreadyManaged` / `LatticeError.addFailed`
    ///   (same contract as `add(_:)`). A `VirtualModel` that does not also
    ///   conform to `Model` is a programmer error and still traps.
    public func add(_ object: any VirtualModel) throws {
        guard let model = object as? any Model else {
            fatalError("VirtualModel type must also conform to Model")
        }
        guard !model.isManaged else { throw LatticeError.alreadyManaged }
        try backend.add(model._dynamicObject._ref)
        _noteWrite(tables: [type(of: model).entityName])
        model._registerIfNeeded()
    }

    @discardableResult public func delete(_ object: any VirtualModel) -> Bool {
        guard let model = object as? any Model else {
            fatalError("VirtualModel type must also conform to Model")
        }
        let removed = backend.remove(model._dynamicObject._ref)
        if removed { _noteWrite(tables: [type(of: model).entityName]) }
        return removed
    }

    func beginObserving<T: Model>(_ object: T) {
    }
    func finishObserving<T: Model>(_ object: T) {
    }
    
    public func object<T>(isolation: isolated (any Actor)? = #isolation,
                          _ type: T.Type = T.self, primaryKey: Int64) -> T? where T: Model {
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
        let removed = backend.remove(object._dynamicObject._ref)
        if removed { _noteWrite(tables: [T.entityName]) }
        return removed
    }

    @discardableResult public func delete<T: Model>(_ modelType: T.Type = T.self,
                                                    where: ((Query<T>) -> Query<Bool>)? = nil) -> Bool {
        let whereClause: String? = `where`.map { $0(Query<T>()).predicate }
        let deleted = backend.deleteWhere(table: T.entityName, where: whereClause)
        if deleted { _noteWrite(tables: [T.entityName]) }
        return deleted
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

    /// Incremental query-planner statistics refresh (`PRAGMA optimize`).
    /// Cheap — only re-analyzes tables with missing or stale stats. Long-lived
    /// processes should call this from maintenance paths; the automatic
    /// close-time refresh never runs when the process is killed.
    public func optimize() {
        backend.optimize()
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
        // Item A §4.6: tear down this identity's generation coordinator
        // (invalidation hook, keeper holds, shape caches) before the backend
        // closes — the core close additionally retires its whole read pool
        // ahead of connection teardown; a reopened database mints a new
        // identityHash and a fresh coordinator.
        GenerationCoordinatorRegistry.evict(identityHash: backend.identityHash)
        backend.close()
    }

    /// Retire every open read generation now (item A §3.6): force-COMMIT
    /// keeper transactions, return pooled connections. Facades re-pin lazily
    /// at the next access; caches keyed by epoch survive if no invalidation
    /// arrived meanwhile.
    ///
    /// Called automatically on app backgrounding where UIKit is available
    /// (`UIApplication.willResignActiveNotification` /
    /// `protectedDataWillBecomeUnavailableNotification`). REQUIRED manually
    /// from app extensions and non-UIKit hosts that share an app-group
    /// container — a suspended process holding WAL read-marks in a shared
    /// container is terminated with `0xdead10cc`. SwiftUI hosts where the
    /// UIKit notifications do not fire should call this from a `ScenePhase`
    /// hook: `.onChange(of: scenePhase) { if $0 == .background {
    /// lattice.retireAllGenerations() } }`.
    public func retireAllGenerations() {
        // Never MINT a coordinator here (retiring must not pin): drop the
        // coordinator's holds when one exists, then force-retire everything
        // this instance still holds core-side.
        //
        // Item A §3.6: retiring LATCHES keeper suppression — retire-all is
        // not a one-shot pass. Any access that races the retire (a stale
        // fill re-resolving) or lands after it (URLSession callbacks,
        // BGTask wrap-up while the app finishes background execution) would
        // otherwise re-pin a fresh keeper that nothing retires again, and
        // the process would suspend holding WAL read-marks — the exact
        // 0xdead10cc state §3.6 forbids. While latched, accesses serve
        // unpinned tolerant (live) reads. The latch clears automatically on
        // `didBecomeActive`/`protectedDataDidBecomeAvailable` where UIKit
        // is available; manual-contract hosts (extensions, non-UIKit
        // daemons) call `resumeGenerations()` after resuming.
        GenerationCoordinatorRegistry.existingCoordinator(identityHash: backend.identityHash)?
            .retireAllGenerations()
        backend.retireAllReadGenerations()
    }

    /// Clear the keeper-suppression latch installed by
    /// `retireAllGenerations()` (item A §3.6). Re-pin stays lazy: the next
    /// live-Results access mints a fresh generation; nothing is pinned here.
    /// Called automatically on `UIApplication.didBecomeActiveNotification` /
    /// `protectedDataDidBecomeAvailableNotification` where UIKit is
    /// available; REQUIRED manually (paired with `retireAllGenerations()`)
    /// from app extensions and non-UIKit hosts.
    public func resumeGenerations() {
        GenerationCoordinatorRegistry.existingCoordinator(identityHash: backend.identityHash)?
            .resumeGenerations()
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
    /// Entries in the sync set not yet synchronized across every registered
    /// sync channel — the same number the passive sync-progress observer
    /// reports as pending. 0 means fully relayed/acknowledged.
    public var pendingSyncEntryCount: Int {
        Int(backend.pendingSyncEntryCount())
    }

    public func onSyncProgress(_ handler: @escaping @Sendable (SyncProgress) -> Void) {
        if backend.isSyncAgent() {
            // In-process path: register callback on synchronizer atomics
            backend.setOnSyncProgress { pending, total, acked, received in
                handler(SyncProgress(
                    pendingUpload: Int(pending),
                    totalUpload: Int(total),
                    acked: Int(acked),
                    received: Int(received)
                ))
            }
        } else {
            // Cross-process path: observe AuditLog changes and derive progress
            // from the count of unsynchronized entries.
            _startPassiveSyncProgressObserver(handler)
        }
    }

    /// Register a callback for sync errors (connection failures, protocol errors, etc.).
    public func onSyncError(_ handler: @escaping @Sendable (String) -> Void) {
        backend.setOnSyncError(handler)
    }

    /// Register a callback for sync connection state changes.
    public func onSyncStateChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        backend.setOnSyncStateChange(handler)
    }

    /// AsyncStream of sync progress updates. Yields on every progress change
    /// from the synchronizer's background thread.
    /// Termination: when the consumer cancels iteration, the callback is replaced
    /// with nil (clearing the C++ handler and releasing the context).
    ///
    /// Transparently works cross-process via AuditLog observation when
    /// this process is not the sync agent.
    public var syncProgressStream: AsyncStream<SyncProgress> {
        let backend = self.backend
        let isSyncAgent = backend.isSyncAgent()
        let modelTypes = self.modelTypes
        let configuration = self.configuration
        return AsyncStream { continuation in
            if isSyncAgent {
                // In-process path
                backend.setOnSyncProgress { pending, total, acked, received in
                    continuation.yield(SyncProgress(
                        pendingUpload: Int(pending),
                        totalUpload: Int(total),
                        acked: Int(acked),
                        received: Int(received)
                    ))
                }

                continuation.onTermination = { _ in
                    backend.setOnSyncProgress(nil)
                }
            } else {
                // Cross-process path: observe AuditLog changes via Darwin notifications.
                // queryLattice is only touched from the serial observer callback;
                // wrap it for capture by the @Sendable observer closure.
                // Opening the query Lattice is IO — a failure here (deleted
                // file, exhausted descriptors) degrades to an empty stream
                // instead of crashing the host process from a background path.
                let queryLattice: UncheckedSendable<Lattice>
                do {
                    queryLattice = UncheckedSendable(try Lattice(for: modelTypes, configuration: configuration))
                } catch {
                    Logger.sync.error("syncProgressStream: failed to open query Lattice (\(String(describing: error))) — finishing stream")
                    continuation.finish()
                    return
                }
                // nonisolated(unsafe): mutated only from the serial AuditLog
                // observer callback (no concurrent access), captured by the
                // @Sendable observer closure.
                nonisolated(unsafe) var previousPending = 0

                let observerId = backend.addTableObserver(table: AuditLog.entityName) { _ in
                    // Batch contents are irrelevant — re-read pending count.
                    let pending = queryLattice.value.count(AuditLog.self, where: { $0.isSynchronized == false })
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

                continuation.onTermination = { _ in
                    backend.removeTableObserver(table: AuditLog.entityName, observerId: observerId)
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
        private let backend: any LatticeBackend
        private let tableName: String
        private let observerId: UInt64
        private var isCancelled = false

        init(backend: any LatticeBackend, tableName: String, observerId: UInt64) {
            self.backend = backend
            self.tableName = tableName
            self.observerId = observerId
        }

        public func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            backend.removeTableObserver(table: tableName, observerId: observerId)
        }

        deinit {
            cancel()
        }
    }

    // The C-fn-ptr table-observer trampoline, its TableChange struct, and the
    // SyncProgress/Error/State context classes that used to live here are gone:
    // the observer/sync-callback registration now happens inside CxxBackend
    // (the `_CxxClosureBox` + @convention(c) thunks), so every call site passes
    // a plain Swift closure through the neutral backend surface instead.

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
        let backend = self.backend

        backend.setOnXprocIdle {
            let pending = Int(backend.pendingSyncEntryCount())
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
    }

    /// Delivery-ordering contract (1.0): payload-bearing change streams — this
    /// AuditLog observer and the table/collection observers — guarantee that
    /// every committed change from a SAME-PROCESS writer is delivered exactly
    /// once and that each BATCH is walked synchronously in commit order.
    /// Cross-PROCESS delivery is best-effort: a race between the writer's
    /// cursor advance and the notifier's scan can drop a remote commit's
    /// notification (the data itself is durable and readable — only the
    /// wakeup can be lost; poll or re-query on reconnect for guarantees). Cross-batch ARRIVAL order is
    /// best-effort: near-simultaneous commits can interleave under CPU
    /// contention (delivery hops threads between the C++ notify path and the
    /// callback), so consumers needing a total order must sort by AuditLog
    /// id — the ids are commit-ordered by construction. Property-change
    /// signals (`objectWillChange` / `@Observable` triggers) additionally
    /// carry no payload and may coalesce; the row itself always reads
    /// latest-committed. Pinned by ObservationOrderingTests.
    public func observe(_ block: @escaping ([AuditLog]) -> ()) -> AnyCancellable {
        let backend = self.backend
        // The C++ side delivers batches per WAL flush; this public Swift API has
        // historically fired the block ONCE PER ROW with a one-element array
        // (the `[AuditLog]` shape was a misnomer — always length 1). Preserve
        // that contract by fanning the batch out here: walk each change in commit
        // order, resolve its AuditLog row, fire `block([auditLog])` per row.
        // Consumers (e.g. CrossProcessTests c556cd2) that count callback fires
        // see the same N firings the per-row implementation gave.
        //
        // The observer callback fires on the synchronizer's background thread, so
        // the neutral surface requires @Sendable; `self`/`block` are not Sendable
        // but are only touched here, so wrap them for capture.
        let s = UncheckedSendable(self)
        let blk = UncheckedSendable(block)
        let observerId = backend.addTableObserver(table: AuditLog.entityName) { changes in
            for change in changes {
                if let auditLog = s.value.object(AuditLog.self, primaryKey: change.rowId) {
                    blk.value([auditLog])
                }
            }
        }

        let token = TableObservationToken(backend: backend, tableName: AuditLog.entityName, observerId: observerId)

        return AnyCancellable {
            token.cancel()
        }
    }

    public var changeStream: AsyncStream<[AnySendableReference<AuditLog>]> {
        AsyncStream<[AnySendableReference<AuditLog>]> { [backend, modelTypes, configuration] stream in
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
            // Only touched from the serial observer callback below; wrap for the
            // @Sendable observer closure.
            let queryLattice = UncheckedSendable(try! Lattice(for: modelTypes, configuration: queryConfig))

            let observerId = backend.addTableObserver(table: AuditLog.entityName) { changes in
                // One yield per WAL flush, with all refs from this
                // batch. Wire-relay consumers (e.g. ClaudeCodeIRC's
                // RoomSyncServer.broadcastEntries) ship one frame per
                // yield — so a cascade delete (parent + N link-table
                // DELETEs from one transaction) reaches the peer as
                // one frame and applies atomically. See the
                // notify_changes_batched comment in LatticeCore for
                // the full rationale.
                let refs: [AnySendableReference<AuditLog>] = changes.compactMap { c in
                    guard let auditLog = queryLattice.value.object(AuditLog.self, primaryKey: c.rowId) else {
                        log.warning("changeStream: no AuditLog for pk=\(c.rowId)")
                        return nil
                    }
                    log.debug("changeStream entry: table=\(auditLog.tableName) modelOp=\(auditLog.operation) modelRowId=\(auditLog.rowId)")
                    return AnySendableReference(auditLog.sendableReference)
                }
                if !refs.isEmpty {
                    log.debug("changeStream yield: count=\(refs.count)")
                    stream.yield(refs)
                }
            }

            stream.onTermination = { _ in
                backend.removeTableObserver(table: AuditLog.entityName, observerId: observerId)
            }
        }
    }

    @dynamicCallable struct UnsafeBlock: @unchecked Sendable {
        let block: (CollectionChange) -> ()
        
        func dynamicallyCall(withArguments args: [CollectionChange]) {
            args.forEach(block)
        }
    }
    
    /// Exactly-once, per-batch commit-ordered delivery — see the
    /// delivery-ordering contract on `observe(_:)` ([AuditLog] overload).
    func observe<T: Model>(_ modelType: T.Type, where: Query<Bool>? = nil,
                           block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        let backend = self.backend

        let block = UnsafeBlock(block: block)

        // Capture a sendable reference once, rather than resolving on every
        // notification. Avoids creating a new Lattice (and running
        // ensure_tables()) per callback, which races with teardown under load.
        let ref = self.sendableReference

        let observerId = backend.addTableObserver(table: T.entityName) { changes in
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

                // Filtered observers fire on RESULT-SET membership, not on
                // "did the changed fields satisfy the predicate". The old
                // changedFields-vs-predicate check had two failure modes:
                // (1) a member row mutating an unrelated column (e.g. a
                // running job's progress tick — predicate is on `status`)
                // never fired, freezing observing UI; (2) with auditing
                // disabled (_SyncControl.disabled=1) there are NO AuditLog
                // rows, so filtered observers never fired at all.
                //
                // INSERT membership is knowable (evaluate the predicate
                // against the live row). UPDATE/DELETE membership-before-the-
                // change is NOT knowable post-hoc (audit rows carry new
                // values only), so a row leaving the set can only be caught
                // by firing conservatively. Conservative fires are cheap:
                // LatticeQuery debounces and re-fetches at most once per
                // frame.
                func rowMatchesNow(_ rowId: Int64) -> Bool {
                    guard let `where` else { return true }
                    return TableResults<T>(self)
                        .where({ _ in `where` && Query<Bool>.primaryKeyEquals(rowId) })
                        .first != nil
                }
                for entry in changes {
                    let operation = entry.operation
                    let rowId = entry.rowId
                    switch operation {
                    case "INSERT":
                        if rowMatchesNow(rowId) {
                            await dispatch(.insert(rowId))
                        }
                    case "DELETE":
                        // Pre-delete membership IS knowable when auditing is
                        // on: the audit DELETE row carries the OLD values.
                        // Without an audit row (auditing disabled), fire
                        // conservatively — prior state is unknowable.
                        if let `where` {
                            let convertedQuery = `where`.convertKeyPathsToEmbedded(rootPath: "changedFields", isAnyProperty: false)
                            let wasMember = TableResults<AuditLog>(self).where({
                                $0.rowId == rowId && convertedQuery && $0.operation == .delete
                            }).first != nil
                            let anyAuditForRow = TableResults<AuditLog>(self).where({
                                $0.rowId == rowId && $0.operation == .delete
                            }).first != nil
                            if wasMember || !anyAuditForRow {
                                await dispatch(.delete(rowId))
                            }
                        } else {
                            await dispatch(.delete(rowId))
                        }
                    case "UPDATE":
                        await dispatch(.update(rowId))
                    default:
                        break
                    }
                }
            }
        }

        let token = TableObservationToken(backend: backend, tableName: T.entityName, observerId: observerId)

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
    static func observeLinkTable(_ linkTableName: String, backend: any LatticeBackend, block: @escaping (CollectionChange) -> ()) -> AnyCancellable {
        // block is non-Sendable but only invoked from the serial observer
        // callback; wrap for the @Sendable observer closure.
        let blk = UncheckedSendable(block)
        let observerId = backend.addTableObserver(table: linkTableName) { changes in
            // Walk batch synchronously, fire block per row in commit order.
            for entry in changes {
                switch entry.operation {
                case "INSERT":
                    blk.value(.insert(entry.rowId))
                case "DELETE":
                    blk.value(.delete(entry.rowId))
                case "UPDATE":
                    blk.value(.update(entry.rowId))
                default:
                    break
                }
            }
        }

        let token = TableObservationToken(backend: backend, tableName: linkTableName, observerId: observerId)
        return AnyCancellable {
            token.cancel()
        }
    }

    // MARK: Explicit-transaction ownership (item A §4.1)
    //
    // Memory-family live reads take the per-store write gate by riding the
    // lattice-level transaction entry (TableResults._gatedLiveRead /
    // materialized-id captures). When the CURRENT THREAD already holds an
    // explicit transaction ON THIS BACKEND, a nested same-connection BEGIN
    // would wait on itself (the core retry loop waits out "transaction
    // within a transaction" for its full 30 s deadline) — and the enclosing
    // transaction already owns the gate — so the read must skip its own
    // BEGIN and serve through the writer connection (which trivially
    // satisfies read-your-writes inside one's own transaction).
    //
    // Ownership is recorded PER BACKEND IDENTITY in a process-global map,
    // not as a bare thread-local depth, because:
    //  (a) the skip must be scoped to the backend whose gate the
    //      transaction owns — an open transaction on lattice A must not
    //      disable the §4.1 read gate for an unrelated lattice B on the
    //      same thread (cross-lattice contamination would reintroduce the
    //      capture-vs-writer interleaving the gate exists to prevent); and
    //  (b) begin/commit are public and may legally land on different
    //      threads (an `await` between them migrates cooperative-pool
    //      threads) — a process-global record keyed by identity is cleared
    //      by the commit wherever it runs, where a thread-dictionary depth
    //      was stranded at >0 on the begin thread forever, permanently
    //      disabling the gate for every future task scheduled onto it.
    //
    // A DIFFERENT thread's gated read waiting out this thread's transaction
    // is exactly the §4.1 capture-vs-writer exclusion — only the owning
    // thread skips.
    private static let _explicitTxnOwners =
        UnfairLock<[Int64: (owner: ObjectIdentifier, depth: Int)]>(initialState: [:])

    /// True iff the CURRENT THREAD holds an open explicit transaction on the
    /// backend identified by `identityHash`.
    internal static func _threadHoldsExplicitTransaction(identityHash: Int64) -> Bool {
        let current = ObjectIdentifier(Thread.current)
        return _explicitTxnOwners.withLockUnchecked { owners in
            guard let entry = owners[identityHash] else { return false }
            return entry.depth > 0 && entry.owner == current
        }
    }

    private static func _recordExplicitTxnBegin(identityHash: Int64) {
        let current = ObjectIdentifier(Thread.current)
        _explicitTxnOwners.withLockUnchecked { owners in
            if let entry = owners[identityHash], entry.owner == current {
                owners[identityHash] = (current, entry.depth + 1)
            } else {
                // The core serializes explicit transactions per store, so a
                // successful begin from another thread means the previous
                // owner's transaction ended — adopt ownership.
                owners[identityHash] = (current, 1)
            }
        }
    }

    private static func _recordExplicitTxnEnd(identityHash: Int64) {
        _explicitTxnOwners.withLockUnchecked { owners in
            guard let entry = owners[identityHash] else { return }
            if entry.depth <= 1 {
                owners.removeValue(forKey: identityHash)
            } else {
                owners[identityHash] = (entry.owner, entry.depth - 1)
            }
        }
    }

    public func beginTransaction(isolation: isolated (any Actor)? = #isolation) {
        // Start the transaction; record ownership only once it is really
        // open (the backend call may block behind another writer).
        backend.beginTransaction()
        Self._recordExplicitTxnBegin(identityHash: backend.identityHash)
    }

    public func commitTransaction(isolation: isolated (any Actor)? = #isolation) {
        backend.commit()
        Self._recordExplicitTxnEnd(identityHash: backend.identityHash)
        // §1.3 Layer 1: an explicit transaction can touch any table (managed
        // property setters included) — the touched set is unknown here, so
        // the settled commit invalidates every shape (tables: nil). (The
        // §2.3 core hook additionally delivers the exact changed-table
        // batch inline during `commit` — a harmless double bump.)
        _noteWrite(tables: nil)
    }

    public func rollbackTransaction(isolation: isolated (any Actor)? = #isolation) {
        backend.rollback()
        Self._recordExplicitTxnEnd(identityHash: backend.identityHash)
    }

    /// Runs `block` inside an explicit transaction. On throw the transaction
    /// is ROLLED BACK and the error rethrown — the block's writes are
    /// discarded and the connection is immediately usable. (Previously a
    /// throw left the transaction OPEN: the next beginTransaction blocked on
    /// the busy timeout and killed the process — far more reachable now that
    /// the `add` family throws.)
    public func transaction<T>(isolation: isolated (any Actor)? = #isolation,
                               _ block: () throws -> T) rethrows -> T {
        beginTransaction()
        do {
            let value = try block()
            commitTransaction()
            return value
        } catch {
            rollbackTransaction()
            throw error
        }
    }
    
    public mutating func attach(lattice: Lattice) throws {
        try backend.attach(lattice.backend)
        // Item A §4.2: attaching changes what this handle's tables mean
        // (union views over both stores) — every cached shape is stale. Link
        // the two paths so writes on either store invalidate this handle's
        // shapes while attached, and MINT the attached store's coordinator
        // now: its synchronous core hook (§2.3) is what relays writes that
        // never pass through the attached lattice's Swift write APIs
        // (sync-applied chunks on the synchronizer's own instance, second
        // core handles) to this parent's union shapes via the attach links.
        // Without an active hook on the attached path, those writes would
        // bump only attached-path coordinators that happen to exist — i.e.
        // possibly none — and the parent's cached union counts/pages would
        // be stale indefinitely.
        _ = GenerationCoordinatorRegistry.coordinator(for: lattice.backend,
                                                      tuning: lattice.configuration.resultsTuning)
        GenerationCoordinatorRegistry.linkAttachedPaths(parent: backend.path,
                                                        attached: lattice.backend.path)
        _noteWrite(tables: nil)
        let key = lattice.configuration.canonicalPath
        // Idempotent at the Swift layer too: the C++ side no-ops a repeat
        // attach of the same path — do not double-book its schema (a stale
        // duplicate would survive one detach and poison polymorphic queries).
        guard !attachedSchemas.contains(where: { $0.0 == key }) else { return }
        if baseSchema == nil { baseSchema = schema }
        attachedSchemas.append((key, lattice.schema!))
        schema = schema?.merge(typeErased: lattice.schema!)
    }

    /// Remove a previously attached lattice: drops its union/passthrough
    /// views, DETACHes the database, and rebuilds this handle's merged
    /// schema from the remaining attachments. Keyed by database path (like
    /// the C++ side), so ANY handle over the attached database — including
    /// one reopened later — detaches it. Idempotent: detaching a lattice
    /// that isn't attached is a no-op and leaves the schema untouched.
    public mutating func detach(lattice: Lattice) throws {
        try backend.detach(lattice.backend)
        GenerationCoordinatorRegistry.unlinkAttachedPaths(parent: backend.path,
                                                          attached: lattice.backend.path)
        _noteWrite(tables: nil)
        let key = lattice.configuration.canonicalPath
        guard let idx = attachedSchemas.firstIndex(where: { $0.0 == key }) else { return }
        attachedSchemas.remove(at: idx)
        // Rebuild from the ORIGINAL pre-attach schema + remaining attachments.
        var rebuilt: any _Schema = baseSchema ?? SchemaCompat(modelTypes: modelTypes)
        for (_, attached) in attachedSchemas {
            rebuilt = rebuilt.merge(typeErased: attached)
        }
        schema = rebuilt
    }

    public func attaching(lattice: Lattice) throws -> Lattice {
        // Build a query-only config: strip IPC/WSS to avoid duplicate socket
        // bind and unnecessary sync on a connection used only for UNION ALL reads.
        var queryConfig = configuration
        queryConfig.ipcTargets = nil
        queryConfig.wssEndpoint = nil
        queryConfig.authorizationToken = nil
        queryConfig.syncFilter = nil
        let cxxConfig = queryConfig.cxxConfiguration()
        // UNCACHED construction is load-bearing: when the parent has no
        // sync/IPC, the stripped config's cache key is IDENTICAL to the
        // parent's — the keyed cache would return the PARENT instance and the
        // ATTACH below would mutate the parent's own connection.
        // `_requireLatticeRef` unwraps the FRT-optional / value-non-optional gap.
        let newCxxLattice = _requireLatticeRef(LatticeCxx.swift_lattice_ref.createUncached(swiftConfig: cxxConfig,
                                                                schemas: modelTypes.cxxSchema))
        guard newCxxLattice.attach(lattice.cxxLatticeRef) else {
            let reason = newCxxLattice.last_attach_error()
            throw LatticeError.attachFailed(
                reason.__convertToBool() ? String(reason.pointee) : "unknown attach failure")
        }
        var newLattice = Lattice(backend: CxxBackend(newCxxLattice),
                                 configuration: queryConfig,
                                 modelTypes: modelTypes,
                                 schema: schema,
                                 isolation: isolation)
        // Item A §4.2: the clone unions rows from the attached store — writes
        // on either store must invalidate its shapes (see attach(lattice:)).
        // Mint the attached store's coordinator so its core hook relays
        // cross-handle/sync-applied writes through the attach link.
        _ = GenerationCoordinatorRegistry.coordinator(for: lattice.backend,
                                                      tuning: lattice.configuration.resultsTuning)
        GenerationCoordinatorRegistry.linkAttachedPaths(parent: newLattice.backend.path,
                                                        attached: lattice.backend.path)
        // Record the attachment on the clone so detach(lattice:) works on it
        // and a repeat attach can't double-book (same bookkeeping as attach).
        newLattice.baseSchema = schema
        newLattice.attachedSchemas = [(lattice.configuration.canonicalPath, lattice.schema!)]
        newLattice.schema = schema?.merge(typeErased: lattice.schema!)
        Self.cacheLock.withLockUnchecked {
            Self.cache[CacheKey(newLattice.backend)] = WeakCacheEntry(newLattice)
        }
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
// it.
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


// Build VirtualResults outside of variadic generic context to avoid IRGen crash on Linux.
// Uses existential opening on `any Model.Type` instead of pack element archetypes.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
private func _makeInitialVirtualResults<M: Model, T>(
    _ modelType: M.Type, proto: T.Type, lattice: Lattice
) -> any VirtualResults<T> {
    _VirtualResults<M, T>(types: modelType, proto: proto, lattice: lattice)
}

extension Lattice {
    /// Test seam: forces the array-backed compat results types (the < iOS 17
    /// path) even where `#available` would select the parameter-pack types, so
    /// the macOS test suite can runtime-verify the compat surface (which is
    /// otherwise dead code on every test platform). Task-local — scope it with
    /// `Lattice.$_forceCompatPaths.withValue(true) { ... }`.
    @TaskLocal package static var _forceCompatPaths = false
}

private func _buildVirtualResults<T>(
    from types: [any Model.Type], proto: T.Type, lattice: Lattice
) -> any VirtualResults<T> {
    guard let first = types.first else { fatalError("No types conform to \(T.self)") }
    // iOS 17+: build the parameter-pack `_VirtualResults` (grown one type at a
    // time). iOS 15: build the array-backed `_VirtualResultsCompat` directly.
    if !Lattice._forceCompatPaths, #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
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
        let path = fileURL.path
        // FileHandle.standardError, never stdout: stdout may be a wire
        // protocol (MCP stdio) and any stray line corrupts the stream.
        // (Not fputs(stderr): on Glibc `stderr` is a shared-mutable global
        // and Swift 6 rejects the reference — broke the Linux build.)
        guard let cFilePointer = fopen(path, "w") else {
            FileHandle.standardError.write(Data("Failed to open log file: \(path)\n".utf8))
            return
        }
        lattice.set_log_file(cFilePointer)
        FileHandle.standardError.write(Data("Log file path: \(path)\n".utf8))
    }
}

extension lattice.cxx_error: Error {
    
}
