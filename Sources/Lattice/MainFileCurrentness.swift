import Foundation

/// An optional checked capability. A custom/older backend cannot silently claim
/// that its live primary file still matches the pathname.
public protocol MainFileCurrentnessBackend: LatticeBackend {
    func requireMainFileUnmoved(expectedPath: String) throws
}

extension Lattice {
    /// Ask the exact owned primary SQLite connection's VFS whether its main file
    /// still occupies the opened pathname. `expectedPath` must be the caller's
    /// expected opened main filename, matching the Core `mainFilePath()` accessor
    /// byte-for-byte (at most 4096 UTF-8 bytes, without NUL). This checks the open
    /// filename, not whether a separately configured alias still resolves to it.
    /// No SQL, schema writes, new connection,
    /// credential access or network work is performed. Closed/memory databases and
    /// unsupported VFS/backends fail closed.
    ///
    /// This is a current-state probe, not a physical identity receipt or a lock on
    /// the filesystem namespace. It cannot detect a swap-away-and-back between
    /// probes. Callers still bracket their operation with this check and compare
    /// their independently owned reader's file identity and logical read fences.
    public func requireMainFileUnmoved(expectedPath: String) throws {
        guard !expectedPath.isEmpty, expectedPath.utf8.count <= 4096, !expectedPath.utf8.contains(0) else {
            throw Lattice.Error.databaseError("Main file currentness expected path is invalid")
        }
        guard let checker = backend as? any MainFileCurrentnessBackend else {
            throw Lattice.Error.databaseError("Main file currentness is unsupported by this backend")
        }
        try checker.requireMainFileUnmoved(expectedPath: expectedPath)
    }
}
