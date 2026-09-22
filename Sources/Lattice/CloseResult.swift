import Foundation

/// Local teardown observations. Only `drained` observed the active upload
/// queue becoming idle; it is not remote installation or receipt authority.
public struct LatticeCloseResult: Sendable, Equatable {
    public enum SyncState: Int32, Sendable {
        case notAttempted = 0, drained, disconnected, retired, deadlinePending, reentrantPending, failed
        case unavailable = -1
    }
    public let sync: SyncState
    public let cleanupComplete: Bool
    public let failed: Bool
    public let cleanupFailed: Bool
    public let errorMessage: String?
    public let errorMessageUnavailable: Bool
    public init(sync: SyncState, cleanupComplete: Bool, failed: Bool = false,
                cleanupFailed: Bool = false, errorMessage: String? = nil, errorMessageUnavailable: Bool = false) {
        self.sync = sync; self.cleanupComplete = cleanupComplete; self.failed = failed
        self.cleanupFailed = cleanupFailed; self.errorMessage = errorMessage
        self.errorMessageUnavailable = errorMessageUnavailable
    }
}
