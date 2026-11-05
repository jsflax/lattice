import Foundation
import Testing
import Lattice
@testable import Lattice

@Suite("Immutable Sync", .serialized)
final class ImmutableSyncTests: BaseTest {
    private func entry(value: Int = 41, row: UUID = UUID(), event: UUID = UUID()) -> [String: Any] {
        ["globalId": event.uuidString, "globalRowId": row.uuidString,
         "tableName": "SimpleSyncObject", "operation": "INSERT", "rowId": 1,
         "changedFields": ["value": ["kind": 0, "value": value],
                           "floatValue": ["kind": 5, "value": 1.5]],
         "changedFieldsNames": ["value", "floatValue"], "timestamp": "2026-09-08T12:00:00Z"]
    }

    private func frame(_ entries: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "auditLog", "auditLog": entries])
    }

    @Test func publicReceiveAcceptsReplayAndRejectsChangedInsert() throws {
        let db = try testLattice(SimpleSyncObject.self)
        let row = UUID(), event = UUID()
        let first = entry(row: row, event: event)
        #expect(try db.receive(frame([first]), immutableTables: ["simplesyncobject"]) == [event])
        var replay = first
        replay["rowId"] = 300
        replay["timestamp"] = "2026-10-01T00:00:00Z"
        replay["changedFieldsNames"] = ["floatValue", "value"]
        #expect(try db.receive(frame([replay]), immutableTables: ["SimpleSyncObject"]) == [event])
        #expect(throws: (any Error).self) {
            try db.receive(frame([entry(value: 99, row: row, event: event)]), immutableTables: ["SimpleSyncObject"])
        }
        #expect(throws: (any Error).self) {
            try db.receive(frame([entry(value: 99, row: row)]), immutableTables: ["SimpleSyncObject"])
        }
        #expect(db.objects(SimpleSyncObject.self).count == 1)
        #expect(db.objects(SimpleSyncObject.self).first?.value == 41)
    }

    @Test func entireFrameRollsBackPastLegacyChunkBoundary() throws {
        let db = try testLattice(SimpleSyncObject.self)
        let row = UUID()
        var entries = (0..<75).map { entry(value: $0) }
        entries.append(entry(row: row))
        entries.append(entry(value: 99, row: row))
        #expect(throws: (any Error).self) {
            try db.receive(frame(entries), immutableTables: ["SimpleSyncObject"])
        }
        #expect(db.objects(SimpleSyncObject.self).count == 0)
        #expect(db.objects(AuditLog.self).count == 0)
        entries.removeLast()
        #expect(try db.receive(frame(entries), immutableTables: ["SimpleSyncObject"]).count == 76)
    }

    @Test func malformedEntryCannotBeSkippedAheadOfValidEntry() throws {
        let db = try testLattice(SimpleSyncObject.self)
        #expect(throws: (any Error).self) {
            try db.receive(frame([0, entry()]), immutableTables: ["SimpleSyncObject"])
        }
        #expect(db.objects(SimpleSyncObject.self).count == 0)
    }

    @Test func donorAuditLogSnapshotWorksWithoutCustomSerialization() throws {
        let donor = try testLattice(SimpleSyncObject.self)
        try donor.add(SimpleSyncObject(value: 7, floatValue: 0.5))
        let data = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(donor.eventsAfter(globalId: nil))))
        let receiver = try testLattice(SimpleSyncObject.self)
        #expect(try receiver.receive(data, immutableTables: ["SimpleSyncObject"]).count == 1)
        #expect(receiver.objects(SimpleSyncObject.self).first?.value == 7)
    }
    @Test func authorizationReadsWriterAndRevocationRollsBackWithoutLeakingScope() throws {
        let db = try testLattice(SimpleSyncObject.self)
        let data = try frame([entry()])
        let cached = db.objects(SimpleSyncObject.self)
        #expect(cached.count == 0)
        var observed: [Int] = []
        #expect(throws: LatticeError.self) {
            try db.receive(data, immutableTables: [], authorize: {
                observed.append(cached.count)
                return observed.count == 1
            })
        }
        #expect(observed == [0, 1])
        #expect(db.objects(SimpleSyncObject.self).count == 0)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        #expect(try db.receive(data, immutableTables: [], authorize: { true }).count == 1)
    }

    @Test func policyFailureSurvivesLaterReadAndUnwinds() throws {
        let db = try testLattice(SimpleSyncObject.self)
        let object = SimpleSyncObject(value: 7, floatValue: 1)
        try db.add(object)
        #expect(throws: LatticeError.self) {
            try db.receive(frame([entry()]), immutableTables: [], authorize: {
                object.increment("missing_column")
                _ = object.value // clears the bridge error slot, not the checked failure
                return true
            })
        }
        #expect(db.objects(SimpleSyncObject.self).count == 1)
        #expect(object.value == 7)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        #expect(try db.receive(frame([entry()]), immutableTables: [], authorize: { true }).count == 1)
    }

    @Test func authorizedAckNeverEchoesAndRejectedControlDoesNotApply() throws {
        let db = try testLattice(SimpleSyncObject.self)
        let object = SimpleSyncObject(value: 7, floatValue: 1)
        try db.add(object)
        let event = try #require(db.eventsAfter(globalId: nil).first)
        let id = try #require(event.globalId)
        let ack = try JSONEncoder().encode(ServerSentEvent.ack([id]))
        #expect(throws: LatticeError.self) {
            try db.receive(ack, immutableTables: [], authorize: { false })
        }
        #expect(!event.isSynchronized)
        #expect(try db.receive(ack, immutableTables: [], authorize: { true }).isEmpty)
        #expect(event.isSynchronized)
        let nack = try JSONEncoder().encode(ServerSentEvent.nack(ids: [id], reason: "denied"))
        #expect(throws: LatticeError.self) {
            try db.receive(nack, immutableTables: [], authorize: { true })
        }
    }

}
