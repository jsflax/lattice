import Foundation
import CxxStdlib
import LatticeSwiftCppBridge

/// Explicit storage declarations for a fresh continuous producer. These labels
/// and incoming claim bytes do not authenticate a peer, source, or receipt.
/// Existing stores require a separately validated adoption path, not a rename.
public struct ContinuousProducerContribution: Sendable {
    public let channel, authority, source, epoch, scope, schema: String
    public let profileDigest, receiptNamespace: String
    public let models: [String]
    public let incomingGrantClaim: Data
    public init(channel: String, authority: String, source: String, epoch: String,
                scope: String, schema: String, profileDigest: String, receiptNamespace: String,
                models: [String], incomingGrantClaim: Data) {
        self.channel = channel; self.authority = authority; self.source = source; self.epoch = epoch
        self.scope = scope; self.schema = schema; self.profileDigest = profileDigest
        self.receiptNamespace = receiptNamespace; self.models = models; self.incomingGrantClaim = incomingGrantClaim
    }
}
public struct ContinuousProducerRoute: Sendable {
    public let syncID, endpoint: String
    public init(syncID: String, endpoint: String) { self.syncID = syncID; self.endpoint = endpoint }
}
/// Explicit finite storage and admission caps. They include retained evidence;
/// exhausting a cap refuses work. No queue, automatic evidence pruning, or
/// delivery guarantee is implied. Zero, excessive and inconsistent caps refuse.
public struct ContinuousProducerLimits: Sendable {
    public let scopes, records, fieldBytes, journalBytes: Int
    public let channels, bindingFieldBytes, bindingBytes: Int
    public let profiles, stamps, producerFieldBytes, manifestBytes, producerBytes: Int
    public let owners, physicalRoutes, operations, frozenEntries, frozenBytes: Int
    public init(scopes: Int, records: Int, fieldBytes: Int, journalBytes: Int,
                channels: Int, bindingFieldBytes: Int, bindingBytes: Int,
                profiles: Int, stamps: Int, producerFieldBytes: Int, manifestBytes: Int, producerBytes: Int,
                owners: Int, physicalRoutes: Int, operations: Int, frozenEntries: Int, frozenBytes: Int) {
        self.scopes = scopes; self.records = records; self.fieldBytes = fieldBytes; self.journalBytes = journalBytes
        self.channels = channels; self.bindingFieldBytes = bindingFieldBytes; self.bindingBytes = bindingBytes
        self.profiles = profiles; self.stamps = stamps; self.producerFieldBytes = producerFieldBytes
        self.manifestBytes = manifestBytes; self.producerBytes = producerBytes
        self.owners = owners; self.physicalRoutes = physicalRoutes; self.operations = operations
        self.frozenEntries = frozenEntries; self.frozenBytes = frozenBytes
    }
}
/// Opt-in to the actual retained Swift owner and generated local provenance.
/// The file must be `store.sqlite` in an exclusively created directory whose
/// name ends in `.lattice-continuous`. Reopen requires the exact durable profile,
/// full Swift declarations and canonical physical identity. Multiple admitted
/// owners and channels may share rows. Legacy/raw writable paths refuse.
/// This surface does not activate authentication, installation or recovery.
public struct ContinuousProducerPolicy: Sendable {
    public let contributions: [ContinuousProducerContribution]
    public let routes: [ContinuousProducerRoute]
    public let limits: ContinuousProducerLimits
    public init(contributions: [ContinuousProducerContribution], routes: [ContinuousProducerRoute], limits: ContinuousProducerLimits) {
        self.contributions = contributions; self.routes = routes; self.limits = limits
    }
    internal func native() throws -> lattice.continuous_policy {
        func bounded(_ value: String, _ limit: Int) -> Bool { !value.isEmpty && value.utf8.count <= limit }
        guard (1...16).contains(contributions.count), (1...32).contains(routes.count) else {
            throw ContinuousProducerError.invalidPolicy
        }
        for c in contributions {
            guard [c.channel, c.authority, c.source, c.epoch, c.scope, c.schema, c.profileDigest, c.receiptNamespace].allSatisfy({ bounded($0, 4096) }),
                  (1...16).contains(c.models.count), c.models.allSatisfy({ bounded($0, 128) }),
                  (1...65_536).contains(c.incomingGrantClaim.count) else { throw ContinuousProducerError.invalidPolicy }
        }
        guard routes.allSatisfy({ bounded($0.syncID, 4096) && bounded($0.endpoint, 4096) }) else {
            throw ContinuousProducerError.invalidPolicy
        }
        var value = lattice.continuous_policy()
        let l = limits
        value.scopes = Int64(l.scopes); value.records = Int64(l.records)
        value.field_bytes = Int64(l.fieldBytes); value.journal_bytes = Int64(l.journalBytes)
        value.channels = Int64(l.channels); value.binding_field_bytes = Int64(l.bindingFieldBytes); value.binding_bytes = Int64(l.bindingBytes)
        value.profiles = Int64(l.profiles); value.stamps = Int64(l.stamps); value.producer_field_bytes = Int64(l.producerFieldBytes)
        value.manifest_bytes = Int64(l.manifestBytes); value.producer_bytes = Int64(l.producerBytes)
        value.owners = Int64(l.owners); value.physical_routes = Int64(l.physicalRoutes); value.operations = Int64(l.operations)
        value.frozen_entries = Int64(l.frozenEntries); value.frozen_bytes = Int64(l.frozenBytes)
        for c in contributions {
            var entry = lattice.continuous_contribution()
            entry.channel = std.string(c.channel); entry.authority = std.string(c.authority)
            entry.source = std.string(c.source); entry.epoch = std.string(c.epoch)
            entry.scope = std.string(c.scope); entry.schema = std.string(c.schema)
            entry.profile_digest = std.string(c.profileDigest); entry.receipt_namespace = std.string(c.receiptNamespace)
            for name in c.models { entry.models.push_back(std.string(name)) }
            for byte in c.incomingGrantClaim { entry.incoming_grant_claim.push_back(byte) }
            value.contributions.push_back(entry)
        }
        for r in routes {
            var entry = lattice.continuous_route()
            entry.sync_id = std.string(r.syncID); entry.endpoint = std.string(r.endpoint)
            value.routes.push_back(entry)
        }
        return value
    }
}
public enum ContinuousProducerPhase: Int32, Sendable {
    case refused = 0, rolledBack, committed, unsettled, ownershipLost
}
/// `committed` records a known native COMMIT even if later pointer-cache,
/// registry, notifier or transport publication failed. An error never implies
/// rollback, remote cancellation, ACK, successful install or a safe overwrite.
public struct ContinuousProducerSettlement: Sendable {
    public let phase: ContinuousProducerPhase
    public let unexpectedCommitObserved: Bool
    public let primaryError, cleanupError, postcommitError, notificationError: String?
    public let hasError: Bool
    internal init(_ value: lattice.continuous_result) {
        func message(_ value: std.string) -> String? { let text = String(value); return text.isEmpty ? nil : text }
        phase = ContinuousProducerPhase(rawValue: value.phase()) ?? .refused
        unexpectedCommitObserved = value.unexpectedCommit(); hasError = value.hasError()
        primaryError = message(value.primaryError()); cleanupError = message(value.cleanupError())
        postcommitError = message(value.postcommitError()); notificationError = message(value.notificationError())
    }
}
public enum ContinuousProducerError: Error, Sendable {
    case invalidPolicy, migrationUnsupported, unsupportedBackend
    case open(ContinuousProducerSettlement)
}
/// Not Sendable. Keep this handle and its last release on the owner's executor.
/// Copies on the native side retain one actual barrier identity. There is no
/// public verified-UNSENT constructor or installation admission on this type.
public final class ContinuousProducerBarrier {
    private let value: lattice.continuous_barrier
    fileprivate init(_ value: lattice.continuous_barrier) { self.value = value }
    /// Nonblocking: waiting requires a later turn on the existing scheduler.
    public func finish() -> ContinuousProducerResult { .init(value.finish()) }
    /// Reopens local admission only after exact durable cancellation commits.
    /// It does not establish remote cancellation or remote quiescence.
    public func cancel() -> ContinuousProducerSettlement { .init(value.cancel()) }
}
public struct ContinuousProducerResult {
    public let settlement: ContinuousProducerSettlement
    public let waiting, frozen: Bool
    public let localUnsentCount: Int64
    public let barrier: ContinuousProducerBarrier?
    fileprivate init(_ value: lattice.continuous_result) {
        settlement = .init(value); waiting = value.waiting(); frozen = value.frozen()
        localUnsentCount = value.localUnsentCount()
        let token = value.barrier(); barrier = token.isValid() ? .init(token) : nil
    }
}
extension Lattice {
    /// Must run on this owner's executor, like its transaction operations.
    public func beginContinuousProducerBarrier(attempt: Int64) throws -> ContinuousProducerResult {
        guard let ref = backend.asCxxLatticeRef else { throw ContinuousProducerError.unsupportedBackend }
        return .init(ref.beginContinuous(attempt: attempt))
    }
    /// Inspect a durable closed barrier after a supported same-file reopen.
    public func inspectContinuousProducer() throws -> ContinuousProducerResult {
        guard let ref = backend.asCxxLatticeRef else { throw ContinuousProducerError.unsupportedBackend }
        return .init(ref.inspectContinuous())
    }
}
