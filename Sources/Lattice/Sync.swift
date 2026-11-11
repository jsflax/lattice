import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import LatticeSwiftCppBridge

extension Lattice {
    /// Maximum encoded audit JSON bytes per sync message. The same Core value
    /// governs client upload and relay fan-out/catch-up/observer publication. Relay
    /// ingress retains its larger legacy limit for older clients.
    public static var maximumEncodedSyncMessageBytes: Int {
        Int(lattice.sync_max_encoded_message_bytes_value())
    }
}

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
        let noHistoryNulls: [String]
        let synthesized: Bool

        private enum CodingKeys: String, CodingKey {
            case id, globalId, tableName, operation, rowId, globalRowId, changedFields
            case changedFieldsNames, timestamp, isFromRemote, isSynchronized, noHistoryNulls, synthesized
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            globalId = try c.decode(String.self, forKey: .globalId)
            tableName = try c.decode(String.self, forKey: .tableName)
            operation = try c.decode(String.self, forKey: .operation)
            rowId = try c.decode(Int64.self, forKey: .rowId)
            globalRowId = try c.decode(String.self, forKey: .globalRowId)
            changedFields = try c.decode([String: AnyProperty].self, forKey: .changedFields)
            changedFieldsNames = try c.decode([String].self, forKey: .changedFieldsNames)
            timestamp = try c.decode(String.self, forKey: .timestamp)
            isFromRemote = try c.decode(Bool.self, forKey: .isFromRemote)
            isSynchronized = try c.decode(Bool.self, forKey: .isSynchronized)
            noHistoryNulls = c.contains(.noHistoryNulls)
                ? try c.decode([String].self, forKey: .noHistoryNulls) : []
            synthesized = c.contains(.synthesized) ? try c.decode(Bool.self, forKey: .synthesized) : false
            try AuditLog.validateNoHistoryNullWireValues(from: decoder, names: noHistoryNulls)
        }
    }

    /// Create a Swift AuditLog from C++ audit_log_entry JSON
    /// Uses JSON serialization to bridge the complex C++ types
    static func fromCxxJSON(_ jsonString: String) throws -> AuditLog {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AuditLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        let decoder = JSONDecoder()
        let json = try decoder.decode(CxxAuditLogJSON.self, from: data)
        guard let operation = AuditLog.Operation(rawValue: json.operation) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "Unknown audit operation"))
        }
        if !json.noHistoryNulls.isEmpty && json.operation != "INSERT" && json.operation != "UPDATE" {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "noHistoryNulls requires an INSERT or UPDATE operation"))
        }

        let auditLog = AuditLog()

        auditLog.tableName = json.tableName

        auditLog.operation = operation

        auditLog.rowId = json.rowId
        auditLog.globalRowId = UUID(uuidString: json.globalRowId)
        auditLog.changedFields = json.changedFields
        auditLog.changedFieldsNames = json.changedFieldsNames
        auditLog.noHistoryNulls = json.noHistoryNulls
        auditLog.synthesized = json.synthesized
        try auditLog.validateNoHistoryNulls()

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
            self.noHistoryNulls = parsed.noHistoryNulls
            self.synthesized = parsed.synthesized
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
    /// End of this connection's initial replay pass. The relay sends this
    /// only when the client requests `lattice-catch-up-complete=1`.
    /// It does not certify client uploads or future/live server changes.
    case catchUpComplete
    /// Server refused a client frame (relay write-policy). The frame was
    /// neither applied nor fanned out; its entries stay unACKed client-side.
    /// Clients without explicit support may ignore this control or reconnect;
    /// nullopt is not a universal compatibility guarantee.
    case rejected(reason: String)
    /// Server ACCEPTED the frame but could not store these entries (write-lock
    /// contention that outlived the relay's bounded retry, or a per-entry
    /// failure the core contained). The named ids are NOT in the channel
    /// database and were NOT fanned out: release them from in-flight and
    /// resend. Applies are idempotent (`ON CONFLICT(globalId) DO UPDATE`, plus
    /// an already-applied probe per entry), so an immediate resend is safe
    /// even if one of them raced to completion.
    ///
    /// Older clients may ignore an unsupported nack or reconnect when their
    /// download parser fails closed. A nack must never decode as an ACK of
    /// data that was not stored. Immediate resend requires explicit client
    /// support; otherwise recovery depends on the client's retry policy.
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
    /// unsynchronized, re-upload. Clients with explicit floorReset support validate it as an informational
    /// control: it preserves its committed cursor and upload policy while ordinary downlink replay
    /// applies. Validation alone does not implement uplink repair. Older clients may ignore the control or
    /// reconnect on nullopt; compatibility cannot be inferred from fresh keys. nack is NOT reusable: its ids mean
    /// "not stored — resend these", and a relay that lost history cannot name the ids it lost.
    case floorReset(durableHead: UUID?, reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, auditLog, ack, replayRequest, catchUpComplete, rejected, nack, nackReason, floorReset, floorReason
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
        case "catchUpComplete":
            guard try container.decode(Bool.self, forKey: .catchUpComplete),
                  !container.contains(.auditLog), !container.contains(.ack),
                  !container.contains(.replayRequest), !container.contains(.rejected), !container.contains(.nack),
                  !container.contains(.floorReset) else {
                throw DecodingError.dataCorruptedError(forKey: .catchUpComplete,
                    in: container, debugDescription: "Invalid initial replay completion marker")
            }
            self = .catchUpComplete
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
        case .catchUpComplete:
            try container.encode("catchUpComplete", forKey: .kind)
            try container.encode(true, forKey: .catchUpComplete)
        case .rejected(let reason):
            try container.encode("rejected", forKey: .kind)
            try container.encode(reason, forKey: .rejected)
        case .nack(let ids, let reason):
            // Deliberately NOT keyed `ack`/`auditLog`: a nack must never
            // decode to an ack of entries the server did
            // not store. Unsupported clients may ignore it or reconnect.
            try container.encode("nack", forKey: .kind)
            try container.encode(ids, forKey: .nack)
            try container.encode(reason, forKey: .nackReason)
        case .floorReset(let durableHead, let reason):
            // Distinct validated control, never an audit entry or ACK. The
            // client must earn its next cursor by applying the replay.
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
    /// Appends exact current model rows to the audit stream once per publication
    /// key, preserving previous history. Use only for an authoritative snapshot
    /// inside `withTransaction`; replicas must not certify their partial state.
    @discardableResult public func appendCurrentSnapshots(tables: Set<String>, publicationKey: String) throws -> Int64 {
        guard Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash) else {
            throw LatticeError.transactionError("Snapshot publication requires withTransaction.")
        }
        guard let core = backend as? CxxBackend else { throw LatticeError.syncReceiveFailed("Snapshot publication requires the core backend.") }
        var names = lattice.StringVector()
        for name in tables.sorted() { names.push_back(std.string(name)) }
        let count = core.ref.append_current_snapshots(names, std.string(publicationKey))
        if let error = core.lastQueryError() { throw LatticeError.syncReceiveFailed(error) }
        return count
    }

    /// Makes retained history sufficient to bootstrap a fresh peer. Appends
    /// complete current model and relationship INSERTs where no INSERT remains,
    /// preserving existing audit events, cursors, and replication slots. A tail
    /// containing only UPDATEs does not count as a baseline. Repeated calls are
    /// idempotent until retention removes those baselines again.
    ///
    /// Call only on the authoritative database, inside `withTransaction`.
    /// This does not reconcile a stale replica or certify partial replica state.
    @discardableResult public func ensureCurrentHistory() throws -> Int64 {
        guard Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash) else {
            throw LatticeError.transactionError("History publication requires withTransaction.")
        }
        guard let core = backend as? CxxBackend else {
            throw LatticeError.syncReceiveFailed("History publication requires the core backend.")
        }
        let count = core.ref.ensure_current_history()
        if let error = core.lastQueryError() { throw LatticeError.syncReceiveFailed(error) }
        return count
    }

    /// A consistent, canonical JSON snapshot of every model's global IDs and
    /// all ordinary/polymorphic relationship row identities and endpoints.
    /// Contains no model scalar payloads or audit events. Use inside
    /// `withTransaction` on either authority or replica; compare or hash the
    /// returned value to verify identities/links as well as row counts.
    public func currentIdentitySnapshot() throws -> String {
        guard Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash) else {
            throw LatticeError.transactionError("Identity snapshot requires withTransaction.")
        }
        guard let core = backend as? CxxBackend else {
            throw LatticeError.syncReceiveFailed("Identity snapshot requires the core backend.")
        }
        let snapshot = core.ref.current_identity_snapshot()
        if let error = core.lastQueryError() { throw LatticeError.syncReceiveFailed(error) }
        return String(snapshot)
    }

    /// Reads exact applied-event evidence, including a suppressed no-op's
    /// receipt and equality with a persisted channel cursor after retention.
    /// This does not certify stream completeness or current model/relationship
    /// state; retain application validation. No bookkeeping, schema, or
    /// cursor writes occur. Successful standalone probes emit no result
    /// invalidation or commit notification.
    ///
    /// Standalone calls own a checked backend transaction (and its bounded
    /// reservation). An existing explicit transaction is reused, never ended.
    /// The standalone path intentionally avoids `withTransaction`'s write
    /// invalidation. Its synchronous body only calls Core; it cannot invoke
    /// Swift model reads or arbitrary callbacks inside the unrecorded scope.
    public func hasAppliedSyncEvent(globalID: UUID) throws -> Bool {
        guard let core = backend as? CxxBackend else {
            throw LatticeError.syncReceiveFailed("Applied-event lookup requires the core backend.")
        }
        let ownsTransaction = !Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash)
        if ownsTransaction { try core.beginTransactionChecked() }
        do {
            let applied = core.ref.has_applied_sync_event(std.string(globalID.uuidString.lowercased()))
            if let error = core.lastQueryError() { throw LatticeError.syncReceiveFailed(error) }
            if ownsTransaction { try core.commitChecked() }
            return applied
        } catch {
            if ownsTransaction { core.rollback() }
            throw error
        }
    }

    /// Receives one frame atomically when `immutableTables` is nonempty.
    /// Protected tables accept complete INSERT snapshots only. Identical row
    /// content is replayable; changed content under a previously accepted row
    /// identity fails the whole frame. Table names match case-insensitively.
    /// JSON stored in a text property is compared as text; canonicalize it in
    /// the application. Transport timestamps/row ids and field ordering do not
    /// affect identity. Local writes are not restricted by this receive policy.
    public func receive(_ data: Data, immutableTables: Set<String>, authorize: (() -> Bool)? = nil) throws -> [UUID] {
        guard !immutableTables.isEmpty || authorize != nil else { return try receive(data) }
        let checked: (() -> Bool)? = authorize.map { callback in
            { self._authorizeSyncWrite(callback) }
        }
        return try backend.receiveSyncData(data, immutableTables: immutableTables, authorize: checked)
            .compactMap(UUID.init(uuidString:))
    }

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
    /// DELETE row follows). An observed SQL NULL is retained and marked in
    /// `noHistoryNulls`; a qualified receiver checks its column nullability.
    /// The stored audit rows are NEVER
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
        for (index, stored) in rows.enumerated() where stored.operation != .delete {
            guard let flagged = noHistoryByTable[stored.tableName],
                  let names = stored.changedFieldsNames else { continue }
            // A managed AuditLog writes every assignment back to the store; the
            // relay must not rewrite history it only ships. Work on a copy.
            guard let data = try? JSONEncoder().encode(stored),
                  let row = try? JSONDecoder().decode(AuditLog.self, from: data) else { continue }
            row.primaryKey = stored.primaryKey
            row.noHistoryNulls = []
            let listed = names.compactMap { $0 }
            if row.operation == .insert {
                // INSERT history contains complete values, not placeholders.
                row.noHistoryNulls = listed.filter { col in
                    guard flagged.contains(col), let value = row.changedFields[col] else { return false }
                    if case .null = value { return true }
                    return false
                }.sorted()
                out[index] = row
                continue
            }
            let need = listed.filter { col in
                guard flagged.contains(col) else { return false }
                guard let value = row.changedFields[col] else { return true }
                if case .null = value { return true }
                return false
            }
            guard !need.isEmpty, let globalRowId = row.globalRowId else {
                out[index] = row
                continue
            }
            let json = backend.noHistoryLiveValuesJSON(tableName: row.tableName,
                                                       globalRowId: globalRowId.uuidString.lowercased(),
                                                       columns: need)
            let live = (try? JSONDecoder().decode([String: AnyProperty].self, from: Data(json.utf8))) ?? [:]
            var fields = row.changedFields
            var keptNames = names
            for col in need {
                if let value = live[col] {
                    fields[col] = value
                    if case .null = value { row.noHistoryNulls.append(col) }
                } else {
                    fields.removeValue(forKey: col)
                    keptNames.removeAll { $0 == col }
                }
            }
            row.changedFields = fields
            row.changedFieldsNames = keptNames
            row.noHistoryNulls.sort()
            out[index] = row
        }
        return out
    }

    /// Failures in the checked, outbound `@NoHistory` binding path. The legacy
    /// nonthrowing API above keeps its existing behavior for existing callers.
    public enum NoHistoryBindingError: Swift.Error {
        case queryFailed(String)
        case missingRowIdentity
    }

    /// Late-bind current no-history values without turning a failed read into a
    /// successful omission. Query errors are captured immediately, before another
    /// model getter/setter can clear the bridge's thread-local error slot. Codable
    /// failures also propagate; callers must not advance their cursor on failure.
    public func lateBindNoHistoryChecked(_ rows: [AuditLog]) throws -> [AuditLog] {
        try _lateBindNoHistoryChecked(rows) { table, id, columns in
            let json = backend.noHistoryLiveValuesJSON(tableName: table,
                globalRowId: id.uuidString.lowercased(), columns: columns)
            if let error = lastQueryError() { throw NoHistoryBindingError.queryFailed(error) }
            // A closed native connection can return an empty result without a sealed
            // error. Check it before interpreting `{}` as a legitimately deleted row.
            _ = try auditCursor()
            return json
        }
    }

    /// Internal synchronous seam: the production closure performs the checked native
    /// read above; tests can supply malformed bridge output without corrupting a store.
    func _lateBindNoHistoryChecked(_ rows: [AuditLog],
        liveValuesJSON: (String, UUID, [String]) throws -> String) throws -> [AuditLog] {
        var noHistoryByTable: [String: Set<String>] = [:]
        for type in modelTypes where !type.noHistoryProperties.isEmpty {
            noHistoryByTable[type.entityName] = type.noHistoryProperties
        }
        guard !noHistoryByTable.isEmpty else { return rows }
        var out = rows
        for (index, stored) in rows.enumerated() where stored.operation != .delete {
            guard let flagged = noHistoryByTable[stored.tableName],
                  let names = stored.changedFieldsNames else { continue }
            let data = try JSONEncoder().encode(stored)
            let row = try JSONDecoder().decode(AuditLog.self, from: data)
            row.primaryKey = stored.primaryKey
            row.noHistoryNulls = []
            let listed = names.compactMap { $0 }
            if row.operation == .insert {
                row.noHistoryNulls = listed.filter { col in
                    guard flagged.contains(col), let value = row.changedFields[col] else { return false }
                    if case .null = value { return true }
                    return false
                }.sorted()
                out[index] = row
                continue
            }
            let need = listed.filter { col in
                guard flagged.contains(col) else { return false }
                guard let value = row.changedFields[col] else { return true }
                if case .null = value { return true }
                return false
            }
            guard !need.isEmpty else {
                out[index] = row
                continue
            }
            guard let globalRowId = row.globalRowId else { throw NoHistoryBindingError.missingRowIdentity }
            let json = try liveValuesJSON(row.tableName, globalRowId, need)
            let live = try JSONDecoder().decode([String: AnyProperty].self, from: Data(json.utf8))
            var fields = row.changedFields
            var keptNames = names
            for col in need {
                if let value = live[col] {
                    fields[col] = value
                    if case .null = value { row.noHistoryNulls.append(col) }
                } else {
                    fields.removeValue(forKey: col)
                    keptNames.removeAll { $0 == col }
                }
            }
            row.changedFields = fields
            row.changedFieldsNames = keptNames
            row.noHistoryNulls.sort()
            try row.validateNoHistoryNulls()
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
