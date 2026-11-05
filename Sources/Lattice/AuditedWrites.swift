extension Lattice {
    /// Explicitly prepare a physical store for a role that requires audited
    /// local writes. This validates the native sync-control state and, in its
    /// own checked write transaction, enables auditing if a legacy operation
    /// left it disabled. Generic store opening preserves the existing policy.
    ///
    /// Call outside `withTransaction`, only after deciding that a new write is
    /// authorized. This creates no model or audit records and does not repair
    /// historical unaudited changes. A caller requiring replication must still
    /// verify its own mutation's audit event in the mutation transaction.
    /// Returns true only when the stored disabled flag changed.
    @discardableResult
    public func prepareForAuditedWrites() throws -> Bool {
        guard !TransactionFailureScope.isActive,
              !Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash) else {
            throw LatticeError.transactionError("Audited-write preparation requires its own transaction")
        }
        guard let provider = backend as? any AuditedWritesBackend else {
            throw Lattice.Error.databaseError("Audited-write preparation is unsupported by this backend")
        }
        return try provider.prepareForAuditedWrites()
    }
}
