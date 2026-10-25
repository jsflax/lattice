import Foundation
import Testing
@testable import Lattice

@Model private final class LocalMetadataItem {
    var value: String = ""
    init(value: String = "") { self.value = value }
}

@Suite("Atomic local metadata", .serialized)
struct LocalMetadataTests {
    private let namespace = "engram.consumer-operations.v1"

    private func configuration() -> Lattice.Configuration {
        .init(fileURL: testTemporaryDirectory.appendingPathComponent("local-metadata-\(UUID().uuidString).sqlite"),
              busyTimeoutMs: 2000)
    }

    @Test func insertionRequiresCheckedTransactionAndIsImmutable() throws {
        let config = configuration()
        let db = try Lattice(LocalMetadataItem.self, configuration: config)
        defer { db.close(); try? Lattice.delete(for: config) }
        #expect(try db.localMetadata(namespace: namespace, key: "op") == nil)
        #expect(throws: LatticeError.self) {
            try db.insertLocalMetadataIfAbsent("receipt", namespace: namespace, key: "op")
        }
        #expect(throws: LatticeError.self) {
            try db.transaction {
                try db.insertLocalMetadataIfAbsent("receipt", namespace: namespace, key: "op")
            }
        }
        try db.withTransaction {
            #expect(try db.insertLocalMetadataIfAbsent("receipt", namespace: namespace, key: "op"))
            #expect(!(try db.insertLocalMetadataIfAbsent("different", namespace: namespace, key: "op")))
            #expect(try db.localMetadata(namespace: namespace, key: "op") == "receipt")
        }
        #expect(db.objects(AuditLog.self).count == 0)
        #expect(try db.localMetadata(namespace: "different.namespace", key: "op") == nil)
    }

    @Test func receiptAndAuditedMutationCommitAndRollbackTogether() throws {
        let config = configuration()
        var db = try Lattice(LocalMetadataItem.self, configuration: config)
        defer { db.close(); try? Lattice.delete(for: config) }
        enum Stop: Error { case rollback }
        #expect(throws: Stop.self) {
            try db.withTransaction {
                try db.add(LocalMetadataItem(value: "rolled back"))
                try db.insertLocalMetadataIfAbsent("aborted", namespace: namespace, key: "op")
                throw Stop.rollback
            }
        }
        #expect(db.objects(LocalMetadataItem.self).count == 0)
        #expect(db.objects(AuditLog.self).count == 0)
        #expect(try db.localMetadata(namespace: namespace, key: "op") == nil)
        try db.withTransaction {
            try db.add(LocalMetadataItem(value: "committed"))
            try db.insertLocalMetadataIfAbsent("original receipt", namespace: namespace, key: "op")
        }
        db.close()
        db = try Lattice(LocalMetadataItem.self, configuration: config)
        #expect(try db.localMetadata(namespace: namespace, key: "op") == "original receipt")
        #expect(db.objects(LocalMetadataItem.self).first?.value == "committed")
        #expect(db.objects(AuditLog.self).count == 1)
        #expect(db.objects(AuditLog.self).snapshot().allSatisfy { $0.tableName == "LocalMetadataItem" })
    }

    @Test func swallowedMetadataFailureStillRollsBackTheMutation() throws {
        let config = configuration()
        let db = try Lattice(LocalMetadataItem.self, configuration: config)
        defer { db.close(); try? Lattice.delete(for: config) }
        #expect(throws: LatticeError.self) {
            try db.withTransaction {
                try db.add(LocalMetadataItem(value: "must roll back"))
                _ = try? db.insertLocalMetadataIfAbsent(String(repeating: "x", count: 65_537),
                                                       namespace: namespace, key: "oversized")
                // A later successful native read must not clear the failure
                // latch owned by this checked transaction.
                _ = try db.localMetadata(namespace: namespace, key: "absent")
            }
        }
        #expect(db.objects(LocalMetadataItem.self).count == 0)
        #expect(db.objects(AuditLog.self).count == 0)
        #expect(try db.localMetadata(namespace: namespace, key: "oversized") == nil)
    }

    @Test func separateActorsCommitOneMutationForOneOperationAndRejectChangedPayload() async throws {
        let config = configuration()
        let first = LocalMetadataWriter(configuration: config)
        let second = LocalMetadataWriter(configuration: config)
        do {
            // Construct sequentially; the race under test is the operation's
            // transaction, rather than first-open schema registration.
            try await first.open()
            try await second.open()
            async let a = first.commit(operation: "same", payload: "original")
            async let b = second.commit(operation: "same", payload: "original")
            let results = try await [a, b]
            #expect(results.filter { $0 }.count == 1)
            #expect(try await first.counts() == [1, 1])
            await #expect(throws: LocalMetadataWriter.Rejection.self) {
                try await second.commit(operation: "same", payload: "changed")
            }
            #expect(try await first.counts() == [1, 1])
            #expect(try await first.commit(operation: "distinct", payload: "original"))
            #expect(try await first.counts() == [2, 2])
        } catch {
            await first.close(); await second.close()
            try? Lattice.delete(for: config)
            throw error
        }
        await first.close(); await second.close()
        try Lattice.delete(for: config)
    }
}

private actor LocalMetadataWriter {
    enum Rejection: Error { case payloadConflict }
    let configuration: Lattice.Configuration
    var db: Lattice?
    init(configuration: Lattice.Configuration) { self.configuration = configuration }
    func open() throws { db = try Lattice(LocalMetadataItem.self, configuration: configuration) }
    func close() { db?.close(); db = nil }
    func commit(operation: String, payload: String) throws -> Bool {
        let db = try #require(db)
        return try db.withTransaction {
            if let existing = try db.localMetadata(namespace: "test.operations", key: operation) {
                guard existing == payload else { throw Rejection.payloadConflict }
                return false
            }
            try db.add(LocalMetadataItem(value: payload))
            let inserted = try db.insertLocalMetadataIfAbsent(payload, namespace: "test.operations", key: operation)
            #expect(inserted)
            return inserted
        }
    }
    func counts() throws -> [Int] {
        let db = try #require(db)
        return [db.objects(LocalMetadataItem.self).count, db.objects(AuditLog.self).count]
    }
}
