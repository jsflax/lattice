import Foundation
import Testing
@testable import Lattice

@Model private final class BulkUpdateItem {
    var accessCount: Int = 0
    var touchedAt: Date = Date(timeIntervalSince1970: 100)
    var note: String = ""
    var computedCount: Int { accessCount + 1 }
}

@Suite("Selected checked bulk updates", .serialized)
struct BulkUpdateTests {
    private func store(count: Int = 2) throws -> (Lattice, [BulkUpdateItem]) {
        let db = try Lattice(BulkUpdateItem.self, configuration: .init(storage: .memory()))
        var rows: [BulkUpdateItem] = []
        try db.withTransaction {
            for index in 0..<count {
                let row = BulkUpdateItem()
                row.note = "row-\(index)"
                try db.add(row)
                rows.append(row)
            }
        }
        return (db, rows)
    }

    @Test func duplicateSelectedReferencesUpdateOnce() throws {
        let (db, rows) = try store()
        defer { db.close() }
        let changed = try db.bulkUpdate([rows[0], rows[1], rows[0]], changes: [
            .set(\.touchedAt, to: Date(timeIntervalSince1970: 123.5)),
            .increment(\.accessCount, by: 2)
        ])
        #expect(changed == 2)
        #expect(rows.map(\.accessCount) == [2, 2])
        #expect(rows.map(\.touchedAt) == Array(repeating: Date(timeIntervalSince1970: 123.5), count: 2))
        #expect(rows.map(\.note) == ["row-0", "row-1"])
    }

    @Test func joinsCheckedTransactionAndCaughtFailureRemainsSticky() throws {
        let (db, rows) = try store()
        defer { db.close() }
        #expect(throws: LatticeError.self) {
            try db.withTransaction {
                try db.bulkUpdate(rows, changes: [.increment(\.accessCount)])
                do {
                    try db.bulkUpdate(rows, changes: [.increment(\.computedCount)])
                    Issue.record("computed field must not become a SQL mutation")
                } catch {}
                rows[0].note = "must roll back"
                _ = rows[0].accessCount // successful reads cannot clear the failure
            }
        }
        #expect(rows.map(\.accessCount) == [0, 0])
        #expect(rows[0].note == "row-0")
        try db.bulkUpdate(rows, changes: [.increment(\.accessCount)])
        #expect(rows.map(\.accessCount) == [1, 1])
    }

    @Test func duplicateColumnsAndInvalidDatesFailBeforeWrites() throws {
        let (db, rows) = try store()
        defer { db.close() }
        #expect(throws: BulkUpdateError.self) {
            try db.bulkUpdate(rows, changes: [.increment(\.accessCount), .increment(\.accessCount)])
        }
        #expect(throws: BulkUpdateError.self) {
            try db.bulkUpdate(rows, changes: [.set(\.touchedAt, to: Date(timeIntervalSince1970: .infinity))])
        }
        #expect(rows.map(\.accessCount) == [0, 0])
        #expect(rows.allSatisfy { $0.touchedAt == Date(timeIntervalSince1970: 100) })
    }

    @Test func overflowAndMissingRowsDoNotPartiallyUpdateOtherRows() throws {
        let (db, rows) = try store()
        defer { db.close() }
        rows[1].accessCount = Int.max
        #expect(throws: BulkUpdateError.self) {
            try db.bulkUpdate(rows, changes: [
                .set(\.touchedAt, to: Date(timeIntervalSince1970: 500)),
                .increment(\.accessCount)
            ])
        }
        #expect(rows.map(\.accessCount) == [0, Int.max])
        #expect(rows[0].touchedAt == Date(timeIntervalSince1970: 100))
        _ = db.delete(rows[1])
        #expect(throws: BulkUpdateError.self) {
            try db.bulkUpdate(rows, changes: [.increment(\.accessCount)])
        }
        #expect(rows[0].accessCount == 0)
    }

    @Test func materializedInputsKeepTheirSnapshotsThroughCommitAndRollback() throws {
        let (db, rows) = try store(count: 1)
        defer { db.close() }
        let row = rows[0]
        let key = try #require(row.primaryKey)
        row.materialize()
        try db.bulkUpdate(rows, changes: [.increment(\.accessCount)])
        #expect(row.isMaterialized)
        #expect(row.accessCount == 0)
        #expect(db.object(BulkUpdateItem.self, primaryKey: key)?.accessCount == 1)
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try db.withTransaction {
                try db.bulkUpdate(rows, changes: [.increment(\.accessCount)])
                throw Stop()
            }
        }
        #expect(row.isMaterialized)
        #expect(row.accessCount == 0)
        row.refreshMaterialized()
        #expect(row.accessCount == 1)
    }

    @Test func unmanagedAndForeignHandleTargetsAreRejected() throws {
        let (db, rows) = try store(count: 1)
        let (other, foreign) = try store(count: 1)
        defer { db.close(); other.close() }
        #expect(throws: BulkUpdateError.self) {
            try db.bulkUpdate([rows[0], BulkUpdateItem()], changes: [.increment(\.accessCount)])
        }
        #expect(throws: BulkUpdateError.self) {
            try db.bulkUpdate([rows[0], foreign[0]], changes: [.increment(\.accessCount)])
        }
        #expect(rows[0].accessCount == 0)
        #expect(foreign[0].accessCount == 0)
    }

    @Test func legacyTransactionIsNotSilentlyJoined() throws {
        let (db, rows) = try store(count: 1)
        defer { db.close() }
        db.beginTransaction()
        #expect(throws: BulkUpdateError.requiresCheckedTransaction) {
            try db.bulkUpdate(rows, changes: [.increment(\.accessCount)])
        }
        db.rollbackTransaction()
        #expect(rows[0].accessCount == 0)
    }

    @Test func anotherHandlesCheckedScopeCannotAuthorizeALegacyTransaction() throws {
        let (db, rows) = try store(count: 1)
        let (other, foreign) = try store(count: 1)
        defer { db.close(); other.close() }
        #expect(throws: LatticeError.self) {
            try db.withTransaction {
                other.beginTransaction()
                defer { other.rollbackTransaction() }
                #expect(throws: BulkUpdateError.requiresCheckedTransaction) {
                    try other.bulkUpdate(foreign, changes: [.increment(\.accessCount)])
                }
                rows[0].accessCount = 5
            }
        }
        #expect(rows[0].accessCount == 0)
        #expect(foreign[0].accessCount == 0)
    }

    @Test func selectedAttachedReplicaPersistsWithoutChangingItsLocalCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/bulk-update-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mainURL = root.appendingPathComponent("main.sqlite")
        let otherURL = root.appendingPathComponent("other.sqlite")
        let main = try Lattice(BulkUpdateItem.self, configuration: .init(fileURL: mainURL))
        let other = try Lattice(BulkUpdateItem.self, configuration: .init(fileURL: otherURL))
        defer { main.close(); other.close() }
        let replicaID = UUID()
        let local = BulkUpdateItem(); local.note = "local"
        let remote = BulkUpdateItem(); remote.note = "remote"
        try main.add(local, preservingGlobalId: replicaID)
        try other.add(remote, preservingGlobalId: replicaID)
        let attached = try main.attaching(lattice: other)
        defer { attached.close() }
        let selected = attached.objects(BulkUpdateItem.self).sortedBy(\.note).snapshot()
        #expect(selected.count == 2)
        #expect(selected.map(\.primaryKey) == [1, 1])
        #expect(throws: BulkUpdateError.self) {
            try attached.bulkUpdate(selected, changes: [.increment(\.accessCount)])
        }
        #expect(selected.map(\.accessCount) == [0, 0])
        let selectedRemote = try #require(selected.first { $0.note == "remote" })
        #expect(try attached.bulkUpdate([selectedRemote, selectedRemote], changes: [
            .set(\.touchedAt, to: Date(timeIntervalSince1970: 1234)),
            .increment(\.accessCount, by: 3)
        ]) == 1)
        attached.close(); main.close(); other.close()
        let freshMain = try Lattice(BulkUpdateItem.self, configuration: .init(fileURL: mainURL))
        let freshOther = try Lattice(BulkUpdateItem.self, configuration: .init(fileURL: otherURL))
        defer { freshMain.close(); freshOther.close() }
        let persistedLocal = try #require(freshMain.object(BulkUpdateItem.self, globalId: replicaID))
        let persistedRemote = try #require(freshOther.object(BulkUpdateItem.self, globalId: replicaID))
        #expect(persistedLocal.accessCount == 0)
        #expect(persistedLocal.touchedAt == Date(timeIntervalSince1970: 100))
        #expect(persistedRemote.accessCount == 3)
        #expect(persistedRemote.touchedAt == Date(timeIntervalSince1970: 1234))
    }
}
