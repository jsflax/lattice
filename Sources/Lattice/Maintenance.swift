import Foundation

/// What a TRUNCATE checkpoint actually did (``Lattice/checkpoint()``).
///
/// A TRUNCATE checkpoint silently loses to a concurrent reader; an ignored
/// outcome is how multi-GB WAL files accumulate. `complete` is the only
/// value that means "the -wal is empty again".
public struct CheckpointResult: Sendable, Equatable {
    /// A reader/writer held the WAL — nothing could run this time.
    public let busy: Bool
    /// Every WAL frame folded back and the -wal truncated.
    public let complete: Bool
    /// Frames in the WAL before the call (-1 when unavailable).
    public let logFrames: Int64
    /// Frames folded back (< `logFrames` = partial).
    public let checkpointed: Int64

    public init(busy: Bool, complete: Bool, logFrames: Int64, checkpointed: Int64) {
        self.busy = busy
        self.complete = complete
        self.logFrames = logFrames
        self.checkpointed = checkpointed
    }
}

/// What ``Lattice/reclaimSpace(maxPasses:)`` did.
///
/// Page counts are the ground truth for "the file shrank" — in WAL mode
/// `VACUUM` writes the rebuilt image into the WAL and the main file only
/// shrinks at the checkpoint that follows, which is why this operation
/// exists as one ordered recipe instead of two calls.
public struct ReclaimResult: Sendable, Equatable {
    /// False when VACUUM threw; `error` carries the message.
    public let ok: Bool
    public let pagesBefore: Int64
    public let pagesAfter: Int64
    /// Bytes left in the -wal after the final checkpoint (≈0 on success).
    public let walBytesAfter: Int64
    /// Passes run (a second pass only when the first checkpoint was busy).
    public let passes: Int
    /// The final TRUNCATE checkpoint lost to a concurrent reader.
    public let checkpointBusy: Bool
    public let error: String

    public init(ok: Bool, pagesBefore: Int64, pagesAfter: Int64, walBytesAfter: Int64,
                passes: Int, checkpointBusy: Bool, error: String) {
        self.ok = ok
        self.pagesBefore = pagesBefore
        self.pagesAfter = pagesAfter
        self.walBytesAfter = walBytesAfter
        self.passes = passes
        self.checkpointBusy = checkpointBusy
        self.error = error
    }

    /// The main file got smaller.
    public var shrank: Bool { pagesAfter >= 0 && pagesBefore >= 0 && pagesAfter < pagesBefore }
}

/// One delivered change, header only — what ``Lattice/changeHeaders`` yields.
///
/// Every in-repo consumer of ``Lattice/changeStream`` reads just the table
/// name and the operation; hydrating the full `AuditLog` row for that
/// (twice — once to build the reference, once to resolve it) read the whole
/// `changedFields` payload per change, which for a streamed 300 KB column was
/// two 300 KB reads per token per process. The header columns precede the
/// payload in the row, so producing this never touches it.
public struct ChangeHeader: Sendable, Equatable {
    /// AuditLog primary key — commit-ordered; a monotone cursor if you need one.
    public let auditId: Int64
    /// The affected model table (or link table).
    public let tableName: String
    public let operation: AuditLog.Operation
    /// The affected row's id in `tableName` (0 for link-table rows).
    public let rowId: Int64
    /// The affected row's globalId, when it has one.
    public let globalRowId: UUID?

    public init(auditId: Int64, tableName: String, operation: AuditLog.Operation, rowId: Int64, globalRowId: UUID?) {
        self.auditId = auditId
        self.tableName = tableName
        self.operation = operation
        self.rowId = rowId
        self.globalRowId = globalRowId
    }
}
