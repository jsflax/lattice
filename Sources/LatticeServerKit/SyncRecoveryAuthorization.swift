import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

extension SyncWritePolicy.Operation: Codable {}
public struct SyncRecoveryPeerIdentity: Sendable, Codable, Equatable {
    public let replicaID: String
    public let receiverIncarnation: UUID
    public let channelIncarnation: UUID
    public init(replicaID: String, receiverIncarnation: UUID, channelIncarnation: UUID) {
        self.replicaID = replicaID; self.receiverIncarnation = receiverIncarnation; self.channelIncarnation = channelIncarnation
    }
}
public struct SyncRecoverySourceDescriptor: Sendable, Codable, Equatable {
    public let authority: String
    public let sourceID: UUID
    public let epoch: UUID
    public let scopeDigest: String
    public let schemaDigest: String
    public let receiptNamespace: String
    public let coverageID: String
    public let coverageRevision: Int64
    public let descriptorDigest: String
}
public struct SyncRecoveryModelScope: Sendable, Codable, Equatable {
    public let table: String
    public let incomingOperations: [SyncWritePolicy.Operation]
}
public struct SyncRecoveryRelationScope: Sendable, Codable, Equatable {
    public let table: String
    public let lhsModel: String
    public let rhsModel: String
    public let incomingOperations: [SyncWritePolicy.Operation]
}
public struct SyncRecoveryIncomingScope: Sendable, Codable, Equatable {
    public let models: [SyncRecoveryModelScope]
    public let relations: [SyncRecoveryRelationScope]
    public let scopedLinkTables: [String]
    public let catalogDigest: String
}
/// Copied from the actual opened source. No caller can add a row grant here;
/// a receiver controller still needs its own durable membership/Q/barrier.
public struct SyncRecoveryAuthorizationContext: Sendable {
    public let channel: SyncChannel
    public let declaredPeer: SyncRecoveryPeerIdentity
    public let source: SyncRecoverySourceDescriptor
    public let incomingScope: SyncRecoveryIncomingScope
}
/// The app must authorize the peer's persistent store registration using its
/// authenticated request, including retirement/membership and this exact scope.
/// Authentication of a user alone does not authorize an arbitrary replica ID.
public struct SyncRecoveryAuthorization: Sendable {
    public let authenticatedUserID: UUID
    public let peer: SyncRecoveryPeerIdentity
    public let source: SyncRecoverySourceDescriptor
    public let incomingScope: SyncRecoveryIncomingScope
    public let authorizationRevision: String
    public let validForMilliseconds: Int64
    public init(authenticatedUserID: UUID, peer: SyncRecoveryPeerIdentity,
                source: SyncRecoverySourceDescriptor, incomingScope: SyncRecoveryIncomingScope,
                authorizationRevision: String, validForMilliseconds: Int64) {
        self.authenticatedUserID = authenticatedUserID; self.peer = peer; self.source = source
        self.incomingScope = incomingScope; self.authorizationRevision = authorizationRevision
        self.validForMilliseconds = validForMilliseconds
    }
}
public struct SyncRecoveryNamespace: Sendable, Codable {
    public let namespaceID: String
    public let coverageID: String
    public let revision: Int64
    public init(namespaceID: String, coverageID: String, revision: Int64) {
        self.namespaceID = namespaceID; self.coverageID = coverageID; self.revision = revision
    }
}
public enum SyncRecoveryDurability: Sendable { case walFull }
public enum SyncRecoveryConfigurationError: Error, Sendable { case invalidBounds, ambiguousPolicy, invalidPeer, staleAuthorization }
/// Explicit bounded-v1 source enrollment. The full registered model/relation
/// closure is authoritative; a filtered scope label is not supported. Enrolling
/// a file changes its durable canonical profile and requires exact reopen.
public struct SyncRecoveryMountConfiguration: Sendable {
    let authority: String, sourceID: UUID, epoch: UUID, localNamespace: String, receiptNamespace: String
    let namespaces: [SyncRecoveryNamespace], models: [String]
    let maximumAuthorizationMilliseconds: Int64
    public init(authority: String, sourceID: UUID, epoch: UUID, localNamespace: String,
                namespaces: [SyncRecoveryNamespace], receiptNamespace: String, models: [String],
                durability: SyncRecoveryDurability, maximumAuthorizationMilliseconds: Int64) throws {
        func bounded(_ s: String, _ cap: Int) -> Bool { !s.isEmpty && s.utf8.count <= cap && !s.contains("\0") }
        guard bounded(authority, 256), bounded(localNamespace, 256), bounded(receiptNamespace, 256),
              (1...64).contains(namespaces.count), (1...16).contains(models.count),
              namespaces.allSatisfy({ bounded($0.namespaceID, 256) && bounded($0.coverageID, 256) && $0.revision > 0 }),
              Set(namespaces.map(\.namespaceID)).count == namespaces.count,
              namespaces.contains(where: { $0.namespaceID == localNamespace }),
              namespaces.contains(where: { $0.namespaceID == receiptNamespace }), receiptNamespace != localNamespace,
              models.allSatisfy({ bounded($0, 64) }), Set(models).count == models.count,
              (1...3_600_000).contains(maximumAuthorizationMilliseconds) else { throw SyncRecoveryConfigurationError.invalidBounds }
        self.authority = authority; self.sourceID = sourceID; self.epoch = epoch; self.localNamespace = localNamespace
        self.namespaces = namespaces; self.receiptNamespace = receiptNamespace; self.models = models
        self.maximumAuthorizationMilliseconds = maximumAuthorizationMilliseconds
    }
    func policy(_ upload: SyncWritePolicy?) throws -> Data {
        let tables = upload?.allowedOperations ?? [:]
        guard tables.count <= 16, tables.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              Set(tables.keys.map { $0.lowercased() }).count == tables.count,
              (0...256).contains(upload?.maxDeletesPerFrame ?? 256) else { throw SyncRecoveryConfigurationError.ambiguousPolicy }
        let ns: [[String: Any]] = namespaces.map { ["namespaceID": $0.namespaceID, "coverageID": $0.coverageID, "revision": $0.revision] }
        let masks: [[String: Any]] = tables.keys.sorted().map { key in
            ["table": key, "operations": SyncWritePolicy.Operation.allCases.filter { tables[key]!.contains($0) }.map(\.rawValue)]
        }
        let unlisted: String
        if let upload { switch upload.unlistedTables { case .allow: unlisted = "allow"; case .deny: unlisted = "deny" } }
        else { unlisted = "allow" }
        let payload: [String: Any] = ["version": 1, "authority": authority, "sourceID": sourceID.uuidString.lowercased(),
            "epoch": epoch.uuidString.lowercased(), "localNamespace": localNamespace, "namespaces": ns,
            "receiptNamespace": receiptNamespace, "models": models, "walFull": true,
            "maximumAuthorizationMilliseconds": maximumAuthorizationMilliseconds,
            "upload": ["tables": masks, "unlisted": unlisted,
                       "maximumDeletes": upload?.maxDeletesPerFrame ?? 256]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= 32_768 else { throw SyncRecoveryConfigurationError.invalidBounds }; return data
    }
}

extension Lattice {
    /// Additive real relay authorization. This wires authenticated upstream
    /// receipt provenance; automatic canonical recovery and receiver source
    /// authority are not activated. The app owns its actual TLS/auth boundary.
    @discardableResult public static func configureSyncRelay(
        on routes: any RoutesBuilder, path: [PathComponent] = ["sync"], for schema: [any Lattice.Model.Type],
        storageURL: URL, writePolicy: SyncWritePolicy? = nil, handshake: SyncSchemaHandshake? = nil,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil, observerPush: SyncObserverPush? = nil,
        recovery: SyncRecoveryMountConfiguration,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel,
        recoveryAuthorization: @escaping @Sendable (Request, SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization
    ) throws -> SyncRelayHandle {
        let mount = try RecoveryRelayMount(configuration: recovery, upload: writePolicy, authorize: recoveryAuthorization)
        return configureSyncRelayImpl(on: routes, path: path, for: schema, storageURL: storageURL,
            writePolicy: writePolicy, handshake: handshake, storeConfiguration: storeConfiguration,
            observerPush: observerPush, recoveryMount: mount, channelExtractor: channelExtractor)
    }

    /// Multi-file mounts resolve stable registered source IDs for this actual
    /// authorized channel. The provider runs off native locks; its recipe is
    /// still verified by actual enrollment/reopen before peer authorization.
    @discardableResult public static func configureSyncRelay(
        on routes: any RoutesBuilder, path: [PathComponent] = ["sync"], for schema: [any Lattice.Model.Type],
        storageURL: URL, writePolicy: SyncWritePolicy? = nil, handshake: SyncSchemaHandshake? = nil,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil, observerPush: SyncObserverPush? = nil,
        recoverySource: @escaping @Sendable (SyncChannel) throws -> SyncRecoveryMountConfiguration,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel,
        recoveryAuthorization: @escaping @Sendable (Request, SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization
    ) -> SyncRelayHandle {
        let mount = RecoveryRelayMount(source: recoverySource, upload: writePolicy, authorize: recoveryAuthorization)
        return configureSyncRelayImpl(on: routes, path: path, for: schema, storageURL: storageURL,
            writePolicy: writePolicy, handshake: handshake, storeConfiguration: storeConfiguration,
            observerPush: observerPush, recoveryMount: mount, channelExtractor: channelExtractor)
    }
}

struct RecoveryRelayResolvedSource: Sendable {
    let configuration: SyncRecoveryMountConfiguration
    let policy: Data
}

final class RecoveryRelayLifetime: @unchecked Sendable {
    private struct State { var stopped = false; var authorized = false; var native: RecoveryRelayNativeStop?; var readScope: [String: Set<String>] = [:] }
    private let state = NIOLockedValueBox(State())
    var isStopped: Bool { state.withLockedValue { $0.stopped } }
    var publishable: Bool { state.withLockedValue { !$0.stopped && $0.authorized && ($0.native?.isLive ?? false) } }
    var retiredOrExpired: Bool { state.withLockedValue { $0.stopped || ($0.authorized && !($0.native?.isLive ?? false)) } }
    func didAuthorize(_ scope: SyncRecoveryIncomingScope) {
        var rules: [String: Set<String>] = [:]
        for table in scope.models { rules[table.table] = Set(table.incomingOperations.map(\.rawValue)) }
        for table in scope.relations { rules[table.table] = Set(table.incomingOperations.map(\.rawValue)) }
        state.withLockedValue { $0.readScope = rules; $0.authorized = true }
    }
    func filter(_ page: [AuditLog]) -> [AuditLog] {
        let rules = state.withLockedValue { $0.readScope }
        guard publishable else { return [] }
        return page.filter { rules[$0.tableName]?.contains($0.operation.rawValue) == true }
    }
    func bind(_ native: RecoveryRelayNativeStop) {
        let stop = state.withLockedValue { s in s.native = native; return s.stopped }
        if stop { native.stop() }
    }
    func stop() {
        let native = state.withLockedValue { s in s.stopped = true; return s.native }
        native?.stop()
    }
}
final class RecoveryRelayMount: @unchecked Sendable {
    let id = UUID()
    private let source: @Sendable (SyncChannel) throws -> SyncRecoveryMountConfiguration
    private let upload: SyncWritePolicy?
    let authorize: @Sendable (Request, SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization
    private struct State { var retired = false; var sessions: [UUID: RecoveryRelayLifetime] = [:] }
    private let state = NIOLockedValueBox(State())
    convenience init(configuration: SyncRecoveryMountConfiguration, upload: SyncWritePolicy?,
         authorize: @escaping @Sendable (Request, SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization) throws {
        _ = try configuration.policy(upload)
        self.init(source: { _ in configuration }, upload: upload, authorize: authorize)
    }
    init(source: @escaping @Sendable (SyncChannel) throws -> SyncRecoveryMountConfiguration, upload: SyncWritePolicy?,
         authorize: @escaping @Sendable (Request, SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization) {
        self.source = source; self.upload = upload; self.authorize = authorize
    }
    func resolve(_ channel: SyncChannel) throws -> RecoveryRelayResolvedSource {
        let configuration = try source(channel)
        return .init(configuration: configuration, policy: try configuration.policy(upload))
    }
    func enroll() throws -> (UUID, RecoveryRelayLifetime) {
        // Capacity is checked before adding a connection cell; no native work
        // or app callback runs under this leaf lock.
        try state.withLockedValue { s in
            guard !s.retired, s.sessions.count < 1_024 else { throw SyncRecoveryConfigurationError.invalidBounds }
            let id = UUID(), lifetime = RecoveryRelayLifetime(); s.sessions[id] = lifetime; return (id, lifetime)
        }
    }
    var sessionCount: Int { state.withLockedValue { $0.sessions.count } }
    func remove(_ id: UUID) { _ = state.withLockedValue { $0.sessions.removeValue(forKey: id) } }
    func retire() {
        let stopped = state.withLockedValue { s in s.retired = true; return Array(s.sessions.values) }
        for cell in stopped { cell.stop() }
    }
}
