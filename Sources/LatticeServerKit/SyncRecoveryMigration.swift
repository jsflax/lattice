import Foundation
import Lattice

/// The receipt migration establishes a new source profile only. Existing
/// historical receipts remain legacy-unbound and retain their original
/// namespace; no producer lineage or cross-namespace acceptance is invented.
public enum SyncRecoveryMigrationOutcome: Sendable {
    case migrated(SyncRecoveryMountConfiguration)
    case pendingQuiescence
}

/// Validated value-only administration inputs. The provider still defines the
/// mount's declared version, but cannot redirect or configure the native owner.
struct RecoveryReceiptAdministrativeOpen: Sendable {
    let fileURL: URL
    let schemaVersion: Int64
    let busyTimeoutMilliseconds: Int32

    static func resolve(fileURL: URL,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)?) throws -> Self {
        let configuration = SyncRelayApplyPolicy.configuration(fileURL: fileURL, storeConfiguration: storeConfiguration)
        guard fileURL.isFileURL, case .file(let selected) = configuration.storage,
              selected.isFileURL, selected.standardizedFileURL == fileURL.standardizedFileURL,
              !configuration.isReadOnly, configuration.wssEndpoint == nil,
              configuration.ipcTargets?.isEmpty != false, configuration.auditRetention == nil || configuration.auditRetention == 0,
              configuration.recoverySourceExpectation == nil,
              configuration.busyTimeoutMs >= 0, configuration.busyTimeoutMs <= 30_000 else {
            throw SyncRecoveryConfigurationError.ambiguousPolicy
        }
        let versions = configuration.migration?.keys.map { $0 } ?? []
        guard versions.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }) else {
            throw SyncRecoveryConfigurationError.invalidBounds
        }
        // Same declared version as ordinary mount construction, without ever
        // invoking a migration body or passing its schema recipes to native IO.
        return .init(fileURL: fileURL.standardizedFileURL, schemaVersion: Int64(versions.max() ?? 1),
                     busyTimeoutMilliseconds: Int32(configuration.busyTimeoutMs))
    }
}

/// Preserve bytes during adoption; the explicit grace starts at the first
/// actual target enrollment. Later expiry may retire transport capsules only.
public enum SyncRecoveryRetainedTransfers: Sendable { case preserveCompleted }
public enum SyncRecoveryAdministrationPhase: Sendable {
    case refused, rolledBack, committed, unsettled, ownershipLost, unrecognized(Int32)
}
/// Errors and COMMIT truth are independent. Neither an error nor an unknown
/// result proves receipt absence, rollback, receiver installation or safe replay.
public struct SyncRecoveryAdministrationSettlement: Sendable {
    public let phase: SyncRecoveryAdministrationPhase
    public let unexpectedCommitObserved: Bool
    public let hasError: Bool
    public let primaryError, cleanupError, postcommitError, notificationError: String?
    init(_ value: RecoveryRelayLifecycleNativeOutcome) {
        switch value.phase {
        case 0: phase = .refused
        case 1: phase = .rolledBack
        case 2: phase = .committed
        case 3: phase = .unsettled
        case 4: phase = .ownershipLost
        default: phase = .unrecognized(value.phase)
        }
        unexpectedCommitObserved = value.unexpectedCommitObserved
        hasError = value.hasError || value.postcommitError != nil
        primaryError = value.primaryError; cleanupError = value.cleanupError
        postcommitError = value.postcommitError; notificationError = value.notificationError
    }
}
public enum SyncRecoveryLifecycleAdoptionDisposition: Sendable { case applied, verifiedExisting }
/// Passive source-owner fact. Receivers must acquire their own authenticated
/// predecessor proof; this value is never a source/route/receipt admission.
public struct SyncRecoveryLifecycleTransition: Sendable {
    public let id: UUID
    public let recordDigest: String
    public let disposition: SyncRecoveryLifecycleAdoptionDisposition
    public let retainedTransfers: SyncRecoveryRetainedTransfers
    public let configuration: SyncRecoveryMountConfiguration
}
public struct SyncRecoveryLifecycleAdoptionResult: Sendable {
    public let settlement: SyncRecoveryAdministrationSettlement
    public let transition: SyncRecoveryLifecycleTransition?
    init(_ value: RecoveryRelayLifecycleNativeOutcome, configuration: SyncRecoveryMountConfiguration) {
        settlement = .init(value)
        if value.phase == 2, let id = value.transitionID, let digest = value.recordDigest,
           value.disposition == 1 || value.disposition == 2 {
            transition = .init(id: id, recordDigest: digest,
                disposition: value.disposition == 1 ? .applied : .verifiedExisting,
                retainedTransfers: .preserveCompleted, configuration: configuration)
        } else { transition = nil }
    }
}
public enum SyncRecoveryLifecycleAdoptionOutcome: Sendable {
    /// Only the physical registry refused before administrative file open.
    case pendingQuiescence
    case settled(SyncRecoveryLifecycleAdoptionResult)
}
