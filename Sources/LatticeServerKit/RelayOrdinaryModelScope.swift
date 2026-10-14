import Foundation
import Vapor
import NIOConcurrencyHelpers
@_spi(LatticeServer) import Lattice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Route convention on the retained actual typed mount, never source/cut authority.
public enum SyncOrdinaryHistoryRelationRole: Sendable { case personal, group }
struct RelayOrdinaryHistoryRouteObservation: Sendable {
    let principal: String, channel: String, profile: String
    let group: String?
    fileprivate init(principal: String, channel: String, profile: String, group: String?) {
        self.principal = principal; self.channel = channel; self.profile = profile; self.group = group
    }
}

/// Typed mount declaration only. A wire identifier cannot supply model types,
/// policy, principal, source identity, history, installation or receipt facts.
public struct SyncOrdinaryModelProfile: @unchecked Sendable {
    public let identifier: String
    fileprivate let models: [any Lattice.Model.Type]
    fileprivate let historyRelationRole: SyncOrdinaryHistoryRelationRole?
    public init(identifier: String, models: [any Lattice.Model.Type], historyRelationRole: SyncOrdinaryHistoryRelationRole? = nil) throws {
        guard Self.validIdentifier(identifier), (1...256).contains(models.count) else {
            throw RelayOrdinaryModelError.configuration
        }
        let names = models.map { $0.entityName }
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              names.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw RelayOrdinaryModelError.configuration
        }
        self.identifier = identifier; self.models = models; self.historyRelationRole = historyRelationRole
    }
    static func validIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
    }
}

enum RelayOrdinaryModelError: Error, Sendable { case configuration, control, stopped, effectUnavailable }

/// Retains the FULL actual mount declaration. Registration is not authorization.
/// Linked declarations are resolved with the actual root-first Swift model rules.
final class RelayOrdinaryModelMount: @unchecked Sendable {
    fileprivate let schema: [any Lattice.Model.Type]
    private let profiles: [String: SyncOrdinaryModelProfile]
    fileprivate let requiredEffect: Bool
    init(schema: [any Lattice.Model.Type], profiles: [SyncOrdinaryModelProfile], requiredEffect: Bool = false) throws {
        guard (1...256).contains(schema.count),
              (requiredEffect ? (0...16).contains(profiles.count) : (1...16).contains(profiles.count)) else {
            throw RelayOrdinaryModelError.configuration
        }
        let names = schema.map { $0.entityName }
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              names.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw RelayOrdinaryModelError.configuration
        }
        let completeSchema = try Self.fullCatalog(for: schema)
        let actualTypes = Set(completeSchema.map { ObjectIdentifier($0) })
        var registered: [String: SyncOrdinaryModelProfile] = [:]
        for profile in profiles {
            guard registered[profile.identifier] == nil,
                  profile.models.allSatisfy({ actualTypes.contains(ObjectIdentifier($0)) }) else {
                throw RelayOrdinaryModelError.configuration
            }
            registered[profile.identifier] = profile
        }
        self.schema = completeSchema; self.profiles = registered; self.requiredEffect = requiredEffect
    }
    /// Read-only type discovery, matching Lattice's explicit-root precedence
    /// and transitive LinkProperty semantics. This is not native admission.
    static func fullCatalog(for roots: [any Lattice.Model.Type]) throws -> [any Lattice.Model.Type] {
        guard (1...256).contains(roots.count) else { throw RelayOrdinaryModelError.configuration }
        var discovered = Set<ObjectIdentifier>(), covered = Set<String>()
        var complete: [any Lattice.Model.Type] = []
        var pending: [any Lattice.Model.Type] = []
        var enqueued = Set<ObjectIdentifier>()
        func append(_ type: any Lattice.Model.Type) throws {
            guard complete.count < 256, !type.entityName.isEmpty, type.entityName.utf8.count <= 256 else {
                throw RelayOrdinaryModelError.configuration
            }
            discovered.insert(ObjectIdentifier(type)); covered.insert(type.entityName); complete.append(type)
        }
        for type in roots {
            if !discovered.contains(ObjectIdentifier(type)) { try append(type) }
        }
        func enqueueLinks(of type: any Lattice.Model.Type) throws {
            let properties = type.properties
            guard properties.count <= 65_536 else { throw RelayOrdinaryModelError.configuration }
            for (_, property) in properties {
                if let link = property as? any LinkProperty.Type {
                    let target = link.modelType, identity = ObjectIdentifier(link.modelType)
                    if !discovered.contains(identity), enqueued.insert(identity).inserted {
                        guard pending.count < 256 else { throw RelayOrdinaryModelError.configuration }
                        pending.append(target)
                    }
                }
            }
        }
        for type in complete { try enqueueLinks(of: type) }
        var head = 0
        while head < pending.count {
            let type = pending[head]; head += 1
            guard !discovered.contains(ObjectIdentifier(type)), !covered.contains(type.entityName) else { continue }
            try append(type); try enqueueLinks(of: type)
        }
        guard complete.reduce(0, { $0 + $1.entityName.utf8.count }) <= 65_536 else { throw RelayOrdinaryModelError.configuration }
        return complete
    }
    // Shared guarded HTTP/WSS route facts from THIS full retained declaration.
    // The caller's actual channelExtractor and existing middleware authenticate;
    // these bytes are DATA and never substitute for the SDK's fresh requests.
    fileprivate func historyRoute(profile: SyncOrdinaryModelProfile, channel: SyncChannel) throws -> RelayOrdinaryHistoryRouteObservation {
        let retained = try self.profile(profile.identifier)
        guard let role = retained.historyRelationRole,
              !channel.id.isEmpty, channel.id.utf8.count <= 1_024,
              !channel.databaseFileName.isEmpty, channel.databaseFileName.utf8.count <= 255 else {
            throw RelayOrdinaryModelError.control
        }
        let group: String?
        switch role {
        case .personal:
            guard UUID(uuidString: channel.id) == channel.userId,
                  channel.databaseFileName == "\(channel.id).sqlite" else { throw RelayOrdinaryModelError.control }
            group = nil
        case .group:
            guard channel.id.hasPrefix("group-"),
                  let actualGroup = UUID(uuidString: String(channel.id.dropFirst(6))),
                  channel.databaseFileName == "\(channel.id).sqlite" else { throw RelayOrdinaryModelError.control }
            group = actualGroup.uuidString.lowercased()
        }
        return .init(principal: channel.userId.uuidString.lowercased(), channel: channel.id,
                     profile: retained.identifier, group: group)
    }
    func receiverAdmission(channel: SyncChannel, nonce: String) throws -> Data {
        guard profiles.count == 1, let profile = profiles.values.first else { throw RelayOrdinaryModelError.control }
        let observed = try historyRoute(profile: profile, channel: channel)
        let object: [String: Any] = ["version": 1, "kind": "receiverAdmission", "request": nonce,
            "principal": observed.principal, "group": observed.group.map { $0 as Any } ?? NSNull(),
            "modelProfile": observed.profile, "channel": observed.channel]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        guard bytes.count <= 4_096 else { throw RelayOrdinaryModelError.control }
        return bytes
    }

    // Called by the actual relay only after handshake + async channelExtractor.
    func authorize(channel: SyncChannel, key: String, socket: WebSocket,
                   revocation: RevocationFlag, expires: UInt64,
                   onActualEffectAdmission: (@Sendable () -> Void)? = nil) throws -> RelayOrdinaryModelAuthorization {
        guard !channel.id.isEmpty, channel.id.utf8.count <= 1_024,
              !channel.databaseFileName.isEmpty, channel.databaseFileName.utf8.count <= 255,
              !key.isEmpty, key.utf8.count <= 4_096 else { throw RelayOrdinaryModelError.configuration }
        return try RelayOrdinaryModelAuthorization(mount: self, channel: channel, key: key,
                                                   socket: socket, revocation: revocation, expires: expires,
                                                   onActualEffectAdmission: onActualEffectAdmission)
    }
    fileprivate func profile(_ identifier: String) throws -> SyncOrdinaryModelProfile {
        guard let profile = profiles[identifier] else { throw RelayOrdinaryModelError.control }
        return profile
    }
}

/// Physical socket/principal/channel/key authorization from the real extractor.
/// SDK channel.id retains its own namespace; it is never a native wss: channel.
final class RelayOrdinaryModelAuthorization: @unchecked Sendable {
    private let mount: RelayOrdinaryModelMount
    let channel: SyncChannel
    let key: String
    private let socket: WebSocket
    private let revocation: RevocationFlag
    private let expires: UInt64
    private let creatorPID = getpid()
    private let onActualEffectAdmission: (@Sendable () -> Void)?
    // One actual original effect ending, never a caller-supplied success flag.
    private enum EffectAdmission { case setup, scalar(ObjectIdentifier), history(ObjectIdentifier) }
    private let effectAdmission = NIOLockedValueBox<EffectAdmission>(.setup)
    // These originals are IO-confined. The published identity above is the
    // only off-lane observation, used solely to retire the SAME setup timer.
    private weak var admittedScalar: RelayOrdinaryConnection?
    private weak var admittedHistory: RelayOrdinaryHistoryProducer?
    fileprivate init(mount: RelayOrdinaryModelMount, channel: SyncChannel, key: String,
                     socket: WebSocket, revocation: RevocationFlag, expires: UInt64,
                     onActualEffectAdmission: (@Sendable () -> Void)?) throws {
        self.mount = mount; self.channel = channel; self.key = key
        self.socket = socket; self.revocation = revocation; self.expires = expires
        self.onActualEffectAdmission = onActualEffectAdmission
        try validateCurrent()
    }
    fileprivate func validateCurrent() throws {
        guard getpid() == creatorPID, !socket.isClosed, !revocation.isRevoked else { throw RelayOrdinaryModelError.stopped }
        switch effectAdmission.withLockedValue({ $0 }) {
        case .setup:
            // Existing model-only scope remains exactly this original expiry.
            guard DispatchTime.now().uptimeNanoseconds < expires else { throw RelayOrdinaryModelError.stopped }
        case .scalar(let identity):
            guard isOnOwnerTurn, let original = admittedScalar, ObjectIdentifier(original) == identity,
                  original.hasCurrentAdmittedOriginal(for: self) else { throw RelayOrdinaryModelError.stopped }
        case .history(let identity):
            guard isOnOwnerTurn, let original = admittedHistory, ObjectIdentifier(original) == identity,
                  original.hasCurrentAdmittedOriginal(for: self) else { throw RelayOrdinaryModelError.stopped }
        }
    }
    func ownsOriginalTransport(socket: WebSocket, key: String, revocation: RevocationFlag) -> Bool {
        getpid() == creatorPID && self.socket === socket && self.key == key && self.revocation === revocation
    }
    var actualInitialEffectAdmissionSettled: Bool {
        effectAdmission.withLockedValue { phase in
            switch phase { case .setup: return false; case .scalar, .history: return true }
        }
    }
    fileprivate func admitOriginalScalar(_ original: RelayOrdinaryConnection, selection: RelayOrdinaryModelSelection) throws {
        guard mount.requiredEffect, isOnOwnerTurn,
              DispatchTime.now().uptimeNanoseconds < expires,
              case .setup = effectAdmission.withLockedValue({ $0 }),
              original.hasSuccessfulOriginalOffer(for: self, selection: selection) else { throw RelayOrdinaryModelError.control }
        try validateCurrent() // PID/socket/revocation and SAME original setup expiry.
        admittedScalar = original
        effectAdmission.withLockedValue { $0 = .scalar(ObjectIdentifier(original)) }
        onActualEffectAdmission?() // Timer retirement follows the real transition.
    }
    fileprivate func admitOriginalHistory(_ original: RelayOrdinaryHistoryProducer, selection: RelayOrdinaryModelSelection) throws {
        guard mount.requiredEffect, isOnOwnerTurn,
              DispatchTime.now().uptimeNanoseconds < expires,
              case .setup = effectAdmission.withLockedValue({ $0 }),
              original.hasSuccessfulOriginalOffer(for: self, selection: selection) else { throw RelayOrdinaryModelError.control }
        try validateCurrent()
        admittedHistory = original
        effectAdmission.withLockedValue { $0 = .history(ObjectIdentifier(original)) }
        onActualEffectAdmission?()
    }
    func validateUse(socket: WebSocket, key: String, revocation: RevocationFlag) throws {
        try validateCurrent()
        guard self.socket === socket, self.key == key, self.revocation === revocation else {
            throw RelayOrdinaryModelError.control
        }
    }
    fileprivate var isOnOwnerTurn: Bool {
        getpid() == creatorPID && RelayExecutionPool.io.isExecuting(for: key)
    }
    fileprivate func validateOwner(_ owner: Lattice) throws {
        try validateCurrent()
        guard isOnOwnerTurn, !owner.configuration.isReadOnly,
              case .file(let url) = owner.configuration.storage,
              FileWatchManager.canonicalKey(for: url) == key else { throw RelayOrdinaryModelError.control }
        let actual = Set(owner.modelTypes.map { ObjectIdentifier($0) })
        guard actual == Set(mount.schema.map { ObjectIdentifier($0) }) else {
            throw RelayOrdinaryModelError.control
        }
        // Native mounting separately proves physical storage/catalog/source custody.
    }
    func openExistingOwner(configuration: Lattice.Configuration) throws -> Lattice {
        try validateCurrent()
        guard isOnOwnerTurn, !configuration.isReadOnly, case .file(let url) = configuration.storage,
              FileWatchManager.canonicalKey(for: url) == key else { throw RelayOrdinaryModelError.control }
        // Actual authenticated mount owns the full linked typed catalog. Native
        // existing READ validates storage; neither path/model input issues a cut.
        let owner = try Lattice.openMountedServerExisting(for: mount.schema, configuration: configuration)
        try validateOwner(owner)
        return owner
    }
    fileprivate func registerNativeMount(owner: Lattice) throws -> OwnedOrdinaryMountedHistorySource {
        try validateOwner(owner)
        let issued = try owner.registerOrdinaryMountedHistorySource(models: mount.schema)
        // Registration has its own real native COMMIT. A later authorization
        // veto suppresses publication; it cannot undo already durable enrollment.
        try validateOwner(owner)
        return issued
    }
    fileprivate func historyRelationRoute(role: SyncOrdinaryHistoryRelationRole, profile: String) throws -> RelayOrdinaryHistoryRouteObservation {
        guard isOnOwnerTurn, SyncOrdinaryModelProfile.validIdentifier(profile) else { throw RelayOrdinaryModelError.control }
        try validateCurrent()
        let retained = try mount.profile(profile)
        switch (retained.historyRelationRole, role) {
        case (.some(.personal), .personal), (.some(.group), .group): break
        default: throw RelayOrdinaryModelError.control
        }
        let observed = try mount.historyRoute(profile: retained, channel: channel)
        try validateCurrent()
        return observed
    }
    // Required effects use the SAME physical issuer and owner checks as the
    // existing model-only gate. nil means an explicit full mounted selection;
    // unknown nonnil selectors always refuse. No arbitrary model array enters.
    func resolve(identifier: String?, owner: Lattice, key: String) throws -> RelayOrdinaryModelSelection {
        guard self.key == key, isOnOwnerTurn else { throw RelayOrdinaryModelError.control }
        try validateOwner(owner)
        let models: [any Lattice.Model.Type]
        let profileIdentifier: String
        let role: SyncOrdinaryHistoryRelationRole?
        if let identifier {
            let retained = try mount.profile(identifier)
            models = retained.models; profileIdentifier = retained.identifier; role = retained.historyRelationRole
        } else {
            models = mount.schema; profileIdentifier = ""; role = nil
        }
        return RelayOrdinaryModelSelection(authorization: self, owner: UnsafeSendableBox(owner),
            models: models, profileIdentifier: profileIdentifier, historyRelationRole: role, ownsOwnerBox: true)
    }

    fileprivate func resolve(identifier: String, owner: UnsafeSendableBox<Lattice>) throws -> RelayOrdinaryModelSelection {
        guard isOnOwnerTurn else { throw RelayOrdinaryModelError.control }
        guard let value = owner.valueIfPresent else { throw RelayOrdinaryModelError.stopped }
        try validateOwner(value)
        let profile = try mount.profile(identifier)
        return RelayOrdinaryModelSelection(authorization: self, owner: owner, profile: profile)
    }
}

/// Private immutable selection, issued only against the actual opened owner.
/// No public constructor and no source/cut/history/install/result/ACK authority.
final class RelayOrdinaryModelSelection: @unchecked Sendable {
    let models: [any Lattice.Model.Type]
    let profileIdentifier: String
    private let authorization: RelayOrdinaryModelAuthorization
    private let owner: UnsafeSendableBox<Lattice>
    private let historyRelationRole: SyncOrdinaryHistoryRelationRole?
    private let ownsOwnerBox: Bool
    private let mounted = UnsafeSendableBox(RelayOrdinaryMountedCaptureSlot())
    fileprivate convenience init(authorization: RelayOrdinaryModelAuthorization, owner: UnsafeSendableBox<Lattice>,
                     profile: SyncOrdinaryModelProfile) {
        self.init(authorization: authorization, owner: owner, models: profile.models,
            profileIdentifier: profile.identifier, historyRelationRole: profile.historyRelationRole, ownsOwnerBox: false)
    }
    fileprivate init(authorization: RelayOrdinaryModelAuthorization, owner: UnsafeSendableBox<Lattice>,
                     models: [any Lattice.Model.Type], profileIdentifier: String,
                     historyRelationRole: SyncOrdinaryHistoryRelationRole?, ownsOwnerBox: Bool) {
        self.authorization = authorization; self.owner = owner
        self.models = models; self.profileIdentifier = profileIdentifier
        self.historyRelationRole = historyRelationRole; self.ownsOwnerBox = ownsOwnerBox
    }
    deinit {
        let original = owner, mounted = mounted, key = authorization.key, owns = ownsOwnerBox
        RelayExecutionPool.io.submitRequired(for: key) {
            mounted.clear()
            if owns { original.clear() }
        }
    }
    func hasIssuer(_ original: RelayOrdinaryModelAuthorization) -> Bool { authorization === original }
    func admitOriginalScalarOffer(_ original: RelayOrdinaryConnection) throws {
        // Same selection/physical owner fences both sides of the actual offer
        // ending. Caller booleans, copied nonce and timer cancellation grant nothing.
        try withCurrentOwner { _, _ in () }
        try authorization.admitOriginalScalar(original, selection: self)
        try withCurrentOwner { _, _ in () }
    }
    func admitOriginalHistoryOffer(_ original: RelayOrdinaryHistoryProducer) throws {
        try withCurrentOwner { _, _ in () }
        try authorization.admitOriginalHistory(original, selection: self)
        try withCurrentOwner { _, _ in () }
    }
    func captureCurrentMountedHistory(observingLineage: Bool = false) throws -> OwnedOrdinaryHistoryExport {
        try withCurrentOwner { value, selected in
            if observingLineage { _ = try historyRelationRoute() }
            let source: OwnedOrdinaryMountedHistorySource
            if let retained = mounted.value.source { source = retained }
            else {
                let issued = try authorization.registerNativeMount(owner: value)
                mounted.value.source = issued; source = issued
            }
            return try observingLineage ? source.captureWithLineageObservation(models: selected) : source.capture(models: selected)
        }
    }
    func historyRelationRoute() throws -> RelayOrdinaryHistoryRouteObservation {
        guard let historyRelationRole else { throw RelayOrdinaryModelError.control }
        return try withCurrentOwner { _, _ in
            try authorization.historyRelationRoute(role: historyRelationRole, profile: profileIdentifier)
        }
    }
    func withCurrentOwner<Value>(_ operation: (Lattice, [any Lattice.Model.Type]) throws -> Value) throws -> Value {
        guard authorization.isOnOwnerTurn else { throw RelayOrdinaryModelError.control }
        guard let value = owner.valueIfPresent else { throw RelayOrdinaryModelError.stopped }
        try authorization.validateOwner(value)
        let result = try operation(value, models)
        try authorization.validateOwner(value)
        return result
    }
}

/// Actual model-only control syntax. Effect controls are intentionally refused
/// until S3 owning effect admission and transport are composed.
struct RelayOrdinaryModelRequest: Sendable {
    let request: String
    let profile: String
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4_096 else { throw RelayOrdinaryModelError.control }
        var syntax = RelayACKSyntax(data); _ = try syntax.scan()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["latticeOrdinarySync"],
              let body = root["latticeOrdinarySync"] as? [String: Any],
              Set(body.keys) == ["version", "kind", "request", "modelProfile"],
              let version = body["version"] as? NSNumber,
              String(cString: version.objCType) != "c", version.stringValue == "2",
              body["kind"] as? String == "modelRequest",
              let request = body["request"] as? String, request.utf8.count == 36,
              UUID(uuidString: request) != nil,
              let profile = body["modelProfile"] as? String,
              SyncOrdinaryModelProfile.validIdentifier(profile) else { throw RelayOrdinaryModelError.control }
        return .init(request: request, profile: profile)
    }
}

/// At most one selection/nonce per actual connection. All selection mutation and
/// borrowing occur on the original canonical keyed IO lane. Retirement is a
/// one-way veto; it never returns native authority or declares a drain settled.
private final class RelayOrdinaryMountedCaptureSlot {
    var source: OwnedOrdinaryMountedHistorySource?
}

final class RelayOrdinaryModelGate: @unchecked Sendable {
    private let authorization: RelayOrdinaryModelAuthorization
    private let socket: WebSocket
    private let owner: UnsafeSendableBox<Lattice>
    private let stopped = RevocationFlag()
    private let mounted = UnsafeSendableBox(RelayOrdinaryMountedCaptureSlot())
    private var selection: RelayOrdinaryModelSelection?
    private var request: String?
    init(authorization: RelayOrdinaryModelAuthorization, owner: Lattice,
         socket: WebSocket, key: String, revocation: RevocationFlag) throws {
        try authorization.validateUse(socket: socket, key: key, revocation: revocation)
        try authorization.validateOwner(owner)
        self.authorization = authorization; self.socket = socket
        self.owner = UnsafeSendableBox(owner)
    }
    deinit {
        let owner = owner, mounted = mounted, key = authorization.key
        RelayExecutionPool.io.submitRequired(for: key) { mounted.clear(); owner.clear() }
    }
    func retire() { stopped.revoke() }
    func releaseOwnerOnIO() {
        precondition(authorization.isOnOwnerTurn)
        stopped.revoke(); selection = nil; mounted.clear(); owner.clear()
    }
    func validatePublication() throws {
        guard !stopped.isRevoked else { throw RelayOrdinaryModelError.stopped }
        try authorization.validateCurrent()
    }
    func receive(_ data: Data) -> Result<Data, RelayOrdinaryModelError> {
        do {
            guard authorization.isOnOwnerTurn else { throw RelayOrdinaryModelError.control }
            try validatePublication()
            let control = try RelayOrdinaryModelRequest.decode(data)
            if let selection {
                guard request == control.request, selection.profileIdentifier == control.profile else {
                    throw RelayOrdinaryModelError.control
                }
                try selection.withCurrentOwner { _, _ in () }
            } else {
                selection = try authorization.resolve(identifier: control.profile, owner: owner)
                request = control.request
            }
            let offer = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": [
                "version": 2, "kind": "modelOffer", "request": control.request, "modelProfile": control.profile]])
            guard offer.count <= 256, offer.count <= data.count else { throw RelayOrdinaryModelError.control }
            try validatePublication()
            return .success(offer)
        } catch let failure as RelayOrdinaryModelError { return .failure(failure) }
        catch { return .failure(.control) }
    }
    // Owning S2/S3 caller seam; no caller-supplied owner or model array.
    func withCurrentSelection<Value>(_ operation: (Lattice, [any Lattice.Model.Type]) throws -> Value) throws -> Value {
        guard authorization.isOnOwnerTurn else { throw RelayOrdinaryModelError.control }
        try validatePublication()
        guard let selection else { throw RelayOrdinaryModelError.control }
        let value = try selection.withCurrentOwner(operation)
        try validatePublication()
        return value
    }
    /// Genuine native mounted capture, borrowing only the retained selected
    /// types on the actual keyed turn. This does not activate an effect request,
    /// transport a frame, or issue receiver install/result/ACK/prune authority.
    func captureHistoryExport() throws -> OwnedOrdinaryHistoryExport {
        try withCurrentSelection { owner, models in
            guard let slot = mounted.valueIfPresent else { throw RelayOrdinaryModelError.stopped }
            if slot.source == nil { slot.source = try authorization.registerNativeMount(owner: owner) }
            guard let source = slot.source else { throw RelayOrdinaryModelError.stopped }
            // Capture allocates/seals a cut in its own genuine native WRITE.
            // A post-COMMIT veto can discard this owner, not roll back that cut.
            return try source.capture(models: models)
        }
    }
    // Service input remains charged until BOTH synchronous send return and real
    // promise completion. The 256-byte Data remains retained by this closure.
    func sendOffer(_ bytes: Data) async throws {
        try validatePublication()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let send = RelayOrdinaryModelOfferSend(gate: self, socket: socket, bytes: bytes, continuation: continuation)
            socket.eventLoop.execute { send.begin() }
        }
        try validatePublication()
    }
}

/// Two-fact fence confined to the original socket event loop. It retains no
/// native owner directly; the gate queues final native disposal on canonical IO.
private final class RelayOrdinaryModelOfferSend: @unchecked Sendable {
    private let gate: RelayOrdinaryModelGate
    private let socket: WebSocket
    private var bytes: Data?
    private let continuation: CheckedContinuation<Void, any Error>
    private var returned = false, settled = false
    private var completed: Result<Void, Error>?
    init(gate: RelayOrdinaryModelGate, socket: WebSocket, bytes: Data,
         continuation: CheckedContinuation<Void, any Error>) {
        self.gate = gate; self.socket = socket; self.bytes = bytes; self.continuation = continuation
    }
    func begin() {
        precondition(socket.eventLoop.inEventLoop)
        do { try gate.validatePublication() }
        catch { completed = .failure(error); returned = true; settle(); return }
        let promise = socket.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [self] result in
            socket.eventLoop.execute { self.completed = result; self.settle() }
        }
        socket.send(raw: bytes!, opcode: .binary, promise: promise)
        returned = true; settle()
    }
    private func settle() {
        precondition(socket.eventLoop.inEventLoop)
        guard returned, let result = completed, !settled else { return }
        settled = true; completed = nil; bytes = nil
        continuation.resume(with: result)
    }
}
