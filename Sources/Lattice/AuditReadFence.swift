import Foundation

public struct AuditCursor: Equatable, Sendable {
    public let head: Int64
    public let headID: UUID?
    /// Oldest surviving audit sequence, not a schema version or a count of rows.
    public let floor: Int64

    public init(head: Int64, headID: UUID?, floor: Int64) {
        self.head = head; self.headID = headID; self.floor = floor
    }
}

/// One SQL snapshot of the owning store's main audit cursor and cooperative prune/reset generation.
/// A missing generation is explicitly the pre-protocol state. Any cooperative removal creates or
/// changes it, so nil-to-value also invalidates a reader's interval. This is not an integrity proof
/// and cannot detect direct, unlogged database tampering or maintenance by incompatible old writers.
public struct AuditReadFence: Equatable, Sendable {
    public let cursor: AuditCursor
    public let historyGeneration: UUID?
    public init(cursor: AuditCursor, historyGeneration: UUID?) {
        self.cursor = cursor; self.historyGeneration = historyGeneration
    }
}

/// Distinct from AuditCursorBackend: an older/custom backend must not silently omit generation
/// evidence. Implementations capture all fields atomically and fail on missing/malformed tables.
public protocol AuditReadFenceBackend: LatticeBackend {
    func auditReadFence() throws -> AuditReadFence
}

extension Lattice {
    /// Checked, payload-free metadata on the existing owned read/transaction route. This never
    /// creates a history marker and never opens another connection, including on strict read-only.
    public func auditReadFence() throws -> AuditReadFence {
        guard let reader = backend as? any AuditReadFenceBackend else {
            throw Lattice.Error.databaseError("Audit read fence is unsupported by this backend")
        }
        return try reader.auditReadFence()
    }
}
