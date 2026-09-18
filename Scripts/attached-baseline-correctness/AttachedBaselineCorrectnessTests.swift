import Foundation
import CryptoKit
import Testing
import CLatticeTestSQLite
@testable import Lattice

// Separate correctness overlay; no BaseTest, benchmark edit, materialization,
// candidate-only API, diagnostic scheduler, sleep, or additional actor hop.
@Model private final class PerfRefinementMemory {
    @Indexed var rank: Int = 0
    var title: String = ""
    var body: String = ""
    var accessCount: Int = 0
    var lastAccessed: Date = Date(timeIntervalSince1970: 0)
    var pinned: Bool = false
}

private enum AttachedOracleError: Error {
    case invariant(String)
    case intentionalRollback
}
private func demand(_ condition: Bool, _ code: String) throws {
    if !condition { throw AttachedOracleError.invariant(code) }
}
private func fixtureUUID(_ rank: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(rank + 1)))!
}
private struct DisplayValues: Codable, Equatable {
    var rank: Int
    var title: String
    var body: String
    var accessCount: Int
    var lastAccessedSeconds: Double
    var pinned: Bool
    init(rank: Int) {
        self.rank = rank
        title = String(format: "memory-%05d", Int32(rank))
        body = String(repeating: String(UnicodeScalar(97 + rank % 26)!), count: 256)
        accessCount = rank % 17
        lastAccessedSeconds = 1_700_000_000 + Double(rank)
        pinned = rank % 3 == 0
    }
    // Exactly six live property reads. UUID/primaryKey checks happen separately.
    init(_ row: PerfRefinementMemory) {
        rank = row.rank; title = row.title; body = row.body
        accessCount = row.accessCount
        lastAccessedSeconds = row.lastAccessed.timeIntervalSince1970
        pinned = row.pinned
    }
}
private struct RawRow {
    let id: Int64
    let globalID: String
    let values: DisplayValues
}
private struct Evidence: Codable {
    let caseName: String
    var complete = false
    var phase = "fixture"
    var failure: String?
    var sql: [String: UInt64] = [:]
    var counts: [String: Int] = [:]
    var files: [String: String] = [:]
    var returned: [DisplayValues] = []
    var returnedUUIDs: [String] = []
    var localIDs: [Int64] = []
}

@Suite("AttachedBaselineCorrectnessTests", .serialized)
struct AttachedBaselineCorrectnessTests {
    private func configuration(_ url: URL) -> Lattice.Configuration {
        var result = Lattice.Configuration(fileURL: url)
        result.resultsTuning.pageSize = 100
        return result
    }
    private func save(_ evidence: Evidence, _ root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        try demand(data.count <= 128 * 1024, "EVIDENCE_CAP")
        try data.write(to: root.appendingPathComponent("RESULT.json"), options: .atomic)
    }
    private func runCase(_ name: String, _ body: (URL, inout Evidence) throws -> Void) throws {
        guard let value = ProcessInfo.processInfo.environment["LATTICE_ATTACHED_CORRECTNESS_ROOT"], value.hasPrefix("/") else {
            throw AttachedOracleError.invariant("OWNED_ROOT_REQUIRED")
        }
        let parent = URL(fileURLWithPath: value, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let allowed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("localdev", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        try demand(parent.path.hasPrefix(allowed), "ROOT_OUTSIDE_LOCALDEV")
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try demand(!FileManager.default.fileExists(atPath: root.path), "CASE_DIRECTORY_ALREADY_EXISTS")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var evidence = Evidence(caseName: name)
        do {
            try body(root, &evidence)
            evidence.phase = "complete"; evidence.complete = true
            try save(evidence, root)
        } catch {
            evidence.complete = false; evidence.failure = String(describing: error)
            do { try save(evidence, root) }
            catch { print("ATTACHED_CORRECTNESS_EVIDENCE_WRITE_FAILED") }
            throw error
        }
        // Preserve masters, copies and all sidecars. The owning runner bounds them.
    }
    private func seed(_ url: URL, parity: Int) throws {
        let db = try Lattice(isolation: nil, PerfRefinementMemory.self, configuration: configuration(url))
        defer { db.close() }
        try db.withTransaction {
            for rank in stride(from: parity, to: 10_000, by: 2) {
                let value = DisplayValues(rank: rank)
                let row = PerfRefinementMemory()
                row.rank = value.rank; row.title = value.title; row.body = value.body
                row.accessCount = value.accessCount
                row.lastAccessed = Date(timeIntervalSince1970: value.lastAccessedSeconds)
                row.pinned = value.pinned
                try db.add(row, preservingGlobalId: fixtureUUID(rank))
            }
        }
        try demand(db.checkpoint().complete, "MASTER_CHECKPOINT")
    }
    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func rawRows(_ url: URL, immutable: Bool) throws -> [RawRow] {
        var filename = url.path
        var flags = SQLITE_OPEN_READONLY
        if immutable {
            let wal = url.path + "-wal"
            if FileManager.default.fileExists(atPath: wal) {
                let bytes = try FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber
                try demand(bytes?.uint64Value == 0, "CLOSED_INPUT_HAS_WAL")
            }
            var uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            uri.queryItems = [.init(name: "mode", value: "ro"), .init(name: "immutable", value: "1")]
            filename = uri.string!; flags |= SQLITE_OPEN_URI
        }
        var pointer: OpaquePointer?
        let opened = sqlite3_open_v2(filename, &pointer, flags, nil)
        guard let db = pointer else { throw AttachedOracleError.invariant("SQLITE_OPEN_HANDLE") }
        defer { sqlite3_close(db) }
        try demand(opened == SQLITE_OK, "SQLITE_OPEN")
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db,
            "SELECT id,globalId,rank,title,body,accessCount,lastAccessed,pinned FROM PerfRefinementMemory ORDER BY rank", -1, &statement, nil)
        guard let statement else { throw AttachedOracleError.invariant("SQLITE_PREPARE_HANDLE") }
        defer { sqlite3_finalize(statement) }
        try demand(prepared == SQLITE_OK, "SQLITE_PREPARE")
        func string(_ column: Int32) throws -> String {
            guard let bytes = sqlite3_column_text(statement, column) else {
                throw AttachedOracleError.invariant("SQLITE_NULL_TEXT")
            }
            return String(cString: bytes)
        }
        var rows: [RawRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            try demand([Int32(0), 2, 5, 7].allSatisfy { sqlite3_column_type(statement, $0) == SQLITE_INTEGER }, "RAW_INTEGER_TYPES")
            try demand([Int32(1), 3, 4].allSatisfy { sqlite3_column_type(statement, $0) == SQLITE_TEXT }, "RAW_TEXT_TYPES")
            try demand(sqlite3_column_type(statement, 6) == SQLITE_FLOAT || sqlite3_column_type(statement, 6) == SQLITE_INTEGER, "RAW_DATE_TYPE")
            try demand(sqlite3_column_int64(statement, 7) == 0 || sqlite3_column_int64(statement, 7) == 1, "RAW_BOOL_VALUE")
            let rank = Int(sqlite3_column_int64(statement, 2))
            try demand((0..<10_000).contains(rank), "RAW_RANK_RANGE")
            var value = DisplayValues(rank: rank)
            value.title = try string(3); value.body = try string(4)
            value.accessCount = Int(sqlite3_column_int64(statement, 5))
            value.lastAccessedSeconds = sqlite3_column_double(statement, 6)
            value.pinned = sqlite3_column_int64(statement, 7) != 0
            rows.append(.init(id: sqlite3_column_int64(statement, 0), globalID: try string(1).lowercased(), values: value))
            try demand(rows.count <= 5_000, "RAW_ROW_CAP")
            step = sqlite3_step(statement)
        }
        try demand(step == SQLITE_DONE, "SQLITE_STEP")
        return rows
    }
    private func verify(_ urls: [URL], immutable: Bool, overrides: [Int: DisplayValues] = [:]) throws {
        try demand(urls.count == 2, "STORE_INVENTORY")
        for (parity, url) in urls.enumerated() {
            let rows = try rawRows(url, immutable: immutable)
            try demand(rows.count == 5_000, "PHYSICAL_ROW_COUNT")
            for (index, row) in rows.enumerated() {
                let rank = index * 2 + parity
                try demand(row.id == Int64(index + 1), "PHYSICAL_ID_ORDER")
                try demand(row.values == (overrides[rank] ?? DisplayValues(rank: rank)), "PHYSICAL_POSTIMAGE_\(rank)")
                try demand(row.globalID == fixtureUUID(rank).uuidString.lowercased(), "PHYSICAL_UUID_\(rank)")
            }
        }
    }
    private func fixtures(_ root: URL, _ evidence: inout Evidence) throws -> [URL] {
        let masters = [root.appendingPathComponent("master-main.sqlite"), root.appendingPathComponent("master-attached.sqlite")]
        for (parity, master) in masters.enumerated() { try seed(master, parity: parity) }
        try verify(masters, immutable: true)
        let copies = [root.appendingPathComponent("main.sqlite"), root.appendingPathComponent("attached.sqlite")]
        for (master, copy) in zip(masters, copies) {
            try FileManager.default.copyItem(at: master, to: copy)
            let before = try hash(master), after = try hash(copy)
            try demand(before == after, "MASTER_COPY_HASH")
            evidence.files[master.lastPathComponent] = before
            evidence.files[copy.lastPathComponent] = after
        }
        try verify(copies, immutable: true)
        evidence.counts["physicalRowsPerStore"] = 5_000
        return copies
    }
    private func withQuery(_ urls: [URL], _ body: (Lattice, Lattice, Lattice) throws -> Void) throws {
        let main = try Lattice(isolation: nil, PerfRefinementMemory.self, configuration: configuration(urls[0]))
        defer { main.close() }
        let other = try Lattice(isolation: nil, PerfRefinementMemory.self, configuration: configuration(urls[1]))
        defer { other.close() }
        let query = try main.attaching(lattice: other)
        defer { query.close() }
        try body(main, other, query)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATTICE_ATTACHED_CORRECTNESS"] == "1"))
    func attachedDisplayWarmIdentityAndRoutedWrites() throws {
        try runCase("attachedDisplayWarmIdentityAndRoutedWrites") { root, evidence in
            let copies = try fixtures(root, &evidence)
            var expected: [Int: DisplayValues] = [:]
            try withQuery(copies) { _, other, query in
                let results = query.objects(PerfRefinementMemory.self).sortedBy(\.rank)
                let shape = results._shapeState
                try demand(shape.fillCounts.offset == 0 && shape.fillCounts.keyset == 0 && shape.anchorCount == 0, "SHAPE_NOT_COLD")
                evidence.phase = "cold_page"
                var rows: [PerfRefinementMemory] = []
                let coldBefore = Lattice.threadSQLStatementCount
                for index in 4_000..<4_100 {
                    guard let row = results.element(at: index) else { throw AttachedOracleError.invariant("MISSING_DISPLAY_ROW") }
                    rows.append(row)
                }
                evidence.sql["coldPage"] = Lattice.threadSQLStatementCount - coldBefore
                let liveBefore = Lattice.threadSQLStatementCount
                let displayed = rows.map { DisplayValues($0) }
                evidence.sql["sixLiveFields"] = Lattice.threadSQLStatementCount - liveBefore
                evidence.returned = displayed
                evidence.returnedUUIDs = try rows.map { row in
                    guard let value = row.globalId else { throw AttachedOracleError.invariant("MISSING_GLOBAL_ID") }
                    return value.uuidString.lowercased()
                }
                evidence.localIDs = try rows.map { row in
                    guard let id = row.primaryKey else { throw AttachedOracleError.invariant("MISSING_LOCAL_ID") }
                    return id
                }
                evidence.counts["distinctObjects"] = Set(rows.map(ObjectIdentifier.init)).count
                evidence.counts["distinctLocalIDs"] = Set(evidence.localIDs).count
                evidence.counts["coldOffsetFills"] = shape.fillCounts.offset
                evidence.counts["coldKeysetFills"] = shape.fillCounts.keyset
                evidence.counts["coldAnchors"] = shape.anchorCount
                evidence.phase = "display_oracle"
                // First expected original-source failure. It records all returned values before stopping.
                try demand(displayed == (4_000..<4_100).map { DisplayValues(rank: $0) }
                    && evidence.counts["distinctObjects"] == 100
                    && evidence.returnedUUIDs == (4_000..<4_100).map { fixtureUUID($0).uuidString.lowercased() }, "ATTACHED_DISPLAY_ORACLE")
                try demand(rows.allSatisfy { !$0.isMaterialized }, "DISPLAY_MATERIALIZED")
                try demand(evidence.localIDs == (4_000..<4_100).map { Int64($0 / 2 + 1) }, "FIFTY_COLLISION_PAIRS")
                try demand(evidence.sql["sixLiveFields"] == 600, "SIX_LIVE_FIELDS_SQL_600")
                try demand(shape.fillCounts.offset == 1 && shape.fillCounts.keyset == 0 && shape.anchorCount <= 1, "COLD_FILL_INVARIANT")
                let beforeFills = shape.fillCounts, beforeAnchors = shape.anchorCount
                evidence.phase = "warm_page"
                let warmBefore = Lattice.threadSQLStatementCount
                var warm: [PerfRefinementMemory] = []
                for index in 4_000..<4_100 {
                    guard let row = results.element(at: index) else { throw AttachedOracleError.invariant("MISSING_WARM_ROW") }
                    warm.append(row)
                }
                evidence.sql["warmLookup"] = Lattice.threadSQLStatementCount - warmBefore
                try demand(evidence.sql["warmLookup"] == 0, "WARM_LOOKUP_SQL_ZERO")
                try demand(zip(rows, warm).allSatisfy { $0.0 === $0.1 }, "WARM_OBJECT_IDENTITY")
                try demand(shape.fillCounts == beforeFills && shape.anchorCount == beforeAnchors, "WARM_SHAPE_CHANGED")
                let warmScalarBefore = Lattice.threadSQLStatementCount
                let warmValues = warm.map { DisplayValues($0) }
                evidence.sql["warmSixLiveFields"] = Lattice.threadSQLStatementCount - warmScalarBefore
                try demand(warmValues == displayed && evidence.sql["warmSixLiveFields"] == 600, "WARM_LIVE_FIELDS_SQL_600")
                evidence.phase = "routed_commit"
                let first = rows[0], second = rows[1]
                try demand(first !== second && first.primaryKey == second.primaryKey, "ROUTED_DISTINCT_PAIR")
                try query.withTransaction {
                    first.lastAccessed = Date(timeIntervalSince1970: 1_800_000_000)
                    first.increment("accessCount")
                    second.lastAccessed = Date(timeIntervalSince1970: 1_800_000_001)
                    second.increment("accessCount")
                }
                for rank in [4_000, 4_001] {
                    var value = DisplayValues(rank: rank)
                    value.lastAccessedSeconds = 1_800_000_000 + Double(rank - 4_000)
                    value.accessCount += 1; expected[rank] = value
                }
                try verify(copies, immutable: false, overrides: expected)
                try demand(DisplayValues(first) == expected[4_000] && DisplayValues(second) == expected[4_001], "RETAINED_COMMIT_VALUES")
                evidence.phase = "routed_rollback"
                do {
                    try query.withTransaction {
                        first.lastAccessed = Date(timeIntervalSince1970: 1_900_000_000)
                        first.increment("accessCount")
                        second.lastAccessed = Date(timeIntervalSince1970: 1_900_000_001)
                        second.increment("accessCount")
                        throw AttachedOracleError.intentionalRollback
                    }
                    throw AttachedOracleError.invariant("ROLLBACK_DID_NOT_THROW")
                } catch AttachedOracleError.intentionalRollback { }
                try verify(copies, immutable: false, overrides: expected)
                try demand(DisplayValues(first) == expected[4_000] && DisplayValues(second) == expected[4_001], "RETAINED_ROLLBACK_VALUES")
                evidence.phase = "owning_connection_write"
                guard let owned = other.object(PerfRefinementMemory.self, primaryKey: 2_001) else {
                    throw AttachedOracleError.invariant("MISSING_OWNING_ROW")
                }
                try other.withTransaction { owned.title = "outside-owner-04001" }
                expected[4_001]!.title = "outside-owner-04001"
                try demand(DisplayValues(second) == expected[4_001] && !second.isMaterialized, "RETAINED_EXTERNAL_LIVE_VALUE")
                try verify(copies, immutable: false, overrides: expected)
            }
            // Every read uses a new independent read-only SQLite connection;
            // this final read occurs after all three Lattice handles close.
            evidence.phase = "closed_reopened_postimage"
            try verify(copies, immutable: false, overrides: expected)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATTICE_ATTACHED_CORRECTNESS"] == "1"))
    func originalPerRowPrimingRemainsOneStatement() throws {
        try runCase("originalPerRowPrimingRemainsOneStatement") { root, evidence in
            let copies = try fixtures(root, &evidence)
            try withQuery(copies) { _, _, query in
                evidence.phase = "raw_collection"
                let before = Lattice.threadSQLStatementCount
                let raw = query.backend.objects(table: PerfRefinementMemory.entityName, where: nil,
                    orderBy: "rank ASC", limit: 100, offset: 4_000, groupBy: nil, distinctBy: nil)
                evidence.sql["rawCollection"] = Lattice.threadSQLStatementCount - before
                try demand(raw.count == 100 && evidence.sql["rawCollection"] == 1, "RAW_COLLECTION_SQL_ONE")
                evidence.phase = "original_priming"
                var models: [PerfRefinementMemory] = []
                let primeBefore = Lattice.threadSQLStatementCount
                for row in raw {
                    let oneBefore = Lattice.threadSQLStatementCount
                    row.enableRowCache()
                    _ = row.getInt(named: "id")
                    let model = PerfRefinementMemory(dynamicObject: row)
                    row.disableRowCache()
                    try demand(Lattice.threadSQLStatementCount - oneBefore == 1, "ORIGINAL_PRIMING_SQL_ONE_PER_ROW")
                    models.append(model)
                }
                evidence.sql["priming100"] = Lattice.threadSQLStatementCount - primeBefore
                try demand(evidence.sql["priming100"] == 100, "ORIGINAL_PRIMING_SQL_100")
                try demand(models.allSatisfy { !$0.isMaterialized }, "PRIMING_LEFT_MATERIALIZED")
                let scalarBefore = Lattice.threadSQLStatementCount
                let values = models.map { DisplayValues($0) }
                evidence.sql["sixLiveFields"] = Lattice.threadSQLStatementCount - scalarBefore
                try demand(values == (4_000..<4_100).map { DisplayValues(rank: $0) }
                    && evidence.sql["sixLiveFields"] == 600, "PRIMED_ROWS_REMAIN_LIVE")
                evidence.counts["primedRows"] = raw.count
            }
        }
    }
}
