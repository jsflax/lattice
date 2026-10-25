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

    /// Wire-only names whose no-history values are observed SQL NULLs, not
    /// raw UPDATE-history placeholders. This is deliberately not a column.
    /// Old peers ignore the key and cannot apply these nullable clears.
    @Transient public package(set) var noHistoryNulls: [String] = []

    /// Detached wire provenance. Managed encoding reads the existing Core-owned
    /// AuditLog.synthesized column; this property adds no model/SQL column.
    @Transient public package(set) var synthesized: Bool = false

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
        if let gidStr = try container.decodeIfPresent(String.self, forKey: .globalId) {
            self.globalId = UUID(uuidString: gidStr)
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
        self.noHistoryNulls = container.contains(.noHistoryNulls)
            ? try container.decode([String].self, forKey: .noHistoryNulls) : []
        self.synthesized = container.contains(.synthesized)
            ? try container.decode(Bool.self, forKey: .synthesized) : false
        try Self.validateNoHistoryNullWireValues(from: decoder, names: noHistoryNulls)
        try validateNoHistoryNulls()
    }

    /// Also used for typed callers and the Core bridge, before re-encoding.
    func validateNoHistoryNulls() throws {
        guard !noHistoryNulls.isEmpty else { return }
        let names = Set(changedFieldsNames?.compactMap { $0 } ?? [])
        var seen = Set<String>()
        for name in noHistoryNulls {
            guard operation != .delete, !name.isEmpty, seen.insert(name).inserted,
                  names.contains(name), let value = changedFields[name], case .null = value else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Invalid noHistoryNulls completeness metadata"))
            }
        }
    }

    /// AnyProperty intentionally accepts legacy/coercible payloads. Marked
    /// NULLs need strict decoding so invalid input cannot become a clear.
    static func validateNoHistoryNullWireValues(from decoder: Decoder, names: [String]) throws {
        guard !names.isEmpty else { return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fields = try c.nestedContainer(keyedBy: FieldKey.self, forKey: .changedFields)
        for name in names { _ = try fields.decode(ObservedNull.self, forKey: FieldKey(name)) }
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    private struct ObservedNull: Decodable {
        private enum Keys: String, CodingKey { case kind, value }
        init(from decoder: Decoder) throws {
            if try decoder.singleValueContainer().decodeNil() { return }
            let c = try decoder.container(keyedBy: Keys.self)
            guard try c.decode(Int.self, forKey: .kind) == AnyProperty.Kind.null.rawValue,
                  c.contains(.value), try c.decodeNil(forKey: .value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Marked no-history value must be an explicit NULL"))
            }
        }
    }

    /// Core owns this existing provenance column outside Swift model metadata.
    /// Never default a failed managed read to false: that would turn a snapshot
    /// into an overwriting INSERT. One bounded read per managed encode, including
    /// the detached copy made by lateBindNoHistory; no speculative lifetime cache.
    private func wireSynthesized() throws -> Bool {
        guard isManaged else { return synthesized }
        guard let backend = _dynamicObject._ref.lattice, let globalId else {
            throw EncodingError.invalidValue(self, .init(codingPath: [],
                debugDescription: "Managed audit provenance is unavailable"))
        }
        let json = backend.noHistoryLiveValuesJSON(tableName: "AuditLog",
            globalRowId: globalId.uuidString.lowercased(), columns: ["synthesized"])
        let fields = try JSONDecoder().decode([String: AnyProperty].self, from: Data(json.utf8))
        let flag: Int64?
        switch fields["synthesized"] {
        case .int(let value)?: flag = Int64(value)
        case .int64(let value)?: flag = value
        default: flag = nil
        }
        guard let flag, flag == 0 || flag == 1 else {
            throw EncodingError.invalidValue(self, .init(codingPath: [],
                debugDescription: "Managed audit provenance must be explicit 0 or 1"))
        }
        return flag == 1
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
        case globalId
        case noHistoryNulls
        case synthesized
    }

    public func encode(to encoder: any Encoder) throws {
        try validateNoHistoryNulls()
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Both UUID fields encode as lowercase `.uuidString` so the
        // case stored in SQLite is preserved verbatim across every
        // wire hop (alice's relay encode → peer's `toCxxJSONBytes`
        // re-encode for C++ apply). Foundation's default UUID
        // Codable would emit UPPERCASE — see the comment on the type
        // above for why that breaks `@Relation` link-table joins.
        try container.encodeIfPresent(globalId?.uuidString.lowercased(), forKey: .globalId)
        try container.encode(tableName, forKey: .tableName)
        try container.encode(operation, forKey: .operation)
        try container.encode(rowId, forKey: .rowId)
        try container.encodeIfPresent(globalRowId?.uuidString.lowercased(), forKey: .globalRowId)
        try container.encode(changedFields, forKey: .changedFields)
        try container.encodeIfPresent(changedFieldsNames, forKey: .changedFieldsNames)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isFromRemote, forKey: .isFromRemote)
        try container.encode(isSynchronized, forKey: .isSynchronized)
        if !noHistoryNulls.isEmpty { try container.encode(noHistoryNulls, forKey: .noHistoryNulls) }
        if try wireSynthesized() { try container.encode(true, forKey: .synthesized) }
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
