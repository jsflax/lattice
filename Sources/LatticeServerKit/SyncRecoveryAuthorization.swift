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
    public let receiptCoverage: Lattice.RecoverySourceExpectation.ReceiptCoverage?
    public init(authority: String, sourceID: UUID, epoch: UUID, scopeDigest: String, schemaDigest: String,
                receiptNamespace: String, coverageID: String, coverageRevision: Int64, descriptorDigest: String,
                receiptCoverage: Lattice.RecoverySourceExpectation.ReceiptCoverage? = nil) {
        self.authority = authority; self.sourceID = sourceID; self.epoch = epoch
        self.scopeDigest = scopeDigest; self.schemaDigest = schemaDigest; self.receiptNamespace = receiptNamespace
        self.coverageID = coverageID; self.coverageRevision = coverageRevision; self.descriptorDigest = descriptorDigest
        self.receiptCoverage = receiptCoverage
    }
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
    public let receiptCoverage: SyncRecoveryReceiptCoverageAuthorization
    public init(authenticatedUserID: UUID, peer: SyncRecoveryPeerIdentity,
                source: SyncRecoverySourceDescriptor, incomingScope: SyncRecoveryIncomingScope,
                authorizationRevision: String, validForMilliseconds: Int64,
                receiptCoverage: SyncRecoveryReceiptCoverageAuthorization = .namespaceOnly) {
        self.authenticatedUserID = authenticatedUserID; self.peer = peer; self.source = source
        self.incomingScope = incomingScope; self.authorizationRevision = authorizationRevision
        self.validForMilliseconds = validForMilliseconds; self.receiptCoverage = receiptCoverage
    }
}
public struct SyncRecoveryNamespace: Sendable, Codable, Hashable {
    public let namespaceID: String
    public let coverageID: String
    public let revision: Int64
    public init(namespaceID: String, coverageID: String, revision: Int64) {
        self.namespaceID = namespaceID; self.coverageID = coverageID; self.revision = revision
    }
}
/// An application-authorized persistent producer lineage. Reconnects and
/// different legitimate channel peers may map to this same registration only
/// through the application's durable membership evidence. Never infer it from
/// a user ID, peer declaration, path or a newly generated per-connection UUID.
public struct SyncRecoveryProducerRegistration: Sendable, Codable, Equatable {
    public let registrationID: String
    public let incarnation: UUID
    public init(registrationID: String, incarnation: UUID) {
        self.registrationID = registrationID; self.incarnation = incarnation
    }
    var isBounded: Bool { !registrationID.isEmpty && registrationID.utf8.count <= 256 && !registrationID.contains("\0") }
}
/// Exact immutable enrolled namespace entries. Creating this passive recipe
/// does not enroll, resize or migrate an existing canonical source file.
public struct SyncRecoveryReceiptCohort: Sendable, Codable, Equatable {
    public let id: UUID
    public let revision: Int64
    public let namespaces: [SyncRecoveryNamespace]
    public init(id: UUID, revision: Int64, namespaces: [SyncRecoveryNamespace]) throws {
        guard revision > 0, (1...64).contains(namespaces.count),
              namespaces.allSatisfy({ !$0.namespaceID.isEmpty && $0.namespaceID.utf8.count <= 256 && !$0.namespaceID.contains("\0") &&
                  !$0.coverageID.isEmpty && $0.coverageID.utf8.count <= 256 && !$0.coverageID.contains("\0") && $0.revision > 0 }),
              Set(namespaces.map { Data($0.namespaceID.utf8) }).count == namespaces.count
        else { throw SyncRecoveryConfigurationError.invalidBounds }
        self.id = id; self.revision = revision
        self.namespaces = namespaces.sorted { $0.namespaceID.utf8.lexicographicallyPrecedes($1.namespaceID.utf8) }
    }
    private enum CodingKeys: String, CodingKey { case id, revision, namespaces }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: value.decode(UUID.self, forKey: .id), revision: value.decode(Int64.self, forKey: .revision),
                      namespaces: value.decode([SyncRecoveryNamespace].self, forKey: .namespaces))
    }
}
public enum SyncRecoveryReceiptCoveragePolicy: Sendable {
    /// Existing namespace-only schema and wire. No alias authority is granted.
    case singleNamespaceV2
    /// New v3 enrollment requires an explicit large READY profile: either
    /// .bounded48MiBV1 or .bounded48MiBOrphanV1 with its exact grace.
    /// Its persistent source policy permits 16 retained transfers and 1 GiB
    /// of charged storage; the v2 profile remains at 8 transfers and 512 MiB.
    /// The SDK never upgrades the default profile or an existing source file.
    case registeredProducerV3(SyncRecoveryReceiptCohort)
}
public enum SyncRecoveryReceiptCoverageAuthorization: Sendable {
    /// Default for existing v2 sources. This is refused by an enrolled v3 source.
    case namespaceOnly
    case registeredProducer(SyncRecoveryProducerRegistration, cohortID: UUID, cohortRevision: Int64)
}
public enum SyncRecoveryDurability: Sendable { case walFull }
/// Explicit persistent policy selection. Existing sources must reopen with
/// exactly their enrolled profile; this never resizes or adopts a prior file.
public enum SyncRecoveryReadyProfile: Sendable {
    case boundedV1, bounded48MiBV1
    /// Opt in to terminal READY lifecycle recovery with an explicit source
    /// resume grace (1...3_600_000 ms). This is not a receipt outcome, lease
    /// renewal, or authorization extension. Reopen requires the exact enrolled
    /// profile and grace; choosing this case never migrates an existing store.
    case bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: Int64)
    /// Same 16-transfer, 64 MiB aggregate and 2 MiB-per-transfer small envelope.
    case boundedV1OrphanV1(orphanResumeGraceMilliseconds: Int64)
}
public enum SyncRecoveryConfigurationError: Error, Sendable { case invalidBounds, ambiguousPolicy, invalidPeer, staleAuthorization, administrationInProgress }
/// Explicit source enrollment with namespace-only v2 behavior by default.
/// The full registered model/relation closure is authoritative; a filtered
/// scope label is not supported. V3 is an immutable enrollment choice, not
/// an implicit migration of an existing file; reopening requires its exact profile.
public struct SyncRecoveryMountConfiguration: Sendable {
    let authority: String, sourceID: UUID, epoch: UUID, localNamespace: String, receiptNamespace: String
    let namespaces: [SyncRecoveryNamespace], models: [String]
    let maximumAuthorizationMilliseconds: Int64
    let readyProfile: SyncRecoveryReadyProfile
    let receiptCoverage: SyncRecoveryReceiptCoveragePolicy
    let receiptCoverageFact: Lattice.RecoverySourceExpectation.ReceiptCoverage?
    public init(authority: String, sourceID: UUID, epoch: UUID, localNamespace: String,
                namespaces: [SyncRecoveryNamespace], receiptNamespace: String, models: [String],
                durability: SyncRecoveryDurability, maximumAuthorizationMilliseconds: Int64,
                readyProfile: SyncRecoveryReadyProfile = .boundedV1,
                receiptCoverage: SyncRecoveryReceiptCoveragePolicy = .singleNamespaceV2) throws {
        func bounded(_ s: String, _ cap: Int) -> Bool { !s.isEmpty && s.utf8.count <= cap && !s.contains("\0") }
        guard bounded(authority, 256), bounded(localNamespace, 256), bounded(receiptNamespace, 256),
              (1...64).contains(namespaces.count), (1...16).contains(models.count),
              namespaces.allSatisfy({ bounded($0.namespaceID, 256) && bounded($0.coverageID, 256) && $0.revision > 0 }),
              Set(namespaces.map(\.namespaceID)).count == namespaces.count,
              namespaces.contains(where: { $0.namespaceID == localNamespace }),
              namespaces.contains(where: { $0.namespaceID == receiptNamespace }), receiptNamespace != localNamespace,
              models.allSatisfy({ bounded($0, 64) }), Set(models).count == models.count,
              (1...3_600_000).contains(maximumAuthorizationMilliseconds) else { throw SyncRecoveryConfigurationError.invalidBounds }
        switch readyProfile {
        case .bounded48MiBOrphanV1(let grace), .boundedV1OrphanV1(let grace):
            guard (1...3_600_000).contains(grace) else { throw SyncRecoveryConfigurationError.invalidBounds }
        case .boundedV1, .bounded48MiBV1: break
        }
        let coverageFact: Lattice.RecoverySourceExpectation.ReceiptCoverage?
        switch receiptCoverage {
        case .singleNamespaceV2: coverageFact = nil
        case .registeredProducerV3(let cohort):
            switch readyProfile {
            case .boundedV1, .boundedV1OrphanV1: throw SyncRecoveryConfigurationError.invalidBounds
            case .bounded48MiBV1, .bounded48MiBOrphanV1: break
            }
            guard cohort.namespaces.contains(where: { $0.namespaceID.utf8.elementsEqual(receiptNamespace.utf8) }),
                  cohort.namespaces.allSatisfy({ member in namespaces.contains(where: {
                      $0.namespaceID.utf8.elementsEqual(member.namespaceID.utf8) &&
                      $0.coverageID.utf8.elementsEqual(member.coverageID.utf8) && $0.revision == member.revision
                  }) }) else { throw SyncRecoveryConfigurationError.ambiguousPolicy }
            coverageFact = try .init(cohortID: cohort.id, cohortRevision: cohort.revision, namespaces: cohort.namespaces.map(\.namespaceID))
        }
        self.authority = authority; self.sourceID = sourceID; self.epoch = epoch; self.localNamespace = localNamespace
        self.namespaces = namespaces; self.receiptNamespace = receiptNamespace; self.models = models
        self.maximumAuthorizationMilliseconds = maximumAuthorizationMilliseconds
        self.readyProfile = readyProfile; self.receiptCoverage = receiptCoverage; self.receiptCoverageFact = coverageFact
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
        var payload: [String: Any] = ["version": 1, "authority": authority, "sourceID": sourceID.uuidString.lowercased(),
            "epoch": epoch.uuidString.lowercased(), "localNamespace": localNamespace, "namespaces": ns,
            "receiptNamespace": receiptNamespace, "models": models, "walFull": true,
            "maximumAuthorizationMilliseconds": maximumAuthorizationMilliseconds,
            "upload": ["tables": masks, "unlisted": unlisted,
                       "maximumDeletes": upload?.maxDeletesPerFrame ?? 256]]
        if let coverage = receiptCoverageFact {
            payload["version"] = 2
            payload["receiptCoverage"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(coverage))
        }
        switch readyProfile {
        case .boundedV1: break
        case .bounded48MiBV1: payload["readyProfile"] = "bounded48MiBV1"
        case .bounded48MiBOrphanV1(let grace):
            payload["readyProfile"] = "bounded48MiBOrphanV1"
            payload["orphanResumeGraceMilliseconds"] = grace
        case .boundedV1OrphanV1(let grace):
            payload["readyProfile"] = "boundedV1OrphanV1"
            payload["orphanResumeGraceMilliseconds"] = grace
        }
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

/// One pending setup's payload-free stop notification. Lifetime copies and
/// releases it outside its leaf lock; pending callbacks retain their work charge.
final class RecoveryRelaySetupStopObservation: Sendable {
    let stopped: @Sendable () -> Void
    init(_ stopped: @escaping @Sendable () -> Void) { self.stopped = stopped }
}
final class RecoveryRelayLifetime: @unchecked Sendable {
    private struct State { var setupStop: RecoveryRelaySetupStopObservation?; var stopped = false; var authorized = false; var nativeRetired = false; var native: RecoveryRelayNativeStop?; var readScope: [String: Set<String>] = [:] }
    private let state = NIOLockedValueBox(State())
    var isStopped: Bool { state.withLockedValue { $0.stopped } }
    var hasRetiredNative: Bool { state.withLockedValue { $0.nativeRetired } }
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
        let stop = state.withLockedValue { s in
            guard !s.nativeRetired else { return true }
            s.native = native; return s.stopped
        }
        if stop { native.stop() }
    }
    func observeSetupStop(_ observation: RecoveryRelaySetupStopObservation) {
        let stopped = state.withLockedValue { s in
            precondition(s.setupStop == nil)
            if s.stopped { return true }
            s.setupStop = observation; return false
        }
        if stopped { observation.stopped() }
    }
    func removeSetupStop(_ observation: RecoveryRelaySetupStopObservation) {
        let released = state.withLockedValue { s -> RecoveryRelaySetupStopObservation? in
            guard s.setupStop === observation else { return nil }
            let held = s.setupStop; s.setupStop = nil; return held
        }
        withExtendedLifetime(released) {}
    }
    func stop() {
        let (native, observation) = state.withLockedValue { s in
            s.stopped = true
            let observation = s.setupStop; s.setupStop = nil
            return (s.native, observation)
        }
        native?.stop()
        observation?.stopped()
    }
    /// Called after the actual setup is released on its file IO lane. A closed
    /// socket can retain this cell indefinitely; it must not keep the native
    /// source budget alive. Outstanding results retain their own fence/charge
    /// and still prevent native migration until their real settlement.
    func finishNativeRetirement() {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        let released = state.withLockedValue { s in
            precondition(s.stopped)
            s.nativeRetired = true
            let held = s.native; s.native = nil; return held
        }
        withExtendedLifetime(released) {}
    }
    func reserveReady(bytes: Int) throws -> RecoveryRelayNativeCharge {
        let native = state.withLockedValue { s in !s.stopped && s.authorized ? s.native : nil }
        guard let native else { throw SyncRecoveryConfigurationError.staleAuthorization }
        return try native.reserveReady(bytes: bytes)
    }
}
final class RecoveryRelayMount: @unchecked Sendable {
    let id = UUID()
    private let source: @Sendable (SyncChannel) throws -> SyncRecoveryMountConfiguration
    private let upload: SyncWritePolicy?
    let authorize: @Sendable (Request, SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization
    private struct State { var retired = false; var migration = false; var sessions: [UUID: RecoveryRelayLifetime] = [:] }
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
    var retiredNativeSessionCount: Int {
        let sessions = state.withLockedValue { Array($0.sessions.values) }
        return sessions.filter(\.hasRetiredNative).count
    }
    func reserveMigration() -> Bool {
        state.withLockedValue { s in
            guard s.retired, !s.migration else { return false }
            s.migration = true; return true
        }
    }
    func releaseMigration() { state.withLockedValue { $0.migration = false } }
    func migrationPolicies(_ channel: SyncChannel, cohort: SyncRecoveryReceiptCohort) throws -> (Data, Data, SyncRecoveryMountConfiguration) {
        let prior = try resolve(channel)
        guard case .singleNamespaceV2 = prior.configuration.receiptCoverage else { throw SyncRecoveryConfigurationError.ambiguousPolicy }
        let c = prior.configuration
        let targetProfile: SyncRecoveryReadyProfile
        switch c.readyProfile {
        case .boundedV1, .bounded48MiBV1: targetProfile = .bounded48MiBV1
        case .boundedV1OrphanV1: throw SyncRecoveryConfigurationError.ambiguousPolicy
        case .bounded48MiBOrphanV1(let grace):
            // Receipt migration preserves an already-enrolled lifecycle
            // policy. It cannot enable lifecycle or change its grace.
            targetProfile = .bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: grace)
        }
        let next = try SyncRecoveryMountConfiguration(authority: c.authority, sourceID: c.sourceID, epoch: c.epoch,
            localNamespace: c.localNamespace, namespaces: c.namespaces, receiptNamespace: c.receiptNamespace,
            models: c.models, durability: .walFull, maximumAuthorizationMilliseconds: c.maximumAuthorizationMilliseconds,
            readyProfile: targetProfile, receiptCoverage: .registeredProducerV3(cohort))
        return (prior.policy, try next.policy(upload), next)
    }
    func lifecyclePolicies(_ channel: SyncChannel, grace: Int64,
        retainedTransfers: SyncRecoveryRetainedTransfers) throws -> (Data, Data, SyncRecoveryMountConfiguration) {
        let prior = try resolve(channel), c = prior.configuration
        let target: SyncRecoveryReadyProfile
        switch retainedTransfers { case .preserveCompleted: break }
        switch c.readyProfile {
        case .boundedV1: target = .boundedV1OrphanV1(orphanResumeGraceMilliseconds: grace)
        case .bounded48MiBV1: target = .bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: grace)
        case .boundedV1OrphanV1, .bounded48MiBOrphanV1: throw SyncRecoveryConfigurationError.ambiguousPolicy
        }
        let next = try SyncRecoveryMountConfiguration(authority: c.authority, sourceID: c.sourceID, epoch: c.epoch,
            localNamespace: c.localNamespace, namespaces: c.namespaces, receiptNamespace: c.receiptNamespace,
            models: c.models, durability: .walFull, maximumAuthorizationMilliseconds: c.maximumAuthorizationMilliseconds,
            readyProfile: target, receiptCoverage: c.receiptCoverage)
        return (prior.policy, try next.policy(upload), next)
    }
    func remove(_ id: UUID) { _ = state.withLockedValue { $0.sessions.removeValue(forKey: id) } }
    func retire() {
        let stopped = state.withLockedValue { s in s.retired = true; return Array(s.sessions.values) }
        for cell in stopped { cell.stop() }
    }
}
