import Testing
import Foundation
@testable import Lattice

// MARK: - Explicit-transaction read-your-writes on FILE stores (§4.1
// carve-out, file-store extension)
//
// Inside `lattice.transaction { … }` on a file-backed store, collection
// reads must see the transaction's OWN uncommitted writes: keeper
// generations are MVCC snapshots on pooled READ connections that cannot see
// the writer connection's open transaction, so every in-txn read routes
// through the writer connection instead (InTransactionReads.swift), with no
// keeper minting and no shape-cache traffic while the transaction is open.
//
// Pinned here:
//  1. in-txn visibility — snapshot / count / element(at:) / iteration /
//     object(primaryKey:) / Lattice.count all see the uncommitted insert;
//  2. rollback — a thrown transaction leaves NO trace of its writes in any
//     read path (and no poisoned epoch caches);
//  3. post-commit read-your-writes stays exact (the epoch bump on commit);
//  4. in-txn deletes and managed-property-setter updates are visible to
//     filtered reads before commit.
//
// The cross-SDK contract twin is the conformance corpus scenario
// `transactions/own-writes-visible-inside`.

@Model final class TxnRywItem {
    var name: String
    var rank: Int
}

private struct TxnRywAbort: Error {}

@Suite("Explicit-transaction read-your-writes (file stores)")
class InTransactionReadYourWritesTests: BaseTest {

    private func makeFileLattice() throws -> (lattice: Lattice, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "txn_ryw_\(String.random(length: 12)).sqlite")
        let lattice = try Lattice(TxnRywItem.self, configuration: .init(fileURL: url))
        return (lattice, url)
    }

    private func add(_ lattice: Lattice, name: String, rank: Int) throws {
        let item = TxnRywItem()
        item.name = name
        item.rank = rank
        try lattice.add(item)
    }

    /// (1) In-txn visibility, plus the no-self-deadlock guard: the whole
    /// block must complete without waiting out the 30 s busy timeout
    /// (keeper minting inside the transaction is the in-txn deadlock
    /// class — the carve-out must never resolve a generation).
    @Test(.timeLimit(.minutes(1)))
    func fileStore_readsInsideOwnTransaction_seeUncommittedWrites() throws {
        let (lattice, url) = try makeFileLattice()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        try add(lattice, name: "pre", rank: 0)

        // Warm the generation machinery + epoch caches BEFORE the
        // transaction so the in-txn branch is proven to bypass them.
        #expect(lattice.objects(TxnRywItem.self).count == 1)
        #expect(lattice.objects(TxnRywItem.self).snapshot().count == 1)

        let start = Date()
        try lattice.transaction {
            try add(lattice, name: "in-txn", rank: 1)

            let results = lattice.objects(TxnRywItem.self)
            #expect(results.count == 2, "objects().count sees the uncommitted insert")
            #expect(results.snapshot().map(\.name) == ["pre", "in-txn"],
                    "snapshot() sees the uncommitted insert, in effective (id) order")
            #expect(results.snapshot(limit: 1, offset: 1).map(\.name) == ["in-txn"],
                    "snapshot pagination runs on the writer connection too")
            #expect(results.element(at: 1)?.name == "in-txn", "indexed access sees it")
            #expect(results.map(\.name) == ["pre", "in-txn"], "iteration sees it")
            #expect(results.first?.name == "pre")

            // Sorted + filtered shapes.
            #expect(lattice.objects(TxnRywItem.self)
                .sortedBy(\.rank, order: .reverse).snapshot().map(\.name) == ["in-txn", "pre"])
            #expect(lattice.objects(TxnRywItem.self).where { $0.rank == 1 }.count == 1)

            // Point reads and the dedicated count API.
            #expect(lattice.count(TxnRywItem.self) == 2)
            #expect(lattice.count(TxnRywItem.self, where: { $0.name == "in-txn" }) == 1)
            #expect(lattice.object(TxnRywItem.self, primaryKey: 2)?.name == "in-txn")
        }
        #expect(Date().timeIntervalSince(start) < 5,
                "in-txn reads must not block on the busy timeout (no keeper minting)")

        // (3) Post-commit read-your-writes stays exact.
        #expect(lattice.count(TxnRywItem.self) == 2)
        #expect(lattice.objects(TxnRywItem.self).count == 2)
        #expect(lattice.objects(TxnRywItem.self).snapshot().map(\.name) == ["pre", "in-txn"])
        #expect(lattice.object(TxnRywItem.self, primaryKey: 2)?.name == "in-txn")
    }

    /// (2) Rollback: a thrown transaction discards its writes — post-rollback
    /// reads see NOTHING of them on any path, including the epoch-cached
    /// facade count (the in-txn branch must not have published the
    /// transaction's state into the shape caches).
    @Test func fileStore_postRollback_readsSeeNothingOfRolledBackWrites() throws {
        let (lattice, url) = try makeFileLattice()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        try add(lattice, name: "pre", rank: 0)
        #expect(lattice.objects(TxnRywItem.self).count == 1)   // warm caches

        #expect(throws: TxnRywAbort.self) {
            try lattice.transaction {
                try add(lattice, name: "ghost", rank: 9)
                #expect(lattice.objects(TxnRywItem.self).count == 2,
                        "the write is visible inside its own transaction")
                throw TxnRywAbort()
            }
        }

        #expect(lattice.count(TxnRywItem.self) == 1)
        #expect(lattice.objects(TxnRywItem.self).count == 1)
        #expect(lattice.objects(TxnRywItem.self).snapshot().map(\.name) == ["pre"])
        #expect(lattice.objects(TxnRywItem.self).where { $0.rank == 9 }.count == 0)
        #expect(lattice.object(TxnRywItem.self, primaryKey: 2) == nil)

        // The store stays fully usable: a later committed write is seen.
        try lattice.transaction { try add(lattice, name: "after", rank: 1) }
        #expect(lattice.objects(TxnRywItem.self).snapshot().map(\.name) == ["pre", "after"])
    }

    /// (4) In-txn deletes and managed-property-setter updates: membership
    /// changes from EVERY write path inside the block are visible to
    /// filtered reads before commit (setter writes do not bump the read
    /// epoch until commit — the carve-out must not serve cached counts).
    @Test func fileStore_inTxnDeleteAndSetterUpdate_visibleBeforeCommit() throws {
        let (lattice, url) = try makeFileLattice()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        try add(lattice, name: "a", rank: 1)
        try add(lattice, name: "b", rank: 2)
        let results = lattice.objects(TxnRywItem.self)
        #expect(results.count == 2)   // warm caches
        let a = try #require(lattice.object(TxnRywItem.self, primaryKey: 1))
        let b = try #require(lattice.object(TxnRywItem.self, primaryKey: 2))

        try lattice.transaction {
            lattice.delete(a)
            #expect(results.count == 1, "in-txn delete shrinks the count before commit")
            #expect(results.snapshot().map(\.name) == ["b"])
            #expect(lattice.object(TxnRywItem.self, primaryKey: 1) == nil)

            b.rank = 5   // managed-property setter — no SDK-level epoch bump
            #expect(lattice.objects(TxnRywItem.self).where { $0.rank == 5 }.count == 1,
                    "setter update is visible to filtered reads before commit")
            #expect(lattice.objects(TxnRywItem.self).where { $0.rank == 2 }.count == 0)
        }

        #expect(lattice.objects(TxnRywItem.self).snapshot().map(\.name) == ["b"])
        #expect(lattice.objects(TxnRywItem.self).where { $0.rank == 5 }.count == 1)
    }

    /// Cross-thread §4.1 exclusion is untouched: a DIFFERENT thread reading
    /// while this thread's transaction is open serves committed state only
    /// (never the open transaction's uncommitted rows).
    @Test(.timeLimit(.minutes(1)))
    func fileStore_otherThreadReads_neverSeeTheOpenTransaction() throws {
        let (lattice, url) = try makeFileLattice()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        try add(lattice, name: "pre", rank: 0)

        let box = SendableBox(lattice)
        try lattice.transaction {
            try add(lattice, name: "uncommitted", rank: 1)
            #expect(lattice.count(TxnRywItem.self) == 2)

            let observed = MutableBox(-1)
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                observed.value = box.value.count(TxnRywItem.self)
                done.signal()
            }
            done.wait()
            #expect(observed.value == 1, "another thread must not dirty-read the open transaction")
        }
        #expect(lattice.count(TxnRywItem.self) == 2)
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
