import Foundation
import CLatticeDiagnosticsSQLite

/// Optional host guard for a physically scoped store. A malformed foreign-container row
/// must not be exposed merely because it was written into the authorized source's file.
public enum LatticeScopeValidation {
    public enum Failure: Error, Sendable, CustomStringConvertible, LocalizedError {
        case unavailable, invalidIdentitySchema, scopeMismatch
        public var description: String {
            switch self {
            case .unavailable: "The scoped source could not be validated within its read budget."
            case .invalidIdentitySchema: "The source does not expose the required container identity fields."
            case .scopeMismatch: "The source contains metadata outside the authorized container."
            }
        }
        public var errorDescription: String? { description }
    }

    /// Absent model tables are allowed for legacy stores. Nonempty required identities must
    /// have a matching field on every row. An expected empty identity also accepts a legacy
    /// absent/NULL field. Comparisons ignore UUID letter casing.
    /// Runs off the host's actor, holds one read transaction, and supports cancellation.
    public static func validate(fileURL: URL, requiredValues: [String: [String: String]]) async throws {
        try Task.checkCancellation()
        let worker = Task.detached {
            try check(fileURL: fileURL, requiredValues: requiredValues)
        }
        try await withTaskCancellationHandler {
            try await worker.value
            try Task.checkCancellation()
        } onCancel: {
            worker.cancel()
        }
    }

    private final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
    }

    private static func check(fileURL: URL, requiredValues: [String: [String: String]]) throws {
        try Task.checkCancellation()
        guard requiredValues.count <= 32 else { throw Failure.invalidIdentitySchema }
        var db: OpaquePointer?
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            throw Failure.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let budget = Budget()
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue()
            return Task.isCancelled || ProcessInfo.processInfo.systemUptime >= budget.deadline ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        func statement(_ sql: String, values: [String]) throws -> OpaquePointer {
            var result: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
                throw Failure.unavailable
            }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                guard sqlite3_bind_text(result, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                    sqlite3_finalize(result); throw Failure.unavailable
                }
            }
            return result
        }
        func identifier(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for model in requiredValues.keys.sorted() {
            try Task.checkCancellation()
            let values = requiredValues[model]!
            guard !model.isEmpty, model.utf8.count <= 256, !model.contains("\0"), values.count <= 16,
                  values.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("\0") && $0.key.utf8.count <= 256 && !$0.value.contains("\0") && $0.value.utf8.count <= 4096 }) else {
                throw Failure.invalidIdentitySchema
            }
            let schema = try statement("SELECT name FROM pragma_table_info(?)", values: [model])
            var columns = Set<String>()
            var rc = sqlite3_step(schema)
            while rc == SQLITE_ROW {
                if let name = sqlite3_column_text(schema, 0) { columns.insert(String(cString: name)) }
                rc = sqlite3_step(schema)
            }
            sqlite3_finalize(schema)
            guard rc == SQLITE_DONE else { throw Failure.unavailable }
            if columns.isEmpty { continue }
            guard values.allSatisfy({ columns.contains($0.key) || $0.value.isEmpty }) else { throw Failure.invalidIdentitySchema }
            if values.isEmpty { continue }
            let fields = values.keys.filter { columns.contains($0) }.sorted()
            if fields.isEmpty { continue }
            let predicate = fields.map {
                let column = values[$0]!.isEmpty ? "COALESCE(\(identifier($0)), '')" : identifier($0)
                return "\(column) COLLATE NOCASE IS NOT ?"
            }.joined(separator: " OR ")
            let query = try statement("SELECT 1 FROM \(identifier(model)) WHERE \(predicate) LIMIT 1",
                                      values: fields.map { values[$0]! })
            let result = sqlite3_step(query)
            sqlite3_finalize(query)
            if result == SQLITE_ROW { throw Failure.scopeMismatch }
            guard result == SQLITE_DONE else { throw Failure.unavailable }
        }
        try Task.checkCancellation()
    }
}
