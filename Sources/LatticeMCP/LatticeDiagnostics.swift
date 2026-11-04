import Foundation
import CoreFoundation
import CLatticeDiagnosticsSQLite

/// Bounded diagnostics over a separate SQLITE_OPEN_READONLY connection. Every
/// page (anchor, bounds, and events) shares one read transaction; no connection
/// or transaction survives a long-poll sleep. No sync agent is started here.
public actor LatticeDiagnostics {
    private let fileURL: URL
    private let readPolicy: LatticeReadPolicy?
    private var allowedModels: Set<String>? { readPolicy.map { Set($0.permittedFields.keys) } }
    private static let maxScan = 2_000
    private static let maxResponseBytes = 28 * 1_024
    // Scoped clients must not receive the global audit IDs needed internally
    // for continuity, including anchors on hidden models. Keep those cursors
    // inside the reader and return random, bounded-lifetime handles instead.
    private var scopedCursors: [String: Cursor] = [:]
    private var scopedCursorOrder: [String] = []

    /// Embedders should resolve an authorized store themselves. `readPolicy`
    /// also filters AuditLog, so hidden model names/values never enter responses.
    /// Historical row authorization uses retained event-time identity evidence
    /// when the host supplies requiredRowValues; it never reads current rows.
    public init(fileURL: URL, readPolicy: LatticeReadPolicy? = nil) {
        self.fileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        self.readPolicy = readPolicy
    }

    public func handle(tool: String, argumentsJSON: String) async -> ProviderResult {
        do {
            guard argumentsJSON.utf8.count <= 65_536 else { throw Failure("invalid_arguments", "Arguments exceed the 64 KiB limit.") }
            guard let value = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)), let args = value as? [String: Any] else {
                throw Failure("invalid_arguments", "Arguments must be a JSON object.")
            }
            if tool == "lattice_status" {
                try Self.validateKeys(args, allowed: ["db"])
                return try Self.result(status())
            }
            guard tool == "lattice_changes" else { throw Failure("unknown_tool", "Unknown diagnostics tool.") }
            let options = try Options(args, readPolicy: readPolicy)
            var cursor = try options.cursor.map(decodeIncomingCursor)
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(options.waitMs))
            while true {
                try Task.checkCancellation()
                let page = try changes(options, cursor: cursor)
                if !page.events.isEmpty || page.hasMore || options.waitMs == 0 || ContinuousClock.now >= deadline {
                    var json = page.json(nextCursor: try issueCursor(page.cursor))
                    if readPolicy != nil { json["cursorLifetime"] = "reader_instance" }
                    return try Self.result(json)
                }
                cursor = page.cursor
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining > .zero { try await Task.sleep(for: min(.milliseconds(200), remaining)) }
            }
        } catch let failure as Failure {
            return .error(failure.code, failure.message)
        } catch is CancellationError {
            return .error("cancelled", "The diagnostics request was cancelled.")
        } catch {
            return .error("query_failed", "\(error)")
        }
    }

    private struct Failure: Error {
        let code: String
        let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }

    private struct Cursor: Codable {
        var version = 1
        let database: String
        let filter: String
        let after: Int64
        let anchor: String?
        let upper: Int64?
        let continuity: String
    }

    private struct Options {
        let cursor: String?
        let start: String
        let models: Set<String>?
        let operations: Set<String>?
        let origin: String
        let globalRowID: String?
        let limit: Int
        let waitMs: Int
        let includeValues: Bool
        let fingerprint: String

        init(_ args: [String: Any], readPolicy: LatticeReadPolicy?) throws {
            let allowedModels = readPolicy.map { Set($0.permittedFields.keys) }
            try LatticeDiagnostics.validateKeys(args, allowed: ["db", "cursor", "start", "models", "operations", "origin", "globalRowId", "limit", "waitMs", "includeValues"])
            cursor = try Self.string(args, "cursor", max: 8_192)
            start = try Self.string(args, "start", max: 16) ?? "now"
            guard ["now", "retained"].contains(start), cursor == nil || args["start"] == nil else {
                throw Failure("invalid_arguments", "Use start now or retained; do not combine start with cursor.")
            }
            let requestedModels = try Self.strings(args, "models")
            let provableModels = readPolicy?.requiredRowValues.map { Set($0.filter { !$0.value.isEmpty }.keys) }
            if let allowedModels, let requestedModels, !requestedModels.isSubset(of: allowedModels) {
                throw Failure("forbidden_model", "A requested model is outside this store's authorized scope.")
            }
            if let provableModels, let requestedModels, !requestedModels.isSubset(of: provableModels) {
                throw LatticeDiagnostics.scopeProofFailure()
            }
            models = requestedModels ?? provableModels.map { $0.intersection(allowedModels ?? $0) } ?? allowedModels
            operations = try Self.strings(args, "operations")
            guard operations?.isSubset(of: ["INSERT", "UPDATE", "DELETE"]) != false else {
                throw Failure("invalid_arguments", "Operations must be INSERT, UPDATE, or DELETE.")
            }
            origin = try Self.string(args, "origin", max: 16) ?? "all"
            guard ["all", "local", "remote"].contains(origin) else { throw Failure("invalid_arguments", "Origin must be all, local, or remote.") }
            let row = try Self.string(args, "globalRowId", max: 64)
            guard row == nil || UUID(uuidString: row!) != nil else { throw Failure("invalid_arguments", "globalRowId must be a UUID.") }
            globalRowID = row?.lowercased()
            limit = try Self.integer(args, "limit", defaultValue: 100, range: 1...500)
            waitMs = try Self.integer(args, "waitMs", defaultValue: 0, range: 0...25_000)
            if let value = args["includeValues"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw Failure("invalid_arguments", "includeValues must be a boolean.")
                }
                includeValues = number.boolValue
            } else { includeValues = false }
            var filter: [String: Any] = ["models": models.map { $0.sorted() } as Any? ?? NSNull(),
                                       "operations": operations.map { $0.sorted() } as Any? ?? NSNull(),
                                       "origin": origin, "globalRowId": globalRowID as Any? ?? NSNull(),
                                       "readPolicy": readPolicy.map { $0.permittedFields.mapValues { $0.sorted() } } as Any? ?? NSNull()]
            if let required = readPolicy?.requiredRowValues { filter["requiredRowValues"] = required }
            fingerprint = LatticeDiagnostics.digest(String(decoding: try JSONSerialization.data(withJSONObject: filter, options: [.sortedKeys]), as: UTF8.self))
        }

        private static func string(_ args: [String: Any], _ key: String, max: Int) throws -> String? {
            guard let value = args[key] else { return nil }
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= max, !value.contains("\0") else {
                throw Failure("invalid_arguments", "\(key) must be a nonempty string of at most \(max) bytes.")
            }
            return value
        }
        private static func strings(_ args: [String: Any], _ key: String) throws -> Set<String>? {
            guard let value = args[key] else { return nil }
            guard let values = value as? [String], !values.isEmpty, values.count <= 64,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
                throw Failure("invalid_arguments", "\(key) must contain 1 to 64 nonempty strings.")
            }
            return Set(values)
        }
        private static func integer(_ args: [String: Any], _ key: String, defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = args[key] else { return defaultValue }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
                throw Failure("invalid_arguments", "\(key) must be an integer in \(range.lowerBound)...\(range.upperBound).")
            }
            return number.intValue
        }
    }

    private struct Page {
        let events: [[String: Any]]
        let cursor: Cursor
        let hasMore: Bool
        let minimum: Int64?
        let maximum: Int64?
        let scanningLimited: Bool
        let auditingDisabled: Bool?
        func json(nextCursor: String) -> [String: Any] {
                ["events": events, "nextCursor": nextCursor, "hasMore": hasMore,
                 "coverage": "retained_history_only", "continuity": cursor.continuity,
                 "auditBounds": ["minimum": minimum as Any? ?? NSNull(), "maximum": maximum as Any? ?? NSNull()],
                 "scanLimited": scanningLimited, "auditingDisabled": auditingDisabled as Any? ?? NSNull()]
        }
    }

    private func status() throws -> [String: Any] {
        try withDatabase { db, _ in
            let columns = try db.columns("AuditLog")
            let supported = Self.requiredColumns.isSubset(of: columns)
            let bounds = supported && readPolicy == nil ? try auditBounds(db, models: nil) : (nil, nil, 0)
            let unsynchronized: Int64? = supported && readPolicy == nil && columns.contains("isSynchronized")
                ? try auditUnsynchronizedCount(db, models: allowedModels) : nil
            let mode = try db.rows("PRAGMA journal_mode").first?.values.first as? String ?? "unknown"
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let walAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path + "-wal")
            return ["version": LatticeToolCatalog.version, "readOnly": true, "sqliteVersion": String(cString: sqlite3_libversion()), "journalMode": mode,
                    "fileBytes": attributes[.size] as? NSNumber ?? 0, "walBytes": walAttributes?[.size] as? NSNumber ?? 0,
                    "audit": ["supported": supported, "retainedCount": readPolicy == nil ? bounds.2 as Any : NSNull(),
                              "minimum": bounds.0 as Any? ?? NSNull(), "maximum": bounds.1 as Any? ?? NSNull(),
                              "coverage": "retained_history_only", "auditingDisabled": try auditingDisabled(db) as Any? ?? NSNull(),
                              "countsAvailable": readPolicy == nil,
                              "unsynchronizedRetainedCount": unsynchronized as Any? ?? NSNull(),
                              "unsynchronizedCountMeaning": "Retained audit rows marked isSynchronized=0 in this file; not a per-channel delivery or acknowledgement count."],
                    "sync": ["connection": "unknown", "pendingUpload": NSNull(), "lastError": NSNull(),
                             "detail": "A read-only file inspection does not establish live transport or peer state."]]
        }
    }

    private static let requiredColumns: Set<String> = ["id", "globalId", "tableName", "operation", "globalRowId", "timestamp", "isFromRemote", "changedFields", "changedFieldsNames"]

    private static func scopeProofFailure() -> Failure {
        Failure("scope_proof_unavailable", "Retained audit history cannot establish the authorized container scope for this request.")
    }

    /// The proof concerns recorded transitions, not audit authenticity or writes
    /// made while auditing was disabled. A missing global ID in an evidence
    /// interval is unknown: it could have been a removed identity change.
    private final class HistoryScopeProof {
        private struct Key: Hashable { let model: String; let rowID: String }
        private struct State { var identities: [String: String]; var alive: Bool; var after: Int64 }
        private let db: Database
        private let required: [String: [String: String]]
        private let deadline: CFAbsoluteTime
        private var history: [Int64: [String: Any]] = [:]
        private var states: [Key: State] = [:]
        private var extraRows = 0

        init(db: Database, required: [String: [String: String]], rows: [[String: Any]], deadline: CFAbsoluteTime) {
            self.db = db; self.required = required; self.deadline = deadline
            for row in rows { if let id = row["id"] as? Int64 { history[id] = row } }
        }

        func allows(_ row: [String: Any]) throws -> Bool {
            do {
                try checkBudget()
                guard let model = row["tableName"] as? String, let expected = required[model], !expected.isEmpty,
                      expected.count <= 16,
                      expected.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && !$0.key.contains("\0") && $0.value.utf8.count <= 4096 && !$0.value.contains("\0") }),
                      let rowID = row["globalRowId"] as? String, UUID(uuidString: rowID) != nil,
                      let id = row["id"] as? Int64, id > 0,
                      let operation = row["operation"] as? String else { throw LatticeDiagnostics.scopeProofFailure() }
                let key = Key(model: model, rowID: rowID.lowercased())
                let mutable = Set(expected.keys).subtracting(["globalId"])
                // The event's row UUID is an immutable identity at event time.
                if mutable.isEmpty { return matches(["globalId": key.rowID], expected) }
                if operation == "INSERT" {
                    let delta = try identities(row, key: key, fields: mutable)
                    guard mutable.isSubset(of: Set(delta.keys)) else { throw LatticeDiagnostics.scopeProofFailure() }
                    let state = State(identities: delta.merging(["globalId": key.rowID]) { _, new in new }, alive: true, after: id)
                    states[key] = state
                    return matches(state.identities, expected)
                }
                guard operation == "UPDATE" || operation == "DELETE" else { throw LatticeDiagnostics.scopeProofFailure() }
                let before = try stateBefore(id, key: key, fields: mutable)
                guard before.alive else { throw LatticeDiagnostics.scopeProofFailure() }
                let after = try apply(row, to: before, key: key, fields: mutable)
                states[key] = after
                return matches(before.identities, expected) && (operation == "DELETE" || matches(after.identities, expected))
            } catch { throw LatticeDiagnostics.scopeProofFailure() }
        }

        private func checkBudget() throws {
            guard !Task.isCancelled, CFAbsoluteTimeGetCurrent() < deadline else { throw LatticeDiagnostics.scopeProofFailure() }
        }

        private func matches(_ identities: [String: String], _ expected: [String: String]) -> Bool {
            expected.allSatisfy { key, value in
                guard let actual = identities[key] else { return false }
                return UUID(uuidString: value) != nil ? actual.lowercased() == value.lowercased() : actual == value
            }
        }

        private func isSameRow(_ row: [String: Any], _ key: Key) -> Bool {
            (row["tableName"] as? String) == key.model && (row["globalRowId"] as? String)?.lowercased() == key.rowID
        }

        private func identities(_ row: [String: Any], key: Key, fields: Set<String>) throws -> [String: String] {
            try checkBudget()
            guard let size = row["fieldsBytes"] as? Int64, size <= 8192,
                  let namesSize = row["namesBytes"] as? Int64, namesSize <= 8192,
                  let raw = row["fields"] as? String,
                  let payload = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let rawNames = row["names"] as? String,
                  let names = try? JSONSerialization.jsonObject(with: Data(rawNames.utf8)) as? [Any],
                  names.allSatisfy({ $0 is String || $0 is NSNull }) else { throw LatticeDiagnostics.scopeProofFailure() }
            let named = Set(names.compactMap { $0 as? String })
            var delta: [String: String] = [:]
            for field in fields.union(["globalId"]) {
                let value = payload[field]
                if !named.contains(field) {
                    // Core UPDATE payloads retain unchanged properties as null
                    // placeholders; only the names array identifies deltas.
                    guard value == nil || ((row["operation"] as? String) == "UPDATE" && value is NSNull) else {
                        throw LatticeDiagnostics.scopeProofFailure()
                    }
                    continue
                }
                guard let value else { throw LatticeDiagnostics.scopeProofFailure() }
                do {
                    let identity: String
                    if let text = value as? String, !text.contains("\0"), text.utf8.count <= 4096 { identity = text }
                    else if value is NSNull { identity = "" }
                    else { throw LatticeDiagnostics.scopeProofFailure() }
                    if field == "globalId" {
                        guard identity.lowercased() == key.rowID else { throw LatticeDiagnostics.scopeProofFailure() }
                    } else { delta[field] = identity }
                }
            }
            return delta
        }

        private func historicalRow(_ id: Int64) throws -> [String: Any] {
            try checkBudget()
            guard id > 0 else { throw LatticeDiagnostics.scopeProofFailure() }
            if let row = history[id] { return row }
            let remaining = LatticeDiagnostics.maxScan - extraRows
            guard remaining > 0 else { throw LatticeDiagnostics.scopeProofFailure() }
            let rows = try db.rows("""
                SELECT id, tableName, operation, globalRowId,
                       substr(changedFieldsNames,1,8192) AS names, length(CAST(changedFieldsNames AS BLOB)) AS namesBytes,
                       substr(changedFields,1,8192) AS fields, length(CAST(changedFields AS BLOB)) AS fieldsBytes
                FROM AuditLog WHERE id <= ? ORDER BY id DESC LIMIT ?
                """, [.integer(id), .integer(Int64(min(128, remaining)))], deadline: deadline)
            extraRows += rows.count
            for row in rows { if let value = row["id"] as? Int64 { history[value] = row } }
            guard let row = history[id] else { throw LatticeDiagnostics.scopeProofFailure() }
            return row
        }

        private func stateBefore(_ id: Int64, key: Key, fields: Set<String>) throws -> State {
            if var state = states[key] {
                guard state.after < id else { throw LatticeDiagnostics.scopeProofFailure() }
                var next = state.after + 1
                while next < id {
                    let row = try historicalRow(next)
                    if isSameRow(row, key) { state = try apply(row, to: state, key: key, fields: fields) }
                    next += 1
                }
                return state
            }
            var previous = id - 1
            var intervening: [[String: Any]] = []
            while previous > 0 {
                let row = try historicalRow(previous)
                if isSameRow(row, key) {
                    guard let operation = row["operation"] as? String, operation == "INSERT" || operation == "UPDATE" else {
                        throw LatticeDiagnostics.scopeProofFailure()
                    }
                    let delta = try identities(row, key: key, fields: fields)
                    if fields.isSubset(of: Set(delta.keys)) {
                        var state = State(identities: delta.merging(["globalId": key.rowID]) { _, new in new }, alive: true, after: previous)
                        for item in intervening.reversed() { state = try apply(item, to: state, key: key, fields: fields) }
                        return state
                    }
                    guard operation != "INSERT" else { throw LatticeDiagnostics.scopeProofFailure() }
                    intervening.append(row)
                }
                previous -= 1
            }
            throw LatticeDiagnostics.scopeProofFailure()
        }

        private func apply(_ row: [String: Any], to state: State, key: Key, fields: Set<String>) throws -> State {
            try checkBudget()
            guard let id = row["id"] as? Int64, let operation = row["operation"] as? String else { throw LatticeDiagnostics.scopeProofFailure() }
            if operation == "DELETE" {
                guard state.alive else { throw LatticeDiagnostics.scopeProofFailure() }
                guard row["fields"] is String || row["fieldsBytes"] is NSNull else { throw LatticeDiagnostics.scopeProofFailure() }
                // Core tombstones may omit a payload. If one exists, it must
                // agree with the known pre-delete identities.
                if row["fields"] is String {
                    let delta = try identities(row, key: key, fields: fields)
                    guard delta.allSatisfy({ field, value in
                        guard let previous = state.identities[field] else { return false }
                        return UUID(uuidString: previous) != nil ? previous.lowercased() == value.lowercased() : previous == value
                    }) else { throw LatticeDiagnostics.scopeProofFailure() }
                } else if let names = row["names"] as? String {
                    guard let size = row["namesBytes"] as? Int64, size <= 8192,
                          let parsed = try? JSONSerialization.jsonObject(with: Data(names.utf8)) as? [Any],
                          parsed.allSatisfy({ $0 is String || $0 is NSNull }),
                          Set(parsed.compactMap { $0 as? String }).isDisjoint(with: fields.union(["globalId"])) else {
                        throw LatticeDiagnostics.scopeProofFailure()
                    }
                }
                return State(identities: state.identities, alive: false, after: id)
            }
            guard operation == "INSERT" || (operation == "UPDATE" && state.alive) else { throw LatticeDiagnostics.scopeProofFailure() }
            let delta = try identities(row, key: key, fields: fields)
            if operation == "INSERT" {
                guard fields.isSubset(of: Set(delta.keys)) else { throw LatticeDiagnostics.scopeProofFailure() }
                return State(identities: delta.merging(["globalId": key.rowID]) { _, new in new }, alive: true, after: id)
            }
            return State(identities: state.identities.merging(delta) { _, new in new }, alive: true, after: id)
        }
    }

    private func changes(_ options: Options, cursor: Cursor?) throws -> Page {
        try withDatabase { db, identity in
            let proofDeadline = CFAbsoluteTimeGetCurrent() + 1
            let auditColumns = try db.columns("AuditLog")
            guard Self.requiredColumns.isSubset(of: auditColumns) else {
                throw Failure("unsupported_audit_schema", "This database has no compatible Lattice AuditLog.")
            }
            let bounds = try auditBounds(db, models: nil)
            let maximum = bounds.1 ?? 0
            if let cursor {
                guard cursor.database == identity else { throw Failure("cursor_database_mismatch", "The database file changed or this cursor belongs to another database.") }
                guard cursor.filter == options.fingerprint else { throw Failure("cursor_filter_mismatch", "Continue with the same change filters or start a new cursor.") }
                if let anchor = cursor.anchor {
                    let row = try db.rows("SELECT globalId FROM AuditLog WHERE id = ?", [.integer(cursor.after)]).first
                    guard (row?["globalId"] as? String)?.lowercased() == anchor else {
                        throw Failure("cursor_expired", "The cursor's audit anchor was pruned or reset. Start a new retained-history scan or a new now baseline.")
                    }
                } else if cursor.after != 0 {
                    throw Failure("invalid_cursor", "The cursor has no audit anchor.")
                }
            }
            let after = cursor?.after ?? (options.start == "now" ? maximum : 0)
            let upper = cursor?.upper ?? maximum
            guard after <= maximum || (after == 0 && maximum == 0), upper >= after, upper <= maximum else {
                throw Failure("cursor_expired", "The retained audit history no longer contains the cursor's range.")
            }
            let continuity = cursor?.continuity ?? (maximum == 0 ? "unknown" : "anchored")
            var scannedID = after
            var anchor = cursor?.anchor
            if cursor == nil && after > 0 {
                anchor = try db.rows("SELECT globalId FROM AuditLog WHERE id = ?", [.integer(after)]).first?["globalId"] as? String
            }
            let needsFields = options.includeValues || readPolicy?.requiredRowValues != nil
            let rows = try db.rows("""
                SELECT id, globalId, tableName, operation, globalRowId, timestamp, isFromRemote,
                       \(auditColumns.contains("synthesized") ? "synthesized" : "NULL") AS synthesized,
                       substr(changedFieldsNames,1,8192) AS names, length(CAST(changedFieldsNames AS BLOB)) AS namesBytes,
                       \(needsFields ? "substr(changedFields,1,8192)" : "NULL") AS fields,
                       \(needsFields ? "length(CAST(changedFields AS BLOB))" : "0") AS fieldsBytes
                FROM AuditLog WHERE id > ? AND id <= ? ORDER BY id ASC LIMIT ?
                """, [.integer(after), .integer(upper), .integer(Int64(Self.maxScan + 1))])
            let proof = readPolicy?.requiredRowValues.map { HistoryScopeProof(db: db, required: $0, rows: rows, deadline: proofDeadline) }
            var events: [[String: Any]] = []
            var bytes = 0
            var scanned = 0
            for row in rows.prefix(Self.maxScan) {
                guard let id = row["id"] as? Int64, let gid = row["globalId"] as? String, UUID(uuidString: gid) != nil,
                      let model = row["tableName"] as? String, model.utf8.count <= 512,
                      let operation = row["operation"] as? String, ["INSERT", "UPDATE", "DELETE"].contains(operation) else {
                    if readPolicy?.requiredRowValues != nil { throw Self.scopeProofFailure() }
                    throw Failure("invalid_audit_row", "An audit row has no stable identity or operation.")
                }
                let remote = (row["isFromRemote"] as? Int64 ?? 0) != 0
                let matches = (options.models?.contains(model) ?? true) && (options.operations?.contains(operation) ?? true)
                    && (options.origin == "all" || (options.origin == "remote") == remote)
                    && (options.globalRowID == nil || (row["globalRowId"] as? String)?.lowercased() == options.globalRowID)
                if matches {
                    if events.count >= options.limit { break }
                    if let proof, try !proof.allows(row) {
                        scannedID = id; anchor = gid.lowercased(); scanned += 1
                        continue
                    }
                    var event: [String: Any] = ["auditId": id, "auditGlobalId": gid.lowercased(), "model": model,
                        "operation": operation, "globalRowId": row["globalRowId"] ?? NSNull(),
                        "timestamp": row["timestamp"] ?? NSNull(), "origin": remote ? "remote" : "local",
                        "synthesized": (row["synthesized"] as? Int64).map { $0 != 0 } as Any? ?? NSNull()]
                    let namesBytes = row["namesBytes"] as? Int64 ?? 0
                    if namesBytes <= 8_192, let names = row["names"] as? String,
                       let namesValue = try? JSONSerialization.jsonObject(with: Data(names.utf8)) {
                        event["changedFields"] = namesValue
                    } else {
                        event["changedFields"] = []
                        event["fieldNamesUnavailable"] = true
                    }
                    if options.includeValues {
                        let valueBytes = row["fieldsBytes"] as? Int64 ?? 0
                        if valueBytes <= 8_192, let fields = row["fields"] as? String,
                           let value = try? JSONSerialization.jsonObject(with: Data(fields.utf8)) { event["values"] = value }
                        else { event["valuesUnavailable"] = true; event["valuesBytes"] = valueBytes }
                    }
                    if let permitted = readPolicy?.permittedFields[model] {
                        // Numeric IDs are global sequence positions; gaps would
                        // expose hidden activity despite opaque scoped cursors.
                        event.removeValue(forKey: "auditId")
                        let fields = permitted.union(["id", "globalId"])
                        // AuditLog's Swift schema permits null elements in this
                        // array; one legacy null must not hide visible names.
                        let names = (event["changedFields"] as? [Any] ?? []).compactMap { $0 as? String }.filter { fields.contains($0) }
                        event["changedFields"] = names
                        if let values = event["values"] as? [String: Any] {
                            event["values"] = values.filter { fields.contains($0.key) }
                        } else { event.removeValue(forKey: "values") }
                        // Payload lengths and parse failures for hidden fields
                        // are not useful diagnostics for a restricted reader.
                        event.removeValue(forKey: "valuesBytes")
                        event.removeValue(forKey: "valuesUnavailable")
                        event.removeValue(forKey: "fieldNamesUnavailable")
                        if operation == "UPDATE" && names.isEmpty {
                            scannedID = id; anchor = gid.lowercased(); scanned += 1
                            continue
                        }
                    }
                    var eventBytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]).count
                    if eventBytes > Self.maxResponseBytes {
                        event.removeValue(forKey: "values")
                        event["valuesUnavailable"] = true
                        eventBytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]).count
                    }
                    if eventBytes > Self.maxResponseBytes {
                        event["changedFields"] = []
                        event["fieldNamesUnavailable"] = true
                        eventBytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]).count
                    }
                    guard eventBytes <= Self.maxResponseBytes else {
                        throw Failure("invalid_audit_row", "An audit row's identity metadata exceeds the response bound.")
                    }
                    if events.count >= options.limit || (!events.isEmpty && bytes + eventBytes > Self.maxResponseBytes) { break }
                    events.append(event); bytes += eventBytes
                }
                scannedID = id; anchor = gid.lowercased(); scanned += 1
            }
            // Sparse filters must advance over inspected nonmatching events. If
            // this bounded query exhausted the range, its last global row is the
            // anchor even when the matching result list is empty.
            let hasMore = scannedID < upper
            let next = Cursor(database: identity, filter: options.fingerprint, after: scannedID, anchor: anchor?.lowercased(),
                              upper: hasMore ? upper : nil, continuity: continuity)
            return Page(events: events, cursor: next, hasMore: hasMore,
                        minimum: readPolicy == nil ? bounds.0 : nil, maximum: readPolicy == nil ? bounds.1 : nil,
                        scanningLimited: scanned == Self.maxScan && hasMore, auditingDisabled: try auditingDisabled(db))
        }
    }

    private func auditBounds(_ db: Database, models: Set<String>?) throws -> (Int64?, Int64?, Int64) {
        var sql = "SELECT MIN(id) AS minimum, MAX(id) AS maximum, COUNT(*) AS count FROM AuditLog"
        var parameters: [Database.Parameter] = []
        if let models {
            if models.isEmpty { return (nil, nil, 0) }
            sql += " WHERE tableName IN (" + Array(repeating: "?", count: models.count).joined(separator: ",") + ")"
            parameters = models.sorted().map { .text($0) }
        }
        let row = try db.rows(sql, parameters).first ?? [:]
        return (row["minimum"] as? Int64, row["maximum"] as? Int64, row["count"] as? Int64 ?? 0)
    }

    private func auditingDisabled(_ db: Database) throws -> Bool? {
        guard try db.columns("_SyncControl").contains("disabled") else { return nil }
        return (try db.rows("SELECT disabled FROM _SyncControl WHERE id = 1").first?["disabled"] as? Int64).map { $0 != 0 }
    }

    private func auditUnsynchronizedCount(_ db: Database, models: Set<String>?) throws -> Int64 {
        var sql = "SELECT COUNT(*) AS count FROM AuditLog WHERE isSynchronized = 0"
        var parameters: [Database.Parameter] = []
        if let models {
            if models.isEmpty { return 0 }
            sql += " AND tableName IN (" + Array(repeating: "?", count: models.count).joined(separator: ",") + ")"
            parameters = models.sorted().map { .text($0) }
        }
        return try db.rows(sql, parameters).first?["count"] as? Int64 ?? 0
    }

    private func withDatabase<T>(_ body: (Database, String) throws -> T) throws -> T {
        let identity = try fileIdentity()
        let db = try Database(fileURL.path)
        guard try fileIdentity() == identity else { throw Failure("database_changed", "The database file was replaced while opening it.") }
        try db.execute("BEGIN")
        do {
            let result = try body(db, identity)
            try db.execute("COMMIT")
            guard try fileIdentity() == identity else { throw Failure("database_changed", "The database file was replaced during the read.") }
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func fileIdentity() throws -> String {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
        catch { throw Failure("open_failed", "The database file is unavailable.") }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw Failure("open_failed", "The database must be an existing regular file.")
        }
        // This is an identity checksum, not an authorization token. Paths never
        // appear in native tool responses or their opaque continuation cursors.
        return Self.digest("\(fileURL.path)|\(device)|\(inode)")
    }

    private static func validateKeys(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw Failure("invalid_arguments", "Unknown diagnostics argument.") }
        if let db = args["db"], !(db is String) { throw Failure("invalid_arguments", "db must be a string.") }
    }
    private static func result(_ value: [String: Any]) throws -> ProviderResult {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 32_768 else { throw Failure("result_too_large", "The diagnostics result exceeds 32 KiB. Use narrower filters or a smaller limit.") }
        return ProviderResult(json: String(decoding: data, as: UTF8.self), isError: false)
    }
    private static func encodeCursor(_ cursor: Cursor) throws -> String { try JSONEncoder().encode(cursor).base64EncodedString() }
    private func issueCursor(_ cursor: Cursor) throws -> String {
        guard readPolicy != nil else { return try Self.encodeCursor(cursor) }
        let token = "scoped:" + UUID().uuidString.lowercased()
        scopedCursors[token] = cursor
        scopedCursorOrder.append(token)
        if scopedCursorOrder.count > 128 { scopedCursors.removeValue(forKey: scopedCursorOrder.removeFirst()) }
        return token
    }
    private func decodeIncomingCursor(_ value: String) throws -> Cursor {
        guard readPolicy != nil else { return try Self.decodeCursor(value) }
        guard let cursor = scopedCursors[value] else {
            throw Failure("cursor_expired", "This scoped cursor is no longer held by the reader. Start a new retained-history scan or now baseline.")
        }
        return cursor
    }
    private static func decodeCursor(_ value: String) throws -> Cursor {
        guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              cursor.version == 1, cursor.after >= 0, cursor.database.count == 16, cursor.filter.count == 16,
              ["unknown", "anchored"].contains(cursor.continuity), cursor.anchor == nil || UUID(uuidString: cursor.anchor!) != nil,
              cursor.after != 0 || (cursor.anchor == nil && cursor.continuity == "unknown") else {
            throw Failure("invalid_cursor", "The change cursor is invalid or uses an unsupported version.")
        }
        return cursor
    }
    private static func digest(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

    private final class Database {
        enum Parameter { case integer(Int64), text(String) }
        private var handle: OpaquePointer?
        private final class QueryDeadline { var instant: CFAbsoluteTime = 0 }
        private let queryDeadline = QueryDeadline()
        init(_ path: String) throws {
            let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }; self.handle = nil
                throw Failure("open_failed", "The database could not be opened read-only (SQLite \(status)).")
            }
            guard sqlite3_db_readonly(handle, "main") == 1 else { throw Failure("open_failed", "A read-only database handle is required.") }
            sqlite3_busy_timeout(handle, 250)
            sqlite3_progress_handler(handle, 1_000, { pointer in
                guard let pointer else { return 1 }
                let deadline = Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue()
                return CFAbsoluteTimeGetCurrent() >= deadline.instant ? 1 : 0
            }, Unmanaged.passUnretained(queryDeadline).toOpaque())
        }
        deinit { if let handle { sqlite3_close(handle) } }
        func execute(_ sql: String) throws {
            queryDeadline.instant = CFAbsoluteTimeGetCurrent() + 1
            let status = sqlite3_exec(handle, sql, nil, nil, nil)
            guard status == SQLITE_OK else { throw failure(status) }
        }
        func columns(_ table: String) throws -> Set<String> {
            // Only internal constant table names reach this helper.
            Set(try rows("PRAGMA table_info('\(table)')").compactMap { $0["name"] as? String })
        }
        func rows(_ sql: String, _ parameters: [Parameter] = [], deadline: CFAbsoluteTime? = nil) throws -> [[String: Any]] {
            // LIMIT bounds returned rows, not the work needed to scan a sparse
            // or damaged index. Interrupt CPU-heavy reads as well as busy waits.
            queryDeadline.instant = min(CFAbsoluteTimeGetCurrent() + 1, deadline ?? .greatestFiniteMagnitude)
            guard CFAbsoluteTimeGetCurrent() < queryDeadline.instant else { throw failure(SQLITE_INTERRUPT) }
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else { throw failure(prepared) }
            defer { sqlite3_finalize(statement) }
            for (index, parameter) in parameters.enumerated() {
                let status: Int32
                switch parameter {
                case .integer(let value): status = sqlite3_bind_int64(statement, Int32(index + 1), value)
                case .text(let value):
                    status = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                }
                guard status == SQLITE_OK else { throw failure(status) }
            }
            var output: [[String: Any]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return output }
                guard status == SQLITE_ROW else { throw failure(status) }
                var row: [String: Any] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                    case SQLITE_TEXT:
                        if let text = sqlite3_column_text(statement, index) { row[name] = String(cString: text) }
                    default: row[name] = NSNull()
                    }
                }
                output.append(row)
            }
        }
        private func failure(_ status: Int32) -> Failure {
            let code = status == SQLITE_BUSY || status == SQLITE_LOCKED ? "database_busy"
                : (status == SQLITE_INTERRUPT ? "query_timeout" : "query_failed")
            return Failure(code, "The read-only SQLite query failed (code \(status)).")
        }
    }
}
