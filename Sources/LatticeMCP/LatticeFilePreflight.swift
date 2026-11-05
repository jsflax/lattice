import Foundation
import CLatticeDiagnosticsSQLite

/// Reject invalid/ordinary SQLite files before entering Core's dynamic schema loader.
enum LatticeFilePreflight {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
    static func signature(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure("Source is not a regular database file.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
            throw Failure("Not a Lattice database (bad or empty file).")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            throw Failure("Readonly database open failed.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM _lattice_meta WHERE key IN ('schema_version','lattice_swift_schema') LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw Failure("No recognizable Lattice metadata was found.")
        }
        let hasMetadata = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement); statement = nil
        guard hasMetadata else { throw Failure("No recognizable Lattice metadata was found.") }
        guard sqlite3_prepare_v2(db, "PRAGMA schema_version", -1, &statement, nil) == SQLITE_OK else {
            throw Failure("Cannot read schema version.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw Failure("Cannot read schema version; database may be busy or corrupt.")
        }
        return "\(attributes[.systemNumber] ?? "?"):\(attributes[.systemFileNumber] ?? "?"):\(sqlite3_column_int64(statement, 0))"
    }
    static func identity(_ signature: String) -> String {
        signature.split(separator: ":").prefix(2).joined(separator: ":")
    }
}
