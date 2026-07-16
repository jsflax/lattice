import Testing
import Foundation
@testable import Lattice

// MARK: - Item A Commit 5 (part 1) — keeper generations wired end-to-end
//
// T2b  cross-handle read-your-writes: a write arriving through ANOTHER core
//      instance over the same store must bump this handle's epoch on the
//      writer's thread, BEFORE the write call returns — the synchronous
//      core invalidation hook (§2.3), NOT the Swift write-path bump (the
//      writes below go through `backend.add` directly, bypassing Layer 1)
//      and NOT the scheduler-dispatched table-observer trampoline.
//      MainActor-parameterized per the spec (§7).
// T3   within-generation MVCC exactness: count at generation N, delete via
//      a cross-thread writer, a COLD page fill in the same render batch
//      still serves generation N's rows (keeper snapshot) until re-pin.
// T8   render-batch frame coherence: a background insert-at-head mid-batch
//      must not displace visible row contents relative to the IDs diffed at
//      batch start within one frame (§1.3 batch pin + §8.6).
// Plus: memory-family materialized-id generations (§4.1), keeper pinning
// bookkeeping, close/delete-while-generations-live (§4.6).

@Model final class Gen5Item {
    var name: String
    var rank: Int
}

private final class SendBox5<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@Suite("Live Results Generation Read Tests (item A Commit 5)")
class LiveResultsGenerationReadTests: BaseTest {

    /// Two DISTINCT core instances over one store (different config
    /// fingerprints — the instance cache keys on path + sync tuning + IPC
    /// targets, so a sync-tuning delta forces a second instance). The second
    /// handle is how sync applies chunks and how TSR-resolved handles write
    /// (§2.3 cross-instance fan-out).
    private func twoHandles(_ url: URL) throws -> (a: Lattice, b: Lattice) {
        let configA = Lattice.Configuration(fileURL: url)
        var configB = Lattice.Configuration(fileURL: url)
        configB.syncTuning = .init(chunkSize: 999)
        let a = try Lattice(Gen5Item.self, configuration: configA)
        let b = try Lattice(Gen5Item.self, configuration: configB)
        try #require(a.backend.identityHash != b.backend.identityHash,
                     "test premise: two distinct core instances over one store")
        return (a, b)
    }

    /// End the main-thread render batch: run the main runloop until it goes
    /// idle once, so the coordinator's `.beforeWaiting` observer clears the
    /// batch pin (§1.3). A timer keeps the loop populated — an EMPTY runloop
    /// returns from `run(until:)` immediately without ever reaching the
    /// waiting state.
    @MainActor private func endRenderBatch() {
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func seed(_ lattice: Lattice, count: Int) throws {
        try lattice.add(contentsOf: (0..<count).map { i -> Gen5Item in
            let item = Gen5Item()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })
    }

    // MARK: T2b — cross-handle read-your-writes (MainActor-created handles)

    @Test @MainActor func t2b_crossHandleReadYourWrites_mainActor() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t2b_main_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let (a, b) = try twoHandles(url)

        let all = a.objects(Gen5Item.self)
        let ranked = a.objects(Gen5Item.self).where { $0.rank > 30 }
        // Prime the shared shape caches (and take the main-thread batch pin)
        // BEFORE writing — a stale cache is exactly what a scheduler-hopped
        // delivery would serve.
        #expect(all.count == 0)
        #expect(ranked.count == 0)

        // Write through handle B's BACKEND directly: this bypasses the
        // Swift Layer-1 bump entirely — only the §2.3 core hook (inline on
        // this thread, fanned per path across instances) can tell handle A.
        let item = Gen5Item()
        item.name = "cross"
        item.rank = 40
        try b.backend.add(item._dynamicObject._ref)

        // Same thread, NO await, NO runloop turn: the hook bump is
        // same-thread, so the batch pin cleared and the next access re-pins
        // a snapshot that post-dates the commit (§1.3).
        #expect(all.count == 1)
        #expect(all[0].name == "cross")
        #expect(ranked.count == 1)

        // Cross-handle delete, same contract.
        _ = b.backend.deleteWhere(table: Gen5Item.entityName, where: "rank = 40")
        #expect(all.count == 0)
        #expect(ranked.count == 0)
    }

    // MARK: T2b — cross-handle read-your-writes (nonisolated handles)

    @Test func t2b_crossHandleReadYourWrites_nonisolated() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t2b_noniso_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let (a, b) = try twoHandles(url)

        let all = a.objects(Gen5Item.self)
        #expect(all.count == 0)

        let item = Gen5Item()
        item.name = "cross"
        item.rank = 1
        try b.backend.add(item._dynamicObject._ref)

        // Off the main thread every access is its own batch — the hook bump
        // is visible immediately with no batch boundary needed.
        #expect(all.count == 1)
        #expect(all[0].name == "cross")

        _ = b.backend.deleteWhere(table: Gen5Item.entityName, where: nil)
        #expect(all.count == 0)
    }

    // MARK: T2b — cross-thread write lands at the NEXT batch boundary

    @Test @MainActor func t2b_crossThreadWrite_visibleAtNextBatchBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t2b_thread_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let (a, b) = try twoHandles(url)

        let all = a.objects(Gen5Item.self)
        #expect(all.count == 0)   // pins this main-thread batch

        // Cross-THREAD write through handle B while the batch pin is held.
        let box = SendBox5(b)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let item = Gen5Item()
            item.name = "background"
            item.rank = 7
            try? box.value.backend.add(item._dynamicObject._ref)
            done.signal()
        }
        done.wait()   // blocks the main thread WITHOUT running the runloop

        // Same batch: the pin holds — the frame stays single-generation
        // (§1.3; a cross-thread bump takes effect at the next boundary).
        #expect(all.count == 0)

        // Next batch reflects the cross-handle commit.
        endRenderBatch()
        #expect(all.count == 1)
        #expect(all[0].name == "background")
    }

    // MARK: T3 — within-generation MVCC exactness (§1.2 rung 1)

    @Test @MainActor func t3_withinGenerationMVCCExactness() throws {
        let lattice = try testLattice(Gen5Item.self)
        try seed(lattice, count: 250)

        let results = lattice.objects(Gen5Item.self)
        // Pin the batch at generation N (also mints the keeper).
        #expect(results.count == 250)
        #expect(lattice.backend.localReadGenerationsOutstanding() >= 1,
                "file DB access must hold a keeper generation")

        // Cross-thread delete of rows 100…249 while the batch pin is held.
        let box = SendBox5(lattice)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = box.value.delete(Gen5Item.self, where: { $0.rank >= 100 })
            done.signal()
        }
        done.wait()

        // Same render batch: count still answers from generation N, and a
        // COLD page fill (page 2 was never filled) still serves generation
        // N's MEMBERSHIP — 50 real hydrated rows, not head state. Under
        // Commit-2 live fills this read comes back short and `element(at:)`
        // returns nil. (Row VALUES stay on the live object path by design —
        // §1.3 — so a deleted row's property reads return column defaults;
        // membership, not values, is what the snapshot pins. A real
        // hydrated row carries its primaryKey; ladder rung (d) placeholders
        // do not.)
        #expect(results.count == 250)
        let row249 = results.element(at: 249)
        #expect(row249 != nil, "cold fill in a pinned batch must serve generation N's rows")
        #expect(row249?.primaryKey != nil,
                "generation-N fill must hydrate a real row, not a placeholder")

        // Batch boundary → re-pin: the next batch reflects the deletion.
        endRenderBatch()
        #expect(results.count == 100)
        #expect(results.element(at: 249) == nil)
    }

    // MARK: T8 — render-batch frame coherence (§1.3 pin, §8.6)

    @Test @MainActor func t8_renderBatchFrameCoherence_insertAtHeadMidBatch() throws {
        let lattice = try testLattice(Gen5Item.self)
        try seed(lattice, count: 300)

        let results = lattice.objects(Gen5Item.self).sortedBy(\.rank, order: .forward)
        // "Render pass" begins: identity is diffed at count 300. NO rows
        // have been realized yet — SwiftUI's lazy List fills rows later in
        // the same body evaluation.
        #expect(results.count == 300)

        // A background writer inserts AT THE HEAD mid-body (rank -1 sorts
        // first). Its epoch bump arrives from another thread mid-batch.
        let box = SendBox5(lattice)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let head = Gen5Item()
            head.name = "head"
            head.rank = -1
            try? box.value.add(head)
            done.signal()
        }
        done.wait()

        // Same render batch: rows realized AFTER the commit must agree with
        // the identity diffed at batch start — COLD fills serve the pinned
        // snapshot. A head-state fill would hydrate rank -1 at index 0
        // (visible row displaced within one frame — the §8.6 tear).
        #expect(results.count == 300)
        let row0 = results.element(at: 0)
        #expect(row0?.rank == 0,
                "cold fill mid-batch displaced row 0: got rank \(String(describing: row0?.rank)), expected 0 — the batch pin failed")
        let row250 = results.element(at: 250)
        #expect(row250?.rank == 250,
                "cold fill mid-batch displaced deep rows: got rank \(String(describing: row250?.rank)), expected 250")

        // Next batch: the head insert is visible at index 0.
        endRenderBatch()
        #expect(results.count == 301)
        #expect(results.element(at: 0)?.rank == -1)
    }

    // MARK: Memory family — materialized-id generations (§4.1)

    @Test func memoryFamily_materializedIDGenerations_serveCountAndPages() throws {
        let lattice = try Lattice(Gen5Item.self, configuration: .init(storage: .memory()))
        try seed(lattice, count: 250)

        let results = lattice.objects(Gen5Item.self)
        #expect(results.count == 250)
        // §4.1: NO keepers on the memory family — the generation is the id
        // vector, not a held read transaction.
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0,
                "memory-family stores must never hold keeper read transactions")

        // Subscript hydrates by primary key in captured order.
        #expect(results[0].rank == 0)
        #expect(results[249].rank == 249)
        #expect(results.element(at: 250) == nil)

        // Idle ticks are pure cache hits (ids + pages cached per epoch).
        _ = results[10]
        let before = Lattice.threadSQLStatementCount
        for _ in 0..<10 {
            #expect(results.count == 250)
            _ = results[0]
            _ = results[10]
        }
        #expect(Lattice.threadSQLStatementCount == before,
                "idle memory-family accesses must serve from the materialized-id generation")

        // Same-thread read-your-writes: delete → recapture immediately.
        _ = lattice.delete(Gen5Item.self, where: { $0.rank >= 200 })
        #expect(results.count == 200)
        #expect(results.element(at: 199)?.rank == 199)
        // A stale index past the new end serves the tolerant ladder (rung
        // (b): the retained previous generation's page) — never a trap.
        _ = results[200]
    }

    @Test func memoryFamily_sortedShape_capturesInEffectiveOrder() throws {
        let lattice = try Lattice(Gen5Item.self, configuration: .init(storage: .memory()))
        try seed(lattice, count: 50)

        let descending = lattice.objects(Gen5Item.self).sortedBy(\.rank, order: .reverse)
        #expect(descending.count == 50)
        #expect(descending[0].rank == 49)
        #expect(descending[49].rank == 0)
        // Order must equal the row query's order (id-vector capture uses the
        // same builder + effective ORDER BY).
        let walked = descending.map(\.rank)
        #expect(walked == Array((0..<50).reversed()))
    }

    // MARK: Keeper bookkeeping — generations retire on supersession

    @Test func fileDB_supersededGenerationsRetire() throws {
        let lattice = try testLattice(Gen5Item.self)
        try seed(lattice, count: 50)

        let results = lattice.objects(Gen5Item.self)
        for i in 0..<10 {
            #expect(results.count == 50 + i)
            let item = Gen5Item()
            item.name = "w_\(i)"
            item.rank = 1000 + i
            try lattice.add(item)
        }
        #expect(results.count == 60)
        // Superseded keepers must not accumulate: the pool never exceeds
        // its capacity (3), and steady state after the writes settles to
        // the one current generation (pending releases drain on resolve).
        let outstanding = lattice.backend.localReadGenerationsOutstanding()
        #expect(outstanding >= 1 && outstanding <= 3,
                "keeper pool leaked: \(outstanding) generations outstanding")
    }

    // MARK: snapshot() at the current generation (§7 Commit 5)

    @Test @MainActor func snapshot_onLiveFacade_executesAtPinnedGeneration() throws {
        let lattice = try testLattice(Gen5Item.self)
        try seed(lattice, count: 120)

        let results = lattice.objects(Gen5Item.self)
        #expect(results.count == 120)   // pins generation N on this batch

        // Cross-thread deletion mid-batch.
        let box = SendBox5(lattice)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = box.value.delete(Gen5Item.self, where: { $0.rank >= 20 })
            done.signal()
        }
        done.wait()

        // snapshot() on the live facade executes at the pinned generation —
        // the same MVCC snapshot count/subscript serve this batch.
        let copy = results.snapshot()
        #expect(copy.count == 120,
                "snapshot() served head state (\(copy.count) rows) instead of the pinned generation")

        endRenderBatch()
        #expect(results.snapshot().count == 20)
    }

    // MARK: Close / delete while generations live (§4.6)

    @Test func closeWhileGenerationsLive_readsServeEmptyNeverTrap() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "close_live_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let lattice = try Lattice(Gen5Item.self, configuration: .init(fileURL: url))
        try seed(lattice, count: 50)

        let results = lattice.objects(Gen5Item.self)
        #expect(results.count == 50)
        _ = results[0]   // live generation + warm pages

        lattice.close()

        // Post-close: generation acquisition refuses (0), core reads
        // short-circuit to empty — the ladder serves; the process lives.
        #expect(results.count == 0)
        #expect(results.element(at: 0) == nil)
        let ghost = results[0]   // rung (c)/(d): lifeboat or placeholder — not a trap
        _ = ghost
        var walked = 0
        for _ in results { walked += 1 }
        #expect(walked == 0)
    }

    @Test func deleteWhileGenerationsLive_readsServeEmptyNeverTrap() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "delete_live_\(String.random(length: 12)).sqlite")
        let config = Lattice.Configuration(fileURL: url)
        let lattice = try Lattice(Gen5Item.self, configuration: config)
        try seed(lattice, count: 25)

        let results = lattice.objects(Gen5Item.self)
        #expect(results.count == 25)
        _ = results[10]

        try Lattice.delete(for: config)   // closes cached backends, unlinks files

        #expect(results.count == 0)
        #expect(results.element(at: 3) == nil)
        _ = results[3]   // never a trap
    }
}

// Fix-wave regression pins (adversarial verification findings).
extension LiveResultsGenerationReadTests {
    /// CRITICAL (live-reproduced pre-fix): reading a live memory-family
    /// Results inside an explicit transaction on the same thread must NOT
    /// self-deadlock on the write-gated id capture — it completes in
    /// milliseconds and satisfies read-your-writes via the live in-txn path.
    @Test(.timeLimit(.minutes(1))) func memoryResults_readInsideOwnTransaction_noDeadlock() throws {
        let lattice = try Lattice(Gen5Item.self, configuration: .init(storage: .memory()))
        try lattice.add({ let it = Gen5Item(); it.name = "pre"; return it }())

        let start = Date()
        try lattice.transaction {
            try lattice.add({ let it = Gen5Item(); it.name = "in-txn"; return it }())
            let results = lattice.objects(Gen5Item.self)
            #expect(results.count == 2, "read-your-writes inside own txn")
            #expect(results.map { $0.name }.contains("in-txn"))
        }
        #expect(Date().timeIntervalSince(start) < 5,
                "in-txn read must not block on the 30s busy timeout")
        #expect(lattice.objects(Gen5Item.self).count == 2)
    }

    /// The §3.6 latch: after retireAllGenerations(), accesses must not
    /// re-pin keepers until resumeGenerations().
    @Test func retireAll_isALatch_untilResume() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "latch_\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: path)) }
        let lattice = try Lattice(Gen5Item.self, configuration: .init(fileURL: path))
        try lattice.add({ let it = Gen5Item(); it.name = "a"; return it }())
        _ = lattice.objects(Gen5Item.self).count  // pins

        lattice.retireAllGenerations()
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0)
        _ = lattice.objects(Gen5Item.self).count  // latched: unpinned tolerant read
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0,
                "access under the latch must not re-pin")

        lattice.resumeGenerations()
        // A cached count won't mint (correct); force a fresh resolve with a
        // write (epoch bump) before asserting re-pin works again.
        let b = Gen5Item(); b.name = "b"; try lattice.add(b)
        _ = lattice.objects(Gen5Item.self).count
        #expect(lattice.backend.localReadGenerationsOutstanding() > 0,
                "resume restores lazy re-pinning")
    }

    /// Plan item A3: @LatticeQuery's fetchLimit caps the visible count.
    @Test func fetchLimit_capsFacadeCount() throws {
        let lattice = try Lattice(Gen5Item.self, configuration: .init(storage: .memory()))
        for i in 0..<10 { try lattice.add({ let it = Gen5Item(); it.name = "r\(i)"; return it }()) }
        var results = lattice.objects(Gen5Item.self)
        #expect(results.count == 10)
        results._fetchLimit = 3
        #expect(results.count == 3, "fetchLimit caps endIndex")
        #expect(results.element(at: 2) != nil)
    }
}
