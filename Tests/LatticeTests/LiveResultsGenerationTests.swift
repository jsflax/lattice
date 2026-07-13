import Testing
import Foundation
@testable import Lattice

// MARK: - Item A Commit 1 — shared shape cache + epochs + never-trap
//
// T2a  same-handle read-your-writes (isolation-parameterized: MainActor-
//      created AND nonisolated-created lattices) — §1.3 Layer 1.
// T10  leaf-lock ABBA watchdog — sync-enabled file lattice, tight writer
//      loop vs a reader thread populating cold shapes through the registry,
//      bounded watchdog — pins the §2.3 two-phase pattern on the read-
//      through-write-connection topology.
// Plus the Commit-1 partials from §7: statement budget (idle tick issues
// zero collection queries), the no-`fatalError` grep gate over
// Sources/Lattice/Results/, registry eviction bounds, tolerant-ladder and
// warm-rebind sanity pins.

@Model final class GenItem {
    var name: String
    var rank: Int
}

private final class SendBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@Suite("Live Results Generation Tests (item A Commit 1)")
class LiveResultsGenerationTests: BaseTest {

    // MARK: T2a — same-handle read-your-writes, MainActor-created lattice

    @Test @MainActor func t2a_readYourWrites_mainActorCreatedLattice() throws {
        let lattice = try testLattice(GenItem.self)
        let all = lattice.objects(GenItem.self)
        let old = lattice.objects(GenItem.self).where { $0.rank > 30 }

        // Prime the shared shape caches BEFORE writing — a stale cache is
        // exactly what a scheduler-hopped invalidation would serve.
        #expect(all.count == 0)
        #expect(old.count == 0)

        let item = GenItem()
        item.name = "first"
        item.rank = 1
        try lattice.add(item)

        // Synchronous, same thread, no await: `add()` must bump the epoch
        // before returning (§1.3 Layer 1). The old trampoline path delivers
        // only after a MainActor Task hop — this line is what it fails.
        #expect(all.count == 1)
        #expect(all[0].name == "first")

        // Managed-property setter that changes predicate membership is a
        // settled autocommit write — read-your-writes exact as well.
        item.rank = 40
        #expect(old.count == 1)

        // Deletion, same contract.
        lattice.delete(item)
        #expect(all.count == 0)
        #expect(old.count == 0)
    }

    // MARK: T2a — same-handle read-your-writes, nonisolated-created lattice

    @Test func t2a_readYourWrites_nonisolatedCreatedLattice() throws {
        let lattice = try testLattice(GenItem.self)
        let all = lattice.objects(GenItem.self)
        let old = lattice.objects(GenItem.self).where { $0.rank > 30 }

        #expect(all.count == 0)
        #expect(old.count == 0)

        let item = GenItem()
        item.name = "first"
        item.rank = 1
        try lattice.add(item)

        #expect(all.count == 1)
        #expect(all[0].name == "first")

        item.rank = 40
        #expect(old.count == 1)

        lattice.delete(item)
        #expect(all.count == 0)
        #expect(old.count == 0)
    }

    // MARK: T10 — leaf-lock ABBA watchdog (§2.3)

    /// Sync-enabled FILE lattice (IPC target ⇒ `is_sync_enabled()`), so reads
    /// route through the WRITE connection — the topology that shipped the
    /// pacer_mutex_/connection-mutex ABBA hang (`sync.cpp:668-676`). A tight
    /// writer loop races a reader populating cold shapes through the
    /// process-global registry; if any registry/shape lock were held across
    /// SQL, writer (holding the connection FULLMUTEX, wanting the registry
    /// lock via the epoch bump) and reader (holding the registry lock,
    /// wanting the connection mutex) would deadlock. Bounded watchdog.
    @Test(.timeLimit(.minutes(5)))
    func t10_leafLockABBAWatchdog_syncEnabledFileLattice() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t10_abba_\(String.random(length: 12)).sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.ipcTargets = [.init(channel: "t10_\(String.random(length: 8))")]
        let lattice = try Lattice(GenItem.self, configuration: config)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        try lattice.add(contentsOf: (0..<50).map { i -> GenItem in
            let item = GenItem()
            item.name = "seed_\(i)"
            item.rank = i
            return item
        })

        let box = SendBox(lattice)
        let done = DispatchSemaphore(value: 0)
        let iterations = 400

        // Tight writer loop: every add bumps the epoch (registry + shape
        // leaf locks) right after the backend write returns.
        Thread.detachNewThread {
            let lattice = box.value
            for i in 0..<iterations {
                let item = GenItem()
                item.name = "w_\(i)"
                item.rank = i % 100
                try? lattice.add(item)
            }
            done.signal()
        }

        // Reader thread: cold shapes through the registry (distinct WHERE
        // per iteration → shape create + LRU eviction churn), each issuing
        // COUNT + page-fill SQL through the write connection.
        Thread.detachNewThread {
            let lattice = box.value
            for i in 0..<iterations {
                let shape = lattice.objects(GenItem.self).where { $0.rank > (i % 120) }
                let count = shape.count
                if count > 0 {
                    _ = shape[count - 1]
                }
            }
            done.signal()
        }

        // The watchdog: both loops must drain within the bound. A leaf-lock
        // violation hangs them and fails here rather than hanging CI.
        let first = done.wait(timeout: .now() + 120)
        let second = done.wait(timeout: .now() + 120)
        #expect(first == .success && second == .success,
                "T10: writer/reader did not complete — ABBA deadlock between a registry/shape lock and the sync-enabled write connection")
    }

    // MARK: Statement budget — idle tick issues ZERO collection queries (§5)

    @Test func statementBudget_idleTickIssuesZeroCollectionQueries() throws {
        let lattice = try testLattice(GenItem.self)
        try lattice.add(contentsOf: (0..<250).map { i -> GenItem in
            let item = GenItem()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })

        let results = lattice.objects(GenItem.self)
        // Warm: one COUNT + one page fill.
        #expect(results.count == 250)
        _ = results[0]
        _ = results[42]

        // Idle "render ticks": repeated count + warm-page subscripts must be
        // pure cache hits. threadSQLStatementCount is thread-local, and this
        // body has no suspension points, so the budget is exact.
        let before = Lattice.threadSQLStatementCount
        for _ in 0..<25 {
            #expect(results.count == 250)
            _ = results[0]
            _ = results[17]
            _ = results[42]
        }
        let after = Lattice.threadSQLStatementCount
        #expect(after == before,
                "idle accesses issued \(after - before) SQL statements; expected 0 (count/pages cached per generation)")
    }

    // MARK: Registry eviction bounds (§2.2, `maxCachedShapes`)

    @Test func shapeRegistry_enforcesLRUBound() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "shapes_lru_\(String.random(length: 12)).sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.maxCachedShapes = 8
        let lattice = try Lattice(GenItem.self, configuration: config)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        for i in 0..<40 {
            _ = lattice.objects(GenItem.self).where { $0.rank > i }.count
        }
        let coordinator = GenerationCoordinatorRegistry.coordinator(
            for: lattice.backend, tuning: lattice.configuration.resultsTuning)
        #expect(coordinator.shapeCount <= 8,
                "registry held \(coordinator.shapeCount) shapes; LRU bound is 8")
        // Bound holds and the cache still works after eviction churn.
        #expect(lattice.objects(GenItem.self).where { $0.rank > 39 }.count == 0)
    }

    // MARK: No-`fatalError` grep gate (§1.2 rung 5)

    /// Asserts no `fatalError(` remains under `Sources/Lattice/Results/`.
    /// Exemption (per spec): members marked `@available(*, unavailable)` —
    /// detected as a `fatalError(` whose preceding 6 lines contain the
    /// unavailable attribute. Commented-out occurrences are ignored.
    @Test func grepGate_noFatalErrorUnderResultsSources() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // LatticeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let resultsDir = repoRoot.appending(path: "Sources/Lattice/Results")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resultsDir.path, isDirectory: &isDirectory)
        try #require(exists && isDirectory.boolValue,
                     "Sources/Lattice/Results not found from #filePath — gate cannot run")

        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty)

        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("fatalError(") else { continue }
                guard !trimmed.hasPrefix("//") else { continue }
                let windowStart = max(0, index - 6)
                let window = lines[windowStart..<index].joined(separator: "\n")
                if window.contains("@available(*, unavailable") { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
            }
        }
        #expect(offenders.isEmpty,
                "fatalError( found under Sources/Lattice/Results/ (item A forbids trap paths):\n\(offenders.joined(separator: "\n"))")
    }

    // MARK: Tolerant-ladder sanity pins (§1.2)

    @Test func emptyResults_fabricatedIndex_servesInvalidatedPlaceholder() throws {
        let lattice = try testLattice(GenItem.self)
        let results = lattice.objects(GenItem.self)
        #expect(results.count == 0)
        // element(at:) expresses absence as nil (§1.7)…
        #expect(results.element(at: 3) == nil)
        // …while the Collection subscript serves rung (d): an unmanaged,
        // default-valued (invalidated) placeholder — never a trap.
        let ghost = results[3]
        #expect(ghost.primaryKey == nil)
        #expect(ghost.name == "")
    }

    @Test func staleIndexPastEnd_servesLadderNotTrap() throws {
        let lattice = try testLattice(GenItem.self)
        let item = GenItem()
        item.name = "real"
        item.rank = 0
        try lattice.add(item)

        let results = lattice.objects(GenItem.self)
        #expect(results.count == 1)
        _ = results[0]   // warm page 0 (also records the lifeboat)

        // A fabricated/stale index inside the same page: rung (c) serves the
        // lifeboat (the last element any fill returned) instead of trapping.
        let served = results[5]
        #expect(served.name == "real")
        #expect(results.element(at: 5) == nil)

        // Slice subscripts ride the same ladder (§1.4) — no independent trap.
        let slice = results[0..<1]
        #expect(slice[0].name == "real")
    }

    // MARK: refresh() / generationID (§1.7)

    @Test func refresh_dropsCachesAndAdvancesGeneration() throws {
        let lattice = try testLattice(GenItem.self)
        try lattice.add(contentsOf: (0..<10).map { i -> GenItem in
            let item = GenItem()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })
        let results = lattice.objects(GenItem.self)
        #expect(results.count == 10)
        let generationBefore = results.generationID

        results.refresh()

        let statementsBefore = Lattice.threadSQLStatementCount
        #expect(results.count == 10)   // must re-query (cache dropped)
        #expect(Lattice.threadSQLStatementCount > statementsBefore)
        #expect(results.generationID > generationBefore)
    }

    // MARK: Facade wiring — rebuilt facades land warm (§1.4/§1.5)

    @Test func rebuiltFacades_shareTheWarmShapeCache() throws {
        let lattice = try testLattice(GenItem.self)
        try lattice.add(contentsOf: (0..<30).map { i -> GenItem in
            let item = GenItem()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })

        // Warm the shape through facade A.
        let a = lattice.objects(GenItem.self).where { $0.rank >= 10 }
        #expect(a.count == 20)
        _ = a[0]

        // A TSR rebuild (the same mechanism @LatticeQuery's re-fetch and
        // @Relation's per-access facade use) must be a re-bind, not a
        // re-query: zero SQL for the same accesses.
        let rebuilt = try #require(a.sendableReference.resolve(on: lattice))
        let before = Lattice.threadSQLStatementCount
        #expect(rebuilt.count == 20)
        _ = rebuilt[0]
        #expect(Lattice.threadSQLStatementCount == before,
                "rebuilt facade re-queried instead of binding to the warm shared shape")
    }
}
