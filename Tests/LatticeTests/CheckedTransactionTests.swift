import Foundation
import Testing
@testable import Lattice
import CLatticeTestSQLite

@Model private final class CheckedTransactionItem {
    var value: Int = 0
}

@Model private final class CheckedTransactionListOwner {
    var value: Int = 0
    var items: List<CheckedTransactionItem>
}

@Suite("Checked transactions", .serialized)
struct CheckedTransactionTests {
    private func database() throws -> (Lattice, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checked-txn-\(UUID().uuidString).sqlite")
        let db = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self,
                             configuration: .init(fileURL: url, busyTimeoutMs: 100))
        return (db, url)
    }

    private func sqlite(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        #expect(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        let db = try #require(pointer)
        defer { sqlite3_close(db) }
        try body(db)
    }

    private func sql(_ db: OpaquePointer, _ statement: String) throws {
        let result = sqlite3_exec(db, statement, nil, nil, nil)
        #expect(result == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        if result != SQLITE_OK { throw LatticeError.transactionError(statement) }
    }

    private func value(_ db: Lattice) -> Int? {
        db.objects(CheckedTransactionItem.self).first?.value
    }

    @Test func failedBeginDoesNotExecuteBodyAndRecovers() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem()
        try db.add(item)
        var executed = false
        try sqlite(url) { writer in
            try sql(writer, "BEGIN IMMEDIATE")
            defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }
            #expect(throws: LatticeError.self) {
                try db.withTransaction { executed = true; item.value = 1 }
            }
            #expect(!executed)
            #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        }
        try db.withTransaction { item.increment("value") }
        #expect(value(db) == 1)
    }

    @Test func earlierFailedIncrementSurvivesLaterSuccessfulRead() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem()
        try db.add(item)
        #expect(throws: LatticeError.self) {
            try db.withTransaction {
                item.value = 12
                item.increment("missing_column")
                _ = item.value // clears the bridge slot, not the transaction failure
            }
        }
        #expect(value(db) == 0)
        try db.withTransaction { item.value = 2 }
        #expect(value(db) == 2)
    }

    @Test func attachedWriteFailureRollsBackLocalWrites() throws {
        var (db, url) = try database()
        let (attached, attachedURL) = try database()
        defer {
            db.close(); attached.close()
            try? Lattice.delete(for: .init(fileURL: url))
            try? Lattice.delete(for: .init(fileURL: attachedURL))
        }
        let local = CheckedTransactionItem(); local.value = 7
        let remote = CheckedTransactionItem(); remote.value = 11
        try db.add(local)
        try attached.add(remote)
        let localID = try #require(local.globalId)
        let remoteID = try #require(remote.globalId)
        // Install the fault before BEGIN, then close the external connection.
        // No competing writer can make BEGIN satisfy this test's failure check.
        try sqlite(attachedURL) { connection in
            try sql(connection, "CREATE TRIGGER checked_attached_write_fault BEFORE UPDATE OF value ON CheckedTransactionItem BEGIN SELECT RAISE(ABORT, 'checked-attached-write-fault'); END")
        }
        try db.attach(lattice: attached)
        let foreign = try #require(db.object(CheckedTransactionItem.self, globalId: remoteID))
        var bodyEntered = false
        var earlierLocalWriteObserved = false
        var attachedWriteReturned = false
        var failure: String?
        do {
            try db.withTransaction {
                bodyEntered = true
                local.value = 99
                earlierLocalWriteObserved = local.value == 99
                foreign.increment("value")
                attachedWriteReturned = true
                // The successful read clears the bridge slot, not the first failure.
                _ = local.value
            }
        } catch {
            #expect(error is LatticeError)
            failure = String(describing: error)
        }
        #expect(bodyEntered)
        #expect(earlierLocalWriteObserved)
        #expect(attachedWriteReturned)
        #expect(failure?.contains("checked-attached-write-fault") == true)
        db.retireAllGenerations(); attached.retireAllGenerations()
        #expect(db.object(CheckedTransactionItem.self, globalId: localID)?.value == 7)
        #expect(attached.object(CheckedTransactionItem.self, globalId: remoteID)?.value == 11)
        try sqlite(attachedURL) { try sql($0, "DROP TRIGGER checked_attached_write_fault") }
        try db.withTransaction {
            local.value = 8
            foreign.increment("value")
        }
        db.retireAllGenerations(); attached.retireAllGenerations()
        #expect(db.object(CheckedTransactionItem.self, globalId: localID)?.value == 8)
        #expect(attached.object(CheckedTransactionItem.self, globalId: remoteID)?.value == 12)
    }

    @Test func commitFailureRollsBackAndRecovers() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem()
        try db.add(item)
        try sqlite(url) { connection in
            try sql(connection, "CREATE TABLE commit_guard (id INTEGER PRIMARY KEY, globalId TEXT, parent INTEGER REFERENCES CheckedTransactionItem(id) DEFERRABLE INITIALLY DEFERRED)")
            try sql(connection, "CREATE TRIGGER fail_commit AFTER UPDATE OF value ON CheckedTransactionItem BEGIN INSERT INTO commit_guard (parent) VALUES (-1); END")
        }
        do {
            try db.withTransaction { item.value = 99 }
            Issue.record("Expected a deferred foreign-key failure at COMMIT")
        } catch {
            #expect(String(describing: error).localizedCaseInsensitiveContains("foreign key"))
        }
        #expect(value(db) == 0)
        try sqlite(url) { try sql($0, "DROP TRIGGER fail_commit") }
        try db.withTransaction { item.value = 3 }
        #expect(value(db) == 3)
    }

    @Test func nestedRejectionDoesNotRollbackOuterTransaction() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem()
        try db.add(item)
        try db.withTransaction {
            item.value = 4
            #expect(throws: LatticeError.self) {
                try db.withTransaction { item.value = 100 }
            }
            item.increment("value")
        }
        #expect(value(db) == 5)
    }

    @Test func thrownBodyRollsBackAndRestoresFailureScope() throws {
        struct Stop: Error {}
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem()
        try db.add(item)
        #expect(throws: Stop.self) {
            try db.withTransaction { item.value = 100; throw Stop() }
        }
        #expect(value(db) == 0)
        try db.withTransaction { item.value = 6 }
        #expect(value(db) == 6)
    }

    private func listFixture() throws -> (Lattice, URL, CheckedTransactionListOwner, CheckedTransactionItem, CheckedTransactionItem) {
        let (db, url) = try database()
        do {
            let owner = CheckedTransactionListOwner()
            let original = CheckedTransactionItem(); original.value = 1
            let replacement = CheckedTransactionItem(); replacement.value = 2
            try db.add(owner); try db.add(original); try db.add(replacement)
            owner.items.append(original)
            return (db, url, owner, original, replacement)
        } catch {
            db.close(); try? Lattice.delete(for: .init(fileURL: url))
            throw error
        }
    }

    @Test func invalidListReadPreservesFailureAndRollsBackEarlierWrite() throws {
        let (db, url, owner, original, _) = try listFixture()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let ownerID = try #require(owner.globalId)
        // Exercise the real managed-list backend's optional access, not the
        // public List subscript that intentionally force-unwraps its result.
        let links = owner._dynamicObject._ref.getLinkList(named: "items")
        var bodyEntered = false
        var invalidReadReturned = false
        var indexFailure: String?
        var transactionFailure: String?
        do {
            try db.withTransaction {
                bodyEntered = true
                owner.value = 41
                let missing = links.object(at: 99)
                invalidReadReturned = true
                #expect(missing == nil)
                indexFailure = db.lastQueryError()
                #expect(indexFailure != nil)
                #expect(links.size == 1) // succeeds and clears the native error slot
                #expect(db.lastQueryError() == nil)
            }
        } catch {
            #expect(error is LatticeError)
            transactionFailure = String(describing: error)
        }
        #expect(bodyEntered && invalidReadReturned)
        let firstFailure = try #require(indexFailure)
        #expect(transactionFailure?.contains(firstFailure) == true)
        db.retireAllGenerations()
        #expect(db.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 0)
        #expect(owner.items.count == 1)
        #expect(owner.items.first?.globalId == original.globalId)
        try db.withTransaction {
            owner.value = 3
            #expect(links.object(at: 0) != nil)
        }
        db.retireAllGenerations()
        #expect(db.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 3)
    }

    @Test func invalidListWritePreservesFailureAndRollsBackEarlierWrite() throws {
        let (db, url, owner, original, replacement) = try listFixture()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let ownerID = try #require(owner.globalId)
        let links = owner._dynamicObject._ref.getLinkList(named: "items")
        var bodyEntered = false
        var invalidWriteReturned = false
        var indexFailure: String?
        var transactionFailure: String?
        do {
            try db.withTransaction {
                bodyEntered = true
                owner.value = 42
                links.setObject(at: 99, replacement._dynamicObject._ref)
                invalidWriteReturned = true
                indexFailure = db.lastQueryError()
                #expect(indexFailure != nil)
                #expect(links.size == 1) // succeeds and clears the native error slot
                #expect(db.lastQueryError() == nil)
            }
        } catch {
            #expect(error is LatticeError)
            transactionFailure = String(describing: error)
        }
        #expect(bodyEntered && invalidWriteReturned)
        let firstFailure = try #require(indexFailure)
        #expect(transactionFailure?.contains(firstFailure) == true)
        db.retireAllGenerations()
        #expect(db.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 0)
        #expect(owner.items.count == 1)
        #expect(owner.items.first?.globalId == original.globalId)
        try db.withTransaction {
            owner.value = 4
            // Recovery uses a real append. Valid index replacement has a
            // separate upstream SQL column-name defect, outside this guard fix.
            links.pushBack(replacement._dynamicObject._ref)
        }
        db.retireAllGenerations()
        #expect(db.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 4)
        #expect(owner.items.count == 2)
        #expect(owner.items.snapshot().map { $0.globalId } == [original.globalId, replacement.globalId])
    }

    @Test func crossStoreNestedRejectionDoesNotEnterInnerBodyOrPoisonOuter() throws {
        let (outer, outerURL) = try database()
        let (inner, innerURL) = try database()
        defer {
            outer.close(); inner.close()
            try? Lattice.delete(for: .init(fileURL: outerURL))
            try? Lattice.delete(for: .init(fileURL: innerURL))
        }
        let outerItem = CheckedTransactionItem()
        let innerItem = CheckedTransactionItem()
        try outer.add(outerItem); try inner.add(innerItem)
        var innerBodyEntered = false
        try outer.withTransaction {
            outerItem.value = 5
            #expect(throws: LatticeError.self) {
                try inner.withTransaction {
                    innerBodyEntered = true
                    innerItem.value = 99
                }
            }
            #expect(!innerBodyEntered)
            outerItem.increment("value")
        }
        #expect(!innerBodyEntered)
        outer.retireAllGenerations(); inner.retireAllGenerations()
        #expect(value(outer) == 6)
        #expect(value(inner) == 0)
        // After the outer scope ends, the other store is usable normally.
        try inner.withTransaction { innerItem.value = 7 }
        inner.retireAllGenerations()
        #expect(value(inner) == 7)
    }
}
