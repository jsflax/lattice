import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import LatticeSwiftCppBridge

// ============================================================================
// C++ to Swift Type Conversions via JSON
// ============================================================================

extension AuditLog {
    /// JSON representation that matches C++ audit_log_entry::to_json() format
    private struct CxxAuditLogJSON: Codable {
        let id: Int64
        let globalId: String
        let tableName: String
        let operation: String
        let rowId: Int64
        let globalRowId: String
        let changedFields: [String: AnyProperty]
        let changedFieldsNames: [String]
        let timestamp: String
        let isFromRemote: Bool
        let isSynchronized: Bool
    }

    /// Create a Swift AuditLog from C++ audit_log_entry JSON
    /// Uses JSON serialization to bridge the complex C++ types
    static func fromCxxJSON(_ jsonString: String) throws -> AuditLog {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AuditLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        let decoder = JSONDecoder()
        let json = try decoder.decode(CxxAuditLogJSON.self, from: data)

        let auditLog = AuditLog()

        auditLog.tableName = json.tableName

        // Parse operation
        switch json.operation {
        case "INSERT": auditLog.operation = .insert
        case "UPDATE": auditLog.operation = .update
        case "DELETE": auditLog.operation = .delete
        default: auditLog.operation = .insert
        }

        auditLog.rowId = json.rowId
        auditLog.globalRowId = UUID(uuidString: json.globalRowId)
        auditLog.changedFields = json.changedFields
        auditLog.changedFieldsNames = json.changedFieldsNames

        // Parse timestamp
        if let ts = Double(json.timestamp) {
            auditLog.timestamp = Date(timeIntervalSince1970: ts)
        } else if let date = ISO8601DateFormatter().date(from: json.timestamp) {
            auditLog.timestamp = date
        } else {
            auditLog.timestamp = Date()
        }

        auditLog.isFromRemote = json.isFromRemote
        auditLog.isSynchronized = json.isSynchronized
        auditLog.globalId = UUID(uuidString: json.globalId)  // internal(set): stored @Property

        return auditLog
    }

    /// Create a Swift AuditLog from a C++ audit_log_entry
    /// Uses to_json() on the C++ side and JSON decoding on Swift side
    convenience init(from cxx: lattice.audit_log_entry) {
        let jsonString = String(cxx.to_json())

        do {
            let parsed = try AuditLog.fromCxxJSON(jsonString)
            self.init()
            self.tableName = parsed.tableName
            self.operation = parsed.operation
            self.rowId = parsed.rowId
            self.globalRowId = parsed.globalRowId
            self.changedFields = parsed.changedFields
            self.changedFieldsNames = parsed.changedFieldsNames
            self.timestamp = parsed.timestamp
            self.isFromRemote = parsed.isFromRemote
            self.isSynchronized = parsed.isSynchronized
            self.globalId = parsed.globalId  // internal(set): stored @Property
        } catch {
            // Fallback to empty audit log on parse failure
            self.init()
            self.tableName = ""
            self.rowId = 0
            self.changedFields = [:]
            self.timestamp = Date()
            self.isFromRemote = false
        }
    }

    /// Convert Swift AuditLog to JSON bytes for C++ consumption
    func toCxxJSONBytes() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}

// ============================================================================
// ServerSentEvent
// ============================================================================

public enum ServerSentEvent: Codable {
    // Concrete [AuditLog] rather than `any Sequence<AuditLog>`: the latter is a
    // parameterized existential (iOS-16 runtime floor), and the payload is always
    // materialized to an array on decode/encode anyway. Callers passing a lazy
    // sequence (e.g. a Results Slice) wrap it with `Array(...)`.
    case auditLog([AuditLog])
    case ack([UUID])
    /// Server refused a client frame (relay write-policy). The frame was
    /// neither applied nor fanned out; its entries stay unACKed client-side.
    /// Legacy clients ignore the unknown kind (C++ `from_json` → nullopt).
    case rejected(reason: String)
    /// Server ACCEPTED the frame but could not store these entries (write-lock
    /// contention that outlived the relay's bounded retry, or a per-entry
    /// failure the core contained). The named ids are NOT in the channel
    /// database and were NOT fanned out: release them from in-flight and
    /// resend. Applies are idempotent (`ON CONFLICT(globalId) DO UPDATE`, plus
    /// an already-applied probe per entry), so an immediate resend is safe
    /// even if one of them raced to completion.
    ///
    /// Wire-compatible with every existing client: the C++
    /// `server_sent_event::from_json` dispatches on the presence of
    /// `auditLog` / `ack` / `replayRequest` and returns `nullopt` for anything
    /// else, so a nack frame — which carries neither key — is ignored, and
    /// those clients still recover through their own ack-timeout resend.
    /// Acting on it (an immediate resend) is a client-side change; see the
    /// 1.7.1 changelog.
    case nack(ids: [UUID], reason: String)

    /// §1.7.2 FLOOR HONESTY: the client's claimed catch-up floor (`last-event-id`) names a globalId
    /// the channel's DURABLE history does not contain. Before 1.7.2 this was swallowed silently (the
    /// floor filter dropped, full-history replay, no signal) — the exact shape under which a client
    /// whose acked rows were LOST never learns it should re-upload them. The relay now says so BEFORE
    /// the catch-up pages: `durableHead` is the channel's newest durable audit globalId (nil on an
    /// empty log); `reason` attributes the violation ("server lost history" when the boot ledger shows
    /// the head regressed, "client floor unknown to this channel" otherwise).
    ///
    /// Downlink semantics are unchanged (full replay proceeds; applies are idempotent). This event is
    /// the UPLINK instruction for 1.7.2+ clients: verify local AuditLog above `durableHead`, re-mark
    /// unsynchronized, re-upload. Wire-compatible with every shipped client — fresh JSON keys, so the
    /// C++ `from_json` (dispatching on auditLog/ack/replayRequest presence) returns nullopt and
    /// ignores it: the same discipline nack rode in on. nack itself is NOT reusable here: its ids mean
    /// "not stored — resend these", and a relay that lost history cannot name the ids it lost.
    case floorReset(durableHead: UUID?, reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, auditLog, ack, rejected, nack, nackReason, floorReset, floorReason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "auditLog":
            let logs = try container.decode([AuditLog].self, forKey: .auditLog)
            self = .auditLog(logs)
        case "ack":
            let ids = try container.decode([UUID].self, forKey: .ack)
            self = .ack(ids)
        case "rejected":
            let reason = try container.decode(String.self, forKey: .rejected)
            self = .rejected(reason: reason)
        case "nack":
            let ids = try container.decode([UUID].self, forKey: .nack)
            let reason = try container.decodeIfPresent(String.self, forKey: .nackReason) ?? ""
            self = .nack(ids: ids, reason: reason)
        case "floorReset":
            let head = try container.decodeIfPresent(UUID.self, forKey: .floorReset)
            let reason = try container.decodeIfPresent(String.self, forKey: .floorReason) ?? ""
            self = .floorReset(durableHead: head, reason: reason)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .auditLog(let logs):
            try container.encode("auditLog", forKey: .kind)
            try container.encode(logs, forKey: .auditLog)
        case .ack(let ids):
            try container.encode("ack", forKey: .kind)
            try container.encode(ids, forKey: .ack)
        case .rejected(let reason):
            try container.encode("rejected", forKey: .kind)
            try container.encode(reason, forKey: .rejected)
        case .nack(let ids, let reason):
            // Deliberately NOT keyed `ack`/`auditLog`: the C++ client's
            // `from_json` dispatches on those keys, and a nack must decode to
            // nullopt (ignored) on clients that predate this case — never to
            // an ack of entries the server did not store.
            try container.encode("nack", forKey: .kind)
            try container.encode(ids, forKey: .nack)
            try container.encode(reason, forKey: .nackReason)
        case .floorReset(let durableHead, let reason):
            // Fresh keys, same rationale as nack: the C++ dispatch must see
            // none of auditLog/ack/replayRequest and return nullopt.
            try container.encode("floorReset", forKey: .kind)
            try container.encodeIfPresent(durableHead, forKey: .floorReset)
            try container.encode(reason, forKey: .floorReason)
        }
    }
}

extension Array {
    /// Returns this array split into subarrays of at most `size` elements.
    public func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var chunks: [[Element]] = []
        var idx = 0
        while idx < count {
            let end = Swift.min(idx + size, count)
            chunks.append(Array(self[idx..<end]))
            idx += size
        }
        return chunks
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    
    init(_ value: T) {
        self.value = value
    }
}

extension Lattice {
    public func receive(_ data: Data) throws -> [UUID] {
        let result = backend.receiveSyncData(data).compactMap {
            UUID(uuidString: $0)
        }
        if let lastError = backend.lastReceiveError() {
            throw LatticeError.syncReceiveFailed(lastError)
        }
        return result
    }
    
    /// Audit entries strictly after a primary-key cursor, commit-ordered.
    ///
    /// The pk-cursor twin of `eventsAfter(globalId:)`: the relay's
    /// observer-push pump keeps a monotone `Int64` cursor per socket —
    /// AuditLog ids are commit-ordered by construction (the documented
    /// total-order key, see the delivery contract on `observe(_:)`) — while
    /// the globalId overload stays for the client-dial path, which only
    /// knows its last-event-id UUID.
    ///
    /// Lazy like the globalId overload; use `snapshot(limit:)` to page.
    public func eventsAfter(id: Int64) -> TableResults<AuditLog> {
        objects(AuditLog.self)
            .sortedBy(\.primaryKey, order: .forward)
            .where { $0.primaryKey > id }
    }

    /// `@NoHistory` late-binding for audit rows that leave this process
    /// serialized in Swift (the relay's observer push and connect-time catch-up
    /// encode `AuditLog` rows directly; LatticeCore's own upload path does this
    /// inside `query_audit_log_for_sync`).
    ///
    /// For every UPDATE row whose model declares `noHistoryProperties` that are
    /// listed in `changedFieldsNames` with a null/missing value, the row's
    /// CURRENT value is read and filled in; if the live row is gone, the column
    /// is dropped from both `changedFields` and `changedFieldsNames` (its
    /// DELETE row follows) — a null must never be shipped for a column the
    /// receiver may have declared NOT NULL. The stored audit rows are NEVER
    /// written: a row that needs binding is replaced by a detached copy
    /// (Codable round-trip, `primaryKey` preserved for pk cursors) in the
    /// returned array; rows that need nothing are returned as-is. Invariant:
    /// a peer receives the latest value at push time, not every intermediate
    /// value.
    public func lateBindNoHistory(_ rows: [AuditLog]) -> [AuditLog] {
        var noHistoryByTable: [String: Set<String>] = [:]
        for type in modelTypes where !type.noHistoryProperties.isEmpty {
            noHistoryByTable[type.entityName] = type.noHistoryProperties
        }
        guard !noHistoryByTable.isEmpty else { return rows }
        var out = rows
        for (index, stored) in rows.enumerated() where stored.operation == .update {
            guard let flagged = noHistoryByTable[stored.tableName],
                  let names = stored.changedFieldsNames else { continue }
            // A managed AuditLog writes every assignment back to the store; the
            // relay must not rewrite history it only ships. Work on a copy.
            guard let data = try? JSONEncoder().encode(stored),
                  let row = try? JSONDecoder().decode(AuditLog.self, from: data) else { continue }
            row.primaryKey = stored.primaryKey
            let listed = names.compactMap { $0 }
            let need = listed.filter { col in
                guard flagged.contains(col) else { return false }
                guard let value = row.changedFields[col] else { return true }
                if case .null = value { return true }
                return false
            }
            guard !need.isEmpty, let globalRowId = row.globalRowId else { continue }
            let json = backend.noHistoryLiveValuesJSON(tableName: row.tableName,
                                                       globalRowId: globalRowId.uuidString.lowercased(),
                                                       columns: need)
            let live = (try? JSONDecoder().decode([String: AnyProperty].self, from: Data(json.utf8))) ?? [:]
            var fields = row.changedFields
            var keptNames = names
            for col in need {
                let isNull: Bool
                if let value = live[col], case .null = value { isNull = true } else { isNull = false }
                if let value = live[col], !isNull {
                    fields[col] = value
                } else {
                    fields.removeValue(forKey: col)
                    keptNames.removeAll { $0 == col }
                }
            }
            row.changedFields = fields
            row.changedFieldsNames = keptNames
            out[index] = row
        }
        return out
    }

    /// Get audit log events after a checkpoint as a lazy query.
    /// Use `snapshot(limit:offset:)` to paginate without loading all entries into memory.
    public func eventsAfter(globalId: UUID?) -> TableResults<AuditLog> {
        var results = objects(AuditLog.self)
            .sortedBy(\.primaryKey, order: .forward)
        if let globalId {
            let checkpointId = objects(AuditLog.self)
                .where { $0.globalId == globalId }
                .snapshot(limit: 1)
                .first?
                .primaryKey
            if let checkpointId {
                results = results.where { $0.primaryKey > checkpointId }
            }
        }
        return results
    }
}
