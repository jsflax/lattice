import Foundation
import Testing
@testable import Lattice
import CLatticeTestSQLite
import LatticeSwiftCppBridge

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
        var local = CheckedTransactionItem(); local.value = 7
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
        // ATTACH replaces the unqualified table with a union view. Re-fetch
        // the local row so its writes use the hydrated main-table binding.
        local = try #require(db.object(CheckedTransactionItem.self, globalId: localID))
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

    @Test func checkedBulkActuallyThrowsOnRealSecondInsertFailure() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let first = CheckedTransactionItem(); first.value = 1
        let second = CheckedTransactionItem(); second.value = 2
        try sqlite(url) {
            try sql($0, "CREATE TRIGGER checked_bulk_outcome BEFORE INSERT ON CheckedTransactionItem WHEN NEW.value = 2 AND EXISTS(SELECT 1 FROM CheckedTransactionItem WHERE value = 1) BEGIN SELECT RAISE(ABORT, 'checked-bulk-real-prefix'); END")
        }
        var failure: String?
        do { try db.add(contentsOf: [first, second]) }
        catch { failure = String(describing: error) }
        #expect(failure?.contains("checked-bulk-real-prefix") == true)
        // This uses the existing Core-owned bulk rollback, not a new graph or
        // caller-owned transaction atomicity guarantee.
        #expect(db.objects(CheckedTransactionItem.self).isEmpty)
        #expect(!first.isManaged && !second.isManaged)
    }

    @Test func closedOwnerDoesNotAcceptCheckedAddOrBulk() throws {
        let (db, url) = try database()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        db.close()
        let one = CheckedTransactionItem()
        let two = CheckedTransactionItem()
        #expect(throws: LatticeError.self) { try db.add(one) }
        #expect(throws: LatticeError.self) { try db.add(contentsOf: [two]) }
        #expect(!one.isManaged && !two.isManaged)
    }

    @Test func bridgeCapturePreservesValidEmptyAndUnavailableFailures() {
        defer { lattice.clear_bridge_outcome() }
        "".withCString { lattice.record_bridge_error($0) }
        let empty = _capturedBridgeFailure()
        #expect(empty != nil)
        #expect(empty == "")
        // This calls the actual Native unavailable-diagnostic branch; neither
        // a mock message nor a stored NULL can establish success.
        lattice.record_bridge_error(nil)
        #expect(_capturedBridgeFailure() == "C++ bridge failure (diagnostic unavailable)")
        lattice.clear_bridge_outcome()
        #expect(_capturedBridgeFailure() == nil)
    }


    @Test func invalidListFindPredicatesSurviveLaterSuccessAndRollbackEarlierWrite() throws {
        let (db, url, owner, original, _) = try listFixture()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let ownerID = try #require(owner.globalId)
        let links = owner._dynamicObject._ref.getLinkList(named: "items")
        for ordered in [false, true] {
            var queryFailure: String?
            var transactionFailure: String?
            do {
                try db.withTransaction {
                    owner.value = ordered ? 42 : 41
                    let result = ordered
                        ? links.findIndices(matching: nil, orderedBy: "missing_outcome_order_column", ascending: true)
                        : links.findWhere("missing_outcome_predicate_column = 1")
                    #expect(result.isEmpty)
                    queryFailure = db.lastQueryError()
                    #expect(queryFailure != nil)
                    #expect(links.size == 1) // real success clears current TLS only
                    #expect(db.lastQueryError() == nil)
                }
            } catch {
                #expect(error is LatticeError)
                transactionFailure = String(describing: error)
            }
            let firstFailure = try #require(queryFailure)
            #expect(transactionFailure?.contains(firstFailure) == true)
            db.retireAllGenerations()
            #expect(db.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 0)
            #expect(owner.items.count == 1)
            #expect(owner.items.first?.globalId == original.globalId)
        }
        #expect(links.findIndex(of: original._dynamicObject._ref) == 0)
        #expect(links.findWhere("value = 1") == [0])
        #expect(links.findIndices(matching: nil, orderedBy: "value", ascending: true) == [0])
        #expect(db.lastQueryError() == nil)
    }

}


extension CheckedTransactionTests {
    private func failingOwnerQuery(_ backend: any LatticeBackend) {
        _ = backend.objects(table: "missing_exact_owner_table", where: nil, orderBy: nil,
                            limit: nil, offset: nil, groupBy: nil, distinctBy: nil, params: [])
    }

    @Test func otherOwnerQueryFailureDoesNotPoisonActiveTransaction() throws {
        let (outer, outerURL) = try database()
        let (other, otherURL) = try database()
        defer {
            outer.close(); other.close()
            try? Lattice.delete(for: .init(fileURL: outerURL))
            try? Lattice.delete(for: .init(fileURL: otherURL))
        }
        let item = CheckedTransactionItem(); try outer.add(item)
        try outer.withTransaction {
            item.value = 31
            failingOwnerQuery(other.backend)
            #expect(other.lastQueryError()?.contains("missing_exact_owner_table") == true)
            _ = item.value // clears TLS; does not determine which scope owns the failure
        }
        outer.retireAllGenerations()
        #expect(value(outer) == 31)
    }

    @Test func otherOwnerPrimitiveFailureDoesNotPoisonActiveTransaction() throws {
        let (outer, outerURL) = try database()
        let (other, otherURL) = try database()
        defer {
            outer.close(); other.close()
            try? Lattice.delete(for: .init(fileURL: outerURL))
            try? Lattice.delete(for: .init(fileURL: otherURL))
        }
        let local = CheckedTransactionItem(); let foreign = CheckedTransactionItem()
        try outer.add(local); try other.add(foreign)
        try outer.withTransaction {
            local.value = 32
            foreign.increment("missing_exact_owner_column")
            #expect(other.lastQueryError()?.contains("missing_exact_owner_column") == true)
            _ = local.value
        }
        outer.retireAllGenerations(); other.retireAllGenerations()
        #expect(value(outer) == 32)
        #expect(value(other) == 0)
    }

    @Test func otherOwnerListFailureDoesNotPoisonActiveTransaction() throws {
        let (outer, outerURL) = try database()
        let (other, otherURL, parent, _, _) = try listFixture()
        defer {
            outer.close(); other.close()
            try? Lattice.delete(for: .init(fileURL: outerURL))
            try? Lattice.delete(for: .init(fileURL: otherURL))
        }
        let local = CheckedTransactionItem(); try outer.add(local)
        let links = parent._dynamicObject._ref.getLinkList(named: "items")
        try outer.withTransaction {
            local.value = 33
            #expect(links.object(at: 99) == nil)
            #expect(other.lastQueryError() != nil)
            #expect(links.size == 1) // a later real success clears TLS
        }
        outer.retireAllGenerations()
        #expect(value(outer) == 33)
    }

    @Test func differentSwiftBackendForSameNativeOwnerStillPoisonsTransaction() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem(); try db.add(item)
        let original = try #require(db.backend as? CxxBackend)
        let alias = CxxBackend(original.ref)
        #expect(ObjectIdentifier(alias) != ObjectIdentifier(original))
        #expect(alias._transactionOwnerIdentity.matches(original._transactionOwnerIdentity))
        var failure: String?
        do {
            try db.withTransaction {
                item.value = 34
                failingOwnerQuery(alias)
                #expect(alias.lastQueryError()?.contains("missing_exact_owner_table") == true)
                _ = item.value
                #expect(db.lastQueryError() == nil)
            }
        } catch { failure = String(describing: error) }
        #expect(failure?.contains("missing_exact_owner_table") == true)
        db.retireAllGenerations()
        #expect(value(db) == 0)
        try db.withTransaction { item.value = 35 }
        db.retireAllGenerations()
        #expect(value(db) == 35)
    }
}

@Model private final class CheckedTransactionObjectOwner {
    var value: Int = 0
    var child: CheckedTransactionItem?
}

@Union private enum CheckedTransactionChoice {
    case empty
    case text(value: String)
}

@Model private final class CheckedTransactionUnionOwner {
    var value: Int = 0
    var choice: CheckedTransactionChoice = .empty
}

extension CheckedTransactionTests {
    @Test func objectSetterFailureIsCapturedBeforeLaterSuccess() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checked-object-owner-\(UUID().uuidString).sqlite")
        let db = try Lattice(CheckedTransactionObjectOwner.self, CheckedTransactionItem.self,
                             configuration: .init(fileURL: url))
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let parent = CheckedTransactionObjectOwner(); try db.add(parent)
        let child = CheckedTransactionItem(); child.value = 51
        try sqlite(url) {
            try sql($0, "CREATE TRIGGER exact_owner_link BEFORE INSERT ON _CheckedTransactionObjectOwner_CheckedTransactionItem_child BEGIN SELECT RAISE(ABORT, 'exact-owner-object-failure'); END")
        }
        var failure: String?
        do {
            try db.withTransaction {
                parent.value = 36
                parent.child = child
                #expect(db.lastQueryError()?.contains("exact-owner-object-failure") == true)
                _ = parent.value
                #expect(db.lastQueryError() == nil)
            }
        } catch { failure = String(describing: error) }
        #expect(failure?.contains("exact-owner-object-failure") == true)
        db.retireAllGenerations()
        #expect(db.objects(CheckedTransactionObjectOwner.self).first?.value == 0)
        #expect(db.objects(CheckedTransactionItem.self).isEmpty)
    }

    @Test func unionSetterFailureIsCapturedBeforeLaterSuccess() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checked-union-owner-\(UUID().uuidString).sqlite")
        let db = try Lattice(CheckedTransactionUnionOwner.self, configuration: .init(fileURL: url))
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let parent = CheckedTransactionUnionOwner(); try db.add(parent)
        try sqlite(url) {
            try sql($0, "CREATE TRIGGER exact_owner_union BEFORE INSERT ON \(CheckedTransactionChoice.unionTableName) BEGIN SELECT RAISE(ABORT, 'exact-owner-union-failure'); END")
        }
        var failure: String?
        do {
            try db.withTransaction {
                parent.value = 37
                parent.choice = .text(value: "rejected")
                #expect(db.lastQueryError()?.contains("exact-owner-union-failure") == true)
                _ = parent.value
                #expect(db.lastQueryError() == nil)
            }
        } catch { failure = String(describing: error) }
        #expect(failure?.contains("exact-owner-union-failure") == true)
        db.retireAllGenerations()
        #expect(db.objects(CheckedTransactionUnionOwner.self).first?.value == 0)
    }
}


// The real handler runs synchronously on the failing call's thread. This box
// transports immutable facade/model references into its @Sendable closure;
// its short state lock is never held while calling SQL or a public API.
private final class CheckedCommitSuccessorProbe: @unchecked Sendable {
    let db: Lattice
    let item: CheckedTransactionItem
    let expectedThread = ObjectIdentifier(Thread.current)
    private let lock = NSLock()
    private var calls = 0
    private var firstMessage: String?
    private var setupFailure: String?
    private var completed = false
    private var ownedOnReturn = false
    private var sameThread = false

    init(db: Lattice, item: CheckedTransactionItem) { self.db = db; self.item = item }

    func replaceFailedTransaction(_ message: String) {
        lock.lock()
        calls += 1
        let first = calls == 1
        if first { firstMessage = message }
        lock.unlock()
        guard first else { return } // no recursive error-handler recovery
        let actualThread = ObjectIdentifier(Thread.current) == expectedThread
        db.rollbackTransaction()
        if let failure = db.lastQueryError() { finish(failure, actualThread); return }
        db.beginTransaction()
        if let failure = db.lastQueryError() { finish(failure, actualThread); return }
        item.value = 73 // the fault trigger applies only to the old value 99
        if let failure = db.lastQueryError() { finish(failure, actualThread); return }
        let owned = Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash)
        lock.lock()
        completed = true; ownedOnReturn = owned; sameThread = actualThread
        lock.unlock()
    }

    private func finish(_ failure: String, _ actualThread: Bool) {
        lock.lock(); setupFailure = failure; sameThread = actualThread; lock.unlock()
    }

    func snapshot() -> (Int, String?, String?, Bool, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (calls, firstMessage, setupFailure, completed, ownedOnReturn, sameThread)
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension CheckedTransactionTests {
    // Fixed existing-file probes: no CREATE, no wait/retry and no unfinalized
    // statements. Unknown raw-handle ending retains the exact store namespace
    // and exits before any Native/TempDB cleanup in this process.
    private func successorInspection<T>(_ url: URL,
                                        _ body: (OpaquePointer) throws -> T) throws -> T {
        let retainedStore = url.path.utf8CString
        let debtPrefix = Array("checked-successor raw-close-ending-debt store=".utf8)
        let hexDigits = Array("0123456789abcdef".utf8)
        var endingCode = Array(" sqlite_rc=0x00000000\n".utf8)
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        let connection = try #require(pointer)
        defer {
            let closeRC = sqlite3_close(connection)
            if closeRC != SQLITE_OK {
                for index in 0..<8 {
                    endingCode[13 + index] = hexDigits[Int((UInt32(bitPattern: closeRC) >> ((7 - index) * 4)) & 15)]
                }
                debtPrefix.withUnsafeBytes { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
                retainedStore.withUnsafeBytes { _ = write(STDERR_FILENO, $0.baseAddress, $0.count - 1) }
                endingCode.withUnsafeBytes { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
                _exit(94)
            }
        }
        try #require(rc == SQLITE_OK)
        try #require(sqlite3_busy_timeout(connection, 0) == SQLITE_OK)
        return try body(connection)
    }

    @Test func failedCommitHandlerSuccessorSurvivesOldCheckedCleanup() throws {
        let (db, url) = try database()
        defer {
            db.backend.setOnQueryError(nil) // break the retained callback cycle first
            db.rollbackTransaction()       // bounded best-effort ending on any assertion/throw
            db.close()
            try? Lattice.delete(for: .init(fileURL: url))
        }
        let item = CheckedTransactionItem(); try db.add(item)
        try sqlite(url) { connection in
            try sql(connection, "CREATE TABLE checked_successor_guard (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES CheckedTransactionItem(id) DEFERRABLE INITIALLY DEFERRED)")
            try sql(connection, "CREATE TRIGGER checked_successor_commit AFTER UPDATE OF value ON CheckedTransactionItem WHEN NEW.value = 99 BEGIN INSERT INTO checked_successor_guard(parent) VALUES(-1); END")
        }
        let probe = CheckedCommitSuccessorProbe(db: db, item: item)
        db.onQueryError { probe.replaceFailedTransaction($0) }
        var originalFailure: String?
        do {
            try db.withTransaction { item.value = 99 }
            Issue.record("Expected the old transaction's real deferred-FK COMMIT refusal")
        } catch { originalFailure = String(describing: error) }
        let observed = probe.snapshot()
        #expect(observed.0 == 1)
        #expect(observed.1?.localizedCaseInsensitiveContains("foreign key") == true)
        #expect(originalFailure?.contains(observed.1 ?? "<missing actual COMMIT failure>") == true)
        #expect(observed.2 == nil)
        #expect(observed.3 && observed.4 && observed.5)
        #expect(Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        #expect(item.value == 73)
        // A second connection must find a real uncommitted writer, not merely
        // a stale Swift flag or retained model value. Undo only its own probe
        // BEGIN if the expected exclusion was absent, before reporting it.
        try successorInspection(url) { connection in
            let beginRC = sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil)
            if beginRC == SQLITE_OK {
                let rollbackRC = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
                #expect(rollbackRC == SQLITE_OK)
            }
            #expect(beginRC == SQLITE_BUSY)
        }
        // The successor belongs to its public caller. Only this independent
        // explicit commit may end it after withTransaction already threw.
        db.commitTransaction()
        #expect(db.lastQueryError() == nil)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        #expect(probe.snapshot().0 == 1)
        try successorInspection(url) { connection in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(connection, "SELECT (SELECT value FROM CheckedTransactionItem), (SELECT COUNT(*) FROM checked_successor_guard)", -1, &statement, nil) == SQLITE_OK)
            let query = try #require(statement)
            defer { #expect(sqlite3_finalize(query) == SQLITE_OK) }
            try #require(sqlite3_step(query) == SQLITE_ROW)
            #expect(sqlite3_column_int64(query, 0) == 73)
            #expect(sqlite3_column_int64(query, 1) == 0)
            #expect(sqlite3_step(query) == SQLITE_DONE)
        }
    }
}


extension CheckedTransactionTests {
    @Test func bodyEndedOriginalCannotReportSuccessByCommittingItsSuccessor() throws {
        let (db, url) = try database()
        defer {
            db.rollbackTransaction()
            db.close()
            try? Lattice.delete(for: .init(fileURL: url))
        }
        let item = CheckedTransactionItem(); try db.add(item)
        var refusal: String?
        do {
            try db.withTransaction {
                item.value = 19
                db.rollbackTransaction()
                try #require(db.lastQueryError() == nil)
                db.beginTransaction()
                try #require(db.lastQueryError() == nil)
                item.value = 41
                try #require(db.lastQueryError() == nil)
            }
            Issue.record("A checked transaction whose original was rolled back cannot report a committed result")
        } catch { refusal = String(describing: error) }
        #expect(refusal != nil)
        #expect(Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        #expect(item.value == 41)
        // A real writer still belongs to the explicit successor's caller.
        // Neither the old commit nor its catch cleanup may settle it.
        try successorInspection(url) { connection in
            let beginRC = sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil)
            if beginRC == SQLITE_OK {
                #expect(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            }
            #expect(beginRC == SQLITE_BUSY)
        }
        db.commitTransaction()
        #expect(db.lastQueryError() == nil)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        try successorInspection(url) { connection in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(connection, "SELECT value FROM CheckedTransactionItem", -1, &statement, nil) == SQLITE_OK)
            let query = try #require(statement)
            defer { #expect(sqlite3_finalize(query) == SQLITE_OK) }
            try #require(sqlite3_step(query) == SQLITE_ROW)
            #expect(sqlite3_column_int64(query, 0) == 41)
            #expect(sqlite3_step(query) == SQLITE_DONE)
        }
    }
}


extension CheckedTransactionTests {
    @Test func failedBulkPreservesRealExplicitCallerPrefixAndUnmanagedOffers() throws {
        let (db, url) = try database()
        defer {
            db.rollbackTransaction()
            db.close()
            try? Lattice.delete(for: .init(fileURL: url))
        }
        try successorInspection(url) { connection in
            try sql(connection, "CREATE TRIGGER checked_explicit_bulk BEFORE INSERT ON CheckedTransactionItem WHEN NEW.value = 2 AND EXISTS(SELECT 1 FROM CheckedTransactionItem WHERE value = 1) BEGIN SELECT RAISE(ABORT, 'checked-explicit-bulk-prefix'); END")
        }
        db.beginTransaction()
        try #require(db.lastQueryError() == nil)
        let prefix = CheckedTransactionItem(); prefix.value = 41
        try db.add(prefix)
        let first = CheckedTransactionItem(); first.value = 1
        let second = CheckedTransactionItem(); second.value = 2
        var failure: String?
        do { try db.add(contentsOf: [first, second]) }
        catch { failure = String(describing: error) }
        #expect(failure?.contains("checked-explicit-bulk-prefix") == true)
        #expect(!first.isManaged && !second.isManaged)
        #expect(prefix.isManaged)
        #expect(Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        #expect(db.objects(CheckedTransactionItem.self).map(\.value) == [41])
        try successorInspection(url) { connection in
            let beginRC = sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil)
            if beginRC == SQLITE_OK {
                #expect(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            }
            #expect(beginRC == SQLITE_BUSY)
        }
        db.commitTransaction()
        #expect(db.lastQueryError() == nil)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: db.backend.identityHash))
        try successorInspection(url) { connection in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(connection, "SELECT value FROM CheckedTransactionItem ORDER BY id", -1, &statement, nil) == SQLITE_OK)
            let query = try #require(statement)
            defer { #expect(sqlite3_finalize(query) == SQLITE_OK) }
            try #require(sqlite3_step(query) == SQLITE_ROW)
            #expect(sqlite3_column_int64(query, 0) == 41)
            #expect(sqlite3_step(query) == SQLITE_DONE)
        }
    }
}


extension CheckedTransactionTests {
    private func receiptAlias(_ backend: CxxBackend, of db: Lattice) -> Lattice {
        Lattice(backend: backend, configuration: db.configuration,
                modelTypes: [CheckedTransactionItem.self, CheckedTransactionListOwner.self],
                schema: nil, isolation: nil, observerActorDelivery: nil)
    }

    @Test func explicitCloseRetiresExactFrameThroughDifferentNativeAlias() throws {
        let (db,url)=try database()
        defer { db.close(); try? Lattice.delete(for:.init(fileURL:url)) }
        let native=try #require(db.backend as? CxxBackend)
        let sibling=CxxBackend(native.ref)
        let alias=receiptAlias(sibling,of:db)
        #expect(ObjectIdentifier(native) != ObjectIdentifier(sibling))
        db.beginTransaction(); try #require(db.lastQueryError()==nil)
        let held=try #require(Lattice._explicitTxnFrame(backend:native))
        #expect(Lattice._explicitTxnFrame(backend:sibling) === held)
        _=alias.closeChecked()
        #expect(native._isClosed && sibling._isClosed)
        #expect(native.lastCloseResult==nil) // wrapper-local cache is not shared close truth
        #expect(Lattice._explicitTxnFrame(backend:native)==nil)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash:native.identityHash))
        withExtendedLifetime(held) {} // retained frame does not keep Native writer alive after true owner drop
    }

    @Test func closeWinningBetweenAcceptedBeginAndMapPublicationCannotLeaveFrame() throws {
        let (db,url)=try database()
        defer { db.close(); try? Lattice.delete(for:.init(fileURL:url)) }
        let native=try #require(db.backend as? CxxBackend)
        let alias=receiptAlias(CxxBackend(native.ref),of:db)
        let begin=native.beginLegacyTransactionReceipt()
        try #require(begin.failure==nil && begin.receipt.isValid())
        let frame=TransactionReceiptFrame(native:begin.receipt,ownerIdentity:native._transactionOwnerIdentity)
        try #require(!native._isClosed) // actual first publication check has passed
        _=alias.closeChecked() // exact real alias close wins before map update
        // Actual production publication tail, without a mock outcome, callback
        // hook or scheduler timing assumption. Its post-check must retire it.
        Lattice._publishExplicitTxnFrame(backend:native,frame:frame)
        #expect(native._isClosed)
        #expect(Lattice._explicitTxnFrame(backend:native)==nil)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash:native.identityHash))
    }

    @Test func recordAfterActualCloseRefusesPublicationAndCannotEraseOtherOwner() throws {
        let (db,url)=try database(); let (other,otherURL)=try database()
        defer {
            db.close(); other.rollbackTransaction(); other.close()
            try? Lattice.delete(for:.init(fileURL:url)); try? Lattice.delete(for:.init(fileURL:otherURL))
        }
        let native=try #require(db.backend as? CxxBackend)
        let begin=native.beginLegacyTransactionReceipt()
        try #require(begin.failure==nil && begin.receipt.isValid())
        let frame=TransactionReceiptFrame(native:begin.receipt,ownerIdentity:native._transactionOwnerIdentity)
        other.beginTransaction(); try #require(other.lastQueryError()==nil)
        let otherFrame=try #require(Lattice._explicitTxnFrame(backend:other.backend))
        _=db.closeChecked()
        Lattice._recordExplicitTxnBegin(backend:native,frame:frame)
        #expect(Lattice._explicitTxnFrame(backend:native)==nil)
        #expect(Lattice._explicitTxnFrame(backend:other.backend) === otherFrame)
        other.rollbackTransaction(); #expect(other.lastQueryError()==nil)
    }

    @Test func liveModelMintedBackendCanSettleAfterInitialFacadeScopeEnds() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("checked-txn-alias-\(UUID().uuidString).sqlite")
        let item=CheckedTransactionItem()
        var firstBackendID:ObjectIdentifier?
        var held:TransactionReceiptFrame?
        do {
            let db=try Lattice(CheckedTransactionItem.self,CheckedTransactionListOwner.self,configuration:.init(fileURL:url,busyTimeoutMs:100))
            try db.add(item); db.beginTransaction(); try #require(db.lastQueryError()==nil)
            firstBackendID=ObjectIdentifier(try #require(db.backend as? CxxBackend))
            held=try #require(Lattice._explicitTxnFrame(backend:db.backend))
            item.value=83
        } // no public close: the real managed object still owns its Native owner
        let minted=try #require(item._dynamicObject._ref.lattice as? CxxBackend)
        #expect(ObjectIdentifier(minted) != firstBackendID)
        let alias=Lattice(backend:minted,configuration:.init(fileURL:url,busyTimeoutMs:100),
                          modelTypes:[CheckedTransactionItem.self,CheckedTransactionListOwner.self],
                          schema:nil,isolation:nil,observerActorDelivery:nil)
        defer { alias.close(); try? Lattice.delete(for:.init(fileURL:url)) }
        #expect(Lattice._explicitTxnFrame(backend:minted) === held)
        alias.commitTransaction(); #expect(alias.lastQueryError()==nil)
        #expect(Lattice._explicitTxnFrame(backend:minted)==nil)
        try successorInspection(url) { connection in
            var statement:OpaquePointer?
            try #require(sqlite3_prepare_v2(connection,"SELECT value FROM CheckedTransactionItem",-1,&statement,nil)==SQLITE_OK)
            let query=try #require(statement)
            defer { #expect(sqlite3_finalize(query)==SQLITE_OK) }
            try #require(sqlite3_step(query)==SQLITE_ROW); #expect(sqlite3_column_int64(query,0)==83)
            #expect(sqlite3_step(query)==SQLITE_DONE)
        }
        withExtendedLifetime(held) {}
    }
}
