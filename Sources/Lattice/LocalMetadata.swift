import Foundation

extension Lattice {
    /// Read immutable metadata belonging only to this physical store. Reads
    /// do not create a table or row. Nil means a successful lookup found no key;
    /// backend/query failures throw and must never be treated as absence.
    ///
    /// Namespaces are 1–64 ASCII lowercase letters, digits, dots or hyphens,
    /// starting with a letter. `lattice.` is reserved. Keys are 1–512 UTF-8
    /// bytes without NUL; values contain at most 65,536 UTF-8 bytes.
    /// Values are not models, audit history, or part of synchronization.
    public func localMetadata(namespace: String, key: String) throws -> String? {
        guard let provider = backend as? any LocalMetadataBackend else {
            throw Lattice.Error.databaseError("Local metadata is unsupported by this backend")
        }
        return try provider.localMetadata(namespace: namespace, key: key)
    }

    /// Insert one immutable value inside this handle's active `withTransaction`.
    /// Returns false when the key already exists; it never replaces that value.
    /// Mutations in this handle's owning physical store and this insertion
    /// commit or roll back together. This does not promise atomicity for writes
    /// to attached stores. Inside the same transaction, read and validate an
    /// existing value before deciding whether a repeated operation is an exact
    /// replay or a payload conflict.
    ///
    /// No separate connection, model schema migration, audit entry or sync
    /// publication is created for metadata. Ordinary model changes in the
    /// transaction retain their normal auditing and replication behavior.
    @discardableResult
    public func insertLocalMetadataIfAbsent(_ value: String, namespace: String, key: String) throws -> Bool {
        guard TransactionFailureScope.isActive,
              Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash) else {
            throw LatticeError.transactionError("Local metadata insertion requires this handle's checked transaction")
        }
        guard let provider = backend as? any LocalMetadataBackend else {
            let message = "Local metadata is unsupported by this backend"
            TransactionFailureScope.record(message)
            throw Lattice.Error.databaseError(message)
        }
        return try provider.insertLocalMetadataIfAbsent(value, namespace: namespace, key: key)
    }
}
