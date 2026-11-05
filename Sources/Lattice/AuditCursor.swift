import Foundation

/// Optional backend capability; unsupported backends fail rather than hydrate full audit records.
public protocol AuditCursorBackend: LatticeBackend {
    func auditCursor() throws -> AuditCursor
}

extension Lattice {
    /// Uses the same owned read/transaction route as other queries. The three scalars are selected
    /// by one statement from main.AuditLog; no changedFields or binary content crosses the bridge.
    public func auditCursor() throws -> AuditCursor {
        guard let reader = backend as? any AuditCursorBackend else {
            throw Lattice.Error.databaseError("Audit cursor is unsupported by this backend")
        }
        return try reader.auditCursor()
    }
}
