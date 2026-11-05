import Foundation
import Testing
@testable import Lattice

@Model private final class AuditWireRecord {
    var title: String = ""
    var unchanged: Int = 7
    var note: String? = "keep"
    var embedding: Vector<Float> = Vector<Float>([])

    init(title: String) {
        self.title = title
        self.embedding = Vector<Float>((0..<384).map { Float($0) / 384 })
    }
}

@Suite("Local audit wire compatibility", .serialized)
struct AuditLogWireTests {
    private func withReplicas(_ body: (Lattice, Lattice) throws -> Void) throws {
        let prefix = "audit-wire-\(UUID().uuidString)"
        let sourceConfiguration = Lattice.Configuration(
            fileURL: testTemporaryDirectory.appendingPathComponent("\(prefix)-source.sqlite"))
        let replicaConfiguration = Lattice.Configuration(
            fileURL: testTemporaryDirectory.appendingPathComponent("\(prefix)-replica.sqlite"))
        let source = try Lattice(AuditWireRecord.self, configuration: sourceConfiguration)
        defer { source.close(); try? Lattice.delete(for: sourceConfiguration) }
        let replica = try Lattice(AuditWireRecord.self, configuration: replicaConfiguration)
        defer { replica.close(); try? Lattice.delete(for: replicaConfiguration) }
        try body(source, replica)
    }

    @Test func partialUpdateCannotDropInsertsInTheSameNativeFrame() throws {
        try withReplicas { source, replica in
            let first = AuditWireRecord(title: "version one")
            try source.add(first)
            first.title = "version two"
            let neighbor = AuditWireRecord(title: "neighbor insert")
            try source.add(neighbor)

            let firstID = try #require(first.globalId)
            let neighborID = try #require(neighbor.globalId)
            let entries = source.eventsAfter(id: 0).snapshot()
            #expect(entries.count == 3)
            let update = try #require(entries.first { $0.operation == .update })
            let updateID = try #require(update.globalId)
            let storedNames = try #require(update.changedFieldsNames)
            #expect(storedNames.contains { $0 == nil })
            #expect(storedNames.compactMap { $0 } == ["title"])
            let eventIDs = try entries.map { try #require($0.globalId) }

            // The production relay encodes the real stored AuditLog objects;
            // receive invokes the actual C++ wire parser and apply path.
            let frame = try JSONEncoder().encode(ServerSentEvent.auditLog(entries))
            let acknowledged = try replica.receive(frame)
            #expect(Set(acknowledged) == Set(eventIDs))
            let copied = try #require(replica.objects(AuditWireRecord.self)
                .where { $0.globalId == firstID }.first)
            #expect(copied.title == "version two")
            #expect(copied.unchanged == 7)
            #expect(copied.note == "keep")
            #expect(copied.embedding.dimensions == 384)
            #expect(replica.objects(AuditWireRecord.self)
                .where { $0.globalId == neighborID }.first?.title == "neighbor insert")
            #expect(Set(replica.objects(AuditLog.self).snapshot().compactMap(\.globalId))
                    == Set(eventIDs))
            // Serialization must not rewrite the historical nullable list.
            #expect(source.objects(AuditLog.self)
                .where { $0.globalId == updateID }.first?.changedFieldsNames == storedNames)
        }
    }

    @Test func explicitNullValueSurvivesNamePlaceholderCompaction() throws {
        try withReplicas { source, replica in
            let record = AuditWireRecord(title: "unchanged title")
            try source.add(record)
            let id = try #require(record.globalId)
            let initial = source.eventsAfter(id: 0).snapshot()
            let initialFrame = try JSONEncoder().encode(ServerSentEvent.auditLog(initial))
            #expect(try replica.receive(initialFrame).count == 1)
            let boundary = try #require(initial.last?.primaryKey)

            record.note = nil
            let updates = source.eventsAfter(id: boundary).snapshot()
            #expect(updates.count == 1)
            let update = try #require(updates.first)
            let names = try #require(update.changedFieldsNames)
            #expect(names.contains { $0 == nil })
            #expect(names.compactMap { $0 } == ["note"])
            let updateID = try #require(update.globalId)

            let frame = try JSONEncoder().encode(ServerSentEvent.auditLog(updates))
            #expect(try replica.receive(frame) == [updateID])
            let copied = try #require(replica.objects(AuditWireRecord.self)
                .where { $0.globalId == id }.first)
            #expect(copied.note == nil)
            #expect(copied.title == "unchanged title")
            #expect(copied.unchanged == 7)
            #expect(replica.objects(AuditLog.self)
                .where { $0.globalId == updateID }.count == 1)
            #expect(source.objects(AuditLog.self)
                .where { $0.globalId == updateID }.first?.changedFieldsNames == names)
        }
    }
}
