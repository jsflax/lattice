import Foundation

/// Optional backend capability. Unsupported backends refuse instead of reporting a deletion
/// completed when the underlying operation cannot provide that guarantee.
public protocol SyncChannelRetirementBackend: LatticeBackend {
    func removeSyncChannelStateChecked(syncId: String) throws
}

extension Lattice {
    /// Retires a channel's receipts, membership, replication slot, tracking and fresh-peer cutoff.
    /// Stop and destroy its synchronizers first; disconnect alone is insufficient. The native
    /// guard covers this process only: the caller must also stop other processes using this
    /// channel. Call outside an existing transaction so the reservation spans the entire commit.
    /// A successfully retired ID may be reused by a newly created channel.
    ///
    /// Throws without a partial deletion if the channel is active, the file identity cannot be
    /// established, the database operation fails, or this backend lacks the checked capability.
    /// The legacy nonthrowing API reports native failures through onQueryError/lastQueryError.
    public func removeSyncChannelStateChecked(syncId: String) throws {
        guard let retirement = backend as? any SyncChannelRetirementBackend else {
            throw Lattice.Error.databaseError("Checked sync channel retirement is unsupported by this backend")
        }
        try retirement.removeSyncChannelStateChecked(syncId: syncId)
    }

    /// Convenience for the native IPC channel identity ("ipc:" followed by the channel name).
    public func removeSyncChannelStateChecked(ipcChannel channel: String) throws {
        try removeSyncChannelStateChecked(syncId: "ipc:" + channel)
    }
}
