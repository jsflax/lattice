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
