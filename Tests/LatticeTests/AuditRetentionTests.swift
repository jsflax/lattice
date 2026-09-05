import Testing
import Foundation
@testable import Lattice

// Audit-history retention (1.8): the cursor-safe tear-out for a store without
// sync partners. Background: a room store reached 17 GB with under 1 MB of
// live data because nothing pruned AuditLog on a slot-less store and the only
// alternative renumbered ids (deafening every sibling process).

@Model final class RetentionNote {
    var title: String = ""
    var body: String = ""
}

private func note(_ title: String) -> RetentionNote {
    let n = RetentionNote(); n.title = title; return n
}

@Suite("Audit retention · pruneHistory + auditRetention")
final class AuditRetentionTests: BaseTest {

    private func auditRows(_ l: Lattice) -> Int { l.objects(AuditLog.self).count }
    private func maxAuditId(_ l: Lattice) -> Int64 {
        l.objects(AuditLog.self).snapshot().map { $0.primaryKey ?? 0 }.max() ?? 0
    }
    /// A watermark "taken `age` seconds ago" at the current max id — the
    /// deterministic stand-in for a retention window elapsing.
    private func backdateWatermark(_ l: Lattice, age: Int) {
        l.recordAuditWatermark()
        l.backdateAuditWatermarks(seconds: Int64(age))
    }

    @Test func pruneRemovesOldRowsKeepsFreshOnesAndNeverRenumbers() throws {
        let l = try testLattice(RetentionNote.self)
        for i in 0..<50 { try l.add(note("old \(i)")) }
        #expect(auditRows(l) == 50)
        backdateWatermark(l, age: 1200)
        for i in 0..<10 { try l.add(note("fresh \(i)")) }
        let maxBefore = maxAuditId(l)

        #expect(l.pruneHistory(olderThan: 3600) == 0, "nothing is provably older than an hour")
        #expect(l.pruneHistory(olderThan: 600) == 50)
        #expect(auditRows(l) == 10)
        #expect(maxAuditId(l) == maxBefore, "ids are never renumbered")

        try l.add(note("after"))
        #expect(maxAuditId(l) == maxBefore + 1, "the sequence continues")
        // compactHistory stays slot-only: -1 on a store that never synced.
        #expect(l.compactHistory() == -1)
    }

    @Test func pruneWithoutAnOldWatermarkIsANoOpThatStartsSampling() throws {
        let l = try testLattice(RetentionNote.self)
        for i in 0..<5 { try l.add(note("\(i)")) }
        #expect(l.pruneHistory(olderThan: 600) == 0)
        #expect(auditRows(l) == 5)
        // The no-op call itself recorded a watermark: backdating it makes the same rows prunable.
        l.backdateAuditWatermarks(seconds: 1200)
        #expect(l.pruneHistory(olderThan: 600) == 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func configuredRetentionPrunesFromTheMaintenanceThread() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "retention_thread_\(String.random(length: 8)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        var config = Lattice.Configuration(fileURL: url)
        config.auditRetention = 2   // thread period = 1 s
        let l = try Lattice(RetentionNote.self, configuration: config)
        for i in 0..<20 { try l.add(note("\(i)")) }
        #expect(auditRows(l) == 20)
        backdateWatermark(l, age: 60)

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, auditRows(l) > 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(auditRows(l) == 0, "the store prunes itself without any caller involvement")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSiblingHandlesChangeStreamKeepsDeliveringAcrossAPrune() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "retention_sibling_\(String.random(length: 8)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let a = try Lattice(RetentionNote.self, configuration: .init(fileURL: url))
        var configB = Lattice.Configuration(fileURL: url)
        configB.syncTuning = .init(chunkSize: 999)   // distinct core instance, same file
        let b = try Lattice(RetentionNote.self, configuration: configB)
        for i in 0..<30 { try a.add(note("\(i)")) }
        backdateWatermark(a, age: 1200)

        let stream = b.changeStream
        var iterator = stream.makeAsyncIterator()
        // b's cursor is seeded at MAX(id); prune everything below it on a.
        #expect(a.pruneHistory(olderThan: 600) == 30)
        try a.add(note("after prune"))

        let batch = try await iterator.next()
        let seen = batch?.compactMap { $0.resolve(on: b) }.map(\.tableName) ?? []
        #expect(seen.contains("RetentionNote"), "delivery must survive pruning below every cursor")
    }
}
