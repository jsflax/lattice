import Testing
import Foundation
@testable import Lattice

// MARK: - Item A Commit 5 (part 2) — lifecycle + WAL retention soaks
//
// T5    WAL-bound soak: write burst + scrolling reader on a sync-enabled
//       (pacer-carrying) file lattice — the -wal stays ≤ 2 ×
//       `walKeeperEvictionThresholdBytes` ABSOLUTE during the burst (§3.4
//       threshold keeper eviction), and TRUNCATE recovers within ~2 pacer
//       cycles of the burst ending (§3.3).
// T5-b  non-sync + hidden Results: NO pacer thread exists — a
//       view-model-retained facade with zero accesses must have its keeper
//       retired by the coordinator's MAINTENANCE TIMER (§3.2, the
//       enforcement actor for every config), opening the checkpoint gap.
// T5-c  suspend/resume: retire-all on background simulation → cross-handle
//       writes → TRUNCATE succeeds while "suspended" → resume re-pins and
//       reflects (§3.6, 0xdead10cc contract).
// T6    shared-cache memory containment: named memory, two handles, writer
//       loop vs generation-reading loop — zero surfaced errors, zero
//       deadlock, zero std::terminate, bounded watchdog (§4.1).
// Plus: iterator generation-hop resume after a force-retire (§1.4).
//
// All soaks are time-compressed through the ms-granular tunings
// (`generationTTLSeconds`, `walKeeperEvictionThresholdBytes`, sync
// checkpoint intervals); no test sleeps more than ~5 s total.

@Model final class Soak5Item {
    var name: String
    var payload: String
    var rank: Int
}

private final class SoakBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@Suite("Live Results Lifecycle + Soak Tests (item A Commit 5)", .serialized)
class LiveResultsLifecycleSoakTests: BaseTest {

    private func walSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return (attributes?[.size] as? Int) ?? 0
    }

    private func seed(_ lattice: Lattice, count: Int, payloadBytes: Int = 16) throws {
        let payload = String(repeating: "x", count: payloadBytes)
        try lattice.add(contentsOf: (0..<count).map { i -> Soak5Item in
            let item = Soak5Item()
            item.name = "row_\(i)"
            item.payload = payload
            item.rank = i
            return item
        })
    }

    /// Bounded poll (never sleeps more than `deadline` total).
    private func poll(deadline: TimeInterval, interval: TimeInterval = 0.02,
                      until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }

    // MARK: T5 — WAL-bound soak (write burst + scrolling reader, §3.4)

    @Test(.timeLimit(.minutes(5)))
    func t5_walBoundSoak_burstPlusScrolling_stayswithinThreshold() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t5_soak_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        var config = Lattice.Configuration(fileURL: url)
        // Sync-enabled (IPC target) so the PACER exists; ms-granular
        // checkpoint cadences compress "pacer cycles" to 100 ms.
        config.ipcTargets = [.init(channel: "t5_\(String.random(length: 8))")]
        config.syncTuning = .init(uploadCoalesceMs: 10,
                                  checkpointPassiveIntervalMs: 50,
                                  checkpointTruncateIntervalMs: 100)
        // 4 MB threshold: the §3.5 bound is 2 × threshold ABSOLUTE, where
        // the second threshold covers ONE detection window (flag at commit →
        // serviced at the next acquire/maintenance tick). This burst writes
        // ~16 MB at full speed, so the window (~a few hundred ms of writes)
        // must fit inside one threshold — it does at 4 MB, and the burst
        // still crosses the threshold several times (real sawtooth).
        let threshold = 4 << 20
        config.resultsTuning.walKeeperEvictionThresholdBytes = threshold
        config.resultsTuning.generationTTLSeconds = 0.05

        let lattice = try Lattice(Soak5Item.self, configuration: config)
        try seed(lattice, count: 200)

        let box = SoakBox(lattice)
        let stop = UnfairLock<Bool>(initialState: false)
        let readerDone = DispatchSemaphore(value: 0)
        let maxWal = UnfairLock<Int>(initialState: 0)

        // "Scrolling UI": a reader loop that counts and realizes rows across
        // pages — every epoch bump re-pins a fresh keeper (the §3.1
        // reader-at-every-instant regime that starves log rewind without
        // §3.4's threshold eviction).
        Thread.detachNewThread { [weak self] in
            let results = box.value.objects(Soak5Item.self)
            var i = 0
            while !(stop.withLockUnchecked { $0 }) {
                let count = results.count
                if count > 0 {
                    _ = results.element(at: i % count)
                    _ = results.element(at: (count - 1 + i) % count)
                }
                i += 1
                _ = self
            }
            readerDone.signal()
        }

        // Write burst: ~16 MB of row payloads against a 4 MB threshold —
        // several eviction sawteeth. Sample the -wal as we go.
        let payload = String(repeating: "y", count: 4096)
        for i in 0..<4000 {
            let item = Soak5Item()
            item.name = "burst_\(i)"
            item.payload = payload
            item.rank = i
            try lattice.add(item)
            if i % 20 == 0 {
                let size = walSize(url)
                maxWal.withLockUnchecked { if size > $0 { $0 = size } }
            }
        }
        stop.withLockUnchecked { $0 = true }
        #expect(readerDone.wait(timeout: .now() + 60) == .success, "T5 reader loop wedged")

        // The §3.5 soak pin: -wal ≤ 2 × threshold ABSOLUTE at all times.
        let observedMax = maxWal.withLockUnchecked { $0 }
        #expect(observedMax > 0, "soak never observed the -wal — sampling broken")
        #expect(observedMax <= 2 * threshold,
                "-wal grew to \(observedMax) bytes; the §3.4 bound is \(2 * threshold)")

        // Post-burst recovery: keepers TTL-retire (50 ms TTL + maintenance
        // tick), opening the §3.4 reader gap. The pacer's own TRUNCATE
        // additionally requires upload-idle (`pending == 0`), which a
        // peer-less IPC channel never reaches — its cadence is pinned in
        // latticecore's pacer tests — so after the gap opens this test
        // drives one TRUNCATE explicitly (accepting an earlier
        // eviction-path truncate if it already happened): the log MUST
        // truncate to zero behind the retired keepers.
        let gapOpened = poll(deadline: 2.0) {
            lattice.backend.readGenerationsOutstanding() == 0
        }
        #expect(gapOpened, "keepers never retired post-burst (TTL + maintenance timer broken)")
        if walSize(url) != 0 {
            lattice.backend.checkpoint()
        }
        #expect(walSize(url) == 0,
                "-wal is \(walSize(url)) bytes post-burst behind retired keepers — the §3.4 gap failed")
    }

    // MARK: T5-b — non-sync + hidden Results: timer-driven retire (§3.2)

    @Test(.timeLimit(.minutes(5)))
    func t5b_nonSyncHiddenResults_timerRetiresKeeperAndOpensCheckpointGap() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t5b_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        var config = Lattice.Configuration(fileURL: url)
        // NO sync, NO pacer — the coordinator's maintenance timer is the
        // §3.2 enforcement actor of record. TTL compressed to 300 ms.
        config.resultsTuning.generationTTLSeconds = 0.3
        let lattice = try Lattice(Soak5Item.self, configuration: config)
        try seed(lattice, count: 50)

        // The "view-model-retained, hidden" facade: ONE access pins a
        // keeper, then it is never touched again.
        let hidden = lattice.objects(Soak5Item.self)
        #expect(hidden.count == 50)
        #expect(lattice.backend.localReadGenerationsOutstanding() >= 1)

        // Hours-compressed local writes while the facade stays hidden.
        let payload = String(repeating: "z", count: 1024)
        for i in 0..<200 {
            let item = Soak5Item()
            item.name = "w_\(i)"
            item.payload = payload
            item.rank = i
            try lattice.add(item)
        }

        // Control: while the keeper is (still) pinned, TRUNCATE cannot zero
        // the log. (TTL is 300 ms and the burst takes far less; if the
        // timer already retired it, the control is vacuous — the essential
        // assertion below still bites.)
        lattice.backend.checkpoint()
        let walWhilePinned = walSize(url)

        // THE pin: with ZERO further Results accesses and NO pacer thread,
        // the maintenance timer must TTL-retire the keeper.
        let retired = poll(deadline: 3.0) {
            lattice.backend.localReadGenerationsOutstanding() == 0
        }
        #expect(retired, "maintenance timer never retired the idle keeper (non-sync lattice)")

        // The reader gap is open: TRUNCATE now zeroes the -wal.
        lattice.backend.checkpoint()
        #expect(walSize(url) == 0,
                "-wal is \(walSize(url)) bytes after retirement + TRUNCATE (was \(walWhilePinned) while pinned)")

        // The hidden facade still works — re-pins lazily on next access.
        #expect(hidden.count == 250)
    }

    // MARK: T5-c — suspend/resume (§3.6, 0xdead10cc)

    @Test(.timeLimit(.minutes(5)))
    func t5c_suspendResume_retireAllThenCrossHandleWritesThenRepin() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t5c_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        let a = try Lattice(Soak5Item.self, configuration: .init(fileURL: url))
        var configB = Lattice.Configuration(fileURL: url)
        configB.syncTuning = .init(chunkSize: 999)   // distinct core instance
        let b = try Lattice(Soak5Item.self, configuration: configB)
        try #require(a.backend.identityHash != b.backend.identityHash)

        try seed(a, count: 100)
        let results = a.objects(Soak5Item.self)
        #expect(results.count == 100)
        _ = results[0]
        #expect(a.backend.localReadGenerationsOutstanding() >= 1)

        // "Backgrounding": retire everything — the suspended process must
        // hold ZERO read transactions and zero WAL read-marks.
        a.retireAllGenerations()
        #expect(a.backend.localReadGenerationsOutstanding() == 0)

        // "Cross-process" writes while suspended (a second core instance —
        // the same read-mark topology as another process for TRUNCATE).
        for i in 0..<50 {
            let item = Soak5Item()
            item.name = "suspended_\(i)"
            item.payload = ""
            item.rank = 1000 + i
            try b.backend.add(item._dynamicObject._ref)
        }

        // TRUNCATE succeeds while "suspended" — nothing pins the log.
        b.backend.checkpoint()
        #expect(walSize(url) == 0,
                "-wal is \(walSize(url)) bytes — retired generations must not pin the log")

        // "Resume": retireAllGenerations() now LATCHES (§3.6 fix-wave) —
        // accesses stay unpinned until the foreground/resume signal, exactly
        // so a racing background access can't re-pin while suspended.
        #expect(results.count == 150, "latched reads still serve correct data")
        #expect(a.backend.localReadGenerationsOutstanding() == 0,
                "no re-pin while latched")
        a.resumeGenerations()
        #expect(results.count == 150)
        // A cached count doesn't mint (correct); a fresh resolve after an
        // epoch bump proves re-pinning is restored.
        let extra = Soak5Item(); try a.add(extra)
        #expect(results.count == 151)
        #expect(a.backend.localReadGenerationsOutstanding() >= 1)
        #expect(results.element(at: 149) != nil)
    }

    // MARK: T6 — shared-cache memory containment (§4.1)

    @Test(.timeLimit(.minutes(5)))
    func t6_sharedCacheContainment_writerLoopVsReadingLoop() throws {
        let name = "t6_\(String.random(length: 12))"
        let configA = Lattice.Configuration(storage: .memory(named: name))
        var configB = Lattice.Configuration(storage: .memory(named: name))
        configB.syncTuning = .init(chunkSize: 999)   // distinct core instance

        let a = try Lattice(Soak5Item.self, configuration: configA)
        let b = try Lattice(Soak5Item.self, configuration: configB)
        try #require(a.backend.identityHash != b.backend.identityHash,
                     "test premise: two handles over one shared-cache store")

        try seed(a, count: 100)

        let iterations = 400
        let done = DispatchSemaphore(value: 0)
        let writerErrors = UnfairLock<Int>(initialState: 0)
        let readerAnomalies = UnfairLock<Int>(initialState: 0)
        let boxA = SoakBox(a)
        let boxB = SoakBox(b)

        // Writer loop on handle B: adds + object deletes — both core write
        // paths hold the per-store gate for their duration (§4.1 mechanism
        // 2), so they may WAIT on captures but never surface SQLITE_LOCKED.
        // (`deleteWhere` is not gated core-side in the current bridge — a
        // known Commit-3 gap outside this repo — so the writer deletes
        // through object handles.)
        Thread.detachNewThread {
            let lattice = boxB.value
            for i in 0..<iterations {
                do {
                    let item = Soak5Item()
                    item.name = "w_\(i)"
                    item.payload = "p"
                    item.rank = 200 + (i % 100)
                    try lattice.add(item)
                    if i % 7 == 0 {
                        _ = lattice.delete(item)
                    }
                } catch {
                    writerErrors.withLockUnchecked { $0 += 1 }
                }
            }
            done.signal()
        }

        // Generation-reading loop on handle A: id captures + hydrations +
        // one-shot snapshots — gated captures must never surface
        // SQLITE_LOCKED in either direction, and nothing may deadlock or
        // std::terminate.
        Thread.detachNewThread {
            let lattice = boxA.value
            let results = lattice.objects(Soak5Item.self)
            for i in 0..<iterations {
                let count = results.count
                if count < 0 || count > 100 + iterations {
                    readerAnomalies.withLockUnchecked { $0 += 1 }
                }
                if count > 0 {
                    _ = results.element(at: i % count)
                }
                if i % 11 == 0 {
                    _ = results.first
                }
            }
            done.signal()
        }

        // Bounded watchdog: both loops must drain — a gate/lock inversion
        // or an uncontained LOCKED would wedge (or kill) the process here.
        let first = done.wait(timeout: .now() + 120)
        let second = done.wait(timeout: .now() + 120)
        #expect(first == .success && second == .success,
                "T6: writer/reader loops did not complete — shared-cache deadlock")
        #expect(writerErrors.withLockUnchecked { $0 } == 0,
                "T6: writes surfaced errors under concurrent generation reads")
        #expect(readerAnomalies.withLockUnchecked { $0 } == 0,
                "T6: reader observed out-of-range counts")
    }

    // MARK: Iterator generation-hop resume (§1.4)

    @Test func iterator_resumesByAnchorAcrossForceRetire() throws {
        let lattice = try testLattice(Soak5Item.self)
        try seed(lattice, count: 500)

        let results = lattice.objects(Soak5Item.self)   // keyset walk, ORDER BY id
        let iterator = results.makeIterator()
        var ranks: [Int] = []
        for _ in 0..<150 {
            guard let element = iterator.next() else { break }
            ranks.append(element.rank)
        }
        #expect(ranks.count == 150)

        // Force-retire EVERY generation mid-walk (§3.4 protocol — the same
        // path lifecycle backgrounding takes). The iterator's retained
        // generation dies with it.
        lattice.retireAllGenerations()
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0)

        // The walk transparently re-pins and resumes BY KEYSET ANCHOR:
        // every remaining row is delivered exactly once, in order.
        while let element = iterator.next() {
            ranks.append(element.rank)
        }
        #expect(ranks.count == 500, "generation hop lost/duplicated rows: walked \(ranks.count) of 500")
        #expect(ranks == Array(0..<500), "generation hop broke the walk's total order")
    }

    // MARK: Maintenance timer disarms when idle (§3.2 bookkeeping)

    @Test func maintenanceTimer_retiresAndDisarms_reArmsOnNextPin() throws {
        var config = Lattice.Configuration(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "timer_\(String.random(length: 12)).sqlite"))
        defer { try? Lattice.delete(for: .init(fileURL: config.fileURL)) }
        config.resultsTuning.generationTTLSeconds = 0.1
        let lattice = try Lattice(Soak5Item.self, configuration: config)
        try seed(lattice, count: 10)

        let results = lattice.objects(Soak5Item.self)
        #expect(results.count == 10)
        #expect(lattice.backend.localReadGenerationsOutstanding() >= 1)

        // TTL retire with zero accesses…
        #expect(poll(deadline: 2.0) { lattice.backend.localReadGenerationsOutstanding() == 0 })

        // A warm cache serves WITHOUT re-pinning (§3.2: epoch-keyed caches
        // survive retirement; re-pin happens only when SQL is needed).
        #expect(results.count == 10)
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0)

        // …a write invalidates → the next access re-pins (timer re-arms)
        // and the fresh keeper TTL-retires again.
        let item = Soak5Item()
        item.name = "bump"
        item.payload = ""
        item.rank = 99
        try lattice.add(item)
        #expect(results.count == 11)
        #expect(lattice.backend.localReadGenerationsOutstanding() >= 1)
        #expect(poll(deadline: 2.0) { lattice.backend.localReadGenerationsOutstanding() == 0 })
    }
}
