import Foundation
import CoreFoundation
import CLatticeTestSQLite

// Fixed, sanitized failure codes only. Never interpolate SQLite errors, paths,
// IDs, row values, credentials or protocol bytes into a test issue/receipt.
enum QuietACKFailure: String, Error {
    case environment, deadline, metadata, drop, connections, sourceImage, sourceCounters
    case sourceCoverage, receiverImage, originals, receiverSettlement
    case sqliteOpen, sqlitePrepare, sqliteStep, sqliteType, sqliteBound, sqliteSchema, sqliteCleanup
    case fixtureCleanup, receipt
}
func quietACKRequire(_ condition: @autoclosure () throws -> Bool, _ phase: QuietACKFailure) throws {
    guard try condition() else { throw phase }
}

enum QuietACKCell: Equatable, Sendable {
    case null, integer(Int64), text(String), blob(Data)
    func integer() throws -> Int64 { guard case .integer(let value) = self else { throw QuietACKFailure.sqliteType }; return value }
    func text() throws -> String { guard case .text(let value) = self else { throw QuietACKFailure.sqliteType }; return value }
    func blob() throws -> Data { guard case .blob(let value) = self else { throw QuietACKFailure.sqliteType }; return value }
}
struct QuietACKRow: Equatable, Sendable {
    let cells: [String: QuietACKCell]
    func cell(_ key: String) throws -> QuietACKCell { guard let value = cells[key] else { throw QuietACKFailure.sqliteSchema }; return value }
    func integer(_ key: String) throws -> Int64 { try cell(key).integer() }
    func text(_ key: String) throws -> String { try cell(key).text() }
    func blob(_ key: String) throws -> Data { try cell(key).blob() }
    func selecting(_ keys: [String]) throws -> Self {
        var result: [String: QuietACKCell] = [:]
        for key in keys { result[key] = try cell(key) }
        return .init(cells: result)
    }
}
struct QuietACKSnapshot: Sendable {
    let tables: [String: [QuietACKRow]]
    let schemas: [String: [QuietACKRow]]
    func rows(_ table: String) throws -> [QuietACKRow] {
        guard let rows = tables[table] else { throw QuietACKFailure.sqliteSchema }; return rows
    }
    func one(_ table: String) throws -> QuietACKRow {
        let value = try rows(table); guard value.count == 1 else { throw QuietACKFailure.sqliteBound }; return value[0]
    }
}

// The only callers are B's three known owned fixture files. This reader cannot
// enroll an owner, wake its scheduler, checkpoint, repair or supply authority.
// It opens live WAL databases normally: never URI immutable=1 or a copied main.
private final class QuietACKSQLiteReader {
    private var database: OpaquePointer?
    private let deadline: ContinuousClock.Instant
    private var copiedBytes = 0
    private var finished = false
    private let file: URL
    private let initialDevice, initialInode: UInt64
    private static let maximumBytes = 8 * 1024 * 1024
    private static let maximumFieldBytes = 64 * 1024

    private static func identity(_ file: URL, under root: URL) throws -> (UInt64, UInt64) {
        guard file.isFileURL, file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              file.standardizedFileURL == file, file.resolvingSymlinksInPath() == file,
              root.resolvingSymlinksInPath() == root.standardizedFileURL else { throw QuietACKFailure.sqliteOpen }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw QuietACKFailure.sqliteOpen }
        return (device.uint64Value, inode.uint64Value)
    }
    init(file: URL, root: URL, caseDeadline: ContinuousClock.Instant) throws {
        self.file = file
        let identity = try Self.identity(file, under: root)
        initialDevice = identity.0; initialInode = identity.1
        deadline = min(caseDeadline, ContinuousClock.now.advanced(by: .seconds(2)))
        guard ContinuousClock.now < deadline else { throw QuietACKFailure.deadline }
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw QuietACKFailure.sqliteOpen
        }
        database = opened
        do {
            guard sqlite3_db_readonly(opened, "main") == 1,
                  let name = sqlite3_db_filename(opened, "main"), String(cString: name) == file.path,
                  sqlite3_busy_timeout(opened, 100) == SQLITE_OK else { throw QuietACKFailure.sqliteOpen }
            sqlite3_progress_handler(opened, 1000, { context in
                guard let context else { return 1 }
                let reader = Unmanaged<QuietACKSQLiteReader>.fromOpaque(context).takeUnretainedValue()
                return ContinuousClock.now >= reader.deadline ? 1 : 0
            }, Unmanaged.passUnretained(self).toOpaque())
            try command("BEGIN")
        } catch {
            sqlite3_progress_handler(opened, 0, nil, nil)
            sqlite3_close_v2(opened); database = nil
            throw error
        }
    }
    deinit {
        if let database {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(database)
        }
    }
    private func checkDeadline() throws {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { throw QuietACKFailure.deadline }
    }
    private func charge(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= Self.maximumFieldBytes,
              copiedBytes <= Self.maximumBytes - bytes else { throw QuietACKFailure.sqliteBound }
        copiedBytes += bytes
    }
    private func command(_ sql: String) throws {
        guard let database else { throw QuietACKFailure.sqliteCleanup }
        try checkDeadline()
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw QuietACKFailure.sqliteStep }
    }
    // SQL and projected column names are exclusively the closed literals below.
    // LIMIT+1 detects overflow; no user input, broad counts or polling queries.
    func query(_ sql: String, columns: [String], maximumRows: Int) throws -> [QuietACKRow] {
        guard let database, (1...256).contains(maximumRows), columns.count <= 40 else { throw QuietACKFailure.sqliteBound }
        try checkDeadline()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw QuietACKFailure.sqlitePrepare
        }
        var finalized = false
        defer { if !finalized { sqlite3_finalize(statement) } }
        guard sqlite3_stmt_readonly(statement) == 1, sqlite3_column_count(statement) == Int32(columns.count) else { throw QuietACKFailure.sqlitePrepare }
        var rows: [QuietACKRow] = []
        while true {
            try checkDeadline()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw QuietACKFailure.sqliteStep }
            guard rows.count < maximumRows else { throw QuietACKFailure.sqliteBound }
            var row: [String: QuietACKCell] = [:]
            for (offset, column) in columns.enumerated() {
                let index = Int32(offset), kind = sqlite3_column_type(statement, Int32(offset))
                switch kind {
                case SQLITE_NULL: row[column] = .null
                case SQLITE_INTEGER:
                    try charge(8); row[column] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index)); try charge(count)
                    guard let pointer = sqlite3_column_text(statement, index),
                          let text = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8),
                          !text.contains("\0") else { throw QuietACKFailure.sqliteType }
                    row[column] = .text(text)
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index)); try charge(count)
                    if count == 0 { row[column] = .blob(Data()) }
                    else {
                        guard let pointer = sqlite3_column_blob(statement, index) else { throw QuietACKFailure.sqliteType }
                        row[column] = .blob(Data(bytes: pointer, count: count))
                    }
                default: throw QuietACKFailure.sqliteType
                }
            }
            rows.append(.init(cells: row))
        }
        try checkDeadline()
        let status = sqlite3_finalize(statement); finalized = true
        guard status == SQLITE_OK else { throw QuietACKFailure.sqliteCleanup }
        return rows
    }
    func finish(under root: URL) throws {
        guard let database, !finished else { throw QuietACKFailure.sqliteCleanup }
        // Remove the bounded progress callback even after its deadline fired so
        // cleanup can always release the read transaction. No retries or writes.
        sqlite3_progress_handler(database, 0, nil, nil)
        let rollback = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        let close = sqlite3_close(database)
        if close == SQLITE_OK { self.database = nil; finished = true }
        guard rollback == SQLITE_OK, close == SQLITE_OK else { throw QuietACKFailure.sqliteCleanup }
        let after = try Self.identity(file, under: root)
        guard after.0 == initialDevice, after.1 == initialInode else { throw QuietACKFailure.sqliteOpen }
        try checkDeadline()
    }
}

private struct QuietACKTable {
    let name: String
    let columns: [(String, String)]
    let projection: [String]
    let maximumRows: Int
    let nullable: Set<String>
    init(_ name: String, integers: String = "", blobs: String = "", texts: String = "", real: String = "",
         projection: [String]? = nil, nullable: Set<String> = [], maximumRows: Int) {
        self.name = name; self.maximumRows = maximumRows; self.nullable = nullable
        columns = integers.split(separator: " ").map { (String($0), "INTEGER") }
            + blobs.split(separator: " ").map { (String($0), "BLOB") }
            + texts.split(separator: " ").map { (String($0), "TEXT") }
            + real.split(separator: " ").map { (String($0), "REAL") }
        self.projection = projection ?? columns.map(\.0)
    }
}

enum QuietACKReadOnlySnapshot {
    static let shared = "ConnectedRecoverySharedRow", local = "ConnectedRecoveryLocalRow"
    static let canonical = "_lattice_canonical_store", touch = "_lattice_canonical_touch", receipt = "_lattice_canonical_receipt"
    static let coverageProfile = "_lattice_canonical_receipt_profile", origin = "_lattice_canonical_receipt_origin", coverage = "_lattice_canonical_receipt_coverage"
    static let continuity = "_lattice_producer_continuity", installs = "_lattice_install_channel"
    static let scopes = "_lattice_obligation_scope", entries = "_lattice_obligation_entry"
    static let originalColumns = ["id", "globalId", "tableName", "operation", "globalRowId", "changedFields", "changedFieldsNames"]
    private static let models = [
        QuietACKTable(shared, integers: "id value", texts: "globalId label", maximumRows: 256),
        QuietACKTable(local, integers: "id", texts: "globalId value", maximumRows: 256),
        QuietACKTable("AuditLog", integers: "id rowId isFromRemote isSynchronized synthesized", texts: "globalId tableName operation globalRowId changedFields changedFieldsNames", real: "timestamp", projection: originalColumns, maximumRows: 256)
    ]
    private static let sourceTables = [
        QuietACKTable(canonical, integers: "id version head floor markers marker_bytes receipts receipt_bytes max_markers max_marker_bytes max_receipts max_receipt_bytes max_batch max_identity max_operation", blobs: "source epoch scope schema_id", maximumRows: 1),
        QuietACKTable(touch, integers: "position charge", blobs: "relation identity", maximumRows: 256),
        QuietACKTable(receipt, integers: "position outcome charge", blobs: "original_id relation identity namespace_id", maximumRows: 256),
        QuietACKTable(coverageProfile, integers: "id version revision codec mutation origins origin_bytes cells cell_bytes max_origins max_origin_bytes max_cells max_cell_bytes", blobs: "cohort", maximumRows: 1),
        QuietACKTable("_lattice_canonical_receipt_member", blobs: "namespace_id", maximumRows: 8),
        QuietACKTable(origin, integers: "charge", blobs: "original_id producer incarnation digest operation", maximumRows: 256),
        QuietACKTable(coverage, integers: "revision charge", blobs: "original_id namespace_id", maximumRows: 256),
        QuietACKTable("_lattice_canonical_namespace", integers: "revision status is_local", blobs: "namespace_id coverage_id", maximumRows: 8)
    ]
    private static let receiverTables = [
        QuietACKTable(continuity, integers: "id version main_device main_inode parent_device parent_inode container_device container_inode incarnation barrier attempt phase", blobs: "manifest digest", maximumRows: 1),
        QuietACKTable("_lattice_install_store", integers: "id version max_channels max_field_bytes max_bytes channels bytes", maximumRows: 1),
        QuietACKTable(installs, integers: "frontier_kind frontier revision last_sequence bytes", blobs: "channel authority source epoch scope schema_digest active last_install", nullable: ["frontier", "active", "last_install"], maximumRows: 4),
        QuietACKTable("_lattice_obligation_store", integers: "id version max_scopes max_records max_field max_bytes scopes records bytes incarnation record_sequence export_sequence", maximumRows: 1),
        QuietACKTable(scopes, integers: "incarnation generation revision last_attempt freeze_revision freeze_record freeze_export mode installed_sequence installed_revision installed_head bytes", blobs: "channel authority source epoch scope schema_digest profile_digest receipt_namespace installed_manifest", maximumRows: 4),
        QuietACKTable(entries, integers: "audit_id origin record_sequence first_export stage ack_position ack_outcome settled_sequence bytes", blobs: "channel original actual_original table_name target actual_target", nullable: ["first_export", "ack_position", "ack_outcome"], maximumRows: 128)
    ]
    static func capture(file: URL, root: URL, source: Bool, deadline: ContinuousClock.Instant) throws -> QuietACKSnapshot {
        let reader: QuietACKSQLiteReader
        do { reader = try QuietACKSQLiteReader(file: file, root: root, caseDeadline: deadline) }
        catch let error as QuietACKFailure { throw error }
        catch { throw QuietACKFailure.sqliteOpen }
        var tables: [String: [QuietACKRow]] = [:], schemas: [String: [QuietACKRow]] = [:]
        do {
            for spec in models + (source ? sourceTables : receiverTables) {
                // Exact column name/type inventory, including unprojected audit
                // bookkeeping. These are fixed internal table names, not input.
                let definition = try reader.query("SELECT type,sql FROM main.sqlite_schema WHERE name='\(spec.name)' LIMIT 2", columns: ["type", "sql"], maximumRows: 1)
                guard definition.count == 1, try definition[0].text("type") == "table",
                      try !definition[0].text("sql").isEmpty else { throw QuietACKFailure.sqliteSchema }
                schemas[spec.name + ".definition"] = definition
                let schema = try reader.query("SELECT name,type FROM pragma_table_info('\(spec.name)') ORDER BY cid LIMIT 41", columns: ["name", "type"], maximumRows: 40)
                var actual: [String: String] = [:]
                for row in schema {
                    let name = try row.text("name"), type = try row.text("type")
                    guard actual.updateValue(type, forKey: name) == nil else { throw QuietACKFailure.sqliteSchema }
                }
                guard actual == Dictionary(uniqueKeysWithValues: spec.columns) else { throw QuietACKFailure.sqliteSchema }
                let columns = spec.projection.map { "\"" + $0 + "\"" }.joined(separator: ",")
                let rows = try reader.query("SELECT \(columns) FROM main.\"\(spec.name)\" LIMIT \(spec.maximumRows + 1)", columns: spec.projection, maximumRows: spec.maximumRows)
                let types = Dictionary(uniqueKeysWithValues: spec.columns)
                for row in rows {
                    for column in spec.projection {
                        let cell = try row.cell(column)
                        if cell == .null {
                            guard spec.nullable.contains(column) else { throw QuietACKFailure.sqliteType }
                        } else {
                            switch (types[column], cell) {
                            case (.some("INTEGER"), .integer), (.some("TEXT"), .text), (.some("BLOB"), .blob): break
                            default: throw QuietACKFailure.sqliteType
                            }
                        }
                    }
                }
                tables[spec.name] = rows
                schemas[spec.name] = schema
            }
            try reader.finish(under: root)
        } catch {
            // A failed read never retries or falls back to a public owner. The
            // reader's deinit finalizes any remaining rollback/close cleanup.
            throw error
        }
        return .init(tables: tables, schemas: schemas)
    }
}

// Foundation's NSNumber bridge must not turn Bool or 55.0 into an integer oracle.
func quietACKJSONInteger(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
          number.stringValue == String(number.int64Value) else { throw QuietACKFailure.sqliteType }
    return number.int64Value
}

// Passive decoding of Core receive_install_state.cpp's v1 retained identity.
// Opaque digests stay byte-exact. This checks an observed committed-state link;
// it supplies no native installation, receipt or recovery authority.
struct QuietACKInstallIdentity: Equatable, Sendable {
    let sequence, expectedRevision, baseKind, basePosition, head, mode: Int64
    let requestDigest, receiptDigest, contentDigest, manifestDigest: Data

    static func decode(_ data: Data, maximumFieldBytes: Int64, maximumEncodedBytes: Int64) throws -> Self {
        // The raw reader already applies this field cap. Apply it again before
        // cursor arithmetic or digest copying, including for pure copied inputs.
        guard maximumFieldBytes > 0, maximumEncodedBytes > 0,
              data.count <= 65_536, Int64(data.count) <= maximumEncodedBytes else { throw QuietACKFailure.receiverSettlement }
        var offset = 0
        func number() throws -> Int64 {
            guard offset <= data.count, data.count - offset >= 8 else { throw QuietACKFailure.receiverSettlement }
            var value: UInt64 = 0
            for _ in 0..<8 {
                value = (value << 8) | UInt64(data[data.startIndex + offset]); offset += 1
            }
            guard value <= UInt64(Int64.max) else { throw QuietACKFailure.receiverSettlement }
            return Int64(value)
        }
        func digest() throws -> Data {
            let count = try number()
            guard count > 0, count <= maximumFieldBytes, count <= Int64(data.count - offset) else { throw QuietACKFailure.receiverSettlement }
            // The remaining-input comparison establishes representable bounded
            // Int arithmetic before constructing this sole field copy.
            let end = offset + Int(count)
            let value = Data(data[(data.startIndex + offset)..<(data.startIndex + end)])
            offset = end; return value
        }
        guard try number() == 1 else { throw QuietACKFailure.receiverSettlement }
        let sequence = try number(), revision = try number(), kind = try number(), position = try number()
        let head = try number(), mode = try number()
        guard sequence > 0, revision < Int64.max, sequence > revision,
              (0...2).contains(kind), (0...1).contains(mode),
              (kind == 2) == (revision > 0), kind == 2 || position == 0,
              kind != 2 || head >= position, mode == 0 || kind == 2 else { throw QuietACKFailure.receiverSettlement }
        let request = try digest(), receipt = try digest(), content = try digest(), manifest = try digest()
        guard offset == data.count else { throw QuietACKFailure.receiverSettlement }
        return .init(sequence: sequence, expectedRevision: revision, baseKind: kind, basePosition: position,
                     head: head, mode: mode, requestDigest: request, receiptDigest: receipt,
                     contentDigest: content, manifestDigest: manifest)
    }
}

func quietACKValidateInstalledIdentity(channel: QuietACKRow, scope: QuietACKRow, store: QuietACKRow) throws {
    let identity = try QuietACKInstallIdentity.decode(channel.blob("last_install"),
        maximumFieldBytes: store.integer("max_field_bytes"), maximumEncodedBytes: store.integer("max_bytes"))
    // decode refuses Int64.max before this addition. The independent old scalar
    // checks remain in quietReceiverOpen; here the actual retained blob must
    // agree with both tables, rather than merely being nonempty.
    let revision = identity.expectedRevision + 1
    try quietACKRequire(try identity.sequence == channel.integer("last_sequence") && identity.sequence == scope.integer("installed_sequence") &&
        identity.head == channel.integer("frontier") && identity.head == scope.integer("installed_head") &&
        revision == channel.integer("revision") && revision == scope.integer("installed_revision") &&
        identity.manifestDigest == scope.blob("installed_manifest"), .receiverSettlement)
}
