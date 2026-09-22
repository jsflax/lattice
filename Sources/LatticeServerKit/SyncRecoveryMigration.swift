import Lattice

/// The receipt migration establishes a new source profile only. Existing
/// historical receipts remain legacy-unbound and retain their original
/// namespace; no producer lineage or cross-namespace acceptance is invented.
public enum SyncRecoveryMigrationOutcome: Sendable {
    case migrated(SyncRecoveryMountConfiguration)
    case pendingQuiescence
}
