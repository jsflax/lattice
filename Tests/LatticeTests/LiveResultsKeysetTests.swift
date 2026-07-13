import Testing
import Foundation
@testable import Lattice

// MARK: - Item A Commit 2 — keyset fills + persistent anchors
//
// Spec (docs/design-results-item-A-SPEC.md §7, Commit 2):
//   * keyset property matrix — NULL-first/last × ASC/DESC × collated TEXT ×
//     duplicate keys: walk ≡ `snapshot()` order, no dup, no trap under a
//     concurrent deleter;
//   * deep-scroll budget — a cold jump deep into the collection is exactly
//     ONE OFFSET statement, then paging is keyset (threadSQLStatementCount +
//     the shape's fill-mechanism counters);
//   * anchor survival — anchors survive epoch bumps AND page-LRU eviction
//     (content-anchored burst refill, §2.4);
//   * grouped/distinct OFFSET carve-out;
// plus the class-of-bug pin: the OFFSET-resuming old `Cursor` SKIPPED rows
// under concurrent deletes — reproduced in-test against the same data the
// keyset walk handles correctly.

@Model final class KeysetItem {
    var label: String? = nil
    var rank: Int = 0
    var category: String = ""
}

private final class KeysetSendBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@Suite("Live Results Keyset Tests (item A Commit 2)")
class LiveResultsKeysetTests: BaseTest {

    // MARK: Helpers

    /// The effective total order the walk must produce, computed
    /// independently in Swift: `(label userDir, id ASC)` with SQLite NULL
    /// placement (NULLs first ASC, last DESC) and BINARY (UTF-8 byte)
    /// comparison for TEXT.
    private func expectedOrder(_ rows: [(label: String?, id: Int64)], ascending: Bool)
        -> [(label: String?, id: Int64)] {
        func textLess(_ a: String, _ b: String) -> Bool {
            // BINARY collation = bytewise UTF-8 comparison.
            let ab = Array(a.utf8), bb = Array(b.utf8)
            for i in 0..<min(ab.count, bb.count) where ab[i] != bb[i] {
                return ab[i] < bb[i]
            }
            return ab.count < bb.count
        }
        return rows.sorted { l, r in
            switch (l.label, r.label) {
            case (nil, nil): return l.id < r.id
            case (nil, _): return ascending      // NULLs first ASC, last DESC
            case (_, nil): return !ascending
            case (let a?, let b?):
                if a == b { return l.id < r.id } // id ASC tiebreaker, both dirs
                return ascending ? textLess(a, b) : textLess(b, a)
            }
        }
    }

    private func seedMatrixRows(_ lattice: Lattice, copies: Int = 12) throws {
        // Duplicate keys (several rows per label), NULLs, and mixed case —
        // "ALPHA" < "alpha" under BINARY; a collation mismatch between the
        // anchor comparison and ORDER BY would misorder exactly these.
        let labels: [String?] = [nil, "alpha", "ALPHA", "beta", "Beta", "beta", nil, "gamma", "alpha", nil]
        try lattice.transaction {
            for copy in 0..<copies {
                for (i, label) in labels.enumerated() {
                    let item = KeysetItem()
                    item.label = label
                    item.rank = copy * labels.count + i
                    item.category = "c\(i % 3)"
                    try lattice.add(item)
                }
            }
        }
    }

    // MARK: Keyset property matrix — walk ≡ snapshot(), no dup, no trap

    @Test(arguments: [SortOrder.forward, SortOrder.reverse])
    func matrix_nullableCollatedText_walkEqualsSnapshotOrder(order: SortOrder) throws {
        let lattice = try testLattice(KeysetItem.self)
        try seedMatrixRows(lattice)

        let results = lattice.objects(KeysetItem.self).sortedBy(\.label, order: order)
        let snapshot = results.snapshot().map { (label: $0.label, id: $0.primaryKey!) }
        var walked: [(label: String?, id: Int64)] = []
        for item in results {                       // KeysetCursor batches of pageSize
            walked.append((item.label, item.primaryKey!))
        }

        // Walk ≡ snapshot() order (same effective ORDER BY, same collation).
        #expect(walked.count == snapshot.count)
        #expect(walked.map(\.id) == snapshot.map(\.id),
                "keyset walk order diverged from snapshot() order (\(order))")
        // No key visited twice.
        #expect(Set(walked.map(\.id)).count == walked.count)
        // And both equal the independently computed total order:
        // (label dir, id ASC), NULLs first ASC / last DESC, BINARY text.
        let expected = expectedOrder(walked, ascending: order == .forward)
        #expect(walked.map(\.id) == expected.map(\.id),
                "walk violates the effective total order (label \(order), id ASC)")
    }

    @Test(arguments: [SortOrder.forward, SortOrder.reverse])
    func matrix_duplicateIntKeys_walkEqualsSnapshotOrder(order: SortOrder) throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<400 {
                let item = KeysetItem()
                item.rank = i % 7        // heavy duplicate keys
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self).sortedBy(\.rank, order: order)
        let snapshotIds = results.snapshot().map { $0.primaryKey! }
        var walked: [(rank: Int, id: Int64)] = []
        for item in results { walked.append((item.rank, item.primaryKey!)) }

        #expect(walked.map(\.id) == snapshotIds)
        #expect(Set(walked.map(\.id)).count == walked.count)
        // Duplicate-key runs are ordered by the id ASC tiebreaker in BOTH
        // directions (the effective order is (rank dir, id ASC)).
        for i in 1..<walked.count where walked[i].rank == walked[i - 1].rank {
            #expect(walked[i].id > walked[i - 1].id,
                    "id tiebreaker violated inside a duplicate-key run")
        }
    }

    /// Collated TEXT cell: `globalId` is the schema's `COLLATE NOCASE`
    /// column. The resume predicate keeps the column on the LEFT of every
    /// comparison, so the column's declared collation governs both the walk
    /// order and the anchor comparison — they must agree.
    @Test(arguments: [SortOrder.forward, SortOrder.reverse])
    func matrix_nocaseCollatedColumn_walkEqualsSnapshotOrder(order: SortOrder) throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<350 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self).sortedBy(\.globalId, order: order)
        // The sort resolves to the stored NOCASE TEXT column…
        let spec = try #require(KeysetSortSpec.resolve(for: KeysetItem.self,
                                                       sortColumn: ("globalId", order)))
        #expect(spec.kind == .string)
        // …and the walk (batches of 100) matches the single-statement
        // snapshot exactly, including across every batch boundary.
        let snapshotIds = results.snapshot().map { $0.primaryKey! }
        var walkedIds: [Int64] = []
        for item in results { walkedIds.append(item.primaryKey!) }
        #expect(walkedIds == snapshotIds)
        #expect(Set(walkedIds).count == walkedIds.count)
    }

    // MARK: Matrix — no dup, no trap, order preserved under a concurrent deleter

    @Test(.timeLimit(.minutes(5)), arguments: [SortOrder.forward, SortOrder.reverse])
    func matrix_concurrentDeleter_noDupNoTrapNoMisorder(order: SortOrder) throws {
        let lattice = try testLattice(KeysetItem.self)
        try seedMatrixRows(lattice, copies: 120)   // 1,200 rows

        // The full effective total order BEFORE any deletion. Deletes only
        // remove rows (labels never change), so any correct walk must
        // deliver an ordered subsequence of this sequence.
        let initialOrderedIds = lattice.objects(KeysetItem.self)
            .sortedBy(\.label, order: order).snapshot().map { $0.primaryKey! }

        let box = KeysetSendBox(lattice)
        let done = DispatchSemaphore(value: 0)
        // Deleter: chew through rows in rank order while the walk runs —
        // deletes land behind, at, and ahead of the cursor.
        Thread.detachNewThread {
            let lattice = box.value
            for i in 0..<1200 where i % 2 == 0 {
                lattice.delete(KeysetItem.self, where: { $0.rank == i })
            }
            done.signal()
        }

        let results = lattice.objects(KeysetItem.self).sortedBy(\.label, order: order)
        var walkedIds: [Int64] = []
        for item in results {
            // materialize() pins the hydrated row image, so the id read is
            // served from the handle even if the deleter got this row after
            // the fill — live reads of a deleted row would fabricate values.
            item.materialize()
            walkedIds.append(item.primaryKey!)
        }
        #expect(done.wait(timeout: .now() + 120) == .success)

        // No row delivered twice (the OFFSET cursor's failure class is
        // skip/shift; a keyset walk must never duplicate or misorder).
        #expect(Set(walkedIds).count == walkedIds.count, "duplicate delivery (\(order))")
        // Deliveries respect the effective total order: the walk is an
        // ordered subsequence of the pre-deletion total order — never a step
        // backwards, never a fabricated row (which is what a stale-anchor or
        // collation mismatch would produce).
        #expect(isOrderedSubsequence(walkedIds, of: initialOrderedIds),
                "walk misordered or fabricated rows under concurrent deletes (\(order))")
    }

    private func isOrderedSubsequence(_ sub: [Int64], of full: [Int64]) -> Bool {
        var iterator = full.makeIterator()
        outer: for id in sub {
            while let candidate = iterator.next() {
                if candidate == id { continue outer }
            }
            return false
        }
        return true
    }

    // MARK: The old-Cursor class-of-bug pin (targeted mechanics probe)

    /// The pre-Commit-2 `Cursor` resumed by raw OFFSET
    /// (`snapshot(limit:offset:)` with `offset += batch.count`). OFFSET is
    /// positional: rows deleted BEHIND the cursor shift the remainder left,
    /// so the next batch silently skips live rows. This test reproduces the
    /// old mechanics verbatim against the same mutation the keyset walk
    /// handles correctly — it is the matrix test's failure demonstration,
    /// kept as executable documentation (a source revert would fail to
    /// compile the suite, so the probe recreates the exact resume mechanics
    /// in-test instead).
    @Test func offsetResume_skipsUnderDelete_keysetResumeDoesNot() throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<300 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self)   // ORDER BY id ASC

        // ── Old mechanics (verbatim Cursor resume: positional OFFSET) ──
        var offsetWalked: [Int] = []
        var offset: Int64 = 0
        var batch = results.snapshot(limit: 100, offset: offset)   // rows 0-99
        offset += Int64(batch.count)
        offsetWalked.append(contentsOf: batch.map(\.rank))
        // Mid-walk: delete 50 rows BEHIND the cursor (already visited).
        lattice.delete(KeysetItem.self, where: { $0.rank < 50 })
        while !batch.isEmpty {
            batch = results.snapshot(limit: 100, offset: offset)
            offset += Int64(batch.count)
            offsetWalked.append(contentsOf: batch.map(\.rank))
        }
        let offsetMissed = Set(100..<300).subtracting(offsetWalked)
        // The skip: OFFSET 100 over the shifted table lands at rank 150.
        #expect(offsetMissed == Set(100..<150),
                "expected the OFFSET resume to skip exactly the 50 shifted rows; missed \(offsetMissed.count)")

        // ── Keyset walk over the identical scenario ──
        try lattice.transaction {
            lattice.delete(KeysetItem.self)
            for i in 0..<300 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        var keysetWalked: [Int] = []
        var deleted = false
        for item in lattice.objects(KeysetItem.self) {
            keysetWalked.append(item.rank)
            if keysetWalked.count == 100 && !deleted {
                deleted = true
                lattice.delete(KeysetItem.self, where: { $0.rank < 50 })
            }
        }
        // Value-based resume: every surviving row is delivered exactly once.
        #expect(keysetWalked == Array(0..<300),
                "keyset walk must deliver every surviving row exactly once")
    }

    // MARK: Deep-scroll budget — one OFFSET statement per cold jump, then keyset

    /// The spec's deep-scroll budget (§7 Commit 2, §2.4): a cold random jump
    /// deep into the collection pays exactly ONE collection statement — the
    /// scroll session's only OFFSET statement — and every subsequent page is
    /// a keyset fill, ALSO exactly one collection statement. The budget is
    /// depth-invariant by construction (the OFFSET cost lives inside SQLite's
    /// b-tree skip, not in statement count or per-frame work).
    ///
    /// `threadSQLStatementCount` counts EVERY statement on the thread, and a
    /// fill also pays a fixed non-collection overhead on the Commit-2 live
    /// staging: hydrating each Model issues per-row registration statements
    /// (measured empirically below — probed at 2/row), and the end-of-page
    /// anchor extraction refreshes ONE row snapshot (1 statement). The test
    /// calibrates that overhead on rows the fills never touch, then asserts
    /// EXACT totals: any regression to per-row OFFSET reads, per-page extra
    /// statements, or O(depth) statement growth breaks the equality.
    @Test func deepScroll_jumpPaysOneOffsetStatement_thenKeyset() throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<3000 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self)   // pageSize 100 → 30 pages
        let shape = results._shapeState
        #expect(results.count == 3000)
        #expect(shape.fillCounts == (0, 0))

        // Calibrate the fixed per-fill hydration overhead on page-0 rows
        // (the scroll below only touches pages 25-27): 1 raw collection
        // statement, then a per-row hydration cost.
        var before = Lattice.threadSQLStatementCount
        let rawRows = lattice.backend.objects(table: KeysetItem.entityName, where: nil,
                                              orderBy: "id ASC", limit: 100, offset: nil,
                                              groupBy: nil, distinctBy: nil)
        #expect(Lattice.threadSQLStatementCount - before == 1,
                "a raw 100-row page query must be exactly ONE statement")
        before = Lattice.threadSQLStatementCount
        _ = rawRows.map { KeysetItem(dynamicObject: $0) }
        let hydrationStatements = Lattice.threadSQLStatementCount - before
        // One full-page fill = 1 collection statement + hydration + 1
        // anchor-snapshot refresh.
        let fillBudget: UInt64 = 1 + hydrationStatements + 1

        // Cold random jump deep into the collection: exactly ONE collection
        // statement (the session's only OFFSET statement) + fixed overhead.
        before = Lattice.threadSQLStatementCount
        let jumped = results[2_500]
        let jumpStatements = Lattice.threadSQLStatementCount - before
        #expect(jumpStatements == fillBudget,
                "cold jump must be exactly 1 OFFSET collection statement + fixed fill overhead (\(fillBudget)), was \(jumpStatements)")
        #expect(shape.fillCounts == (1, 0),
                "the jump is the session's one and only OFFSET fill: \(shape.fillCounts)")
        #expect(jumped.rank == 2_500)

        // Scrolling on from the jump: pure keyset fills — each the SAME
        // exact budget as the jump (no O(depth) statement growth), ZERO
        // further OFFSET fills, anchored off the jump page.
        before = Lattice.threadSQLStatementCount
        let e2600 = results[2_600]
        let e2700 = results[2_700]
        let scrollStatements = Lattice.threadSQLStatementCount - before
        #expect(scrollStatements == 2 * fillBudget,
                "2 keyset page fills must cost exactly 2 fill budgets (\(2 * fillBudget)), were \(scrollStatements)")
        #expect(shape.fillCounts == (1, 2),
                "scroll after the jump must be keyset, not OFFSET: \(shape.fillCounts)")
        #expect(e2600.rank == 2_600)
        #expect(e2700.rank == 2_700)

        // Idle re-access of a filled page: ZERO statements (§5 idle budget —
        // the epoch-cached count and the page cache serve without SQL).
        before = Lattice.threadSQLStatementCount
        _ = results.count
        _ = results[2_500]
        _ = results[2_600]
        #expect(Lattice.threadSQLStatementCount - before == 0,
                "warm count + warm-page subscripts must issue ZERO statements")
    }

    // MARK: Anchor survival — epoch bumps and page-LRU eviction (§2.4)

    @Test func anchors_surviveEpochBumps_refillIsKeysetAndContentAnchored() throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<3000 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self)
        let shape = results._shapeState
        #expect(results.count == 3000)
        #expect(results[2_500].rank == 2_500)     // cold jump: the 1 OFFSET fill
        #expect(results[2_600].rank == 2_600)     // keyset from the jump anchor
        #expect(shape.fillCounts == (1, 1))

        // Epoch bump: a write drops count/pages — but NOT anchors.
        let anchorsBefore = shape.anchorCount
        let writeItem = KeysetItem()
        writeItem.rank = 100_000
        try lattice.add(writeItem)
        #expect(shape.anchorCount == anchorsBefore, "anchors must survive the epoch bump")

        // The visible-page refill after the bump rides the retained anchor:
        // keyset, not OFFSET — the O(offset)-per-frame regime is gone.
        #expect(results.count == 3001)            // re-count (cache was dropped)
        #expect(results[2_600].rank == 2_600)
        #expect(shape.fillCounts.offset == 1,
                "refill after epoch bump paid a new OFFSET statement: \(shape.fillCounts)")
        #expect(shape.fillCounts.keyset >= 2)

        // Content-anchored refill (§2.4): delete a row ABOVE the window —
        // every index below shifts by one, but the anchored refill starts at
        // the same CONTENT position (rank 2600 at the page head), not the
        // shifted rank-index. Trap-freedom and the ladder are unaffected.
        lattice.delete(KeysetItem.self, where: { $0.rank == 100 })
        #expect(results.count == 3000)
        #expect(results[2_600].rank == 2_600,
                "refill must be content-anchored (same first row), not index-exact")
        #expect(shape.fillCounts.offset == 1)
    }

    @Test func anchors_survivePageLRUEviction() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "keyset_lru_\(String.random(length: 12)).sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.maxCachedPages = 2   // aggressive eviction
        let lattice = try Lattice(KeysetItem.self, configuration: config)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        try lattice.transaction {
            for i in 0..<800 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self)
        let shape = results._shapeState
        #expect(results.count == 800)

        // Sequential scroll through pages 0…7: page 0 seeds the walk (no
        // OFFSET — keyset from the start), each later page resumes from the
        // previous page's anchor. Only 2 pages stay cached; ALL anchors stay.
        for page in 0..<8 {
            #expect(results[page * 100].rank == page * 100)
        }
        #expect(shape.fillCounts.offset == 0, "sequential scroll must never pay OFFSET")
        #expect(shape.anchorCount >= 7)

        // Revisit an evicted page: its cache is gone (page 3 was LRU-evicted
        // long ago) but its neighborhood anchor survived — the refill is
        // keyset, not an O(offset) restart.
        #expect(results[300].rank == 300)
        #expect(shape.fillCounts.offset == 0,
                "evicted-page refill paid OFFSET despite a surviving anchor")
    }

    /// The keyset walk (`for x in results`) warms the same persistent anchor
    /// map page fills use (§2.4): after one full iteration, a deep subscript
    /// lands keyset off the walk's recorded boundaries — zero OFFSET.
    @Test func iteratorWalk_warmsTheAnchorMap() throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<500 {
                let item = KeysetItem()
                item.rank = i
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self)
        let shape = results._shapeState
        var walked = 0
        for _ in results { walked += 1 }
        #expect(walked == 500)
        // 500 rows / pageSize 100 = 5 FULL batches, each ending exactly at a
        // page boundary — all 5 end-of-page anchors recorded (the walk only
        // learns it is exhausted from the empty 6th fill).
        #expect(shape.anchorCount == 5, "full walk over 5 full pages records 5 end-of-page anchors")

        #expect(results.count == 500)
        #expect(results[420].rank == 420)   // page 4: anchored by the walk
        #expect(shape.fillCounts.offset == 0)
        #expect(shape.fillCounts.keyset == 1)
    }

    // MARK: Grouped/distinct OFFSET carve-out (§2.4/§4.5)

    @Test func groupedAndDistinctShapes_pageByOffset_neverKeyset() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "keyset_group_\(String.random(length: 12)).sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.pageSize = 10
        let lattice = try Lattice(KeysetItem.self, configuration: config)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        try lattice.transaction {
            for i in 0..<120 {
                let item = KeysetItem()
                item.rank = i
                item.category = "cat\(i % 40)"     // 40 groups, 3 rows each
                try lattice.add(item)
            }
        }

        let grouped = lattice.objects(KeysetItem.self).group(by: \.category)
        let groupedShape = grouped._shapeState
        let count = grouped.count
        #expect(count == 40)
        _ = grouped[0]     // page 0
        _ = grouped[15]    // page 1 — MUST be an OFFSET fill (no sound anchor)
        #expect(groupedShape.fillCounts.keyset == 0,
                "grouped shapes have no sound keyset anchor (§2.4 carve-out)")
        #expect(groupedShape.fillCounts.offset >= 1)
        #expect(groupedShape.anchorCount == 0)

        // Iteration falls back to the OFFSET-batched walk and still matches
        // the (deterministically ordered) snapshot.
        var walkedGroups: [String] = []
        for item in grouped { walkedGroups.append(item.category) }
        #expect(walkedGroups == grouped.snapshot().map(\.category))
        #expect(Set(walkedGroups).count == walkedGroups.count)

        let distinct = lattice.objects(KeysetItem.self).distinct(by: \.category)
        let distinctShape = distinct._shapeState
        #expect(distinct.count == 40)
        _ = distinct[15]
        #expect(distinctShape.fillCounts.keyset == 0)
        #expect(distinctShape.anchorCount == 0)
    }

    // MARK: Deterministic order — unsorted queries walk `ORDER BY id ASC` (§2.4)

    @Test func unsortedQueries_getDeterministicIdOrder() throws {
        let lattice = try testLattice(KeysetItem.self)
        try lattice.transaction {
            for i in 0..<250 {
                let item = KeysetItem()
                item.rank = 249 - i     // insertion order ≠ rank order
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self)
        let ids = results.snapshot().map { $0.primaryKey! }
        #expect(ids == ids.sorted(), "unsorted snapshot must be ORDER BY id ASC")
        var walkedIds: [Int64] = []
        for item in results { walkedIds.append(item.primaryKey!) }
        #expect(walkedIds == ids, "unsorted walk must equal snapshot (id order)")
        // Subscripts observe the same order.
        #expect(results[0].primaryKey == ids.first)
        #expect(results[249].primaryKey == ids.last)
    }

    /// Sorted queries gain the `id ASC` tiebreaker (§2.4 / MIGRATION):
    /// duplicate sort keys page deterministically — two adjacent page fills
    /// can never overlap or gap on a duplicate run.
    @Test func duplicateKeys_pageFillsNeitherDupNorSkipAcrossBoundaries() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "keyset_dups_\(String.random(length: 12)).sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.pageSize = 25
        let lattice = try Lattice(KeysetItem.self, configuration: config)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        try lattice.transaction {
            for i in 0..<300 {
                let item = KeysetItem()
                item.rank = i / 100      // three huge duplicate runs: 0,1,2
                try lattice.add(item)
            }
        }
        let results = lattice.objects(KeysetItem.self).sortedBy(\.rank)
        #expect(results.count == 300)
        // Page through every element by subscript — boundary after boundary
        // lands inside a duplicate run.
        var seen: [Int64] = []
        for i in 0..<300 { seen.append(results[i].primaryKey!) }
        #expect(Set(seen).count == 300, "duplicate-key page boundaries duplicated a row")
        #expect(seen == results.snapshot().map { $0.primaryKey! })
    }
}
