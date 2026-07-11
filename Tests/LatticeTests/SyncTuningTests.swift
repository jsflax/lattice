import Foundation
import Lattice
import Testing

@Model final class TunedItem {
    var name: String
    init(name: String = "") { self.name = name }
}

// 1.0 item I2: Configuration.SyncTuning reaches the core sync_config
// (overlay semantics are pinned by core's SyncTuningTest gtest; the
// chunkSize-driven frame-count test lands with the TestSyncServer helper,
// D1b). Here: the surface round-trips Equatable/Hashable and a tuned
// lattice opens and writes normally.
@Suite("Sync Tuning Tests", .serialized)
class SyncTuningTests: BaseTest {

    @Test func tunedConfiguration_equatableHashable() throws {
        let a = Lattice.Configuration.SyncTuning(chunkSize: 1, uploadCoalesceMs: 750, useUploadFloor: false)
        var b = Lattice.Configuration.SyncTuning(chunkSize: 1, uploadCoalesceMs: 750, useUploadFloor: false)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        b.chunkSize = 2
        #expect(a != b)

        var c1 = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory.appending(path: "tuned-eq.sqlite"))
        var c2 = c1
        c1.syncTuning = a
        #expect(c1 != c2)
        c2.syncTuning = a
        #expect(c1 == c2)
    }

    @Test func tunedLattice_opensAndWrites() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: path)) }
        let config = Lattice.Configuration(
            fileURL: path,
            syncTuning: .init(chunkSize: 1, stableConnectionMs: 1, uploadCoalesceMs: 50))
        let lattice = try Lattice(TunedItem.self, configuration: config)
        lattice.add(TunedItem(name: "tuned"))
        #expect(lattice.objects(TunedItem.self).count == 1)
    }
}

// I2's end-to-end evidence (owed since 8ac403d): chunkSize actually reaches
// the live synchronizer. With chunkSize 1, N inserted objects arrive at the
// server as at least N separate auditLog frames; the default (1000) would
// batch them into far fewer. Server lives on the suite (init/deinit) — the
// per-test lifecycle trips Vapor's ServeCommand deinit assertion.
@Suite("Sync Tuning Frame Tests", .serialized)
actor SyncTuningFrameTests {
    let server: TestSyncServer
    let serverURL = FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 24)).sqlite")
    let clientURL = FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 24)).sqlite")

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        self.server = try await TestSyncServer(models: [TunedItem.self],
                                               configuration: .init(fileURL: serverURL),
                                               label: "TuningFrames")
    }

    deinit {
        server.shutdown()
        try? Lattice.delete(for: .init(fileURL: serverURL))
        try? Lattice.delete(for: .init(fileURL: clientURL))
    }

    @Test(.timeLimit(.minutes(5))) func chunkSizeOne_forcesPerEntryFrames() async throws {
        let client = try Lattice(TunedItem.self, configuration: .init(
            fileURL: clientURL,
            authorizationToken: "t",
            wssEndpoint: server.endpoint,
            syncTuning: .init(chunkSize: 1)))

        // ONE transaction → one commit → one upload pass: with the default
        // chunk size all 5 entries ride a single frame, so per-entry frames
        // can only come from chunkSize 1 (per-commit dispatch can't explain
        // them away).
        let writes = 5
        client.transaction {
            for i in 0..<writes {
                client.add(TunedItem(name: "tuned-\(i)"))
            }
        }

        let start = Date()
        while server.auditFrameCount < writes, Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(server.auditFrameCount >= writes,
                "chunkSize 1 must produce at least one frame per entry, got \(server.auditFrameCount)")
    }
}
