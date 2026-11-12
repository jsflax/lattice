import Foundation
import Lattice

/// One bounded message and the exact prefix it contains. Managed handles never
/// leave the synchronous preparation route; callers send bytes and scalar IDs.
struct BoundedAuditFrame {
    let data: Data
    let count: Int
    let lastID: Int64?
    let ids: [UUID?]
    /// Includes filtered rows, but never a visible row rejected by the byte cap.
    let scannedCount: Int
    let scannedLastID: Int64?

    enum Failure: Error, CustomStringConvertible {
        case invalidLimit, missingRow, queryFailed
        var description: String {
            switch self {
            case .invalidLimit: "Invalid encoded sync message byte limit"
            case .missingRow: "Audit row became unavailable during sync preparation"
            case .queryFailed: "Audit query failed during sync preparation"
            }
        }
    }

    /// Loads/encodes one row at a time, retaining only the emitted prefix. A row
    /// that does not fit after an emitted row is left for the next page. A first
    /// visible row that exceeds the byte budget is sent alone so it cannot block
    /// the cursor or the rows after it.
    /// The relay re-encodes stored rows and adds an envelope, so the client's
    /// per-row hard limit must not be applied to the resulting one-row frame.
    /// A single row encoder may allocate that row; this is not a hostile-parser
    /// or pre-hydration allocation limit.
    /// `nil` means a successful end-of-page read. Query failures must throw;
    /// no whole-tail COUNT is needed before starting a bounded page.
    static func encode(start: Int, maxCount: Int,
                       maximumBytes: Int = Lattice.maximumEncodedSyncMessageBytes,
                       including: (AuditLog) -> Bool = { _ in true },
                       didPrepare: (([AuditLog]) -> Void)? = nil,
                       rowAt: (Int) throws -> AuditLog?) throws -> Self {
        let prefix = Data(#"{"kind":"auditLog","auditLog":["#.utf8)
        let suffix = Data("]}".utf8)
        let envelope = prefix.count + suffix.count
        guard maximumBytes > envelope, start >= 0, maxCount > 0 else { throw Failure.invalidLimit }
        var data = prefix
        var count = 0
        var scannedCount = 0
        var scannedLastID: Int64?
        var lastID: Int64?
        var ids: [UUID?] = []
        var diagnosticRows: [AuditLog] = []
        let encoder = JSONEncoder()
        for offset in 0..<maxCount {
            guard offset <= Int.max - start else { throw Failure.invalidLimit }
            guard let row = try rowAt(start + offset) else { break }
            if !including(row) {
                scannedCount += 1
                scannedLastID = row.primaryKey
                continue
            }
            let encoded = try encoder.encode(row)
            let separator = count == 0 ? 0 : 1
            guard count == 0 || encoded.count + separator <= maximumBytes - suffix.count - data.count else { break }
            if separator != 0 { data.append(0x2c) }
            data.append(encoded)
            count += 1
            scannedCount += 1
            scannedLastID = row.primaryKey
            lastID = row.primaryKey
            ids.append(row.globalId)
            if didPrepare != nil { diagnosticRows.append(row) }
        }
        data.append(suffix)
        didPrepare?(diagnosticRows) // synchronous only; managed rows are dropped before return
        return Self(data: data, count: count, lastID: lastID, ids: ids,
                    scannedCount: scannedCount, scannedLastID: scannedLastID)
    }

    /// Run synchronously on the existing store IO route. Materializing the single
    /// selected audit row avoids re-fetching its fields during JSON encoding.
    /// Check the thread-local query error before any subsequent database call.
    static func nextRow(in lattice: Lattice, events: TableResults<AuditLog>, after: Int64) throws -> AuditLog? {
        let rows = events.where { $0.primaryKey > after }.materializedSnapshot(limit: 1)
        guard lattice.lastQueryError() == nil else { throw Failure.queryFailed }
        guard let stored = rows.first else {
            // Some native closed-handle reads return an empty vector without a sealed error.
            // This scalar checked read distinguishes that failure from a real empty tail.
            _ = try lattice.auditCursor()
            return nil
        }
        let bound = try lattice.lateBindNoHistoryChecked([stored])
        guard let row = bound.first else { throw Failure.missingRow }
        return row
    }
}
