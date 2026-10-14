#if LATTICE_MANAGED_ATTACHMENT_QUALIFICATION
import Foundation

/// Dedicated exact-pair qualification only. These are observations of actual
/// enrolled owners and resources, never a capability or caller supplied proof.
@_spi(Installation)
public struct ManagedAttachmentResourceFacts: Sendable, Codable {
    public let issued: Bool
    public let throwCleanup: Bool
    public let writerMismatch: Bool
    public let readerMismatch: Bool
    public let closedTarget: Bool
    public let rawDenied: Bool
    public let reentrantDenied: Bool
    public let cleanupComplete: Bool
    public let failedStage: Int
    public var passed: Bool {
        issued && throwCleanup && writerMismatch && readerMismatch && closedTarget &&
            rawDenied && reentrantDenied && cleanupComplete && failedStage == 0
    }
}

extension Lattice {
    @_spi(Installation)
    public func qualifyManagedAttachment(target: Lattice) -> ManagedAttachmentResourceFacts {
        let observed = cxxLatticeRef.qualifyManagedAttachment(target: target.cxxLatticeRef)
        return ManagedAttachmentResourceFacts(issued: observed.issued,
            throwCleanup: observed.throw_cleanup, writerMismatch: observed.writer_mismatch,
            readerMismatch: observed.reader_mismatch, closedTarget: observed.closed_target,
            rawDenied: observed.raw_denied, reentrantDenied: observed.reentrant_denied,
            cleanupComplete: observed.cleanup_complete, failedStage: Int(observed.failed_stage))
    }
}
#endif
