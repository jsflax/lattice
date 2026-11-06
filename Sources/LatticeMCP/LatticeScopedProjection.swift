import Foundation
import Lattice
import CLatticeDiagnosticsSQLite

/// Copies scalar debug values while the host's row predicate is evaluated in the
/// same SQLite snapshot. Candidate IDs and ORM objects are never authorization.
enum LatticeScopedProjection {
    enum Failure: Error, Sendable, CustomStringConvertible, LocalizedError {
        case unavailable
        var description: String { "The scoped values could not be read within their read budget." }
        var errorDescription: String? { description }
    }

    static func rows(fileURL: URL, schema: ObjectSchema, fields: Set<String>?, ids: [Int64],
                     scopePredicate: String?) throws -> [Int64: [String: Any]] {
        try readRows(fileURL: fileURL, schema: schema, fields: fields, ids: ids,
                     scopePredicate: scopePredicate, afterFirstRow: nil)
    }

    /// The observer is an internal test seam: a WAL writer can commit after the
    /// first sqlite3_step, proving both later rows and copied values share a snapshot.
    static func readRows(fileURL: URL, schema: ObjectSchema, fields: Set<String>?, ids: [Int64],
                         scopePredicate: String?, afterFirstRow: (() throws -> Void)?) throws -> [Int64: [String: Any]] {
        try Task.checkCancellation()
        guard ids.count <= 501, schema.properties.count <= 512,
              fields == nil || fields!.isSubset(of: Set(schema.properties.map(\.name)).union(["id", "globalId"])),
              schema.properties.allSatisfy({ $0.kind == .primitive }),
              Set(schema.properties.map(\.name)).count == schema.properties.count,
              scopePredicate?.utf8.count ?? 0 <= 65_536,
              scopePredicate?.contains("\0") != true else { throw Failure.unavailable }
        _ = try identifier(schema.name)
        for property in schema.properties { _ = try identifier(property.name) }
        if ids.isEmpty { return [:] }
        let url = fileURL.standardizedFileURL
        let identity = try fileIdentity(url)
        let budget = Budget()
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close(db) }
            throw Failure.unavailable
        }
        defer { sqlite3_close(db) }
        guard try fileIdentity(url) == identity,
              lattice_sqlite_disable_dqs(db) == SQLITE_OK,
              sqlite3_busy_timeout(db, 250) == SQLITE_OK else { throw Failure.unavailable }
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue()
            return Task.isCancelled || budget.expired ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        var columns = [try column("id")]
        var projections: [Projection] = []
        func append(_ property: PropertyInfo) throws {
            let index = Int32(columns.count)
            if property.isVector || property.columnType == .blob {
                projections.append(.omitted(property.name, property.isVector ? "vector" : "blob"))
            } else if property.isGeoBounds {
                for component in components { columns.append(try column(property.name + "_" + component)) }
                projections.append(.geo(property.name, index))
            } else if property.columnType == .text {
                let name = try column(property.name)
                // Only a bounded byte prefix crosses the SQLite interface. typeof
                // is checked before accepting the cast; TEXT stays literal TEXT.
                columns += ["typeof(\(name))", "length(CAST(\(name) AS BLOB))", "substr(CAST(\(name) AS BLOB),1,2048)"]
                projections.append(.text(property.name, index))
            } else {
                columns.append(try column(property.name))
                projections.append(.number(property.name, property.columnType, index))
            }
        }
        try append(PropertyInfo(name: "globalId", kind: .primitive, columnType: .text))
        for property in schema.properties where property.name != "id" && property.name != "globalId" {
            if fields == nil || fields!.contains(property.name) { try append(property) }
        }
        guard columns.count <= 2_000 else { throw Failure.unavailable }
        let predicate = scopePredicate.map { " AND (\($0))" } ?? ""
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT \(columns.joined(separator: ",")) FROM \(try identifier(schema.name)) AS \"_latticeProjection\" WHERE \(try column("id")) IN (\(placeholders))\(predicate)"
        var statement: OpaquePointer?
        let prepared = sql.withCString { sqlBytes -> Bool in
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(db, sqlBytes, -1, &statement, &tail) == SQLITE_OK else { return false }
            return tail.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        }
        guard prepared, let statement else {
            if statement != nil { sqlite3_finalize(statement) }
            throw Failure.unavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw Failure.unavailable }
        for (index, id) in ids.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(index + 1), id) == SQLITE_OK else { throw Failure.unavailable }
        }
        var result: [Int64: [String: Any]] = [:]
        var observedFirstRow = false
        while true {
            try budget.check()
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw Failure.unavailable }
            if !observedFirstRow { observedFirstRow = true; try afterFirstRow?() }
            let id = sqlite3_column_int64(statement, 0)
            guard result[id] == nil, ids.contains(id) else { throw Failure.unavailable }
            var row: [String: Any] = ["id": id]
            var omissions: [String: String] = [:]
            for projection in projections {
                try budget.check()
                switch projection {
                case .omitted(let name, let reason): omissions[name] = reason
                case .text(let name, let index):
                    let value = try text(statement, index)
                    if let value {
                        row[name] = value.value
                        if value.originalBytes > 2_048 { omissions[name] = "text_excerpt; originalBytes=\(value.originalBytes)" }
                    } else if name != "globalId" || (schema.property(named: name) != nil && (fields == nil || fields!.contains(name))) {
                        row[name] = NSNull()
                    }
                case .number(let name, let type, let index):
                    let value = try number(statement, index, type: type)
                    if let value { row[name] = value }
                    else { row[name] = NSNull() }
                    if type == .real, sqlite3_column_type(statement, index) != SQLITE_NULL,
                       !sqlite3_column_double(statement, index).isFinite {
                        omissions[name] = "non_finite_number"
                    }
                case .geo(let name, let index):
                    if sqlite3_column_type(statement, index) == SQLITE_NULL { continue }
                    var bounds: [String: Double] = [:]
                    var nonFinite = false
                    for (offset, component) in components.enumerated() {
                        let position = index + Int32(offset)
                        let value = try number(statement, position, type: .real)
                        // A partially NULL bounds tuple is malformed; unlike a
                        // live getter, this read never silently turns NULL into 0.
                        guard sqlite3_column_type(statement, position) != SQLITE_NULL else { throw Failure.unavailable }
                        if let value = value as? Double { bounds[component] = value }
                        else { nonFinite = true }
                    }
                    if nonFinite { row[name] = NSNull(); omissions[name] = "non_finite_number" }
                    else { row[name] = bounds }
                }
            }
            if !omissions.isEmpty { row["_latticeDebugOmissions"] = omissions }
            result[id] = row
        }
        try budget.check()
        guard try fileIdentity(url) == identity else { throw Failure.unavailable }
        return result
    }

    private static let components = ["minLat", "maxLat", "minLon", "maxLon"]
    private enum Projection {
        case omitted(String, String), text(String, Int32), number(String, ColumnType, Int32), geo(String, Int32)
    }
    private final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
        func check() throws {
            try Task.checkCancellation()
            if expired { throw Failure.unavailable }
        }
    }
    private static func identifier(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 256, !name.contains("\0") else { throw Failure.unavailable }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func column(_ name: String) throws -> String { "\"_latticeProjection\"." + (try identifier(name)) }

    private static func number(_ statement: OpaquePointer, _ index: Int32, type: ColumnType) throws -> Any? {
        let storage = sqlite3_column_type(statement, index)
        if storage == SQLITE_NULL { return nil }
        if type == .integer {
            guard storage == SQLITE_INTEGER else { throw Failure.unavailable }
            return sqlite3_column_int64(statement, index)
        }
        guard type == .real, storage == SQLITE_INTEGER || storage == SQLITE_FLOAT else { throw Failure.unavailable }
        let value = sqlite3_column_double(statement, index)
        return value.isFinite ? value : nil
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) throws -> (value: String, originalBytes: Int64)? {
        guard let rawType = sqlite3_column_text(statement, index) else { throw Failure.unavailable }
        let storage = String(cString: rawType)
        if storage == "null" { return nil }
        guard storage == "text", sqlite3_column_type(statement, index + 1) == SQLITE_INTEGER else { throw Failure.unavailable }
        let originalBytes = sqlite3_column_int64(statement, index + 1)
        let count = Int(sqlite3_column_bytes(statement, index + 2))
        guard originalBytes >= 0, count == min(originalBytes, 2_048) else { throw Failure.unavailable }
        if count == 0 {
            guard originalBytes == 0, [SQLITE_NULL, SQLITE_BLOB].contains(sqlite3_column_type(statement, index + 2)) else { throw Failure.unavailable }
            return ("", originalBytes)
        }
        guard sqlite3_column_type(statement, index + 2) == SQLITE_BLOB else { throw Failure.unavailable }
        guard let pointer = sqlite3_column_blob(statement, index + 2) else { throw Failure.unavailable }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: count)
        // Only an incomplete final code point may be dropped. An invalid prefix
        // or malformed untruncated TEXT fails instead of replacing characters.
        for removed in 0...(originalBytes > 2_048 ? min(3, count) : 0) {
            if let value = String(bytes: bytes.prefix(count - removed), encoding: .utf8) {
                if removed > 0 {
                    let suffix = Array(bytes.suffix(removed))
                    let lead = suffix[0]
                    let width = lead >= 0xC2 && lead <= 0xDF ? 2 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0
                    guard width > suffix.count, suffix.dropFirst().allSatisfy({ $0 >= 0x80 && $0 <= 0xBF }) else { throw Failure.unavailable }
                    if suffix.count > 1 {
                        let second = suffix[1]
                        guard !(lead == 0xE0 && second < 0xA0), !(lead == 0xED && second >= 0xA0),
                              !(lead == 0xF0 && second < 0x90), !(lead == 0xF4 && second >= 0x90) else { throw Failure.unavailable }
                    }
                }
                return (value, originalBytes)
            }
        }
        throw Failure.unavailable
    }

    private static func fileIdentity(_ url: URL) throws -> String {
        guard url.isFileURL else { throw Failure.unavailable }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { throw Failure.unavailable }
            return "\(device):\(inode)"
        } catch { throw Failure.unavailable }
    }
}
