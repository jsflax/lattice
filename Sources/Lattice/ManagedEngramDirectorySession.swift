import Foundation
import LatticeSwiftCppBridge
@_implementationOnly import _LatticeManagedDirectoryInternal
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// These completion symbols are private implementation linkage. They are not
// declared in the public C++ module/header and accept only a retained request
// cookie created BEFORE this exact transport is allocated. No public API takes
// a directory Snapshot, principal, membership, response bytes or verified flag.

/// A live credential session for the fixed Engram directory protocol. Creating
/// this object grants nothing. Each route needs an actual authenticated fetch,
/// exact enrolled owners and a native policy snapshot. It is not Codable.
@_spi(Installation)
public final class ManagedEngramDirectorySession: @unchecked Sendable {
    public enum Failure: Error { case endpoint, unavailable, response, bodyLimit, cancelled, refused }
    public enum Direction: UInt8, Sendable {
        case hubToPersonal = 1, personalToHub = 2, hubToGroup = 3, groupToHub = 4
    }
    private let creator = getpid()
    internal let credentials: lattice.swift_managed_product_credentials
    private let endpoint: URL
    private let authorization: String
    private let lock = NSLock()
    private var closed = false
    private var pending: [ObjectIdentifier: DirectoryTransport] = [:]

    public init(endpoint: URL, authorizationToken: String) throws {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              !authorizationToken.isEmpty, authorizationToken.utf8.count <= 16_384,
              !authorizationToken.contains("\r"), !authorizationToken.contains("\n") else {
            throw Failure.endpoint
        }
        // Use one exact configured base for every fixed path and for native
        // correlation. A redirect can never choose a different authority.
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let base = parts.url, base.absoluteString.utf8.count <= 4096 else { throw Failure.endpoint }
        self.endpoint = base
        self.authorization = authorizationToken
        self.credentials = lattice.swift_managed_product_credentials.create(std.string(base.absoluteString), std.string(authorizationToken))
        guard credentials.valid() else { throw Failure.refused }
    }

    /// Prepares only the fixed product WSS configuration. The private native
    /// receiver separately requires the actual already-enrolled query owner;
    /// this method cannot perform enrollment, start a closed daemon, or grant
    /// remote lineage from the directory request. Actual launch activation is
    /// composed with the managed daemon's separate early-entry path.
    public func configuredWSS(_ original: Lattice.Configuration, group: UUID? = nil) throws -> Lattice.Configuration {
        guard isOpen(), credentials.valid(), original.recoverySourceExpectation == nil else { throw Failure.refused }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        guard var url = parts.url else { throw Failure.endpoint }
        url.appendPathComponent("sync")
        if let group { url.appendPathComponent("group"); url.appendPathComponent(group.uuidString) }
        var result = original
        result.wssEndpoint = url; result.authorizationToken = authorization
        result.managedEngramDirectorySession = self
        return result
    }

    /// Starts the selected enrolled spoke's separately owned native WSS/query
    /// child. Native selection comes from the actual issued route; callers do
    /// not choose an owner, URL, copied profile, filter or configured flag here.
    /// The application configuration remains unchanged.
    public func startWSS(for route: ManagedEngramRoute) throws -> ManagedEngramWSSOwner {
        guard isOpen(), credentials.valid(), route.isCurrent else { throw Failure.refused }
        let owner = route.native.start_wss(credentials, std.string(authorization))
        guard owner.valid() else { throw Failure.refused }
        guard isOpen(), credentials.valid(), route.isCurrent else {
            owner.stop()
            throw Failure.cancelled
        }
        return ManagedEngramWSSOwner(owner)
    }

    /// Opens the genuine managed restart receiver, independently of producer
    /// sharing routes. The native cap selects its actual member and fixed root
    /// profile; no URL/group/models/current-cut argument is accepted here.
    public func startReceiver(for preserved: OrdinaryReceiverPreservation) async throws -> ManagedEngramWSSOwner {
        guard isOpen(), credentials.valid() else { throw Failure.cancelled }
        let request = preserved.native.beginReceiverRequest(credentials: credentials)
        guard request.valid() else { throw Failure.refused }
        let selection = request.directorySelection()
        guard selection.isAvailable(), request.valid() else { request.cancel(); throw Failure.refused }
        let group: UUID?
        if selection.isPersonal() {
            // Only a successful actual native personal selection admits nil.
            // An unavailable/default/error result cannot choose this endpoint.
            guard !selection.isGroup(), String(selection.groupIdentifier()).isEmpty else { request.cancel(); throw Failure.refused }
            group = nil
        } else {
            let spelling = String(selection.groupIdentifier())
            guard selection.isGroup(), spelling.utf8.count == 36,
                  let actual = UUID(uuidString: spelling) else { request.cancel(); throw Failure.refused }
            group = actual
        }
        let nonce = String(selection.admissionNonce())
        guard nonce.utf8.count == 36, let parsedNonce = UUID(uuidString: nonce),
              nonce == parsedNonce.uuidString.lowercased(), isOpen(), credentials.valid(), request.valid() else {
            request.cancel(); throw Failure.refused
        }
        let transport = DirectoryTransport(endpoint: endpoint, authorization: authorization,
            group: group, receiver: request, nonce: nonce)
        guard retainTransport(transport) else { request.cancel(); throw Failure.cancelled }
        defer { releaseTransport(transport) }
        try await withTaskCancellationHandler { try await transport.run() } onCancel: { transport.cancel() }
        try Task.checkCancellation()
        // Starts only after real delegate invalidation+queue barrier and native
        // actual directory completion. Actual native generation/archive/child
        // validation runs here, outside the response callback queue.
        let owner = request.start(credentials, std.string(authorization))
        guard owner.valid() else { throw Failure.refused }
        guard isOpen(), credentials.valid(), request.valid() else { owner.stop(); throw Failure.cancelled }
        return ManagedEngramWSSOwner(owner)
    }

    /// Explicit sign-out/token rotation/membership refresh closes old admission
    /// before any replacement session can issue new routes. Already admitted
    /// operations retain their actual cleanup obligations; this is not a join.
    public func revoke() {
        guard creator == getpid() else { return }
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let tasks = Array(pending.values)
        lock.unlock()
        credentials.revoke()
        for task in tasks { task.cancel() }
    }

    deinit { revoke() }

    private func isOpen() -> Bool {
        guard creator == getpid() else { return false }
        lock.lock(); defer { lock.unlock() }; return !closed
    }
    private func retainTransport(_ transport: DirectoryTransport) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        pending[ObjectIdentifier(transport)] = transport; return true
    }
    private func releaseTransport(_ transport: DirectoryTransport) {
        lock.lock(); let retained = pending.removeValue(forKey: ObjectIdentifier(transport)); lock.unlock()
        withExtendedLifetime(retained) {}
    }

    /// hub/spoke select real owning wrappers, not paths. Core proves their
    /// admitted member roles. Group IDs select a response member; they do not
    /// grant membership. Predicates and principal values are not arguments.
    public func authorize(hub: Lattice, spoke: Lattice, direction: Direction,
                          group: UUID? = nil) async throws -> ManagedEngramRoute {
        guard creator == getpid(), let source = hub.backend.asCxxLatticeRef,
              let target = spoke.backend.asCxxLatticeRef else { throw Failure.refused }
        guard isOpen() else { throw Failure.cancelled }
        let request = source.beginManagedEngramRoute(
            target: target, credentials: credentials, direction: direction.rawValue,
            group: std.string(group?.uuidString.lowercased() ?? ""))
        guard request.valid() else { throw Failure.refused }
        let transport = DirectoryTransport(endpoint: endpoint, authorization: authorization,
            group: group, native: request)
        guard retainTransport(transport) else { request.cancel(); throw Failure.cancelled }
        defer { releaseTransport(transport) }
        try await withTaskCancellationHandler {
            try await transport.run()
        } onCancel: { transport.cancel() }
        try Task.checkCancellation()
        // Native publication repeats the actual pair/profile/policy checks
        // outside URLSession's delegate queue. No response callback runs SQL.
        let issued = request.publish()
        guard issued.current() else { throw Failure.refused }
        return ManagedEngramRoute(issued, request: request)
    }
}

/// Opaque retained result. Public copied IDs never recreate this object. The
/// receipt grants a product route only; upstream canonical lineage, local
/// authoring and explicit privacy intent remain separate checked operations.
@_spi(Installation)
public final class ManagedEngramRoute: @unchecked Sendable {
    fileprivate let native: lattice.swift_managed_product_route
    private let request: lattice.swift_managed_product_request
    fileprivate init(_ native: lattice.swift_managed_product_route, request: lattice.swift_managed_product_request) {
        self.native = native; self.request = request
    }
    public var principalID: UUID? { UUID(uuidString: String(native.principal())) }
    public var isCurrent: Bool { native.current() }
    public func revoke() { request.cancel() }
    /// Only a real native product receipt can register on the actual paired
    /// daemon endpoint. No selector/JSON/filter argument supplies authority.
    public func bind(to peer: ManagedEngramPeerOwner) throws {
        guard isCurrent, !peer.hasFailed, native.bind_peer(peer.native) else {
            throw ManagedEngramDirectorySession.Failure.refused
        }
    }
}

/// A retained real native cleanup owner. stop() only closes admission. The
/// two-second close operation reports actual joined cleanup; false is retained
/// debt, not success. Copies of the native payload share one owner/lifetime.
@_spi(Installation)
public final class ManagedEngramWSSOwner: @unchecked Sendable {
    private let native: lattice.swift_managed_wss_owner
    fileprivate init(_ native: lattice.swift_managed_wss_owner) { self.native = native }
    public func stop() { native.stop() }
    public var isSettled: Bool { native.settled() }
    @discardableResult public func close() -> LatticeCloseResult {
        var result = native.close()
        let message = String(result.takeMessage())
        return LatticeCloseResult(sync: .init(rawValue: result.syncState()) ?? .unavailable,
            cleanupComplete: result.cleanupComplete(), failed: result.failed(),
            cleanupFailed: result.cleanupFailed(), errorMessage: message.isEmpty ? nil : message,
            errorMessageUnavailable: result.messageUnavailable())
    }
    deinit { native.stop() }
}

// A fixed, non-injectable transport. It never uses URLProtocol test overrides,
// cached JSON, custom trust evaluation, or a caller's response callback.
private final class DirectoryTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Part {
        let path: [String]
        let cap: Int
        var data = Data()
        var responseAccepted = false
        var done = false
    }
    private let creator = getpid()
    private let endpoint: URL
    private let authorization: String
    private enum Native {
        case product(lattice.swift_managed_product_request)
        case receiver(lattice.swift_managed_receiver_request)
        func cancel() { switch self { case .product(let value): value.cancel(); case .receiver(let value): value.cancel() } }
        func received(_ me: UnsafeRawPointer?, _ meCount: Int, _ groups: UnsafeRawPointer?, _ groupsCount: Int, _ status: UnsafeRawPointer?, _ statusCount: Int) -> Bool {
            switch self {
            case .product(let value): return lattice_managed_directory_received_v1(value.transportCookie(), me, meCount, groups, groupsCount, status, statusCount)
            case .receiver(let value): return lattice_managed_receiver_directory_received_v1(value.transportCookie(), me, meCount, groups, groupsCount, status, statusCount)
            }
        }
        func failed() { switch self {
            case .product(let value): lattice_managed_directory_failed_v1(value.transportCookie())
            case .receiver(let value): lattice_managed_receiver_directory_failed_v1(value.transportCookie())
        } }
    }
    private let native: Native
    private let lock = NSLock()
    private var session: URLSession?
    private var queue: OperationQueue?
    private var tasks: [URLSessionDataTask] = []
    private var indices: [Int: Int] = [:]
    private var parts: [Part]
    private let receiverNonce: String?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var started = false
    private var invalidating = false
    private var completed = false

    init(endpoint: URL, authorization: String, group: UUID?, native: lattice.swift_managed_product_request) {
        self.endpoint = endpoint; self.authorization = authorization; self.native = .product(native); self.receiverNonce = nil
        let statusPath = group.map { ["groups", $0.uuidString.lowercased(), "subscription"] }
            ?? ["subscriptions", "status"]
        self.parts = [Part(path: ["me"], cap: 16_384), Part(path: ["groups"], cap: 1_048_576),
                      Part(path: statusPath, cap: 16_384)]
    }

    init(endpoint: URL, authorization: String, group: UUID?, receiver: lattice.swift_managed_receiver_request, nonce: String) {
        self.endpoint = endpoint; self.authorization = authorization; self.native = .receiver(receiver); self.receiverNonce = nonce
        let admissionPath = group.map { ["sync", "group", $0.uuidString.lowercased(), "receiver-admission"] }
            ?? ["sync", "receiver-admission"]
        // Same three original bodies/caps/30s episode. No subscription status
        // fallback when the actual private guarded endpoint is unavailable.
        self.parts = [Part(path: ["me"], cap: 16_384), Part(path: ["groups"], cap: 1_048_576),
                      Part(path: admissionPath, cap: 16_384)]
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard creator == getpid() else { continuation.resume(throwing: ManagedEngramDirectorySession.Failure.refused); return }
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            lock.lock()
            if started { lock.unlock(); session.invalidateAndCancel(); continuation.resume(throwing: ManagedEngramDirectorySession.Failure.refused); return }
            started = true; self.continuation = continuation; self.queue = queue; self.session = session
            let cancelled = failure != nil
            for (i, part) in parts.enumerated() {
                var url = endpoint; for path in part.path { url.appendPathComponent(path) }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if i == 2, let receiverNonce {
                    request.setValue(receiverNonce, forHTTPHeaderField: "X-Lattice-Receiver-Request")
                }
                request.timeoutInterval = 30
                let task = session.dataTask(with: request)
                indices[task.taskIdentifier] = i; tasks.append(task)
            }
            let actual = tasks
            lock.unlock()
            if cancelled { for task in actual { task.cancel(); task.resume() } }
            else { for task in actual { task.resume() } }
        }
    }

    func cancel() {
        guard creator == getpid() else { return }
        native.cancel()
        fail(ManagedEngramDirectorySession.Failure.cancelled)
    }

    private func fail(_ error: Error) {
        guard creator == getpid() else { return }
        lock.lock()
        if failure == nil { failure = error }
        let actual = session; let active = tasks
        let finish = started && parts.allSatisfy(\.done) && !invalidating
        if finish { invalidating = true }
        lock.unlock()
        for task in active { task.cancel() }
        if finish { actual?.finishTasksAndInvalidate() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        fail(ManagedEngramDirectorySession.Failure.response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard creator == getpid() else { completionHandler(.cancel); return }
        lock.lock()
        var accepted = false
        if failure == nil, let i = indices[dataTask.taskIdentifier],
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           response.url == dataTask.originalRequest?.url,
           !parts[i].responseAccepted,
           response.expectedContentLength < 0 || response.expectedContentLength <= Int64(parts[i].cap) {
            parts[i].responseAccepted = true; accepted = true
        }
        lock.unlock()
        completionHandler(accepted ? .allow : .cancel)
        if !accepted { fail(ManagedEngramDirectorySession.Failure.response) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard creator == getpid() else { return }
        lock.lock()
        var accepted = false
        if failure == nil, let i = indices[dataTask.taskIdentifier], parts[i].responseAccepted,
           !parts[i].done, data.count <= parts[i].cap - parts[i].data.count {
            // The retained application buffer is charged BEFORE append. The
            // platform's transient delegate Data allocation is not an RSS cap.
            parts[i].data.append(data); accepted = true
        }
        lock.unlock()
        if !accepted { fail(ManagedEngramDirectorySession.Failure.bodyLimit) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard creator == getpid() else { return }
        lock.lock()
        if let i = indices[task.taskIdentifier] {
            if error != nil || !parts[i].responseAccepted || parts[i].done {
                if failure == nil { failure = error ?? ManagedEngramDirectorySession.Failure.response }
            }
            parts[i].done = true
        } else if failure == nil { failure = ManagedEngramDirectorySession.Failure.response }
        let stop = failure != nil; let active = tasks
        let finish = parts.allSatisfy(\.done) && !invalidating
        if finish { invalidating = true }
        lock.unlock()
        if stop { for task in active { task.cancel() } }
        if finish { session.finishTasksAndInvalidate() }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard creator == getpid() else { return }
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        if error != nil && failure == nil { failure = error }
        if !parts.allSatisfy({ $0.done && $0.responseAccepted }) && failure == nil {
            failure = ManagedEngramDirectorySession.Failure.response
        }
        let issue = failure; let data = parts.map(\.data)
        let continuation = self.continuation; self.continuation = nil
        let queue = self.queue; self.queue = nil; self.session = nil
        lock.unlock()
        // Fence this exact serial delegate queue after invalidation. This is
        // response custody, not a claim that a callback proves IPC retirement.
        queue?.addBarrierBlock { [self] in
            let received = issue == nil && data[0].withUnsafeBytes { me in
                data[1].withUnsafeBytes { groups in data[2].withUnsafeBytes { status in
                    native.received(me.baseAddress, me.count, groups.baseAddress, groups.count, status.baseAddress, status.count)
                } }
            }
            if received { continuation?.resume() }
            else { native.failed(); continuation?.resume(throwing: issue ?? ManagedEngramDirectorySession.Failure.refused) }
        }
    }
}
