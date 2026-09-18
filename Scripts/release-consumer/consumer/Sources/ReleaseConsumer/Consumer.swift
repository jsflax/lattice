import Foundation
import Lattice

enum ConsumerFailure: Error {
    case mismatch(String)
    case intentionalRollback
}

struct ExpectedRow: Codable, Equatable {
    let globalId: UUID
    let ordinal: Int
    let title: String
    let score: Double
}

struct ConsumerResult: Codable {
    let schema: String
    let phase: String
    let pid: Int32
    let checkedRowCount: Int
    let rollbackRowAbsent: Bool
    let rollbackSentinelCaught: Bool?
    let rows: [ExpectedRow]
}

@main enum ReleaseConsumer {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ConsumerFailure.mismatch(message) }
    }

    @MainActor static func main() throws {
        let args = CommandLine.arguments
        try require(args.count == 3, "usage: ReleaseConsumer write|read /owned/path/store.sqlite")
        let phase = args[1]
        try require(phase == "write" || phase == "read", "unknown phase")
        let path = args[2]
        try require(path.hasPrefix("/"), "database path must be absolute")
        let file = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try require(fm.fileExists(atPath: file.deletingLastPathComponent().path), "parent directory absent")
        if phase == "write" {
            for suffix in ["", "-wal", "-shm"] {
                try require(!fm.fileExists(atPath: path + suffix), "writer requires a fresh database path")
            }
        } else {
            try require(fm.fileExists(atPath: path), "reader requires the persisted writer database")
        }
        let expected = [
            ExpectedRow(globalId: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!, ordinal: 1, title: "alpha", score: 1.25),
            ExpectedRow(globalId: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!, ordinal: 2, title: "βeta", score: -2.5),
            ExpectedRow(globalId: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!, ordinal: 3, title: "", score: 0),
        ]
        let rollbackID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
        let db = try Lattice(for: [ReleaseRecord.self], configuration: .init(fileURL: file, busyTimeoutMs: 1_000))
        defer { db.close() }
        var rollbackCaught: Bool?
        if phase == "write" {
            try db.withTransaction {
                for row in expected {
                    let object = ReleaseRecord(ordinal: row.ordinal, title: row.title, score: row.score)
                    try db.add(object, preservingGlobalId: row.globalId)
                }
            }
            rollbackCaught = false
            do {
                try db.withTransaction {
                    try db.add(ReleaseRecord(ordinal: 4, title: "must roll back", score: 4), preservingGlobalId: rollbackID)
                    throw ConsumerFailure.intentionalRollback
                }
            } catch ConsumerFailure.intentionalRollback {
                rollbackCaught = true
            }
            try require(rollbackCaught == true, "rollback body did not throw the sentinel")
        }
        try require(db.objects(ReleaseRecord.self).count == expected.count, "exact persisted row count")
        var observed: [ExpectedRow] = []
        for row in expected {
            guard let object = db.object(ReleaseRecord.self, globalId: row.globalId),
                  let globalId = object.globalId else {
                throw ConsumerFailure.mismatch("missing persisted identity")
            }
            let actual = ExpectedRow(globalId: globalId, ordinal: object.ordinal, title: object.title, score: object.score)
            try require(actual == row, "persisted identity or primitive field differs")
            observed.append(actual)
        }
        let rollbackAbsent = db.object(ReleaseRecord.self, globalId: rollbackID) == nil
        try require(rollbackAbsent, "rolled-back row is visible")
        // Deferred close runs before normal process exit. The supervisor requires
        // exit 0 and complete group cleanup before launching the separate reader.
        let result = ConsumerResult(schema: "lattice.release-consumer/1", phase: phase,
            pid: ProcessInfo.processInfo.processIdentifier, checkedRowCount: observed.count,
            rollbackRowAbsent: rollbackAbsent, rollbackSentinelCaught: rollbackCaught, rows: observed)
        let data = try JSONEncoder().encode(result)
        try FileHandle.standardOutput.write(contentsOf: Data("CONSUMER_RESULT ".utf8) + data + Data("\n".utf8))
    }
}
