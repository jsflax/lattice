import Testing
import Foundation
@testable import Lattice

// MARK: - Item A Commit 8 — changedFields skip (§2.3 v1.1)
//
// The final slice: the coordinator consumes the Commit-4 with-fields hook
// trampoline; predicate/sort columns are extracted conservatively per query
// shape; UPDATE-only batches whose changed fields are disjoint from
// (predicate ∪ sort ∪ implicit id) skip that shape's cache invalidation —
// the EPOCH STILL BUMPS (read-your-writes and MVCC generations are
// epoch-level; only the shape-cache rebuild is skipped), and the row still
// repaints through the live object path. Default-on flag:
// `ResultsTuning.fieldAwareInvalidation`.
//
// Tests (spec Commit 8):
//   * member-row unrelated-column update ⇒ NO shape rebuild (fill counters
//     frozen), row repaints via the object path, epoch advanced;
//   * predicate/sort-column update ⇒ rebuild within ≤ 1 debounce cycle
//     (asserted synchronously at the immediately-next access — stronger);
//   * long-soak equivalence flag-on vs flag-off (same seeded write script ⇒
//     identical final visible frame), time-compressed, no sleeps;
// plus extractor unit pins and a with-fields bridge round-trip.

@Model final class CFItem {
    var name: String
    var rank: Int
    var note: String
}

@Suite("Live Results ChangedFields Skip Tests (item A Commit 8)")
class LiveResultsChangedFieldsTests: BaseTest {

    // MARK: Extractor unit pins (conservative column extraction)

    @Test func extractor_plainPredicate() {
        #expect(ShapeColumnExtractor.referencedColumns(in: "rank > 30") == ["rank"])
        #expect(ShapeColumnExtractor.referencedColumns(in: "rank > 30 AND name = 'bob'")
                == ["rank", "name"])
        // Operator keywords and literals are not columns.
        #expect(ShapeColumnExtractor.referencedColumns(
            in: "age BETWEEN 1 AND 5 OR flag IS NOT NULL") == ["age", "flag"])
        // Parameters bind values, not columns (`name` the column is
        // referenced; `:name` the binding is not).
        #expect(ShapeColumnExtractor.referencedColumns(in: "rank > ? AND name = :name")
                == ["rank", "name"])
        #expect(ShapeColumnExtractor.referencedColumns(in: "rank > :minRank")
                == ["rank"])
    }

    @Test func extractor_quotedAndQualifiedIdentifiers() {
        #expect(ShapeColumnExtractor.referencedColumns(in: "\"user name\" = 'x'")
                == ["user name"])
        #expect(ShapeColumnExtractor.referencedColumns(in: "`count` > 3 AND [group] = 1")
                == ["count", "group"])
        // Qualified names contribute both parts (qualifier = extra-name safe).
        #expect(ShapeColumnExtractor.referencedColumns(in: "CFItem.id ASC, name DESC")
                == ["cfitem", "id", "name"])
        // Escaped string literal contents are values.
        #expect(ShapeColumnExtractor.referencedColumns(in: "name = 'O''Brien'")
                == ["name"])
    }

    @Test func extractor_functionsOverColumnsAreReferenced() {
        // Function NAME excluded; its column arguments are referenced.
        #expect(ShapeColumnExtractor.referencedColumns(in: "lower(name) = 'x'")
                == ["name"])
        #expect(ShapeColumnExtractor.referencedColumns(in: "length(note) > 3 AND abs(rank - 2) < 5")
                == ["note", "rank"])
    }

    @Test func extractor_dualUseOperatorKeywordsAreBookedAsColumns() {
        // LIKE/GLOB/… are operators SQLite also permits as identifiers —
        // dual-booked so a genuine column of that name is never missed.
        #expect(ShapeColumnExtractor.referencedColumns(in: "note LIKE 'a%'")
                == ["note", "like"])
    }

    @Test func extractor_conservativeFallbacks() {
        // Subqueries reference data we cannot attribute — must invalidate.
        #expect(ShapeColumnExtractor.referencedColumns(
            in: "id IN (SELECT id FROM Other)") == nil)
        #expect(ShapeColumnExtractor.referencedColumns(
            in: "EXISTS (1)") == nil)
        // Unterminated literal.
        #expect(ShapeColumnExtractor.referencedColumns(in: "name = 'oops") == nil)
        // The bbox shape-key marker (§4.5 carve-out).
        #expect(ShapeColumnExtractor.referencedColumns(
            in: "\u{1F}bbox(location,1.0,2.0,3.0,4.0)") == nil)
        // Foreign syntax.
        #expect(ShapeColumnExtractor.referencedColumns(in: "name = 'x'; DROP TABLE t") == nil)
    }

    @Test func extractor_shapeDependencyIncludesImplicitID() {
        let key = QueryShapeKey(identityHash: 1, table: "CFItem",
                                whereSQL: "rank > 10", orderBySQL: "name ASC, id ASC",
                                groupBy: nil, distinctBy: nil)
        #expect(ShapeColumnExtractor.dependency(of: key)
                == .columns(["id", "rank", "name"]))
        let bbox = QueryShapeKey(identityHash: 1, table: "CFItem",
                                 whereSQL: "rank > 10\u{1F}bbox(loc,1,2,3,4)",
                                 orderBySQL: "CFItem.id ASC",
                                 groupBy: nil, distinctBy: nil)
        #expect(ShapeColumnExtractor.dependency(of: bbox) == .mustInvalidate)
    }

    // MARK: Bridge round-trip — with-fields trampoline delivery

    @Test func withFieldsHook_deliversPerTablePayloadInline() throws {
        let lattice = try testLattice(CFItem.self)
        let item = CFItem()
        item.name = "a"
        item.rank = 20
        item.note = "n"
        try lattice.add(item)

        let received = LockedBox<[(tables: [String], fields: [String], reason: InvalidationReason)]>([])
        let token = lattice.backend.addInvalidationHookWithFields { changes, reason in
            received.withLock {
                $0.append((changes.map(\.table), changes.map(\.changedFields), reason))
            }
        }
        defer { lattice.backend.removeInvalidationHook(token: token) }

        // A local setter write: delivered INLINE (same thread, before the
        // set returns), table named, fields EMPTY in the raw core payload
        // (local writes carry no changedFieldsNames — the coordinator's
        // thread-local annotation supplies them, tested below).
        item.note = "updated"
        let commits = received.withLock { $0 }
        // The batch may carry internal bookkeeping tables (AuditLog)
        // alongside the model table — the coordinator triages per table.
        #expect(commits.contains { $0.tables.contains("CFItem") && $0.reason == .commit },
                "with-fields hook must deliver the changed table inline: \(commits)")
        #expect(commits.allSatisfy { $0.tables.count == $0.fields.count },
                "changed_fields must stay parallel to changed_tables")
        #expect(commits.allSatisfy { commit in
            zip(commit.tables, commit.fields).allSatisfy { $0.0 != "CFItem" || $0.1.isEmpty }
        }, "a local setter write carries no changedFieldsNames in the raw core payload")
    }

    // MARK: Member-row unrelated-column update ⇒ NO shape rebuild

    private func assertUnrelatedColumnUpdateSkips(_ lattice: Lattice,
                                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let results = lattice.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)

        var members: [CFItem] = []
        for (name, rank) in [("alpha", 20), ("bravo", 30), ("carol", 40)] {
            let item = CFItem()
            item.name = name
            item.rank = rank
            item.note = "seed"
            try lattice.add(item)
            members.append(item)
        }
        let outsider = CFItem()
        outsider.name = "zed"
        outsider.rank = 1
        outsider.note = "seed"
        try lattice.add(outsider)

        // Prime the shape cache: count + page 0.
        #expect(results.count == 3, sourceLocation: sourceLocation)
        #expect(results[0].name == "alpha", sourceLocation: sourceLocation)
        let shape = results._shapeState
        let fillsBefore = shape.fillCounts
        let epochBefore = results.generationID
        let coordinator = GenerationCoordinatorRegistry.coordinator(
            for: lattice.backend, tuning: lattice.configuration.resultsTuning)
        let skipsBefore = coordinator.fieldSkipCounter

        // UPDATE of a column disjoint from (rank ∪ name ∪ id).
        members[0].note = "repainted"

        // Same count, same order, NO new fill statements — the shape cache
        // survived the write (§2.3 v1.1 skip).
        #expect(results.count == 3, sourceLocation: sourceLocation)
        #expect(results[0].name == "alpha", sourceLocation: sourceLocation)
        #expect(results[1].name == "bravo", sourceLocation: sourceLocation)
        let fillsAfter = shape.fillCounts
        #expect(fillsAfter.offset == fillsBefore.offset
                && fillsAfter.keyset == fillsBefore.keyset,
                "unrelated-column update must not rebuild the shape: \(fillsBefore) → \(fillsAfter)",
                sourceLocation: sourceLocation)
        #expect(coordinator.fieldSkipCounter > skipsBefore,
                "the skip must actually have engaged (not a vacuous pass)",
                sourceLocation: sourceLocation)

        // The EPOCH STILL BUMPS (§2.3): read-your-writes / keeper retirement
        // are epoch-level; only the shape-cache rebuild was skipped.
        #expect(results.generationID > epochBefore,
                "epoch must advance on every settled commit",
                sourceLocation: sourceLocation)

        // The row repaints through the object path: the SAME hydrated
        // instance the facade serves reads the new value live.
        #expect(results[0].note == "repainted", sourceLocation: sourceLocation)
    }

    @Test func memberRowUnrelatedColumnUpdate_noShapeRebuild_fileDB() throws {
        try assertUnrelatedColumnUpdateSkips(try testLattice(CFItem.self))
    }

    @Test func memberRowUnrelatedColumnUpdate_noShapeRebuild_memoryFamily() throws {
        // §4.1 materialized-id generations: the skip must preserve the id
        // vector too (membership/order provably unchanged).
        let lattice = try Lattice(CFItem.self,
                                  configuration: .init(storage: .memory()))
        try assertUnrelatedColumnUpdateSkips(lattice)
    }

    // MARK: Predicate/sort-column update ⇒ rebuild ≤ 1 debounce cycle

    @Test func predicateColumnUpdate_rebuildsAtNextAccess() throws {
        let lattice = try testLattice(CFItem.self)
        let results = lattice.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)

        var members: [CFItem] = []
        for (name, rank) in [("alpha", 20), ("bravo", 30), ("carol", 40)] {
            let item = CFItem()
            item.name = name
            item.rank = rank
            item.note = "seed"
            try lattice.add(item)
            members.append(item)
        }
        #expect(results.count == 3)
        #expect(results[0].name == "alpha")
        let shape = results._shapeState
        let fillsBefore = shape.fillCounts

        // Predicate-column UPDATE: membership changes. The invalidation is
        // synchronous (§1.3) — the immediately-next access rebuilds, well
        // inside one debounce cycle.
        members[0].rank = 5
        #expect(results.count == 2, "membership change must be visible at the next access")
        #expect(results[0].name == "bravo")
        let fillsAfter = shape.fillCounts
        #expect(fillsAfter.keyset + fillsAfter.offset > fillsBefore.keyset + fillsBefore.offset,
                "the predicate-column update must refill the visible page")
    }

    @Test func sortColumnUpdate_rebuildsAtNextAccess() throws {
        let lattice = try testLattice(CFItem.self)
        let results = lattice.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)

        var members: [CFItem] = []
        for (name, rank) in [("alpha", 20), ("bravo", 30), ("carol", 40)] {
            let item = CFItem()
            item.name = name
            item.rank = rank
            item.note = "seed"
            try lattice.add(item)
            members.append(item)
        }
        #expect(results[0].name == "alpha")

        // Sort-column UPDATE: order changes — visible at the next access.
        members[0].name = "zulu"
        #expect(results[0].name == "bravo")
        #expect(results[2].name == "zulu")
    }

    // MARK: Flag gate — off restores v1 whole-table behavior

    @Test func flagOff_unrelatedColumnUpdateInvalidates() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cf_flagoff_\(String.random(length: 12)).sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.resultsTuning.fieldAwareInvalidation = false
        let lattice = try Lattice(CFItem.self, configuration: config)
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        let results = lattice.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)
        let item = CFItem()
        item.name = "alpha"
        item.rank = 20
        item.note = "seed"
        try lattice.add(item)

        #expect(results.count == 1)
        #expect(results[0].name == "alpha")
        let shape = results._shapeState
        let fillsBefore = shape.fillCounts

        item.note = "changed"
        #expect(results[0].note == "changed")
        let fillsAfter = shape.fillCounts
        #expect(fillsAfter.keyset + fillsAfter.offset > fillsBefore.keyset + fillsBefore.offset,
                "flag off ⇒ v1 whole-table invalidation must rebuild the page")
    }

    // MARK: Core-payload branch — synthetic UPDATE-only fields union

    @Test func syntheticFieldsPayload_skipsDisjointShapes_invalidatesIntersecting() throws {
        // Drives the coordinator's classified entry point directly with a
        // non-empty per-table fields union — the shape sync-applied chunks
        // and upsert-resolved UPDATEs deliver through the with-fields hook
        // (local setter writes exercise the annotation branch instead).
        let lattice = try testLattice(CFItem.self)
        let results = lattice.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)
        let item = CFItem()
        item.name = "alpha"
        item.rank = 20
        item.note = "seed"
        try lattice.add(item)

        #expect(results.count == 1)
        #expect(results[0].name == "alpha")
        let shape = results._shapeState
        let coordinator = GenerationCoordinatorRegistry.coordinator(
            for: lattice.backend, tuning: lattice.configuration.resultsTuning)

        // Disjoint UPDATE-only union ("note") ⇒ skip.
        let fillsBefore = shape.fillCounts
        coordinator.noteWrite(changes: [WriteBatchTableChange(
            table: "CFItem", changedFields: GenerationCoordinator.parseFieldList("note"))])
        #expect(results.count == 1)
        #expect(results[0].name == "alpha")
        let fillsMid = shape.fillCounts
        #expect(fillsMid.keyset + fillsMid.offset == fillsBefore.keyset + fillsBefore.offset,
                "disjoint fields union must not rebuild the shape")

        // Intersecting union ("note,rank") ⇒ invalidate.
        coordinator.noteWrite(changes: [WriteBatchTableChange(
            table: "CFItem", changedFields: GenerationCoordinator.parseFieldList("note,rank"))])
        #expect(results[0].name == "alpha")
        let fillsAfter = shape.fillCounts
        #expect(fillsAfter.keyset + fillsAfter.offset > fillsMid.keyset + fillsMid.offset,
                "an intersecting fields union must rebuild the shape")
    }

    // MARK: Long-soak equivalence — flag on vs flag off

    /// Deterministic seeded generator (identical scripts on both stores).
    private struct SplitMix: Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    }

    @Test(.timeLimit(.minutes(5)))
    func longSoakEquivalence_flagOnVsFlagOff() throws {
        func makeLattice(flag: Bool) throws -> (Lattice, URL) {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "cf_soak_\(flag ? "on" : "off")_\(String.random(length: 12)).sqlite")
            var config = Lattice.Configuration(fileURL: url)
            config.resultsTuning.fieldAwareInvalidation = flag
            return (try Lattice(CFItem.self, configuration: config), url)
        }
        let (on, onURL) = try makeLattice(flag: true)
        let (off, offURL) = try makeLattice(flag: false)
        defer {
            try? Lattice.delete(for: .init(fileURL: onURL))
            try? Lattice.delete(for: .init(fileURL: offURL))
        }

        let onResults = on.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)
        let offResults = off.objects(CFItem.self).where { $0.rank > 10 }.sortedBy(\.name)

        // The SAME seeded write script runs against both stores, with reads
        // interleaved so the caches are exercised mid-script (the soak's
        // point: a wrongly-skipped rebuild would surface as a divergent or
        // stale frame). Time-compressed: no sleeps at all.
        var onItems: [CFItem] = []
        var offItems: [CFItem] = []
        var rng = SplitMix(state: 0xC0FFEE)
        var inserted = 0
        for step in 0..<400 {
            let op = rng.below(10)
            let pick = rng.next()   // consumed even when unused, to keep streams aligned
            switch op {
            case 0...2:
                inserted += 1
                let rank = Int(pick % 40)
                let name = "row_\(String(format: "%04d", inserted))"
                let a = CFItem()
                a.name = name
                a.rank = rank
                a.note = "seed"
                try on.add(a)
                onItems.append(a)
                let b = CFItem()
                b.name = name
                b.rank = rank
                b.note = "seed"
                try off.add(b)
                offItems.append(b)
            case 3:
                guard !onItems.isEmpty else { continue }
                let idx = Int(pick % UInt64(onItems.count))
                on.delete(onItems.remove(at: idx))
                off.delete(offItems.remove(at: idx))
            case 4...6:
                guard !onItems.isEmpty else { continue }
                let idx = Int(pick % UInt64(onItems.count))
                onItems[idx].note = "note_\(step)"
                offItems[idx].note = "note_\(step)"
            case 7...8:
                guard !onItems.isEmpty else { continue }
                let idx = Int(pick % UInt64(onItems.count))
                let rank = Int(pick % 40)
                onItems[idx].rank = rank
                offItems[idx].rank = rank
            default:
                guard !onItems.isEmpty else { continue }
                let idx = Int(pick % UInt64(onItems.count))
                onItems[idx].name = "row_\(String(format: "%04d", step + 5000))"
                offItems[idx].name = "row_\(String(format: "%04d", step + 5000))"
            }
            if step % 7 == 0 {
                // Interleaved reads: identical visible frame mid-script too.
                let countOn = onResults.count
                let countOff = offResults.count
                #expect(countOn == countOff, "mid-script count diverged at step \(step)")
                if countOn > 0, countOn == countOff {
                    for i in [0, countOn / 2, countOn - 1] {
                        #expect(onResults[i].name == offResults[i].name,
                                "mid-script row \(i) diverged at step \(step)")
                    }
                }
            }
        }

        // Final visible frame: identical across flag settings, and equal to
        // the ground truth both ways.
        let countOn = onResults.count
        let countOff = offResults.count
        #expect(countOn == countOff, "final counts diverged")
        let frameOn = (0..<countOn).map { (onResults[$0].name, onResults[$0].rank, onResults[$0].note) }
        let frameOff = (0..<countOff).map { (offResults[$0].name, offResults[$0].rank, offResults[$0].note) }
        #expect(frameOn.count == frameOff.count)
        for (a, b) in zip(frameOn, frameOff) {
            #expect(a == b, "final frame diverged: \(a) vs \(b)")
        }
        let truthOn = onResults.snapshot().map { ($0.name, $0.rank, $0.note) }
        #expect(truthOn.count == frameOn.count, "flag-on frame count ≠ ground truth")
        for (a, b) in zip(frameOn, truthOn) {
            #expect(a == b, "flag-on frame diverged from ground truth: \(a) vs \(b)")
        }
    }
}
