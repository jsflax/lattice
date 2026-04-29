import Foundation

// `@Codable` is intentionally NOT applied here.
//
// The macro auto-synthesises `init(from:)` / `encode(to:)` using
// Foundation's default `UUID: Codable`, which round-trips UUIDs via
// `.uuidString` — UPPERCASE in Swift's standard form. That contradicts
// the storage invariant Lattice maintains everywhere else (lowercase
// globalIds in SQLite — see Model.swift `setField`, Accessor.swift
// `setUUID`, `bind_managed`'s lowercase pass, `generate_global_id`'s
// std::hex output). Sync replay tunnels audit-log entries through
// JSONEncoder twice (once on the relay's encode, once on the peer's
// `toCxxJSONBytes` re-encode), so the UPPERCASE string flows onto the
// wire and ends up as the row's `globalId` column on the receiver —
// which then mismatches against the (still lowercase) `lhs`/`rhs`
// columns of every link table queried via `@Relation`. Symptom:
// peers' `vote.question` resolves correctly but `q.votes` returns 0.
// Manual Codable below mirrors what the macro would have generated
// but encodes the two UUID fields as `.uuidString.lowercased()`.
@Model
public class AuditLog: CustomStringConvertible {
    @LatticeEnum public enum Operation: String, Codable, Sendable, CustomStringConvertible {
        case insert = "INSERT", update = "UPDATE", delete = "DELETE"
        
        public var description: String { rawValue }
    }

    public var description: String {
        do {
            return try String(data: JSONEncoder().encode(self), encoding: .utf8)!
        } catch {
            return "AuditLog(tableName: \(tableName), operation: \(operation), rowId: \(rowId), changedFields: \(changedFields), timestamp: \(timestamp), isFromRemote: \(isFromRemote))"
        }
    }
    
    /// Name of the affected table, e.g., "Person"
    public package(set) var tableName: String
    /// Operation type: "INSERT", "UPDATE", "DELETE", etc.
    public var operation: Operation = .insert
    /// The id of the record that was affected in the target table
    public package(set) var rowId: Int64
    /// The global id of the record that was affected in the target table
    public package(set) var globalRowId: UUID?
    /// JSON string containing the changed fields (if any)
    public package(set) var changedFields: [String: AnyProperty]
    /// JSON containing the names of the changes properties
    public package(set) var changedFieldsNames: [String?]?
    /// Timestamp for when the change occurred
    public package(set) var timestamp: Date
    /// Whether or not this event was propagated locally
    public package(set) var isFromRemote: Bool
    /// Whether or not this event has been synchronized
    public package(set) var isSynchronized: Bool = false

    /// `required` is needed because the class is non-final and
    /// Codable's `init(from:)` is a protocol requirement on `Self` —
    /// satisfying that on a non-final class can't be done from an
    /// extension, hence the in-class declaration. Decodes the two
    /// UUID fields case-insensitively so historical audit logs that
    /// stored UPPERCASE globalIds (pre-canonicalisation fix) still
    /// parse cleanly; new writes always emit lowercase via
    /// `encode(to:)` in the extension below.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let gidStr = try container.decodeIfPresent(String.self, forKey: .__globalId) {
            self.__globalId = UUID(uuidString: gidStr)
        }
        self.tableName = try container.decode(String.self, forKey: .tableName)
        self.operation = try container.decode(Operation.self, forKey: .operation)
        self.rowId = try container.decode(Int64.self, forKey: .rowId)
        if let rowGidStr = try container.decodeIfPresent(String.self, forKey: .globalRowId) {
            self.globalRowId = UUID(uuidString: rowGidStr)
        }
        self.changedFields = try container.decode([String: AnyProperty].self, forKey: .changedFields)
        self.changedFieldsNames = try container.decodeIfPresent([String?].self, forKey: .changedFieldsNames)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.isFromRemote = try container.decode(Bool.self, forKey: .isFromRemote)
        self.isSynchronized = try container.decode(Bool.self, forKey: .isSynchronized)
    }
}

extension AuditLog: Codable {
    public enum CodingKeys: String, CodingKey {
        case tableName
        case operation
        case rowId
        case globalRowId
        case changedFields
        case changedFieldsNames
        case timestamp
        case isFromRemote
        case isSynchronized
        case __globalId = "globalId"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Both UUID fields encode as lowercase `.uuidString` so the
        // case stored in SQLite is preserved verbatim across every
        // wire hop (alice's relay encode → peer's `toCxxJSONBytes`
        // re-encode for C++ apply). Foundation's default UUID
        // Codable would emit UPPERCASE — see the comment on the type
        // above for why that breaks `@Relation` link-table joins.
        try container.encodeIfPresent(__globalId?.uuidString.lowercased(), forKey: .__globalId)
        try container.encode(tableName, forKey: .tableName)
        try container.encode(operation, forKey: .operation)
        try container.encode(rowId, forKey: .rowId)
        try container.encodeIfPresent(globalRowId?.uuidString.lowercased(), forKey: .globalRowId)
        try container.encode(changedFields, forKey: .changedFields)
        try container.encodeIfPresent(changedFieldsNames, forKey: .changedFieldsNames)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isFromRemote, forKey: .isFromRemote)
        try container.encode(isSynchronized, forKey: .isSynchronized)
    }
}

extension AuditLog {
    /// Returns raw SQL plus a list of AnyProperty to bind in-order.
    func generateInstruction() -> (sql: String, params: [AnyProperty]) {
        switch operation {
        case .insert:
            let cols   = ["globalId"] + changedFieldsNames!.compactMap { $0 }
            let props  = cols.map { changedFields[$0] ?? .string(globalRowId!.uuidString.lowercased()) }
            let names  = cols.joined(separator: ", ")
            let marks  = Array(repeating: "?", count: cols.count).joined(separator: ", ")
            let sql    = """
            INSERT INTO \(tableName)(\(names))
                VALUES (\(marks))
                ON CONFLICT(globalId) DO UPDATE
                  SET \(changedFields.keys.map{ "\($0)=excluded.\($0)" }.joined(separator: ", "));
            """
            return (sql, props)
            
        case .update:
            let cols   = changedFieldsNames!.compactMap { $0 }
            let props  = cols.map { changedFields[$0]! }
            let sets   = cols.map { "\($0) = ?" }.joined(separator: ", ")
            let sql    = "UPDATE \(tableName) SET \(sets) WHERE globalId = ?;"
            return (sql, props + [AnyProperty.string(globalRowId!.uuidString.lowercased())])  // append rowId as a param
            
        case .delete:
            let sql    = "DELETE FROM \(tableName) WHERE globalId = ?;"
            return (sql, [AnyProperty.string(globalRowId!.uuidString.lowercased())])
        }
    }
}
