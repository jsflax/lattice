import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

struct RecoveryRelayAuthorizationTurn: Sendable {
    let context: SyncRecoveryAuthorizationContext
    let wire: Data
    let maximumAuthorizationMilliseconds: Int64
    // The real connection captures this turn from the opened native source.
    // Keeping marshaling here makes every answer pass the same exact-context
    // checks before native authorization independently verifies it again.
    func encode(_ answer: SyncRecoveryAuthorization) throws -> Data {
        guard answer.authenticatedUserID == context.channel.userId, answer.peer == context.declaredPeer,
              answer.source == context.source, answer.incomingScope == context.incomingScope,
              !answer.authorizationRevision.isEmpty, answer.authorizationRevision.utf8.count <= 256,
              !answer.authorizationRevision.contains("\0"),
              (1...maximumAuthorizationMilliseconds).contains(answer.validForMilliseconds)
        else { throw SyncRecoveryConfigurationError.staleAuthorization }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        var payload: [String: Any] = ["context": try JSONSerialization.jsonObject(with: wire),
            "authenticatedUserID": answer.authenticatedUserID.uuidString, "peer": try object(answer.peer),
            "source": try object(answer.source), "incomingScope": try object(answer.incomingScope),
            "authorizationRevision": answer.authorizationRevision, "validForMilliseconds": answer.validForMilliseconds]
        switch (context.source.receiptCoverage, answer.receiptCoverage) {
        case (nil, .namespaceOnly): break // Preserve exact existing v2 keys.
        case (.some(let cohort), .registeredProducer(let producer, let cohortID, let revision)):
            guard producer.isBounded, revision > 0, cohort.cohortID == cohortID.uuidString.lowercased(),
                  cohort.cohortRevision == revision,
                  cohort.namespaces.contains(where: { $0.utf8.elementsEqual(context.source.receiptNamespace.utf8) })
            else { throw SyncRecoveryConfigurationError.staleAuthorization }
            payload["receiptCoverage"] = ["kind": "registeredProducer", "registrationID": producer.registrationID,
                "incarnation": producer.incarnation.uuidString.lowercased(), "cohortID": cohortID.uuidString.lowercased(),
                "cohortRevision": revision]
        default: throw SyncRecoveryConfigurationError.staleAuthorization
        }
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard encoded.count <= 32_768 else { throw SyncRecoveryConfigurationError.invalidBounds }; return encoded
    }
}
/// Retains the existing mount slot from before auth task submission through
/// actual callback settlement. Closing a socket cannot recycle that capacity.
final class RecoveryRelayAuthorizationWork: @unchecked Sendable {
    fileprivate let connection: RecoveryRelayConnection
    fileprivate init(_ connection: RecoveryRelayConnection) { self.connection = connection }
    deinit { connection.releaseAuthorization() }
}

/// Covers actual constructor/capture/timer/IO drain before authorization owns
/// the existing mount slot. A closed socket alone cannot settle this work.
final class RecoveryRelaySetupWork: @unchecked Sendable {
    private let connection: RecoveryRelayConnection
    fileprivate init(_ connection: RecoveryRelayConnection) { self.connection = connection }
    deinit { connection.releaseSetup() }
}
struct RecoveryRelayAutomaticRoute: Sendable {
    let connection: Data
    let channel: SyncChannel
    let source: RecoveryRelayResolvedSource
}

struct RelayRecoveryConnectionSample: Sendable {
    let available, socketOpen, lifetimeLive: Bool
}
/// Observation-only handle. It never owns a socket, native result, source
/// owner or stop token. The fixture bounds its wait and joins its own tasks.
final class RelayRecoveryConnectionObservation: @unchecked Sendable {
    let connectionID: UUID
    let peer: SyncRecoveryPeerIdentity
    let channel: String
    private weak var socket: WebSocket?
    private weak var lifetime: RecoveryRelayLifetime?
    private weak var nativeStop: RecoveryRelayNativeStop?
    private let pending = NIOLockedValueBox(false)

    init(connectionID: UUID, peer: SyncRecoveryPeerIdentity, channel: String,
         socket: WebSocket?, lifetime: RecoveryRelayLifetime?, nativeStop: RecoveryRelayNativeStop? = nil) {
        self.connectionID = connectionID; self.peer = peer; self.channel = channel
        self.socket = socket; self.lifetime = lifetime; self.nativeStop = nativeStop
    }
    // Only an explicit test observation retains the payload-free fence.
    func retirementObservation() -> RelayRecoveryRetirementObservation? {
        guard let nativeStop else { return nil }
        return .init(connectionID: connectionID, peer: peer, channel: channel,
                     socket: socket, lifetime: lifetime, nativeStop: nativeStop)
    }
    func sample(_ completion: @escaping @Sendable (RelayRecoveryConnectionSample) -> Void) {
        guard pending.withLockedValue({ value in if value { return false }; value = true; return true }) else {
            completion(.init(available: false, socketOpen: false, lifetimeLive: false)); return
        }
        guard let socket, let lifetime else {
            pending.withLockedValue { $0 = false }
            completion(.init(available: false, socketOpen: false, lifetimeLive: false)); return
        }
        socket.eventLoop.execute { [weak socket, weak lifetime, self] in
            let value: RelayRecoveryConnectionSample
            if let socket, let lifetime {
                value = .init(available: true, socketOpen: !socket.isClosed, lifetimeLive: lifetime.publishable)
            } else { value = .init(available: false, socketOpen: false, lifetimeLive: false) }
            pending.withLockedValue { $0 = false }
            completion(value) // No foreign callback under the observation lock.
        }
    }
}
/// These are observations of one actual connection, not disposal authority.
/// Missing weak resources cannot establish socket/setup retirement. The real
/// fence remains observable after those resources disappear.
struct RelayRecoveryRetirementSample: Sendable {
    let available, socketOpen, lifetimeStopped, nativeSetupRetired: Bool
    let nativeAvailable, nativeLive, nativeDrained: Bool
    var connectionRetired: Bool {
        available && !socketOpen && lifetimeStopped && nativeSetupRetired && nativeAvailable && !nativeLive
    }
    var operationsDrained: Bool { nativeAvailable && !nativeLive && nativeDrained }
}

final class RelayRecoveryRetirementObservation: @unchecked Sendable {
    let connectionID: UUID
    let peer: SyncRecoveryPeerIdentity
    let channel: String
    private weak var socket: WebSocket?
    private weak var lifetime: RecoveryRelayLifetime?
    // This object has no source owner, result, payload, SQL or application
    // callback. No stop or admission operation is exposed by this handle.
    private let nativeStop: RecoveryRelayNativeStop
    private let pending = NIOLockedValueBox(false)

    fileprivate init(connectionID: UUID, peer: SyncRecoveryPeerIdentity, channel: String,
                     socket: WebSocket?, lifetime: RecoveryRelayLifetime?, nativeStop: RecoveryRelayNativeStop) {
        self.connectionID = connectionID; self.peer = peer; self.channel = channel
        self.socket = socket; self.lifetime = lifetime; self.nativeStop = nativeStop
    }
    func sample(_ completion: @escaping @Sendable (RelayRecoveryRetirementSample) -> Void) {
        guard pending.withLockedValue({ value in if value { return false }; value = true; return true }) else {
            completion(.init(available: false, socketOpen: false, lifetimeStopped: false, nativeSetupRetired: false,
                             nativeAvailable: false, nativeLive: false, nativeDrained: false)); return
        }
        guard let socket, let lifetime else {
            let value = copied(socket: nil, lifetime: nil)
            pending.withLockedValue { $0 = false }
            completion(value); return
        }
        socket.eventLoop.execute { [weak socket, weak lifetime, self] in
            let value = copied(socket: socket, lifetime: lifetime)
            pending.withLockedValue { $0 = false }
            completion(value) // Never call a foreign callback under our lock.
        }
    }
    private func copied(socket: WebSocket?, lifetime: RecoveryRelayLifetime?) -> RelayRecoveryRetirementSample {
        if let socket, let lifetime {
            return .init(available: true, socketOpen: !socket.isClosed, lifetimeStopped: lifetime.isStopped,
                         nativeSetupRetired: lifetime.hasRetiredNative, nativeAvailable: true,
                         nativeLive: nativeStop.isLive, nativeDrained: nativeStop.isDrained)
        }
        return .init(available: false, socketOpen: false, lifetimeStopped: false, nativeSetupRetired: false,
                     nativeAvailable: true, nativeLive: nativeStop.isLive, nativeDrained: nativeStop.isDrained)
    }
}
private enum RelayACKTestLoss: Error { case deliberatelySuppressed }

/// One real accepted connection. Native-bearing fields are confined to its
/// file IO lane. All other users hold only its payload-free lifetime cell.
final class RecoveryRelayConnection: @unchecked Sendable {
    let mount: RecoveryRelayMount
    let id: UUID
    let lifetime: RecoveryRelayLifetime
    let peer: SyncRecoveryPeerIdentity
    private let request: NIOLockedValueBox<Request?>
    private weak var socket: WebSocket?
    private let revocation: RevocationFlag
    private var native: RecoveryRelayNativeSetup? // IO only
    private var resolvedScope: SyncRecoveryIncomingScope? // IO only
    private var observedConnection: RelayRecoveryConnectionObservation? // IO only; weak resources
    private struct Retirement {
        var requested = false
        var nativeRetired = false
        var setupKey: String?
        var setupStarted = false
        var setupReserved = false
        var authorizationReserved = false
        var removed = false
    }
    private let retirement = NIOLockedValueBox(Retirement())

    private static func removeIfSettled(_ state: inout Retirement) -> Bool {
        guard state.nativeRetired, !state.setupReserved, !state.authorizationReserved, !state.removed else { return false }
        state.removed = true; return true
    }

    func reserveSetup(for key: String) throws -> RecoveryRelaySetupWork {
        try retirement.withLockedValue { state in
            guard !state.requested, !state.setupStarted, !state.setupReserved, !state.authorizationReserved else {
                throw SyncRecoveryConfigurationError.staleAuthorization
            }
            state.setupKey = key; state.setupStarted = true; state.setupReserved = true
        }
        return RecoveryRelaySetupWork(self)
    }
    fileprivate func releaseSetup() {
        let remove = retirement.withLockedValue { state in
            precondition(state.setupReserved)
            state.setupReserved = false
            return Self.removeIfSettled(&state)
        }
        if remove { mount.remove(id) }
    }

    func reserveAuthorization() throws -> RecoveryRelayAuthorizationWork {
        try retirement.withLockedValue { state in
            guard !state.requested, !state.authorizationReserved else {
                throw SyncRecoveryConfigurationError.staleAuthorization
            }
            state.authorizationReserved = true
        }
        return RecoveryRelayAuthorizationWork(self)
    }

    fileprivate func releaseAuthorization() {
        let remove = retirement.withLockedValue { state in
            precondition(state.authorizationReserved)
            state.authorizationReserved = false
            return Self.removeIfSettled(&state)
        }
        if remove { mount.remove(id) }
    }

    init(mount: RecoveryRelayMount, request: Request, socket: WebSocket, revocation: RevocationFlag) throws {
        self.mount = mount; self.request = NIOLockedValueBox(request); self.socket = socket; self.revocation = revocation
        peer = try Self.declaration(request)
        let enrollment = try mount.enroll(); id = enrollment.0; lifetime = enrollment.1
        revocation.bindRecovery(lifetime)
    }
    deinit { precondition(native == nil, "relay native owner must retire on its file IO lane"); mount.remove(id) }
    private static func declaration(_ request: Request) throws -> SyncRecoveryPeerIdentity {
        // Bound before splitting/percent decoding; every relevant query field
        // occurs exactly once. Header/query spelling is only a declaration.
        guard let raw = request.url.query, raw.utf8.count <= 4_096 else { throw SyncRecoveryConfigurationError.invalidPeer }
        let names: Set<String> = ["recovery-v", "recovery-replica", "recovery-receiver", "recovery-channel"]
        var values: [String: String] = [:]
        for item in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let key = String(first).removingPercentEncoding else { throw SyncRecoveryConfigurationError.invalidPeer }
            if names.contains(key) {
                guard parts.count == 2, values[key] == nil, let value = String(parts[1]).removingPercentEncoding,
                      !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else { throw SyncRecoveryConfigurationError.invalidPeer }
                values[key] = value
            }
        }
        guard values.count == 4, values["recovery-v"] == "1", let replica = values["recovery-replica"],
              let receiver = values["recovery-receiver"].flatMap(UUID.init(uuidString:)),
              let channel = values["recovery-channel"].flatMap(UUID.init(uuidString:)) else { throw SyncRecoveryConfigurationError.invalidPeer }
        return .init(replicaID: replica, receiverIncarnation: receiver, channelIncarnation: channel)
    }
    func open(owner: Lattice, channel: SyncChannel, source: RecoveryRelayResolvedSource) throws -> RecoveryRelayAuthorizationTurn {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard let socket, !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed, native == nil,
              !channel.id.isEmpty, channel.id.utf8.count <= 64 else { throw SyncRecoveryConfigurationError.staleAuthorization }
        struct Route: Encodable { let mount: UUID; let connection: UUID; let channel: String; let authenticatedUserID: UUID; let peer: SyncRecoveryPeerIdentity }
        let connection = try JSONEncoder().encode(Route(mount: mount.id, connection: id, channel: channel.id,
                                                        authenticatedUserID: channel.userId, peer: peer))
        let lifetime = lifetime, revocation = revocation
        let actual = try RecoveryRelayNativeSetup(owner: owner, policy: source.policy, connection: connection,
            onIO: { RelayExecutionPool.io.isCurrentWorker }, current: { [weak socket] in
                !lifetime.isStopped && !revocation.isRevoked && socket?.isClosed == false
            })
        lifetime.bind(actual.stop)
        guard !lifetime.isStopped, !socket.isClosed else { actual.close(); throw SyncRecoveryConfigurationError.staleAuthorization }
        struct Wire: Decodable {
            struct Route: Decodable { let authenticatedUserID: UUID; let peer: SyncRecoveryPeerIdentity }
            let route: Route; let source: SyncRecoverySourceDescriptor; let incomingScope: SyncRecoveryIncomingScope
        }
        do {
            let resolved = try JSONDecoder().decode(Wire.self, from: actual.descriptor)
            guard resolved.route.authenticatedUserID == channel.userId, resolved.route.peer == peer,
                  resolved.source.sourceID == source.configuration.sourceID, resolved.source.epoch == source.configuration.epoch,
                  resolved.source.receiptNamespace == source.configuration.receiptNamespace,
                  resolved.source.receiptCoverage == source.configuration.receiptCoverageFact else { throw SyncRecoveryConfigurationError.staleAuthorization }
            native = actual; resolvedScope = resolved.incomingScope
            return .init(context: .init(channel: channel, declaredPeer: peer, source: resolved.source,
                                        incomingScope: resolved.incomingScope), wire: actual.descriptor,
                         maximumAuthorizationMilliseconds: source.configuration.maximumAuthorizationMilliseconds)
        } catch { actual.close(); throw error }
    }
    /// Freeze the real route once, before the first automatic capture attempt.
    func automaticRoute(channel: SyncChannel, source: RecoveryRelayResolvedSource) throws -> RecoveryRelayAutomaticRoute {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard let socket, !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed, native == nil,
              !channel.id.isEmpty, channel.id.utf8.count <= 64 else { throw SyncRecoveryConfigurationError.staleAuthorization }
        struct Route: Encodable { let mount: UUID; let connection: UUID; let channel: String; let authenticatedUserID: UUID; let peer: SyncRecoveryPeerIdentity }
        let bytes = try JSONEncoder().encode(Route(mount: mount.id, connection: id, channel: channel.id,
                                                  authenticatedUserID: channel.userId, peer: peer))
        return .init(connection: bytes, channel: channel, source: source)
    }
    func openAutomatic(owner: Lattice, route: RecoveryRelayAutomaticRoute,
        admissible: @escaping @Sendable () -> Bool) throws -> RecoveryRelayAuthorizationTurn? {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard let socket, !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed, native == nil else {
            throw SyncRecoveryConfigurationError.staleAuthorization
        }
        let lifetime = lifetime, revocation = revocation
        guard let actual = try RecoveryRelayNativeSetup.openAutomatic(owner: owner,
            policy: route.source.policy, connection: route.connection,
            onIO: { RelayExecutionPool.io.isCurrentWorker }, current: { [weak socket] in
                !lifetime.isStopped && !revocation.isRevoked && socket?.isClosed == false
            }, admissible: admissible) else { return nil }
        lifetime.bind(actual.stop)
        guard !lifetime.isStopped, !socket.isClosed else { actual.close(); throw SyncRecoveryConfigurationError.staleAuthorization }
        struct Wire: Decodable {
            struct Route: Decodable { let authenticatedUserID: UUID; let peer: SyncRecoveryPeerIdentity }
            let route: Route; let source: SyncRecoverySourceDescriptor; let incomingScope: SyncRecoveryIncomingScope
        }
        do {
            let resolved = try JSONDecoder().decode(Wire.self, from: actual.descriptor)
            guard resolved.route.authenticatedUserID == route.channel.userId, resolved.route.peer == peer,
                  resolved.source.sourceID == route.source.configuration.sourceID,
                  resolved.source.epoch == route.source.configuration.epoch,
                  resolved.source.receiptNamespace == route.source.configuration.receiptNamespace,
                  resolved.source.receiptCoverage == route.source.configuration.receiptCoverageFact else {
                throw SyncRecoveryConfigurationError.staleAuthorization
            }
            native = actual; resolvedScope = resolved.incomingScope
            return .init(context: .init(channel: route.channel, declaredPeer: peer, source: resolved.source,
                                       incomingScope: resolved.incomingScope), wire: actual.descriptor,
                         maximumAuthorizationMilliseconds: route.source.configuration.maximumAuthorizationMilliseconds)
        } catch { actual.close(); throw error }
    }
    /// Executes off native/SQL/control locks. The app's actual request/session
    /// and registration outcome is checked again on the returning IO turn.
    func authorize(_ turn: RecoveryRelayAuthorizationTurn, work: RecoveryRelayAuthorizationWork) async throws -> Data {
        guard work.connection === self else { throw SyncRecoveryConfigurationError.staleAuthorization }
        defer { withExtendedLifetime(work) {} }
        guard let socket, !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed else { throw SyncRecoveryConfigurationError.staleAuthorization }
        // A Request can retain its channel. Transfer it once into the actual
        // callback turn instead of retaining a connection/channel cycle.
        let captured = request.withLockedValue { value in let held = value; value = nil; return held }
        guard let captured else { throw SyncRecoveryConfigurationError.staleAuthorization }
        let answer = try await mount.authorize(captured, turn.context)
        guard !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed else { throw SyncRecoveryConfigurationError.staleAuthorization }
        return try turn.encode(answer)
    }
    func finish(_ answer: Data) throws {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard let socket, !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed, let native else { throw SyncRecoveryConfigurationError.staleAuthorization }
        try native.authorize(answer)
        guard let resolvedScope else { throw SyncRecoveryConfigurationError.staleAuthorization }
        lifetime.didAuthorize(resolvedScope)
        guard lifetime.publishable else { throw SyncRecoveryConfigurationError.staleAuthorization }
    }
    func receive(_ data: Data) throws -> RecoveryRelayNativeResult {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard lifetime.publishable, let native else { throw SyncRecoveryConfigurationError.staleAuthorization }
        return try native.receive(data)
    }
    func reserveInput(bytes: Int) throws -> RecoveryRelayNativeCharge { try lifetime.reserveReady(bytes: bytes) }
    func ready(_ data: Data, charge: RecoveryRelayNativeCharge,
               diagnostics: (@Sendable (RecoveryRelayNativeReadyDiagnostics) -> Void)? = nil) throws -> RecoveryRelayNativeReadyResult {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard lifetime.publishable, let native else { throw SyncRecoveryConfigurationError.staleAuthorization }
        if let diagnostics {
            let observed = try native.readyObserved(data, charge: charge)
            diagnostics(observed.diagnostics)
            return observed.result
        }
        return try native.ready(data, charge: charge)
    }
    func connectionObservation(channel: String) -> RelayRecoveryConnectionObservation? {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        guard lifetime.publishable, let socket, !socket.isClosed,
              !channel.isEmpty, channel.utf8.prefix(65).count <= 64 else { return nil }
        if let observedConnection { return observedConnection.channel == channel ? observedConnection : nil }
        let observation = RelayRecoveryConnectionObservation(connectionID: id, peer: peer, channel: channel,
                                                               socket: socket, lifetime: lifetime, nativeStop: native?.stop)
        observedConnection = observation
        return observation
    }
    func sendReady(_ result: RecoveryRelayNativeReadyResult,
                   park: (@Sendable (String, @escaping @Sendable () -> Void) -> Bool)? = nil,
                   didDecision: (@Sendable (String, Bool) -> Void)? = nil,
                   trace: RelayReadyControlTrace? = nil) {
        guard let socket else { trace?.refuse(.socketUnavailable); return }
        let lifetime = lifetime
        let once = NIOLockedValueBox(false)
        let enqueue: @Sendable () -> Void = {
            guard once.withLockedValue({ used in if used { return false }; used = true; return true }) else { return }
            trace?.record(.sendQueued)
            socket.eventLoop.execute {
                trace?.record(.socketLoopEntered)
                // Preserve the original order, one evaluation and short circuit.
                guard !socket.isClosed else { trace?.refuse(.socketClosed); didDecision?(result.requestID, false); return }
                guard lifetime.publishable else { trace?.refuse(.swiftLifetime); didDecision?(result.requestID, false); return }
                guard result.publishable else { trace?.refuse(.nativeResult); didDecision?(result.requestID, false); return }
                let promise = socket.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { [self] outcome in
                    if let trace {
                        switch outcome { case .success: trace.sendSettled(succeeded: true); case .failure: trace.sendSettled(succeeded: false) }
                    }
                    withExtendedLifetime((self, result)) {}
                }
                socket.send(raw: result.data, opcode: .binary, promise: promise)
                trace?.record(.handedOff) // Existing send-call return, not delivery/receipt.
                didDecision?(result.requestID, true)
            }
        }
        if park?(result.requestID, enqueue) != true { enqueue() }
    }
    /// Check on the actual socket event loop immediately before handoff. The
    /// payload-free native operation stays counted until this send settles.
    func send(_ data: Data, result: RecoveryRelayNativeResult? = nil, capacity: RecoveryRelayNativeCharge? = nil, promise supplied: EventLoopPromise<Void>? = nil,
              ackObservation: RelayRecoveryACKObservation? = nil,
              dropACK: (@Sendable (RelayRecoveryACKObservation) -> Bool)? = nil) {
        guard let socket else { supplied?.fail(SyncRecoveryConfigurationError.staleAuthorization); return }
        let lifetime = lifetime
        socket.eventLoop.execute {
            let promise = supplied ?? socket.eventLoop.makePromise(of: Void.self)
            guard !socket.isClosed, lifetime.publishable, result?.publishable != false else {
                promise.fail(SyncRecoveryConfigurationError.staleAuthorization); return
            }
            promise.futureResult.whenComplete { [self] _ in withExtendedLifetime((self, result, capacity)) {} }
            if result?.status == 1,
               RelayRecoveryACKObservation.requestsDrop(ackObservation, connectionID: self.id, peer: self.peer, decision: dropACK) {
                promise.fail(RelayACKTestLoss.deliberatelySuppressed); return
            }
            socket.send(raw: data, opcode: .binary, promise: promise)
        }
    }
    func fanOut(_ data: Data, to recipients: [SocketManager.Entry], result: RecoveryRelayNativeResult,
                didDecision: (@Sendable (Bool) -> Void)? = nil) {
        let lifetime = lifetime
        for recipient in recipients {
            recipient.socket.eventLoop.execute {
                guard lifetime.publishable, result.publishable, !recipient.socket.isClosed,
                      recipient.revocation.publicationAllowed else { didDecision?(false); return }
                let promise = recipient.socket.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { [self] _ in withExtendedLifetime((self, result)) {} }
                recipient.socket.send(raw: data, opcode: .binary, promise: promise)
                didDecision?(true)
            }
        }
    }
    func retire(for key: String) {
        lifetime.stop()
        let releasedRequest = request.withLockedValue { value in let held = value; value = nil; return held }
        withExtendedLifetime(releasedRequest) {}
        let cleanupKey = retirement.withLockedValue { state -> String? in
            if state.requested { return nil }
            state.requested = true
            // An onClose caller may have captured its old unopened key before
            // setup published the real one. Reservation and this transition
            // choose one immutable lane under the same leaf lock.
            return state.setupKey ?? key
        }
        if let cleanupKey {
            RelayExecutionPool.io.submitRequired(for: cleanupKey) {
                self.native?.close(); self.native = nil; self.resolvedScope = nil
                self.lifetime.finishNativeRetirement()
                // Native retirement and actual app authorization are separate
                // obligations. Neither depends on socket wrapper destruction.
                let remove = self.retirement.withLockedValue { state in
                    state.nativeRetired = true
                    return Self.removeIfSettled(&state)
                }
                if remove { self.mount.remove(self.id) }
            }
        }
    }
}
