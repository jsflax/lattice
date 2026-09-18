import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice

// Opt in only after a Release build has been allocated. This suite deliberately
// does not inherit BaseTest (which writes a fixed log in the system temp dir).
// LATTICE_PERF_REFINEMENT=1 and a NEW absolute LATTICE_PERF_RUN_DIR below
// ~/localdev are required. All fixture copies and results belong to that dir.
@Model private final class PerfRefinementMemory {
    @Indexed var rank: Int = 0
    var title: String = ""
    var body: String = ""
    var accessCount: Int = 0
    var lastAccessed: Date = Date(timeIntervalSince1970: 0)
    var pinned: Bool = false
}

private enum PerfRefinementFailure: Error {
    case invalid(String)
}

private struct PerfRefinementValues: Codable, Equatable {
    let rank: Int
    let title: String
    let body: String
    let accessCount: Int
    let lastAccessedSeconds: Double
    let pinned: Bool

    init(rank: Int, updated: Bool = false) {
        self.rank = rank
        title = String(format: "memory-%05d", Int32(rank))
        body = String(repeating: String(UnicodeScalar(97 + rank % 26)!), count: 256)
        accessCount = rank % 17 + (updated ? 1 : 0)
        lastAccessedSeconds = updated ? 1_800_000_000 : 1_700_000_000 + Double(rank)
        pinned = rank % 3 == 0
    }

    init(_ row: PerfRefinementMemory) {
        rank = row.rank
        title = row.title
        body = row.body
        accessCount = row.accessCount
        lastAccessedSeconds = row.lastAccessed.timeIntervalSince1970
        pinned = row.pinned
    }

    init(statement: OpaquePointer) throws {
        func string(_ column: Int32) throws -> String {
            guard let text = sqlite3_column_text(statement, column) else {
                throw PerfRefinementFailure.invalid("unexpected NULL scalar")
            }
            return String(cString: text)
        }
        rank = Int(sqlite3_column_int64(statement, 0))
        title = try string(1)
        body = try string(2)
        accessCount = Int(sqlite3_column_int64(statement, 3))
        lastAccessedSeconds = sqlite3_column_double(statement, 4)
        pinned = sqlite3_column_int64(statement, 5) != 0
    }
}

private struct PerfRefinementPhase: Codable {
    let elapsedNS: UInt64
    let sqlStatements: UInt64
}

private struct PerfRefinementSample: Codable {
    let variant: String
    let iteration: Int
    let warmup: Bool
    let phases: [String: PerfRefinementPhase]
    let readChecksum: String
    let beforeChecksum: String
    let afterChecksum: String
    let readRows: Int
    let updatedRows: Int
    let coldOffsetFills: Int
    let coldKeysetFills: Int
    let coldAnchors: Int
    let warmOffsetFills: Int
    let warmKeysetFills: Int
    let warmAnchors: Int
}

private struct PerfRefinementManifest: Codable {
    let schema = "lattice.perf-refinement/1"
    let contract = "read100-six-scalars-update11-v1"
    #if LATTICE_PERF_SELECTED_BATCH
    let writeImplementation = "selected-batch-set-and-increment-v1"
    #else
    let writeImplementation = "legacy-row-set-and-increment-v1"
    #endif
    let releaseBuild = true
    let fixtureRows = 10_000
    let bodyBytes = 256
    let pageSize = 100
    let readStart = 4_000
    let readCount = 100
    let updateRanks: [Int]
    let measuredSamples: Int
    let warmupSamples: Int
    let startedAt: String
    let runDirectory: String
    let sourceRevision: String
    let coreRevision: String
    let buildIdentity: String
    let hostIdentity: String
    let operatingSystem: String
    let processorCount: Int
    let activeProcessorCount: Int
    let sqlCounterScope = "calling-thread, synchronous API intervals only"
    let fixtureMode = "closed checkpointed master copied to new path per iteration"
    let variants = ["local", "attached"]
}

private struct PerfRefinementResult: Codable {
    let manifest: PerfRefinementManifest
    let complete = true
    let samples: [PerfRefinementSample]
}

@Suite("PerfRefinementBenchmarks", .serialized)
struct PerfRefinementBenchmarks {
    private static let updateRanks = [7, 100, 333, 999, 1234, 2345, 3456, 4567, 5678, 6789, 9998]

    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw PerfRefinementFailure.invalid(reason) }
    }

    private func configuration(_ url: URL) -> Lattice.Configuration {
        // Production defaults, including audit triggers and generation tuning.
        // No observers or network transports are installed in either build.
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.pageSize = 100
        return config
    }

    private func globalID(_ rank: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(rank + 1)))!
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func checksum(_ rows: [PerfRefinementValues]) -> String {
        // Stable FNV-1a over length-delimited scalar fields. Not a security hash.
        var hash: UInt64 = 0xcbf29ce484222325
        for row in rows {
            for field in [String(row.rank), row.title, row.body, String(row.accessCount),
                          String(row.lastAccessedSeconds), row.pinned ? "1" : "0"] {
                for byte in "\(field.utf8.count):\(field)".utf8 {
                    hash = (hash ^ UInt64(byte)) &* 0x100000001b3
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    private func measure<T>(_ body: () throws -> T) rethrows -> (T, PerfRefinementPhase) {
        let sqlBefore = Lattice.threadSQLStatementCount
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        let end = DispatchTime.now().uptimeNanoseconds
        let sqlAfter = Lattice.threadSQLStatementCount
        return (result, .init(elapsedNS: end - start, sqlStatements: sqlAfter - sqlBefore))
    }

    private func seed(_ url: URL, ranks: [Int]) throws {
        let db = try Lattice(PerfRefinementMemory.self, configuration: configuration(url))
        defer { db.close() }
        try db.withTransaction {
            for rank in ranks {
                let value = PerfRefinementValues(rank: rank)
                let row = PerfRefinementMemory()
                row.rank = value.rank; row.title = value.title; row.body = value.body
                row.accessCount = value.accessCount
                row.lastAccessed = Date(timeIntervalSince1970: Double(value.lastAccessedSeconds))
                row.pinned = value.pinned
                try db.add(row, preservingGlobalId: globalID(rank))
            }
        }
        try require(db.checkpoint().complete, "master checkpoint did not complete")
    }

    private enum ValidationPhase: String {
        case checkpointedMaster, unopenedCopy, liveAfterimage
        var usesImmutable: Bool { self != .liveAfterimage }
    }

    private func validationFailure(_ operation: String, phase: ValidationPhase,
                                   url: URL, database: OpaquePointer?, code: Int32) -> PerfRefinementFailure {
        let extended: Int32
        let message: String
        if let database {
            extended = sqlite3_extended_errcode(database)
            message = String(cString: sqlite3_errmsg(database))
        } else {
            extended = code
            message = "no database handle"
        }
        return .invalid("SQLite validation \(operation): phase=\(phase.rawValue) " +
            "path=\(String(url.path.prefix(512))) sqlite=\(String(cString: sqlite3_libversion())) " +
            "rc=\(code) extended=\(extended) error=\(String(message.prefix(384)))")
    }

    /// Independent full-table verification; all SQL remains read-only.
    /// Immutable is restricted to this harness's owned, checkpointed/closed
    /// masters and their exact unopened copies. A live postimage must use WAL.
    /// No Lattice model instances or query shapes are warmed by validation.
    private func validate(_ urls: [URL], updated: Bool, phase: ValidationPhase) throws -> String {
        var values: [PerfRefinementValues] = []
        var changedRanks = Set<Int>()
        for url in urls {
            let filename: String
            let flags: Int32
            if phase.usesImmutable {
                // seed() has returned and closed its handle; runSample has not
                // opened a Lattice on an unopenedCopy. No live writer owns them.
                let wal = url.path + "-wal"
                if FileManager.default.fileExists(atPath: wal) {
                    let bytes = try FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber
                    try require(bytes?.uint64Value == 0,
                                "validation \(phase.rawValue) has nonempty WAL: \(String(url.path.prefix(512)))")
                }
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "mode", value: "ro"),
                                         URLQueryItem(name: "immutable", value: "1")]
                guard let uri = components?.string else {
                    throw PerfRefinementFailure.invalid("validation \(phase.rawValue) file URI: \(String(url.path.prefix(512)))")
                }
                filename = uri
                flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            } else {
                filename = url.path
                flags = SQLITE_OPEN_READONLY
            }
            var raw: OpaquePointer?
            let opened = sqlite3_open_v2(filename, &raw, flags, nil)
            guard let db = raw else {
                throw validationFailure("open", phase: phase, url: url, database: nil, code: opened)
            }
            defer { sqlite3_close(db) }
            guard opened == SQLITE_OK else {
                throw validationFailure("open", phase: phase, url: url, database: db, code: opened)
            }
            var query: OpaquePointer?
            let sql = "SELECT rank,title,body,accessCount,lastAccessed,pinned,globalId FROM PerfRefinementMemory ORDER BY rank"
            let prepared = sqlite3_prepare_v2(db, sql, -1, &query, nil)
            guard prepared == SQLITE_OK, let query else {
                // Capture before cleanup can replace the handle's error text.
                let failure = validationFailure("prepare", phase: phase, url: url, database: db, code: prepared)
                if let query { sqlite3_finalize(query) }
                throw failure
            }
            defer { sqlite3_finalize(query) }
            var step = sqlite3_step(query)
            while step == SQLITE_ROW {
                let value = try PerfRefinementValues(statement: query)
                try require((0..<10_000).contains(value.rank), "invalid rank")
                let changed = updated && Self.updateRanks.contains(value.rank)
                try require(value == PerfRefinementValues(rank: value.rank, updated: changed),
                            "fixture scalar mismatch at rank \(value.rank)")
                if value != PerfRefinementValues(rank: value.rank) {
                    changedRanks.insert(value.rank)
                }
                guard let text = sqlite3_column_text(query, 6) else {
                    throw PerfRefinementFailure.invalid("missing globalId")
                }
                try require(String(cString: text).lowercased() == globalID(value.rank).uuidString.lowercased(),
                            "fixture globalId mismatch at rank \(value.rank)")
                values.append(value)
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else {
                throw validationFailure("step", phase: phase, url: url, database: db, code: step)
            }
        }
        values.sort { $0.rank < $1.rank }
        try require(values.map(\.rank) == Array(0..<10_000), "fixture membership changed")
        try require(changedRanks == (updated ? Set(Self.updateRanks) : Set<Int>()),
                    "fixture did not change exactly the 11 unique intended rows")
        return checksum(values)
    }

    private func runSample(directory: URL, masters: [URL], variant: String,
                           iteration: Int, warmup: Bool) throws -> PerfRefinementSample {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let copies = try masters.map { master -> URL in
            let copy = directory.appendingPathComponent(master.lastPathComponent)
            try fm.copyItem(at: master, to: copy)
            return copy
        }
        let before = try validate(copies, updated: false, phase: .unopenedCopy)
        let main = try Lattice(PerfRefinementMemory.self, configuration: configuration(copies[0]))
        defer { main.close() }
        var attached: Lattice?
        var query = main
        defer {
            if attached != nil { query.close() }
            attached?.close()
        }
        if copies.count == 2 {
            let other = try Lattice(PerfRefinementMemory.self, configuration: configuration(copies[1]))
            attached = other
            query = try main.attaching(lattice: other)
        }

        // Fresh copied path => fresh backend, shape and model registry keys.
        // Constructing this facade does not fill it. Do not call count first.
        let results = query.objects(PerfRefinementMemory.self).sortedBy(\.rank)
        let shape = results._shapeState
        try require(shape.fillCounts.offset == 0 && shape.fillCounts.keyset == 0 && shape.anchorCount == 0,
                    "read shape is unexpectedly warm")
        var rows: [PerfRefinementMemory] = []
        rows.reserveCapacity(100)
        let (readResult, readTotal) = try measure {
            let (_, cold) = try measure {
                for index in 4_000..<4_100 {
                    guard let row = results.element(at: index) else {
                        throw PerfRefinementFailure.invalid("missing displayed row")
                    }
                    rows.append(row)
                }
            }
            let (displayed, scalars) = measure { rows.map { PerfRefinementValues($0) } }
            return (cold, displayed, scalars)
        }
        let (cold, displayed, scalars) = readResult
        let coldFills = shape.fillCounts
        let coldAnchors = shape.anchorCount
        try require(rows.allSatisfy { !$0.isMaterialized }, "read workload silently materialized")
        try require(displayed == (4_000..<4_100).map { PerfRefinementValues(rank: $0) },
                    "displayed values/order differ from contract")
        let readChecksum = checksum(displayed)

        // Explicit warm lookup is reported separately and retains the exact
        // rows from the cold phase. Its scalar read still has live semantics.
        var warmRows: [PerfRefinementMemory] = []
        warmRows.reserveCapacity(100)
        let (_, warmHit) = try measure {
            for index in 4_000..<4_100 {
                guard let row = results.element(at: index) else {
                    throw PerfRefinementFailure.invalid("missing warm row")
                }
                warmRows.append(row)
            }
        }
        let warmFills = shape.fillCounts
        let warmAnchors = shape.anchorCount
        let (warmValues, warmScalars) = measure { warmRows.map { PerfRefinementValues($0) } }
        try require(warmValues == displayed, "warm values changed")
        try require(zip(rows, warmRows).allSatisfy { $0.0 === $0.1 }, "warm identity changed")

        // The complete baseline is one checked transaction, including ID
        // discovery/hydration/routing and COMMIT. Never substitute += for the
        // SQL-side increment. No resets or verification are timed.
        var discovery: PerfRefinementPhase?
        var writes: PerfRefinementPhase?
        var changedRows: Int?
        var selected: [PerfRefinementMemory] = []
        let (_, updateTotal) = try measure {
            try query.withTransaction {
                let (found, timing) = measure {
                    query.objects(PerfRefinementMemory.self)
                        .where { $0.rank.in(Self.updateRanks) }.sortedBy(\.rank).snapshot()
                }
                selected = found
                discovery = timing
                try require(selected.count == 11, "update discovery did not return 11 rows")
                #if LATTICE_PERF_SELECTED_BATCH
                // Candidate-only compile opt-in; the baseline can compile the
                // identical harness without seeing any new bulk-update API.
                let (affected, timingWrites) = try measure {
                    try query.bulkUpdate(selected, changes: [
                        .set(\.lastAccessed, to: Date(timeIntervalSince1970: 1_800_000_000)),
                        .increment(\.accessCount, by: 1),
                    ])
                }
                #else
                let (affected, timingWrites) = measure {
                    for row in selected {
                        row.lastAccessed = Date(timeIntervalSince1970: 1_800_000_000)
                        row.increment("accessCount")
                    }
                    return selected.count
                }
                #endif
                changedRows = affected
                writes = timingWrites
            }
        }
        try require(changedRows == 11, "write implementation did not report 11 changed rows")
        let after = try validate(copies, updated: true, phase: .liveAfterimage)
        guard let discovery, let writes else {
            throw PerfRefinementFailure.invalid("missing update measurements")
        }
        return .init(variant: variant, iteration: iteration, warmup: warmup,
                     phases: ["read.total": readTotal,
                              "read.cold_page_identity_anchor": cold,
                              "read.live_scalars": scalars,
                              "read.warm_hit": warmHit,
                              "read.warm_live_scalars": warmScalars,
                              "update.total": updateTotal,
                              "update.discovery_hydration_routing": discovery,
                              "update.set_and_atomic_increment": writes],
                     readChecksum: readChecksum, beforeChecksum: before, afterChecksum: after,
                     readRows: displayed.count, updatedRows: selected.count,
                     coldOffsetFills: coldFills.offset, coldKeysetFills: coldFills.keyset,
                     coldAnchors: coldAnchors, warmOffsetFills: warmFills.offset,
                     warmKeysetFills: warmFills.keyset, warmAnchors: warmAnchors)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATTICE_PERF_REFINEMENT"] == "1"))
    func releaseRead100AndUpdate11() throws {
        #if DEBUG
        throw PerfRefinementFailure.invalid("this benchmark requires a Release build")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let requested = environment["LATTICE_PERF_RUN_DIR"], requested.hasPrefix("/") else {
            throw PerfRefinementFailure.invalid("set an absolute LATTICE_PERF_RUN_DIR")
        }
        let root = URL(fileURLWithPath: requested, isDirectory: true).standardizedFileURL
        let allowed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("localdev", isDirectory: true).resolvingSymlinksInPath().path + "/"
        try require(root.resolvingSymlinksInPath().path.hasPrefix(allowed), "run directory must be below ~/localdev")
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: root.path), "run directory already exists; use a new directory")
        // Parent directory must already exist; no implicit temp/cache locations.
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let measured = Int(environment["LATTICE_PERF_SAMPLES"] ?? "100") ?? 0
        let warmups = Int(environment["LATTICE_PERF_WARMUPS"] ?? "5") ?? -1
        try require((100...1_000).contains(measured) && (5...100).contains(warmups),
                    "need 100...1000 measured samples and 5...100 warmups")
        func provenance(_ key: String) throws -> String {
            guard let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PerfRefinementFailure.invalid("missing provenance: \(key)")
            }
            return value
        }
        let manifest = try PerfRefinementManifest(
            updateRanks: Self.updateRanks, measuredSamples: measured, warmupSamples: warmups,
            startedAt: ISO8601DateFormatter().string(from: Date()), runDirectory: root.path,
            sourceRevision: provenance("LATTICE_PERF_SOURCE_REVISION"),
            coreRevision: provenance("LATTICE_PERF_CORE_REVISION"),
            buildIdentity: provenance("LATTICE_PERF_BUILD_IDENTITY"),
            hostIdentity: provenance("LATTICE_PERF_HOST_ID"),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
        try encode(manifest, to: root.appendingPathComponent("manifest.json"))
        var samples: [PerfRefinementSample] = []
        for variant in ["local", "attached"] {
            let variantDir = root.appendingPathComponent(variant, isDirectory: true)
            try fm.createDirectory(at: variantDir, withIntermediateDirectories: false)
            let masterDir = variantDir.appendingPathComponent("master", isDirectory: true)
            try fm.createDirectory(at: masterDir, withIntermediateDirectories: false)
            let masterMain = masterDir.appendingPathComponent("main.sqlite")
            var masters = [masterMain]
            if variant == "attached" {
                let masterAttached = masterDir.appendingPathComponent("attached.sqlite")
                masters.append(masterAttached)
                try seed(masterMain, ranks: Array(stride(from: 0, to: 10_000, by: 2)))
                try seed(masterAttached, ranks: Array(stride(from: 1, to: 10_000, by: 2)))
            } else {
                try seed(masterMain, ranks: Array(0..<10_000))
            }
            for master in masters {
                let wal = master.path + "-wal"
                if fm.fileExists(atPath: wal) {
                    let bytes = try fm.attributesOfItem(atPath: wal)[.size] as? NSNumber
                    try require(bytes?.uint64Value == 0, "master WAL is not empty; refuse incomplete copy")
                }
            }
            let masterChecksum = try validate(masters, updated: false, phase: .checkpointedMaster)
            for iteration in 0..<(warmups + measured) {
                let work = variantDir.appendingPathComponent(String(format: "iteration-%04d", iteration), isDirectory: true)
                let sample = try runSample(directory: work, masters: masters, variant: variant,
                                           iteration: iteration, warmup: iteration < warmups)
                try require(sample.beforeChecksum == masterChecksum, "reset changed fixture")
                samples.append(sample)
                try encode(sample, to: variantDir.appendingPathComponent(String(format: "sample-%04d.json", iteration)))
                // Retain the first measured postimage and immutable before
                // masters. Failed iterations remain for diagnosis as well.
                if iteration != warmups { try fm.removeItem(at: work) }
            }
        }
        try encode(PerfRefinementResult(manifest: manifest, samples: samples),
                   to: root.appendingPathComponent("result.json"))
        print("LATTICE_PERF_REFINEMENT_COMPLETE \(root.appendingPathComponent("result.json").path)")
        #endif
    }
}
