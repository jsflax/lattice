import Testing
import Foundation
@testable import Lattice

@Model final class BulkRow {
    var payload: String = ""
}

@Suite("Maintenance · reclaimSpace, checkpoint result, changeHeaders, observer slots")
final class ReclaimAndHeadersTests: BaseTest {

    private func fileBytes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    @Test func reclaimSpaceShrinksTheFileInOnePassAndVacuumReportsSuccess() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reclaim_\(String.random(length: 8)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let l = try Lattice(BulkRow.self, configuration: .init(fileURL: url))
        let blob = String(repeating: "x", count: 64 * 1024)
        for _ in 0..<150 { let r = BulkRow(); r.payload = blob; try l.add(r) }
        #expect(l.checkpoint().complete)
        let peak = fileBytes(url)
        #expect(peak > 8 * 1024 * 1024)

        l.delete(BulkRow.self)
        l.deleteHistory()
        let r = l.reclaimSpace()
        #expect(r.ok, "\(r.error)")
        #expect(r.passes == 1)
        #expect(r.shrank)
        #expect(fileBytes(url) < peak / 10, "the MAIN file shrank, not just the WAL view")
        #expect(r.walBytesAfter < 64 * 1024)
        #expect(l.vacuum())
        #expect(l.lastQueryError() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func changeHeadersDeliverTableOperationAndRowWithoutResolving() async throws {
        let l = try testLattice(BulkRow.self)
        var it = l.changeHeaders.makeAsyncIterator()
        let r = BulkRow(); r.payload = "p"
        try l.add(r)
        let batch = try #require(try await it.next())
        let h = try #require(batch.first { $0.tableName == "BulkRow" })
        #expect(h.operation == .insert)
        #expect(h.rowId == r.primaryKey)
        #expect(h.globalRowId == r.globalId)
        #expect(h.auditId > 0)
        l.transaction { r.payload = "q" }
        let batch2 = try #require(try await it.next())
        #expect(batch2.contains { $0.tableName == "BulkRow" && $0.operation == .update })
    }

    @Test(.timeLimit(.minutes(2)))
    func anObserverSlotDoesNotPinCompactionAndReadOnlyImpliesIt() async throws {
        // A store with its OWN read-only dial (observer slot) plus a writer dial:
        // slot-aware compaction must key on the writer's floor only.
        let channel = "observer_\(String.random(length: 8))"
        let dir = FileManager.default.temporaryDirectory
        let hubURL = dir.appending(path: "obs_hub_\(channel).sqlite")
        let writerURL = dir.appending(path: "obs_writer_\(channel).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: hubURL)); try? Lattice.delete(for: .init(fileURL: writerURL)) }

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel)]
        hubConfig.syncTuning = .init(registersAsObserver: true)   // the hub dials as an observer
        let hub = try Lattice(BulkRow.self, configuration: hubConfig)
        var writerConfig = Lattice.Configuration(fileURL: writerURL)
        writerConfig.ipcTargets = [.init(channel: channel)]
        let writer = try Lattice(BulkRow.self, configuration: writerConfig)

        let r = BulkRow(); r.payload = "hello"
        try writer.add(r)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, hub.objects(BulkRow.self).count == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try #require(hub.objects(BulkRow.self).count == 1, "IPC must connect for a slot to exist")

        // The hub's only slot is an observer's ⇒ slot-aware compaction sees no writer slots (-1),
        // and the age-based prune is free to run there.
        #expect(hub.compactHistory() == -1)
        // Flip it explicitly and back through the public API.
        hub.setReplicationSlotObserver(syncId: "ipc:\(channel)", isObserver: false)
        #expect(hub.compactHistory() >= 0)
        hub.setReplicationSlotObserver(syncId: "ipc:\(channel)", isObserver: true)
        #expect(hub.compactHistory() == -1)
        _ = writer
    }
}
