import Testing
import Foundation
@testable import Lattice
@testable import LatticeServerKit

/// §1.7.2 — floor honesty: the codec's wire-compat discipline, the durable-head ledger's
/// regression detection, and their attribution contract.
@Suite("FloorHonesty", .serialized)
struct FloorHonestyTests {

    @Test("floorReset round-trips, and its JSON carries NONE of the legacy dispatch keys")
    func codecWireCompat() throws {
        let head = UUID()
        let event = ServerSentEvent.floorReset(durableHead: head, reason: "server lost history")
        let data = try JSONEncoder().encode(event)
        // The shipped C++ from_json dispatches on these key PRESENCES — a floorReset frame
        // must carry none of them, so every deployed client decodes nullopt and ignores it
        // (the same discipline nack rode in on; sentinel abuse would release in-flight state).
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["auditLog"] == nil)
        #expect(root["ack"] == nil)
        #expect(root["replayRequest"] == nil)
        #expect(root["kind"] as? String == "floorReset")

        let decoded = try JSONDecoder().decode(ServerSentEvent.self, from: data)
        guard case .floorReset(let decodedHead, let reason) = decoded else {
            Issue.record("did not round-trip"); return
        }
        #expect(decodedHead == head)
        #expect(reason == "server lost history")

        // nil head (empty log) encodes and round-trips too.
        let empty = try JSONDecoder().decode(ServerSentEvent.self,
                                             from: try JSONEncoder().encode(
                                                ServerSentEvent.floorReset(durableHead: nil, reason: "r")))
        guard case .floorReset(nil, "r") = empty else { Issue.record("nil head lost"); return }
    }

    @Test("the ledger detects a durable-head regression and attributes it; a clean boot stays unsuspected")
    func ledgerRegression() throws {
        DurableHeadLedger.shared._reset()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("channel.sqlite")
        let lattice = try Lattice(for: [SimpleSyncObject.self], configuration: .init(fileURL: url))

        // Epoch 1: write, record — the ledger now remembers a real head.
        try lattice.transaction {
            for i in 0..<10 { try lattice.add(SimpleSyncObject(value: i, floatValue: 0)) }
        }
        DurableHeadLedger.shared.record(lattice: lattice, storePath: url.path)
        let recorded = try #require(DurableHeadLedger.readEntry(storePath: url.path))
        #expect(recorded.headPk > 0)

        // Clean boot (same history): not suspect, and the ledger is refreshed.
        DurableHeadLedger.shared._reset()
        #expect(DurableHeadLedger.shared.bootCheck(lattice: lattice, storePath: url.path) == false)

        // Simulate the loss: a FRESH store file at the same path (head pk restarts below the
        // ledgered one — the WAL-epoch discard shape), ledger carries the old head.
        let url2 = dir.appendingPathComponent("channel2.sqlite")
        let lattice2 = try Lattice(for: [SimpleSyncObject.self], configuration: .init(fileURL: url2))
        try lattice2.transaction { try lattice2.add(SimpleSyncObject(value: 1, floatValue: 0)) }
        // Plant the old (higher) ledger at the new store's path.
        let planted = DurableHeadLedger.Entry(headPk: recorded.headPk + 100, headGlobalId: UUID(),
                                              recordedAt: Date())
        try JSONEncoder().encode(planted).write(to: URL(fileURLWithPath: url2.path + "-ledger"))
        DurableHeadLedger.shared._reset()
        #expect(DurableHeadLedger.shared.bootCheck(lattice: lattice2, storePath: url2.path) == true,
                "a boot head behind the ledgered head is the loss signature — FLOOR-SUSPECT")
        // The verdict is sticky for the process (attribution), and the ledger now records truth.
        #expect(DurableHeadLedger.shared.isFloorSuspect(storePath: url2.path))
        let refreshed = try #require(DurableHeadLedger.readEntry(storePath: url2.path))
        #expect(refreshed.headPk < planted.headPk, "the ledger re-records the actual head")
    }

    @Test("a governed checkpoint refreshes the ledger (durable head advances with integration)")
    func governorFeedsLedger() throws {
        RelayCheckpointGovernor.shared._reset()
        DurableHeadLedger.shared._reset()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-gov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("channel.sqlite")
        let lattice = try Lattice(for: [SimpleSyncObject.self], configuration: .init(fileURL: url))
        try lattice.transaction { try lattice.add(SimpleSyncObject(value: 1, floatValue: 0)) }
        RelayCheckpointGovernor.shared.checkpoint(lattice: lattice, storePath: url.path)
        let entry = try #require(DurableHeadLedger.readEntry(storePath: url.path))
        #expect(entry.headPk >= 1, "checkpoint success writes the ledger")
    }
}
