import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

struct RecoveryRelayAuthorizationTurn: Sendable {
    let context: SyncRecoveryAuthorizationContext
    let wire: Data
    let maximumAuthorizationMilliseconds: Int64
}
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
    private let retiring = NIOLockedValueBox(false)

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
                  resolved.source.receiptNamespace == source.configuration.receiptNamespace else { throw SyncRecoveryConfigurationError.staleAuthorization }
            native = actual; resolvedScope = resolved.incomingScope
            return .init(context: .init(channel: channel, declaredPeer: peer, source: resolved.source,
                                        incomingScope: resolved.incomingScope), wire: actual.descriptor,
                         maximumAuthorizationMilliseconds: source.configuration.maximumAuthorizationMilliseconds)
        } catch { actual.close(); throw error }
    }
    /// Executes off native/SQL/control locks. The app's actual request/session
    /// and registration outcome is checked again on the returning IO turn.
    func authorize(_ turn: RecoveryRelayAuthorizationTurn) async throws -> Data {
        guard let socket, !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed else { throw SyncRecoveryConfigurationError.staleAuthorization }
        // A Request can retain its channel. Transfer it once into the actual
        // callback turn instead of retaining a connection/channel cycle.
        let captured = request.withLockedValue { value in let held = value; value = nil; return held }
        guard let captured else { throw SyncRecoveryConfigurationError.staleAuthorization }
        let answer = try await mount.authorize(captured, turn.context)
        guard !lifetime.isStopped, !revocation.isRevoked, !socket.isClosed,
              answer.authenticatedUserID == turn.context.channel.userId, answer.peer == turn.context.declaredPeer,
              answer.source == turn.context.source, answer.incomingScope == turn.context.incomingScope,
              !answer.authorizationRevision.isEmpty, answer.authorizationRevision.utf8.count <= 256,
              !answer.authorizationRevision.contains("\0"),
              (1...turn.maximumAuthorizationMilliseconds).contains(answer.validForMilliseconds)
        else { throw SyncRecoveryConfigurationError.staleAuthorization }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        let payload: [String: Any] = ["context": try JSONSerialization.jsonObject(with: turn.wire),
            "authenticatedUserID": answer.authenticatedUserID.uuidString, "peer": try object(answer.peer),
            "source": try object(answer.source), "incomingScope": try object(answer.incomingScope),
            "authorizationRevision": answer.authorizationRevision, "validForMilliseconds": answer.validForMilliseconds]
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard encoded.count <= 32_768 else { throw SyncRecoveryConfigurationError.invalidBounds }; return encoded
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
    /// Check on the actual socket event loop immediately before handoff. The
    /// payload-free native operation stays counted until this send settles.
    func send(_ data: Data, result: RecoveryRelayNativeResult? = nil, promise supplied: EventLoopPromise<Void>? = nil) {
        guard let socket else { supplied?.fail(SyncRecoveryConfigurationError.staleAuthorization); return }
        let lifetime = lifetime
        socket.eventLoop.execute {
            let promise = supplied ?? socket.eventLoop.makePromise(of: Void.self)
            guard !socket.isClosed, lifetime.publishable, result?.publishable != false else {
                promise.fail(SyncRecoveryConfigurationError.staleAuthorization); return
            }
            promise.futureResult.whenComplete { [self] _ in withExtendedLifetime((self, result)) {} }
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
        let first = retiring.withLockedValue { value in if value { return false }; value = true; return true }
        if first {
            RelayExecutionPool.io.submitRequired(for: key) {
                self.native?.close(); self.native = nil; self.resolvedScope = nil
            }
        }
    }
}
