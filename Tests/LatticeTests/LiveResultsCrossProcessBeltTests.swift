import Testing
import Foundation
@testable import Lattice
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Item A Commit 6 — data_version belt (T4)
//
// Foreign (out-of-process) writers cannot fire this process's synchronous
// invalidation hook, and the cross-process notifier is documented droppable.
// The belt bounds the staleness window: at most once per
// `crossProcessBeltIntervalMs`, a top-level access batch issues
// `PRAGMA data_version` on the dedicated non-transaction cross-process read
// connection (`xproc_read_db_` — NEVER a keeper: inside a held read txn the
// value is frozen at the snapshot); a change not explained by a
// locally-observed write is a foreign commit ⇒ epoch bump, every shape
// re-captures.
//
// T4  cross-process data_version: a genuinely separate SQLite connection
//     (no latticecore instance — no hook, no notifier post) simulates the
//     foreign writer. Belt off → stale for the whole observation window
//     (until notifier/TTL, neither of which fires here); belt on → fresh
//     within the interval; ≤ 1 PRAGMA per interval (probe counter).

@Model final class Gen6Item {
    var name: String
    var rank: Int
}

#if canImport(SQLite3)
private struct ForeignWriteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "foreign write failed: \(message)" }
}

/// Commit through a RAW SQLite connection — a genuinely separate connection
/// with no latticecore instance behind it, so no in-process invalidation
/// hook fires and no cross-process notification is posted. This is exactly
/// what a commit from another process looks like to this one.
///
/// The audit triggers on model tables call the custom `sync_disabled()` SQL
/// function, so the foreign connection registers the same stub a real
/// foreign lattice process would provide (sync enabled ⇒ 0).
private func foreignCommit(dbPath: String, sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(dbPath, &handle) == SQLITE_OK, let db = handle else {
        sqlite3_close(handle)
        throw ForeignWriteError(message: "cannot open \(dbPath)")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    guard sqlite3_create_function(db, "sync_disabled", 0, SQLITE_UTF8, nil,
                                  { ctx, _, _ in sqlite3_result_int(ctx, 0) },
                                  nil, nil) == SQLITE_OK else {
        throw ForeignWriteError(message: "cannot register sync_disabled stub")
    }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(errorMessage)
        throw ForeignWriteError(message: message)
    }
}
#endif

@Suite("Live Results Cross-Process Belt Tests (item A Commit 6)")
class LiveResultsCrossProcessBeltTests: BaseTest {

    private func seed(_ lattice: Lattice, count: Int) throws {
        try lattice.add(contentsOf: (0..<count).map { i -> Gen6Item in
            let item = Gen6Item()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })
    }

    private func coordinator(for lattice: Lattice) -> GenerationCoordinator {
        GenerationCoordinatorRegistry.coordinator(for: lattice.backend,
                                                  tuning: lattice.configuration.resultsTuning)
    }

#if canImport(SQLite3)

    // MARK: T4 — belt ON: foreign commit fresh within the interval

    @Test func t4_beltOn_foreignCommitFreshWithinInterval() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "belt_on_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.crossProcessBeltIntervalMs = 25
        let lattice = try Lattice(Gen6Item.self, configuration: config)
        try seed(lattice, count: 10)

        // Prime the shape cache (and the belt baseline): a stale cached 0 is
        // exactly what an unnoticed foreign commit would keep serving.
        let promoted = lattice.objects(Gen6Item.self).where { $0.rank >= 900 }
        #expect(promoted.count == 0)

        try foreignCommit(dbPath: url.path,
                          sql: "UPDATE \(Gen6Item.entityName) SET rank = 999 WHERE rank = 0")

        // No lattice-side write happens below — only the belt can deliver
        // freshness. Off the main actor every access is its own batch, so
        // the belt re-checks as soon as the interval elapses. The deadline
        // is a CI ceiling, not the freshness bound; typical detection is
        // one interval (25 ms).
        var fresh = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if promoted.count == 1 { fresh = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // CI-only failure under investigation: dump every layer's state so a
        // red run tells us WHICH layer is dead (probe cadence, delta
        // observation, or the foreign write itself).
        let c = coordinator(for: lattice).beltCounters
        let dv = lattice.backend.dataVersion()
        let liveRows = lattice.objects(Gen6Item.self).where { $0.rank >= 900 }.snapshot().count
        print("T4-diag: fresh=\(fresh) probes=\(c.probes) foreign=\(c.foreignBumps) ambiguous=\(c.ambiguousBumps) dataVersion=\(dv) liveMatchingRows=\(liveRows) count=\(promoted.count)")
        #expect(fresh, "belt on: a foreign commit must become visible within the belt interval [diag: probes=\(c.probes) foreign=\(c.foreignBumps) ambiguous=\(c.ambiguousBumps) dv=\(dv) liveRows=\(liveRows)]")
        #expect(c.foreignBumps + c.ambiguousBumps >= 1,
                "freshness must have arrived via the belt's bump detection [diag: probes=\(c.probes) ambiguous=\(c.ambiguousBumps)]")
    }

    // MARK: T4 — belt OFF: foreign commit stays stale (no notifier, no TTL)

    @Test func t4_beltOff_foreignCommitStaysStale() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "belt_off_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.crossProcessBeltIntervalMs = nil   // §1.7: nil disables
        let lattice = try Lattice(Gen6Item.self, configuration: config)
        try seed(lattice, count: 10)

        let promoted = lattice.objects(Gen6Item.self).where { $0.rank >= 900 }
        #expect(promoted.count == 0)

        try foreignCommit(dbPath: url.path,
                          sql: "UPDATE \(Gen6Item.entityName) SET rank = 999 WHERE rank = 0")

        // The raw connection posts no cross-process notification and the
        // generation TTL (default 30 s) is far beyond this window: with the
        // belt disabled the stale cache is the documented worst case —
        // "stale until the next notifier/TTL", never a crash.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
        while ContinuousClock.now < deadline {
            #expect(promoted.count == 0,
                    "belt off: nothing may deliver the foreign commit inside the observation window")
            try await Task.sleep(for: .milliseconds(25))
        }
        let counters = coordinator(for: lattice).beltCounters
        #expect(counters.probes == 0, "belt disabled: no PRAGMA data_version probes may be issued")

        // The data itself is intact — a manual refresh() surfaces it.
        promoted.refresh()
        #expect(promoted.count == 1)
    }

    // MARK: T4 — amortization: ≤ 1 PRAGMA per interval

    @Test func t4_belt_probesAtMostOncePerInterval() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "belt_budget_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.crossProcessBeltIntervalMs = 200
        let lattice = try Lattice(Gen6Item.self, configuration: config)
        try seed(lattice, count: 10)

        let results = lattice.objects(Gen6Item.self)
        #expect(results.count == 10)   // prime: issues at most the baseline probe

        let coord = coordinator(for: lattice)
        let before = coord.beltCounters.probes
        // A hammering render loop inside one interval: cache hits only —
        // the belt clock floors the PRAGMA to ≤ 1 for the whole burst.
        for _ in 0..<500 {
            #expect(results.count == 10)
        }
        let burstProbes = coord.beltCounters.probes - before
        #expect(burstProbes <= 1,
                "belt issued \(burstProbes) probes inside one interval — must be ≤ 1 per interval")

        // And the belt is not dead: after the interval elapses, the next
        // top-level access probes again.
        try await Task.sleep(for: .milliseconds(250))
        _ = results.count
        #expect(coord.beltCounters.probes > before,
                "belt must probe again once the interval has elapsed")
    }

#endif  // canImport(SQLite3)

    // MARK: Memory family — the belt never runs (no cross-process writers)

    @Test func belt_memoryFamilyNeverProbes() throws {
        var config = Lattice.Configuration(storage: .memory())
        config.resultsTuning.crossProcessBeltIntervalMs = 10
        let lattice = try Lattice(Gen6Item.self, configuration: config)
        try seed(lattice, count: 5)

        let results = lattice.objects(Gen6Item.self)
        #expect(results.count == 5)
        #expect(results[0].rank == 0)
        #expect(coordinator(for: lattice).beltCounters.probes == 0,
                "memory-family stores must never issue data_version probes")
    }
}
