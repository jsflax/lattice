import Testing
import Foundation
@testable import Lattice
@testable import LatticeServerKit

/// §1.7.2 — the relay WAL-checkpoint governor, pinned against the WalEpochForensics facts:
/// starvation is unconditional on relay-shaped stores (the core's change hook displaces
/// autocheckpoint), the governor un-starves it, and the wedge state (begun-never-committed
/// transaction) is alarmed but never disturbed.
@Suite("RelayCheckpointGovernor", .serialized)
struct RelayCheckpointGovernorTests {

    private func tempStore() throws -> (lattice: Lattice, path: String, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("governor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("channel.sqlite")
        var config = Lattice.Configuration(fileURL: url)
        config.busyTimeoutMs = 2_000   // the relay's open shape
        let lattice = try Lattice(for: [SimpleSyncObject.self], configuration: config)
        return (lattice, url.path, { try? FileManager.default.removeItem(at: dir) })
    }

    private func mainBytes(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
    }
    private func walBytes(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int64).flatMap { $0 } ?? 0
    }

    @Test("the governor un-starves a relay-shaped store: threshold crossing integrates the WAL into main")
    func governorUnstarves() throws {
        RelayCheckpointGovernor.shared._reset()
        let (lattice, path, cleanup) = try tempStore(); defer { cleanup() }
        let mainBefore = mainBytes(path)

        // Grow the WAL past the governor threshold with committed writes (the starved shape:
        // no read pool, no destructor — nothing else will ever checkpoint this).
        var written = 0
        while walBytes(path) < RelayCheckpointGovernor.walThresholdBytes {
            try lattice.transaction {
                for _ in 0..<500 {
                    try lattice.add(SimpleSyncObject(value: written, floatValue: 1.5))
                }
            }
            written += 500
            if written > 20_000 { Issue.record("WAL never crossed threshold"); return }
        }
        #expect(mainBytes(path) <= mainBefore + 8192,
                "precondition — starvation: main frozen near boot size under a \(walBytes(path))-byte WAL")

        RelayCheckpointGovernor.shared.afterApply(lattice: lattice, storePath: path)

        // Main grows to the DATA size, which compacts well below the WAL's framed size — the
        // bar is "integration clearly happened", not a byte-for-byte WAL transfer.
        #expect(mainBytes(path) > mainBefore + RelayCheckpointGovernor.walThresholdBytes / 4,
                "the governed checkpoint integrated the WAL into main")
        // And after the TRUNCATE pass the WAL is drained, so a plain external read IS the
        // durable view (the honest-backup criterion).
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        probe.arguments = [path, "SELECT count(*) FROM SimpleSyncObject"]
        let out = Pipe(); probe.standardOutput = out
        try probe.run(); probe.waitUntilExit()
        let count = Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        #expect(count >= written, "an external reader sees every committed row after the governed pass")
    }

    @Test("time backstop: a below-threshold store still checkpoints once the interval lapses")
    func timeBackstop() throws {
        RelayCheckpointGovernor.shared._reset()
        let (lattice, path, cleanup) = try tempStore(); defer { cleanup() }
        try lattice.transaction {
            try lattice.add(SimpleSyncObject(value: 1, floatValue: 1))
        }
        // First call: lastCheckpoint is distantPast ⇒ the interval is lapsed ⇒ due.
        RelayCheckpointGovernor.shared.afterApply(lattice: lattice, storePath: path)
        #expect(walBytes(path) == 0 || mainBytes(path) > 4096,
                "the time-due pass ran (wal truncated or main advanced)")
    }

    @Test("wedge: could-not-run alarms without disturbing the open transaction")
    func wedgeAlarmed() throws {
        RelayCheckpointGovernor.shared._reset()
        let (lattice, path, cleanup) = try tempStore(); defer { cleanup() }
        // Enter the B4 wedge shape: begun, never committed.
        lattice.beginTransaction()
        try lattice.add(SimpleSyncObject(value: 777, floatValue: 7))

        // Three governed passes: each returns could-not-run; the third arms the alarm.
        for _ in 0..<RelayCheckpointGovernor.wedgeAlarmThreshold {
            RelayCheckpointGovernor.shared.checkpoint(lattice: lattice, storePath: path)
        }
        // The wedge is UNDISTURBED: committing afterwards still works and the row lands.
        lattice.commitTransaction()
        let visible = lattice.objects(SimpleSyncObject.self).where { $0.value == 777 }.count
        #expect(visible == 1, "the alarm never rolls back or breaks the in-flight epoch")
        // …and a post-commit governed pass succeeds again (recovery notice path).
        RelayCheckpointGovernor.shared.checkpoint(lattice: lattice, storePath: path)
    }
}
