import Foundation
import CoreFoundation
import CLatticeTestSQLite
import RecoveryProcessSupport
import Vapor
@testable import LatticeServerKit

// C-only passive observations. The SQL entry is available solely inside the
// process owner's checked serial post-waitpid window; copied values grant no
// open, spawn, signal, source, receipt or installation authority.
enum ReceiverReapFailure: String, Error { case custody, schema, policy, original, cohort, cut, state, page, installed, bounds }
private func reapRequire(_ condition: @autoclosure () throws -> Bool, _ error: ReceiverReapFailure) throws {
    guard try condition() else { throw error }
}
struct ReceiverReapSnapshot: Sendable {
    let storage: QuietACKSnapshot
    let file: URL
    let configuration: RecoveryProcessConfiguration
    let configurationSHA256, instanceID: String
    let spawnOrdinal: Int
    let killedByOwnedSIGKILL, exitedZero: Bool
}

// Logical copy bounds: each encoded field <=64 KiB, all copied SQL values <=8
// MiB, <=256 rows/table and a 2-second absolute subdeadline. These are not heap
// or RSS limits; SQLite/Foundation object overhead and source buffers coexist.
private final class ReapSQLiteReader {
    private var database: OpaquePointer?
    private let deadline: ContinuousClock.Instant
    private var copiedBytes = 0
    private var finished = false
    private let file: URL
    let initialDevice, initialInode: UInt64
    private static let maximumBytes = 8 * 1024 * 1024
    private static let maximumFieldBytes = 64 * 1024

    private static func identity(_ file: URL, under root: URL) throws -> (UInt64, UInt64) {
        guard file.isFileURL, file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              file.standardizedFileURL == file, file.resolvingSymlinksInPath() == file,
              root.resolvingSymlinksInPath() == root.standardizedFileURL else { throw QuietACKFailure.sqliteOpen }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
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
                let reader = Unmanaged<ReapSQLiteReader>.fromOpaque(context).takeUnretainedValue()
                return ContinuousClock.now >= reader.deadline ? 1 : 0
            }, Unmanaged.passUnretained(self).toOpaque())
            var moved: Int32 = 1
            guard sqlite3_file_control(opened, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK, moved == 0 else { throw QuietACKFailure.sqliteOpen }
            let mode = try query("PRAGMA main.journal_mode", columns: ["mode"], maximumRows: 1)
            guard mode.count == 1, try mode[0].text("mode") == "wal" else { throw QuietACKFailure.sqliteOpen }
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
        var moved: Int32 = 1
        let custody = sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK && moved == 0
        let rollback = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        let close = sqlite3_close(database)
        if close == SQLITE_OK { self.database = nil; finished = true }
        guard custody, rollback == SQLITE_OK, close == SQLITE_OK else { throw QuietACKFailure.sqliteCleanup }
        let after = try Self.identity(file, under: root)
        guard after.0 == initialDevice, after.1 == initialInode else { throw QuietACKFailure.sqliteOpen }
        try checkDeadline()
    }
}

private struct ReapTable {
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

enum ReceiverReapReadOnlySnapshot {
    static let shared = "RecoveryProcessSharedRow", local = "RecoveryProcessLocalRow"
    static let canonical = "_lattice_canonical_store", touch = "_lattice_canonical_touch", receipt = "_lattice_canonical_receipt"
    static let coverageProfile = "_lattice_canonical_receipt_profile", origin = "_lattice_canonical_receipt_origin", coverage = "_lattice_canonical_receipt_coverage"
    static let continuity = "_lattice_producer_continuity", installs = "_lattice_install_channel"
    static let scopes = "_lattice_obligation_scope", entries = "_lattice_obligation_entry"
    static let originalColumns = ["id", "globalId", "tableName", "operation", "globalRowId", "changedFields", "changedFieldsNames"]
    private static let models = [
        ReapTable(shared, integers: "id value", texts: "globalId label", maximumRows: 256),
        ReapTable(local, integers: "id", texts: "globalId value", maximumRows: 256),
        ReapTable("AuditLog", integers: "id rowId isFromRemote isSynchronized synthesized", texts: "globalId tableName operation globalRowId changedFields changedFieldsNames", real: "timestamp", projection: originalColumns, nullable: ["changedFieldsNames"], maximumRows: 256)
    ]
    private static let receiverTables = [
        ReapTable(continuity, integers: "id version main_device main_inode parent_device parent_inode container_device container_inode incarnation barrier attempt phase", blobs: "manifest digest", maximumRows: 1),
        ReapTable("_lattice_install_store", integers: "id version max_channels max_field_bytes max_bytes channels bytes", maximumRows: 1),
        ReapTable(installs, integers: "frontier_kind frontier revision last_sequence bytes", blobs: "channel authority source epoch scope schema_digest active last_install", nullable: ["frontier", "active", "last_install"], maximumRows: 4),
        ReapTable("_lattice_obligation_store", integers: "id version max_scopes max_records max_field max_bytes scopes records bytes incarnation record_sequence export_sequence", maximumRows: 1),
        ReapTable(scopes, integers: "incarnation generation revision last_attempt freeze_revision freeze_record freeze_export mode installed_sequence installed_revision installed_head bytes", blobs: "channel authority source epoch scope schema_digest profile_digest receipt_namespace installed_manifest", maximumRows: 4),
        ReapTable(entries, integers: "audit_id origin record_sequence first_export stage ack_position ack_outcome settled_sequence bytes", blobs: "channel original actual_original table_name target actual_target", nullable: ["first_export", "ack_position", "ack_outcome"], maximumRows: 128)
    ]
    private static let recoveryTables = [
        ReapTable("_lattice_recovery_request_config", integers: "id version max_rows max_frame max_context max_bytes", maximumRows: 1),
        ReapTable("_lattice_recovery_request", integers: "incarnation generation barrier sequence journal_revision route", blobs: "channel domain source_context request_frame manifest_frame", maximumRows: 4),
        ReapTable("_lattice_range_store", integers: "id version channels content_pages identities content_bytes receipt_pages receipts receipt_bytes stored_bytes", blobs: "configuration", maximumRows: 1),
        ReapTable("_lattice_range_attempt", integers: "route verified content_pages identities content_bytes receipt_pages receipts receipt_bytes page_bytes", blobs: "channel logical state", maximumRows: 4),
        ReapTable("_lattice_range_page", integers: "stream page_index", blobs: "channel wire", maximumRows: 16),
        ReapTable("_lattice_obligation_producer_store", integers: "id version max_profiles max_stamps max_field max_manifest max_bytes profiles stamps bytes", maximumRows: 1),
        ReapTable("_lattice_obligation_producer_profile", integers: "incarnation program_revision bytes", blobs: "channel program_digest manifest", maximumRows: 4),
        ReapTable("_lattice_obligation_producer_stamp", integers: "incarnation program_revision audit_id record_sequence generation scope_revision base_scopes base_records base_bytes base_incarnation base_export producer_profiles producer_stamps producer_bytes bytes", blobs: "channel original", maximumRows: 128)
    ]
    // No path/context/PID-only overload exists. Even an old authentic retirement
    // is refused by the owner after a later spawn starts.
    static func capture(owner: RecoveryProcessOwner, retirement: RecoveryProcessOwner.Retirement,
                        deadline: ContinuousClock.Instant) async throws -> ReceiverReapSnapshot {
        try await owner.withReapedChild(retirement) { context in
            let value = try read(context: context, deadline: deadline)
            return .init(storage: value, file: context.file, configuration: context.configuration,
                configurationSHA256: context.configurationSHA256, instanceID: context.instanceID,
                spawnOrdinal: context.spawnOrdinal, killedByOwnedSIGKILL: retirement.killedByOwnedSIGKILL,
                exitedZero: retirement.exitedZero)
        }
    }
    private static func read(context: RecoveryProcessOwner.ReapedContext, deadline: ContinuousClock.Instant) throws -> QuietACKSnapshot {
        let file = context.file, root = context.root
        let reader: ReapSQLiteReader
        do { reader = try ReapSQLiteReader(file: file, root: root, caseDeadline: deadline) }
        catch let error as QuietACKFailure { throw error }
        catch { throw QuietACKFailure.sqliteOpen }
        var tables: [String: [QuietACKRow]] = [:], schemas: [String: [QuietACKRow]] = [:]
        do {
            for spec in models + receiverTables + recoveryTables {
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
            let row = try QuietACKSnapshot(tables: tables, schemas: schemas).one(continuity)
            try reapRequire(try row.integer("main_device") == Int64(exactly: reader.initialDevice) &&
                row.integer("main_inode") == Int64(exactly: reader.initialInode), .custody)
            // Owner independently holds/rechecks the case root before/after this
            // callback. Check both native directory identities as well as main.
            for (url, prefix) in [(root, "parent"), (file.deletingLastPathComponent(), "container")] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                try reapRequire(try url.resolvingSymlinksInPath() == url && (attributes[.type] as? FileAttributeType) == .typeDirectory &&
                    (attributes[.systemNumber] as? NSNumber)?.int64Value == row.integer(prefix + "_device") &&
                    (attributes[.systemFileNumber] as? NSNumber)?.int64Value == row.integer(prefix + "_inode"), .custody)
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

// These pure functions consume copied bytes/rows only. They are deliberately
// separate from acquisition so negative tests cannot manufacture a reap token.
enum ReceiverReapComparison {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func object(_ data: Data) throws -> [String: Any] {
        var syntax = ReadyCutpointSyntax(data); try syntax.validate()
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReceiverReapFailure.state }
        return value
    }
    static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw ReceiverReapFailure.state }; return value
    }
    static func encoded(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try reapRequire(data.count <= 65_536, .bounds); var syntax = ReadyCutpointSyntax(data); try syntax.validate(); return data
    }
    static func keys(_ value: [String: Any], _ keys: [String]) throws {
        try reapRequire(Set(value.keys) == Set(keys), .state)
    }
    static func decimal(_ value: Any?, positive: Bool = false) throws -> Int64 {
        guard let text = value as? String, let n = Int64(text), n >= (positive ? 1 : 0), String(n) == text else { throw ReceiverReapFailure.state }; return n
    }
    static func bytes(_ value: Any?) throws -> Data {
        guard let text = value as? String else { throw ReceiverReapFailure.state }; return Data(text.utf8)
    }
    static func envelope(_ data: Data) throws -> [String: Any] {
        try reapRequire(RelayReadyCutpoint.canonicalFrame(data) != nil, .state)
        return try object(object(data)["latticeCanonicalRange"])
    }
    static func frame(_ data: Data) throws -> RelayReadyCanonicalFrame {
        guard let frame = RelayReadyCutpoint.canonicalFrame(data) else { throw ReceiverReapFailure.state }; return frame
    }
    static func sameLogical(_ a: RelayReadyCanonicalFrame, _ b: RelayReadyCanonicalFrame) -> Bool {
        a.canonicalVersion == b.canonicalVersion && a.receiverIncarnation == b.receiverIncarnation &&
        a.channelIncarnation == b.channelIncarnation && a.channel.utf8.elementsEqual(b.channel.utf8) &&
        a.attemptID == b.attemptID && a.sequence == b.sequence
    }
    static func sameFrame(_ stored: Data, observed: RelayReadyCanonicalFrame, storedRoute: String? = nil) throws {
        let actual = try frame(stored)
        try reapRequire(sameLogical(actual, observed) && actual.kind == observed.kind &&
            actual.normalizedFrameSHA256 == observed.normalizedFrameSHA256 &&
            (storedRoute == nil || actual.routeGeneration == storedRoute), .page)
    }
    static func row(_ rows: [QuietACKRow], channel: Data) throws -> QuietACKRow {
        let found = try rows.filter { try $0.blob("channel") == channel }
        try reapRequire(found.count == 1, .cohort); return found[0]
    }
    static func policyManifest(_ configuration: RecoveryProcessConfiguration, file: URL) throws -> Data {
        try configuration.validate()
        var output = Data()
        func number(_ n: Int) throws {
            try reapRequire(n >= 0, .policy)
            for shift in stride(from: 56, through: 0, by: -8) { output.append(UInt8(truncatingIfNeeded: UInt64(n) >> shift)) }
        }
        func field(_ data: Data) throws { try number(data.count); output.append(data); try reapRequire(output.count <= 65_536, .bounds) }
        try field(Data("lattice-continuous-canonical-receiver-v2".utf8))
        for n in [16,4194304,65536,134217728,16777216,8192,262144,536870912,4096,131072,134217728,805306368] { try number(n) }
        let l = configuration.limits
        for n in [l.scopes,l.records,l.fieldBytes,l.journalBytes,l.channels,l.bindingFieldBytes,l.bindingBytes,
                  l.profiles,l.stamps,l.producerFieldBytes,l.manifestBytes,l.producerBytes,
                  l.owners,l.physicalRoutes,l.operations,l.frozenEntries,l.frozenBytes] { try number(n) }
        let channels = configuration.channels.sorted { $0.channel.utf8.lexicographicallyPrecedes($1.channel.utf8) }
        try number(channels.count)
        for c in channels {
            for s in [c.channel,c.authority,c.sourceID,c.epoch,c.scopeDigest,c.schemaDigest,c.profileDigest,c.receiptNamespace] { try field(Data(s.utf8)) }
            try number(1); try field(Data("RecoveryProcessSharedRow".utf8)); try field(c.incomingGrantClaim)
        }
        try number(channels.count)
        for c in channels { try field(Data(c.channel.utf8)); try field(Data(c.endpoint.utf8)) }
        try field(Data(file.path.utf8)); return output
    }
    static func validatePolicy(_ snapshot: ReceiverReapSnapshot) throws -> QuietACKRow {
        let row = try snapshot.storage.one(ReceiverReapReadOnlySnapshot.continuity)
        let expected = try policyManifest(snapshot.configuration, file: snapshot.file)
        try reapRequire(try row.integer("id") == 1 && row.integer("version") == 2 && row.integer("incarnation") > 0 &&
            row.blob("manifest") == expected && row.blob("digest") == Data(hash(expected).utf8), .policy)
        let limits = snapshot.configuration.limits
        let stores: [(String, [String: Int])] = [
            ("_lattice_obligation_store", ["id":1,"version":2,"max_scopes":limits.scopes,"max_records":limits.records,
                "max_field":limits.fieldBytes,"max_bytes":limits.journalBytes,"scopes":2]),
            ("_lattice_install_store", ["id":1,"version":2,"max_channels":limits.channels,"max_field_bytes":limits.bindingFieldBytes,
                "max_bytes":limits.bindingBytes,"channels":2]),
            ("_lattice_obligation_producer_store", ["id":1,"version":1,"max_profiles":limits.profiles,"max_stamps":limits.stamps,
                "max_field":limits.producerFieldBytes,"max_manifest":limits.manifestBytes,"max_bytes":limits.producerBytes,"profiles":2]),
            ("_lattice_recovery_request_config", ["id":1,"version":1,"max_rows":16,"max_frame":4194304,"max_context":65536,"max_bytes":134217728])]
        for (name, fields) in stores {
            let store = try snapshot.storage.one(name)
            for (key,value) in fields { try reapRequire(try store.integer(key) == Int64(value), .policy) }
        }
        return row
    }
    // Preserve exact typed AuditLog tuples copied on the child actor. Unlike a
    // model-only comparison this detects replacement IDs, operations and fields.
    static func validateImage(_ snapshot: QuietACKSnapshot, expected: RecoveryProcessImage) throws {
        try expected.validate()
        let rows = try snapshot.rows(ReceiverReapReadOnlySnapshot.shared)
        try reapRequire(rows.count == expected.rows.count, .original)
        for expected in expected.rows {
            let found = try rows.filter { try $0.text("globalId").lowercased() == expected.id.uuidString.lowercased() }
            try reapRequire(found.count == 1, .original)
            try reapRequire(try found[0].text("label").utf8.elementsEqual(expected.label.utf8) && found[0].integer("value") == Int64(expected.value), .original)
        }
        let locals = try snapshot.rows(ReceiverReapReadOnlySnapshot.local).map { try $0.text("value") }
        try reapRequire(locals.sorted() == expected.localValues.sorted(), .original)
        let audits = try snapshot.rows("AuditLog")
        for original in expected.originals {
            let matches = try audits.filter { try $0.text("globalId").lowercased() == original.id.uuidString.lowercased() }
            try reapRequire(matches.count == 1, .original); let actual = matches[0]
            try reapRequire(try actual.text("globalRowId").lowercased() == original.target.uuidString.lowercased() &&
                actual.text("tableName") == original.table && actual.text("operation") == original.operation, .original)
            // Both sides retain JSON types and all unchanged NULL placeholders.
            // Equality uses canonical JSON bytes after strict duplicate scanning.
            try rawFields(Data(actual.text("changedFields").utf8), match: original.fields, table: original.table)
            let namesData = try actual.cell("changedFieldsNames") == .null ? Data("null".utf8) : Data(actual.text("changedFieldsNames").utf8)
            var scanner = ReadyCutpointSyntax(namesData); try scanner.validate()
            let names = try JSONSerialization.jsonObject(with: namesData, options: [.fragmentsAllowed])
            let expectedNames: Any
            if let names = original.names { expectedNames = names.map { value -> Any in if let value { return value }; return NSNull() } }
            else { expectedNames = NSNull() }
            let a = try JSONSerialization.data(withJSONObject: ["names": names], options: [.sortedKeys])
            let b = try JSONSerialization.data(withJSONObject: ["names": expectedNames], options: [.sortedKeys])
            try reapRequire(a == b, .original)
        }
    }
    static func boundObservation(_ observation: RelayReadyControlObservation, to q: RelayReadyCanonicalFrame,
                                 channel: RecoveryProcessChannelConfiguration) throws -> RelayReadyCutpoint {
        guard let cut = observation.cutpoint else { throw ReceiverReapFailure.cut }
        try reapRequire(sameLogical(cut.frame, q) && observation.channel == channel.channel &&
            observation.peer.replicaID == channel.replicaID && observation.peer.receiverIncarnation.uuidString.lowercased() == channel.receiverIncarnation &&
            observation.peer.channelIncarnation.uuidString.lowercased() == channel.channelIncarnation &&
            observation.routeGeneration == cut.frame.routeGeneration && cut.requestDigest == q.requestDigest &&
            UUID(uuidString: observation.requestID)?.uuidString.lowercased() == observation.requestID, .cut)
        if observation.operation == "prepare" {
            // These legacy observer fields are top-level input keys. Prepare
            // carries them only inside Q; the accepted cutpoint binds that Q.
            try reapRequire(observation.requestDigest == nil && observation.attemptID == nil && observation.sequence == nil, .cut)
        } else {
            try reapRequire(observation.requestDigest == q.requestDigest && observation.attemptID == q.attemptID && observation.sequence == q.sequence, .cut)
        }
        return cut
    }
    static func rawFields(_ raw: Data, match typed: Data, table: String) throws {
        let actual = try object(raw), expected = try object(typed)
        try reapRequire(Set(actual.keys) == Set(expected.keys), .original)
        let allowed = table == "RecoveryProcessSharedRow" ? Set(["label", "value"]) : Set(["value"])
        try reapRequire(Set(actual.keys).isSubset(of: allowed), .original)
        for key in actual.keys {
            let property = try object(expected[key]); try keys(property, ["kind", "value"])
            let kind = try quietACKJSONInteger(property["kind"])
            if property["value"] is NSNull {
                try reapRequire(kind == 4 && actual[key] is NSNull, .original)
            } else if key == "value" && table == "RecoveryProcessSharedRow" {
                try reapRequire(kind == 0 || kind == 1, .original)
                try reapRequire(try quietACKJSONInteger(actual[key]) == quietACKJSONInteger(property["value"]), .original)
            } else {
                try reapRequire(try kind == 2 && bytes(actual[key]) == bytes(property["value"]), .original)
            }
        }
    }
    // State keeps bodies, not complete frames. Reconstruct exactly the fixed
    // envelope at route 1 after the whole raw state passed the syntax scanner.
    static func stateFrame(_ state: [String: Any], key: String, kind: String) throws -> Data {
        guard let version = state["version"], let attempt = state["attempt"], let body = state[key] else { throw ReceiverReapFailure.state }
        return try encoded(["latticeCanonicalRange": ["version": version,
            "attempt": attempt, "route_generation": "1", "kind": kind, "body": body]])
    }
    static func partialState(_ raw: Data, q: Data, manifest: Data, page: Data,
                             observedPage: RelayReadyCanonicalFrame) throws {
        let root = try object(raw); try keys(root, ["latticeCanonicalRangeState"])
        let state = try object(root["latticeCanonicalRangeState"])
        try keys(state, ["version","attempt","request","manifest","phase","next_content_page","next_receipt_page",
                         "identities","present","tombstones","content_bytes","receipts","receipt_bytes","last_identity","rebase_seen"])
        try reapRequire(state["phase"] as? String == "receiving", .state)
        try sameFrame(stateFrame(state, key: "request", kind: "request"), observed: frame(q))
        try sameFrame(stateFrame(state, key: "manifest", kind: "manifest"), observed: frame(manifest))
        try sameFrame(page, observed: observedPage, storedRoute: "1")
        let pageFrame = try frame(page), body = try object(envelope(page)["body"])
        let content = try decimal(state["next_content_page"]), receipts = try decimal(state["next_receipt_page"])
        try reapRequire(content <= 1 && receipts <= 1 && content + receipts == 1 && pageFrame.pageIndex == "0", .state)
        let isContent = pageFrame.kind == .contentPage
        try reapRequire((isContent && content == 1 && receipts == 0) || (pageFrame.kind == .receiptPage && content == 0 && receipts == 1), .state)
        guard let items = body["items"] as? [[String: Any]], !items.isEmpty else { throw ReceiverReapFailure.page }
        let count = try decimal(body["count"], positive: true), bytes = try decimal(body["bytes"], positive: true)
        let identities = try decimal(state["identities"]), present = try decimal(state["present"]), tombstones = try decimal(state["tombstones"])
        let contentBytes = try decimal(state["content_bytes"]), receiptCount = try decimal(state["receipts"]), receiptBytes = try decimal(state["receipt_bytes"])
        let totals = try object(object(envelope(manifest)["body"])["totals"])
        if isContent {
            try reapRequire(identities == count && present == Int64(items.filter { $0["tag"] as? String == "present" }.count) &&
                tombstones == Int64(items.filter { $0["tag"] as? String == "tombstone" }.count) &&
                contentBytes == bytes && receiptCount == 0 && receiptBytes == 0, .state)
            let last = try object(state["last_identity"]); try keys(last, ["table","id"])
            try reapRequire(try encoded(last) == encoded(["table": items.last!["table"] as Any, "id": items.last!["id"] as Any]), .state)
        } else {
            try reapRequire(try decimal(totals["content_pages"]) == 0 && identities == 0 && present == 0 && tombstones == 0 &&
                contentBytes == 0 && receiptCount == count && receiptBytes == bytes && state["last_identity"] is NSNull, .state)
        }
        for (key, value) in [("content_pages",content),("receipt_pages",receipts),("identities",identities),("present",present),
                             ("tombstones",tombstones),("content_bytes",contentBytes),("receipts",receiptCount),("receipt_bytes",receiptBytes)] {
            try reapRequire(try value <= decimal(totals[key]), .state)
        }
        let request = try object(envelope(q)["body"])
        guard let requests = request["receipt_requests"] as? [[String: Any]], let bitmap = state["rebase_seen"] as? String else { throw ReceiverReapFailure.state }
        var targets = Set<Data>()
        for request in requests {
            guard let values = request["targets"] as? [[String: Any]] else { throw ReceiverReapFailure.state }
            for target in values { targets.insert(try encoded(target)) }
        }
        let sorted = try targets.map { try object($0) }.sorted {
            let a = ($0["table"] as! String, $0["id"] as! String), b = ($1["table"] as! String, $1["id"] as! String)
            return a.0.utf8.elementsEqual(b.0.utf8) ? a.1.utf8.lexicographicallyPrecedes(b.1.utf8) : a.0.utf8.lexicographicallyPrecedes(b.0.utf8)
        }
        var expected = ""
        for target in sorted {
            if isContent {
                let last = items.last!, t = target["table"] as! String, id = target["id"] as! String
                let lt = last["table"] as! String, li = last["id"] as! String
                let passed = t.utf8.elementsEqual(lt.utf8) ? !li.utf8.lexicographicallyPrecedes(id.utf8) : t.utf8.lexicographicallyPrecedes(lt.utf8)
                expected += passed ? "1" : "0"
            } else { expected += "0" }
        }
        try reapRequire(bitmap == expected, .state)
    }
    static func validateSourceContext(_ raw: Data, channel c: RecoveryProcessChannelConfiguration,
                                      q: [String: Any]) throws -> Data {
        let context = try object(raw)
        try keys(context, ["source","incomingScope","peer","channel","profile","upload","receiptBinding"])
        try reapRequire(try bytes(context["channel"]) == Data(c.channel.utf8), .cohort)
        let peer = try object(context["peer"]); try keys(peer, ["replicaID","receiverIncarnation","channelIncarnation"])
        for (key, value) in [("replicaID",c.replicaID),("receiverIncarnation",c.receiverIncarnation),("channelIncarnation",c.channelIncarnation)] {
            try reapRequire(try bytes(peer[key]) == Data(value.utf8), .cohort)
        }
        let source = try object(context["source"])
        try keys(source, ["authority","sourceID","epoch","scopeDigest","schemaDigest","receiptNamespace","coverageID","coverageRevision","descriptorDigest","receiptCoverage"])
        for (key, value) in [("authority",c.authority),("sourceID",c.sourceID),("epoch",c.epoch),("scopeDigest",c.scopeDigest),
                             ("schemaDigest",c.schemaDigest),("receiptNamespace",c.receiptNamespace),("coverageID",c.coverageID),("descriptorDigest",c.descriptorDigest)] {
            try reapRequire(try bytes(source[key]) == Data(value.utf8), .cohort)
        }
        try reapRequire(try quietACKJSONInteger(source["coverageRevision"]) == c.coverageRevision, .cohort)
        let coverage = try JSONEncoder().encode(c.receiptCoverage)
        try reapRequire(try encoded(object(source["receiptCoverage"])) == encoded(object(coverage)), .cohort)
        try reapRequire(try encoded(object(context["incomingScope"])) == encoded(object(c.incomingGrantClaim)), .cohort)
        try reapRequire(try encoded(object(context["receiptBinding"])) == encoded(object(q["registered_producer"])) &&
            bytes(q["receipt_namespace"]) == Data(c.receiptNamespace.utf8), .cohort)
        let sourceQ = try object(q["source"])
        for (key,value) in [("authority",c.authority),("source_id",c.sourceID),("epoch",c.epoch),("scope_digest",c.scopeDigest),("schema_digest",c.schemaDigest)] {
            try reapRequire(try bytes(sourceQ[key]) == Data(value.utf8), .cohort)
        }
        // Domain intentionally excludes receipt enrollment metadata, matching
        // controller::domain. All full source context remains copied above.
        var domainSource = source
        for key in ["receiptNamespace","coverageID","coverageRevision","descriptorDigest","receiptCoverage"] { domainSource.removeValue(forKey: key) }
        return Data(hash(try encoded(["source": domainSource, "incomingScope": context["incomingScope"] as Any])).utf8)
    }
}

struct ReceiverReapCutEvidence: Sendable {
    let prepare: RelayReadyControlObservation
    // All three reads are present for the partial-range cut; absent for Q-only.
    let manifest, firstPage, heldSecondRead: RelayReadyControlObservation?
}

extension ReceiverReapComparison {
    static func validateCut(_ snapshot: ReceiverReapSnapshot, evidence: ReceiverReapCutEvidence,
                            preimage: RecoveryProcessImage, pendingOriginals: [RecoveryProcessOriginal]) throws {
        try reapRequire(pendingOriginals.count == 3 && Set(pendingOriginals.map(\.id)).count == 3 &&
            Set(pendingOriginals.map(\.operation)) == Set(["UPDATE","DELETE","INSERT"]) &&
            pendingOriginals.allSatisfy { $0.table == "RecoveryProcessSharedRow" && preimage.originals.contains($0) }, .original)
        try reapRequire(snapshot.spawnOrdinal == 1 && snapshot.killedByOwnedSIGKILL && !snapshot.exitedZero, .custody)
        let continuity = try validatePolicy(snapshot)
        try reapRequire(try continuity.integer("phase") == 2 && continuity.integer("barrier") > 0 && continuity.integer("attempt") > 0, .cohort)
        try validateImage(snapshot.storage, expected: preimage)
        let s = snapshot.storage, requests = try s.rows("_lattice_recovery_request"), scopes = try s.rows(ReceiverReapReadOnlySnapshot.scopes)
        try reapRequire(requests.count == 2 && scopes.count == 2, .cohort)
        var domains = Set<Data>(), contexts = Set<Data>(), requestTargets: Set<Data>?
        for c in snapshot.configuration.channels {
            let channel = Data(c.channel.utf8), request = try row(requests, channel: channel), scope = try row(scopes, channel: channel)
            let q = try request.blob("request_frame"), meta = try frame(q), body = try object(envelope(q)["body"])
            try reapRequire(meta.kind == .request && meta.canonicalVersion == 3 && meta.channel == c.channel &&
                meta.receiverIncarnation == c.receiverIncarnation && meta.channelIncarnation == c.channelIncarnation, .cohort)
            try reapRequire(try request.integer("barrier") == continuity.integer("barrier") && request.integer("sequence") == continuity.integer("attempt") &&
                String(request.integer("sequence")) == meta.sequence && request.integer("route") > 0 &&
                request.integer("incarnation") == scope.integer("incarnation") && request.integer("generation") == scope.integer("generation") &&
                request.integer("journal_revision") == scope.integer("revision") && scope.integer("freeze_revision") == scope.integer("revision") &&
                scope.integer("mode") == 1 && scope.integer("last_attempt") == request.integer("sequence"), .cohort)
            let sourceContext = try object(request.blob("source_context"))
            let profile = try object(sourceContext["profile"])
            try reapRequire(try profile["name"] as? String == "bounded48MiBOrphanV1" &&
                quietACKJSONInteger(profile["orphanResumeGraceMilliseconds"]) == 10_000, .cohort)
            contexts.insert(try encoded(["profile": profile, "upload": object(sourceContext["upload"])]))
            let domain = try validateSourceContext(request.blob("source_context"), channel: c, q: body)
            try reapRequire(try request.blob("domain") == domain, .cohort); domains.insert(domain)
            for (key,value) in [("authority",c.authority),("source",c.sourceID),("epoch",c.epoch),("scope",c.scopeDigest),
                                 ("schema_digest",c.schemaDigest),("profile_digest",c.profileDigest),("receipt_namespace",c.receiptNamespace)] {
                try reapRequire(try scope.blob(key) == Data(value.utf8), .cohort)
            }
            guard let receipts = body["receipt_requests"] as? [[String: Any]] else { throw ReceiverReapFailure.cohort }
            let targets = Set(try receipts.map { try encoded($0) })
            if let previous = requestTargets { try reapRequire(targets == previous, .cohort) }; requestTargets = targets
            for original in pendingOriginals {
                let key = original.id.uuidString.lowercased()
                let actual = receipts.filter { $0["original_id"] as? String == key }
                try reapRequire(actual.count == 1, .original)
                guard let targets = actual[0]["targets"] as? [[String: Any]] else { throw ReceiverReapFailure.original }
                try reapRequire(targets.contains { ($0["table"] as? String) == original.table && ($0["id"] as? String) == original.target.uuidString.lowercased() }, .original)
            }
            let entries = try s.rows(ReceiverReapReadOnlySnapshot.entries).filter { try $0.blob("channel") == channel }
            let stamps = try s.rows("_lattice_obligation_producer_stamp").filter { try $0.blob("channel") == channel }
            for original in pendingOriginals {
                let id = Data(original.id.uuidString.lowercased().utf8), target = Data(original.target.uuidString.lowercased().utf8)
                let entry = try entries.filter { try $0.blob("original") == id }, stamp = try stamps.filter { try $0.blob("original") == id }
                try reapRequire(entry.count == 1 && stamp.count == 1, .original)
                try reapRequire(try entry[0].blob("actual_original") == id && entry[0].blob("table_name") == Data(original.table.utf8) &&
                    entry[0].blob("target") == target && entry[0].blob("actual_target") == target &&
                    stamp[0].integer("audit_id") == entry[0].integer("audit_id") && stamp[0].integer("record_sequence") == entry[0].integer("record_sequence"), .original)
            }
        }
        try reapRequire(domains.count == 1 && contexts.count == 1, .cohort)
        guard let c = snapshot.configuration.channels.first(where: { $0.channel == evidence.prepare.channel }) else { throw ReceiverReapFailure.cut }
        let channel = Data(c.channel.utf8), selected = try row(requests, channel: channel)
        let q = try selected.blob("request_frame"), qMeta = try frame(q)
        let prepare = try boundObservation(evidence.prepare, to: qMeta, channel: c)
        try reapRequire(prepare.kind == .positivePrepareLease && evidence.prepare.operation == "prepare" && evidence.prepare.index == nil &&
            prepare.requestFrameSHA256 == hash(q) && prepare.frame.normalizedFrameSHA256 == qMeta.normalizedFrameSHA256 &&
            evidence.prepare.routeGeneration == String(try selected.integer("route")), .cut)
        let attempts = try s.rows("_lattice_range_attempt").filter { try $0.blob("channel") == channel }
        let pages = try s.rows("_lattice_range_page").filter { try $0.blob("channel") == channel }
        guard let manifestObservation = evidence.manifest else {
            try reapRequire(try evidence.firstPage == nil && evidence.heldSecondRead == nil &&
                selected.blob("manifest_frame").isEmpty && attempts.isEmpty && pages.isEmpty, .cut)
            return
        }
        guard let first = evidence.firstPage, let held = evidence.heldSecondRead else { throw ReceiverReapFailure.cut }
        let manifestCut = try boundObservation(manifestObservation, to: qMeta, channel: c)
        let firstCut = try boundObservation(first, to: qMeta, channel: c), heldCut = try boundObservation(held, to: qMeta, channel: c)
        try reapRequire(manifestCut.kind == .manifest && manifestObservation.index == "0" && first.index == "1" && held.index == "2" &&
            [manifestObservation, first, held].allSatisfy { $0.operation == "read" && $0.connectionID == evidence.prepare.connectionID &&
                $0.routeGeneration == evidence.prepare.routeGeneration } &&
            Set([evidence.prepare.requestID,manifestObservation.requestID,first.requestID,held.requestID]).count == 4 &&
            [RelayReadyCutpoint.Kind.contentPage,.receiptPage].contains(firstCut.kind) &&
            [RelayReadyCutpoint.Kind.contentPage,.receiptPage,.end].contains(heldCut.kind), .cut)
        let m = try selected.blob("manifest_frame")
        try sameFrame(m, observed: manifestCut.frame)
        // At this first connection's selected cut no intervening rebind has
        // occurred. Stored M and observed output must carry the same route.
        try reapRequire(try frame(m).routeGeneration == manifestCut.frame.routeGeneration, .cut)
        try reapRequire(manifestCut.frame.requestDigest == qMeta.requestDigest &&
            firstCut.frame.manifestDigest == manifestCut.frame.manifestDigest && heldCut.frame.manifestDigest == manifestCut.frame.manifestDigest, .cut)
        try reapRequire(attempts.count == 1 && pages.count == 1, .cut)
        let attempt = attempts[0], page = pages[0], wire = try page.blob("wire")
        try reapRequire(try attempt.integer("verified") == 0 && attempt.integer("route") == selected.integer("route") &&
            page.integer("page_index") == 0 && page.integer("stream") == (firstCut.kind == .contentPage ? 0 : 1) &&
            attempt.integer("page_bytes") == Int64(channel.count + wire.count), .cut)
        let logical = try frame(attempt.blob("logical"))
        // Core's logical END key is v2 even for a registered/v3 sequence.
        try reapRequire(logical.kind == .end && logical.routeGeneration == "1" && logical.channel == qMeta.channel &&
            logical.receiverIncarnation == qMeta.receiverIncarnation && logical.channelIncarnation == qMeta.channelIncarnation &&
            logical.attemptID == qMeta.attemptID && logical.sequence == qMeta.sequence && logical.manifestDigest == manifestCut.frame.manifestDigest, .cut)
        let totals = try object(object(envelope(m)["body"])["totals"])
        for key in ["content_pages","identities","content_bytes","receipt_pages","receipts","receipt_bytes"] {
            try reapRequire(try attempt.integer(key) == decimal(totals[key]), .cut)
        }
        try partialState(attempt.blob("state"), q: q, manifest: m, page: wire, observedPage: firstCut.frame)
    }
    static func validateFinal(_ final: ReceiverReapSnapshot, after cut: ReceiverReapSnapshot,
                              expected: RecoveryProcessImage, pendingOriginals: [RecoveryProcessOriginal]) throws {
        try reapRequire(pendingOriginals.count == 3 && Set(pendingOriginals.map(\.id)).count == 3 &&
            pendingOriginals.allSatisfy { expected.originals.contains($0) }, .original)
        try reapRequire(final.spawnOrdinal == 2 && final.exitedZero && !final.killedByOwnedSIGKILL &&
            final.instanceID != cut.instanceID && final.file == cut.file && final.configuration == cut.configuration &&
            final.configurationSHA256 == cut.configurationSHA256, .custody)
        let a = try validatePolicy(cut), b = try validatePolicy(final)
        for key in ["main_device","main_inode","parent_device","parent_inode","container_device","container_inode"] {
            try reapRequire(try a.integer(key) == b.integer(key), .custody)
        }
        try reapRequire(try b.integer("incarnation") > a.integer("incarnation") && b.integer("phase") == 0 &&
            b.integer("attempt") >= a.integer("attempt") && b.integer("barrier") >= a.integer("barrier"), .installed)
        try validateImage(final.storage, expected: expected)
        let store = try final.storage.one("_lattice_install_store")
        for c in final.configuration.channels {
            let channel = Data(c.channel.utf8), installed = try row(final.storage.rows(ReceiverReapReadOnlySnapshot.installs), channel: channel)
            let scope = try row(final.storage.rows(ReceiverReapReadOnlySnapshot.scopes), channel: channel)
            try reapRequire(try installed.cell("active") == .null && installed.integer("frontier_kind") == 2 && scope.integer("mode") == 0 &&
                installed.integer("last_sequence") >= a.integer("attempt"), .installed)
            try quietACKValidateInstalledIdentity(channel: installed, scope: scope, store: store)
            for original in pendingOriginals {
                let entries = try final.storage.rows(ReceiverReapReadOnlySnapshot.entries).filter {
                    try $0.blob("channel") == channel && $0.blob("original") == Data(original.id.uuidString.lowercased().utf8)
                }
                try reapRequire(entries.count == 1, .original)
                try reapRequire(try entries[0].integer("stage") == 2 && entries[0].integer("settled_sequence") > 0 &&
                    entries[0].integer("settled_sequence") <= installed.integer("last_sequence"), .installed)
            }
            let identity = try QuietACKInstallIdentity.decode(installed.blob("last_install"), maximumFieldBytes: store.integer("max_field_bytes"), maximumEncodedBytes: store.integer("max_bytes"))
            if try installed.integer("last_sequence") == a.integer("attempt") {
                let request = try row(cut.storage.rows("_lattice_recovery_request"), channel: channel)
                try reapRequire(identity.requestDigest == Data(try frame(request.blob("request_frame")).requestDigest!.utf8), .installed)
                let m = try request.blob("manifest_frame")
                if !m.isEmpty { try reapRequire(identity.manifestDigest == Data(try frame(m).manifestDigest!.utf8), .installed) }
            }
        }
        for before in try cut.storage.rows("AuditLog") {
            let matches = try final.storage.rows("AuditLog").filter { try $0.cell("id") == before.cell("id") }
            try reapRequire(matches.count == 1 && matches[0] == before, .original)
        }
        // Retained ACK/claim/original identity and allocator high-water evidence
        // is not rewritten to fit a new Q. Mutable settlement bits may advance.
        for table in [ReceiverReapReadOnlySnapshot.entries, "_lattice_obligation_producer_stamp"] {
            for before in try cut.storage.rows(table) {
                let matches = try final.storage.rows(table).filter { try $0.blob("channel") == before.blob("channel") && $0.blob("original") == before.blob("original") }
                try reapRequire(matches.count == 1, .original)
                let immutable = table == ReceiverReapReadOnlySnapshot.entries ?
                    ["channel","original","audit_id","actual_original","table_name","target","actual_target","origin","record_sequence"] : Array(before.cells.keys)
                try reapRequire(try before.selecting(immutable) == matches[0].selecting(immutable), .original)
                if table == ReceiverReapReadOnlySnapshot.entries {
                    for key in ["first_export","ack_position","ack_outcome"] where try before.cell(key) != .null {
                        try reapRequire(try before.cell(key) == matches[0].cell(key), .original)
                    }
                    try reapRequire(try matches[0].integer("stage") >= before.integer("stage"), .original)
                }
            }
        }
        for key in ["incarnation","record_sequence","export_sequence"] {
            try reapRequire(try final.storage.one("_lattice_obligation_store").integer(key) >= cut.storage.one("_lattice_obligation_store").integer(key), .original)
        }
    }
}
