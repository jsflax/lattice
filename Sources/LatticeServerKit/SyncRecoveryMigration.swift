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
