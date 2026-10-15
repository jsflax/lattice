import Foundation

/// One frame of a checked catalog snapshot. Every event is PROVISIONAL until
/// reduce returns successfully after the original native statement/snapshot
/// cleanup. Callbacks must not reenter this database owner or publish effects.
public enum OwnedCatalogEvent: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public let name: String
        /// Exact SQLite declaration from the installed physical schema.
        public let type: String
        public init(name: String, type: String) { self.name = name; self.type = type }
    }
    public enum Kind: String, Sendable { case null, integer, real, text, blob }
    case beginTable(table: String, columns: [Column])
    /// UUID syntax is checked; original stored spelling remains intact.
    case beginRow(primaryKey: Int64, globalID: String)
    case beginCell(column: String, kind: Kind, byteCount: Int64)
    /// At most 65,536 bytes. Integer/real cells contain exactly eight bytes in
    /// big-endian order: Int64 two's-complement / Double bit pattern. Text and
    /// blob cells may span many chunks; NULL has no payload. UTF-8 scalar
    /// boundaries need not coincide with text chunk boundaries.
    case bytes(Data)
    case endCell
    case endRow
    case endTable
}

/// Bounded parser state: requested tables, one schema, one row/cell cursor.
/// Neither row history nor value bodies are retained here.
struct OwnedCatalogDecoder {
    let tables: [String]
    private var tableIndex = 0
    private var columns: [OwnedCatalogEvent.Column]?
    private var rowOpen = false
    private var lastRowID: Int64 = 0
    private var columnIndex = 0
    private var remainingCellBytes: Int64?

    init(tables: [String]) { self.tables = tables }

    mutating func accept(kind: Int32, bytes: Data) throws -> OwnedCatalogEvent? {
        guard bytes.count <= 65_536 else { throw failure("Oversized frame") }
        switch kind {
        case 0:
            guard columns == nil, !rowOpen, remainingCellBytes == nil, tableIndex < tables.count else {
                throw failure("Unexpected table frame")
            }
            let object = try metadata(bytes, keys: ["table", "columns"])
            guard let table = object["table"] as? String, table == tables[tableIndex],
                  let fields = object["columns"] as? [[String: Any]], !fields.isEmpty else {
                throw failure("Table identity or columns mismatch")
            }
            var names = Set<String>()
            let decoded = try fields.map { field -> OwnedCatalogEvent.Column in
                guard Set(field.keys) == ["name", "type"], let name = field["name"] as? String,
                      !name.isEmpty, !name.contains("\0"), names.insert(name).inserted,
                      let type = field["type"] as? String, !type.contains("\0") else {
                    throw failure("Invalid or repeated column metadata")
                }
                return .init(name: name, type: type)
            }
            guard names.contains("id"), names.contains("globalId") else {
                throw failure("Table identity columns missing")
            }
            columns = decoded; lastRowID = 0
            return .beginTable(table: table, columns: decoded)
        case 1:
            guard columns != nil, !rowOpen, remainingCellBytes == nil else {
                throw failure("Unexpected row frame")
            }
            let object = try metadata(bytes, keys: ["id", "globalId"])
            let id = try decimal(object["id"])
            guard id > lastRowID, id > 0, let globalID = object["globalId"] as? String,
                  globalID.utf8.count == 36, UUID(uuidString: globalID) != nil else {
                throw failure("Invalid or unordered row identity")
            }
            lastRowID = id; rowOpen = true; columnIndex = 0
            return .beginRow(primaryKey: id, globalID: globalID)
        case 2:
            guard let columns, rowOpen, remainingCellBytes == nil, columnIndex < columns.count else {
                throw failure("Unexpected cell frame")
            }
            let object = try metadata(bytes, keys: ["column", "kind", "bytes"])
            let count = try decimal(object["bytes"])
            guard let column = object["column"] as? String, column == columns[columnIndex].name,
                  let rawKind = object["kind"] as? String, let valueKind = OwnedCatalogEvent.Kind(rawValue: rawKind),
                  count >= 0 else { throw failure("Invalid cell metadata or ordering") }
            switch valueKind {
            case .null: guard count == 0 else { throw failure("NULL cell has payload") }
            case .integer, .real: guard count == 8 else { throw failure("Numeric cell must have eight bytes") }
            case .text, .blob: break
            }
            remainingCellBytes = count
            return .beginCell(column: column, kind: valueKind, byteCount: count)
        case 3:
            guard let remaining = remainingCellBytes, !bytes.isEmpty, Int64(bytes.count) <= remaining else {
                throw failure("Cell payload exceeds its declared length")
            }
            remainingCellBytes = remaining - Int64(bytes.count)
            return .bytes(bytes)
        case 4:
            guard bytes.isEmpty, remainingCellBytes == 0 else { throw failure("Incomplete cell") }
            remainingCellBytes = nil; columnIndex += 1
            return .endCell
        case 5:
            guard bytes.isEmpty, let columns, rowOpen, remainingCellBytes == nil, columnIndex == columns.count else {
                throw failure("Incomplete row")
            }
            rowOpen = false
            return .endRow
        case 6:
            guard bytes.isEmpty, columns != nil, !rowOpen, remainingCellBytes == nil else {
                throw failure("Incomplete table")
            }
            columns = nil; tableIndex += 1
            return .endTable
        case 7:
            guard bytes.isEmpty else { throw failure("Checkpoint has payload") }
            return nil
        default: throw failure("Unknown frame kind")
        }
    }

    func finish() throws {
        guard tableIndex == tables.count, columns == nil, !rowOpen, remainingCellBytes == nil else {
            throw failure("Native capture ended before the complete catalog")
        }
    }

    private func metadata(_ bytes: Data, keys: Set<String>) throws -> [String: Any] {
        try OwnedCatalogJSONShape.validate(bytes)
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(value.keys) == keys else { throw failure("Metadata fields mismatch") }
        return value
    }
    private func decimal(_ value: Any?) throws -> Int64 {
        guard let raw = value as? String, let result = Int64(raw), String(result) == raw else {
            throw failure("Invalid decimal integer metadata")
        }
        return result
    }
    private func failure(_ message: String) -> OwnedCatalogError {
        .malformedFrame(message)
    }
}
