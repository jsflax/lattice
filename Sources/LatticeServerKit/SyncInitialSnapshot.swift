import Foundation
import Lattice

/// A detached, single-frame bootstrap for an empty, read-only replica.
/// Build this inside the same transaction that reads all current model rows
/// and the durable audit head. No synthetic entry is written to source history.
public struct SyncInitialSnapshot: Sendable {
    public static let maximumEntries = 25_002
    public static let maximumFrameBytes = 32 * 1024 * 1024

    let frame: Data
    let boundary: Int64
    let entryCount: Int

    public enum Failure: Error {
        case invalidSnapshot, capacity
    }

    /// `inserts` contains the complete current rows, in dependency order.
    /// The unchanged durable head is appended LAST so successful bootstrap
    /// leaves the client's resume UUID in the source's actual audit history.
    /// One frame is not one client database transaction: core may apply chunks.
    /// Its contiguous-success cursor must not reach this last head after a
    /// partial apply; intermediate synthetic floors use existing recovery.
    /// Later live frames retain core's existing partial-apply behavior.
    /// A nil head is valid only for an empty snapshot and empty source log.
    public init(inserts: [AuditLog], durableHead: AuditLog?) throws {
        guard inserts.count < Self.maximumEntries else { throw Failure.capacity }
        var ids = Set<UUID>()
        for entry in inserts {
            guard entry.operation == .insert, let id = entry.globalId,
                  entry.globalRowId != nil, ids.insert(id).inserted else {
                throw Failure.invalidSnapshot
            }
        }
        var entries = inserts
        if let head = durableHead {
            guard let id = head.globalId, !ids.contains(id),
                  let primaryKey = head.primaryKey, primaryKey > 0 else {
                throw Failure.invalidSnapshot
            }
            boundary = primaryKey
            entries.append(head)
        } else {
            guard inserts.isEmpty else { throw Failure.invalidSnapshot }
            boundary = 0
        }
        let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(entries))
        guard encoded.count <= Self.maximumFrameBytes else { throw Failure.capacity }
        frame = encoded
        entryCount = entries.count
    }

    /// Presence is separate from UUID decoding: empty, malformed and encoded
    /// last-event-id parameters must retain the existing reconnect behavior.
    static func hasLastEventID(in query: String?) -> Bool {
        query?.split(separator: "&", omittingEmptySubsequences: false).contains { field in
            let name = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(name).removingPercentEncoding == "last-event-id"
        } ?? false
    }
}
