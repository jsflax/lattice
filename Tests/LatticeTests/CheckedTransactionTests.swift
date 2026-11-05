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
        let url = testTemporaryDirectory
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

    private func withTwoDatabases(_ body: (Lattice, Lattice) throws -> Void) throws {
        let (outer, outerURL) = try database()
        defer { outer.close(); try? Lattice.delete(for: .init(fileURL: outerURL)) }
        let (inner, innerURL) = try database()
        defer { inner.close(); try? Lattice.delete(for: .init(fileURL: innerURL)) }
        try body(outer, inner)
    }

    @Test func distinctStoreNestedTransactionsCommitBothOwners() throws {
        try withTwoDatabases { outer, inner in
            let outerItem = CheckedTransactionItem()
            let innerItem = CheckedTransactionItem()
            try outer.add(outerItem); try inner.add(innerItem)
            var innerBodyEntered = false
            try outer.withTransaction {
                outerItem.value = 5
                try inner.withTransaction {
                    innerBodyEntered = true
                    innerItem.value = 99
                    // A remains an active checked owner while B is on top.
                    let insertedOuter = try outer.insertLocalMetadataIfAbsent("outer", namespace: "checked.nesting", key: "receipt")
                    let insertedInner = try inner.insertLocalMetadataIfAbsent("inner", namespace: "checked.nesting", key: "receipt")
                    #expect(insertedOuter)
                    #expect(insertedInner)
                }
                outerItem.increment("value")
            }
            #expect(innerBodyEntered)
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(value(outer) == 6)
            #expect(value(inner) == 99)
            #expect(try outer.localMetadata(namespace: "checked.nesting", key: "receipt") == "outer")
            #expect(try inner.localMetadata(namespace: "checked.nesting", key: "receipt") == "inner")
            try inner.withTransaction { innerItem.value = 7 }
            inner.retireAllGenerations()
            #expect(value(inner) == 7)
        }
    }

    @Test func sameHandleReentryBelowAnotherScopeDoesNotEnterBody() throws {
        try withTwoDatabases { outer, inner in
            let outerItem = CheckedTransactionItem()
            let innerItem = CheckedTransactionItem()
            try outer.add(outerItem); try inner.add(innerItem)
            var reentered = false
            try outer.withTransaction {
                outerItem.value = 3
                try inner.withTransaction {
                    innerItem.value = 4
                    #expect(throws: LatticeError.self) {
                        try outer.withTransaction { reentered = true }
                    }
                    #expect(!reentered)
                }
                outerItem.increment("value")
            }
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(!reentered)
            #expect(value(outer) == 4)
            #expect(value(inner) == 4)
        }
    }

    @Test func caughtInnerWriteFailureRollsBackOnlyInnerStore() throws {
        try withTwoDatabases { outer, inner in
            let outerItem = CheckedTransactionItem()
            let innerItem = CheckedTransactionItem()
            try outer.add(outerItem); try inner.add(innerItem)
            var entered = false
            try outer.withTransaction {
                outerItem.value = 2
                #expect(throws: LatticeError.self) {
                    try inner.withTransaction {
                        entered = true
                        innerItem.value = 9
                        innerItem.increment("missing_column")
                        _ = innerItem.value
                    }
                }
                outerItem.increment("value")
            }
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(entered)
            #expect(value(outer) == 3)
            #expect(value(inner) == 0)
            try inner.withTransaction { innerItem.value = 8 }
            inner.retireAllGenerations()
            #expect(value(inner) == 8)
        }
    }

    @Test func failedInnerBeginNeverEntersBodyOrPoisonsOuterStore() throws {
        let (outer, outerURL) = try database()
        defer { outer.close(); try? Lattice.delete(for: .init(fileURL: outerURL)) }
        let (inner, innerURL) = try database()
        defer { inner.close(); try? Lattice.delete(for: .init(fileURL: innerURL)) }
        let outerItem = CheckedTransactionItem()
        let innerItem = CheckedTransactionItem()
        try outer.add(outerItem); try inner.add(innerItem)
        var entered = false
        try sqlite(innerURL) { writer in
            try sql(writer, "BEGIN IMMEDIATE")
            defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }
            try outer.withTransaction {
                outerItem.value = 5
                #expect(throws: LatticeError.self) {
                    try inner.withTransaction { entered = true; innerItem.value = 9 }
                }
                #expect(!entered)
                #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: inner.backend.identityHash))
                outerItem.increment("value")
            }
        }
        outer.retireAllGenerations(); inner.retireAllGenerations()
        #expect(!entered)
        #expect(value(outer) == 6)
        #expect(value(inner) == 0)
        try inner.withTransaction { innerItem.value = 7 }
        inner.retireAllGenerations()
        #expect(value(inner) == 7)
    }

    @Test func committedInnerStoreSurvivesThrownOuterBody() throws {
        enum Stop: Error { case rollbackOuter }
        try withTwoDatabases { outer, inner in
            let outerItem = CheckedTransactionItem()
            let innerItem = CheckedTransactionItem()
            try outer.add(outerItem); try inner.add(innerItem)
            #expect(throws: Stop.self) {
                try outer.withTransaction {
                    outerItem.value = 10
                    try inner.withTransaction { innerItem.value = 20 }
                    throw Stop.rollbackOuter
                }
            }
            // Distinct stores commit independently; nesting is not a
            // cross-database atomic transaction.
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(value(outer) == 0)
            #expect(value(inner) == 20)
            try outer.withTransaction { outerItem.value = 11 }
            outer.retireAllGenerations()
            #expect(value(outer) == 11)
        }
    }

    enum OuterFailure: CaseIterable {
        case increment, query, listRead, listWrite, metadata
    }

    @Test(arguments: OuterFailure.allCases)
    func outerFailureWhileInnerScopeIsActiveRollsBackOnlyOuter(_ failure: OuterFailure) throws {
        let (outer, outerURL, owner, original, replacement) = try listFixture()
        defer { outer.close(); try? Lattice.delete(for: .init(fileURL: outerURL)) }
        let (inner, innerURL) = try database()
        defer { inner.close(); try? Lattice.delete(for: .init(fileURL: innerURL)) }
        let innerItem = CheckedTransactionItem()
        try inner.add(innerItem)
        let ownerID = try #require(owner.globalId)
        let links = owner._dynamicObject._ref.getLinkList(named: "items")
        var entered = false
        var firstFailure: String?
        var transactionFailure: String?
        do {
            try outer.withTransaction {
                owner.value = 40
                try inner.withTransaction {
                    entered = true
                    innerItem.value = 70
                    switch failure {
                    case .increment:
                        owner.increment("missing_column")
                    case .query:
                        _ = outer.backend.count(table: "CheckedTransactionListOwner", where: "missing_column = 1",
                                                groupBy: nil, distinctBy: nil, params: [])
                    case .listRead:
                        #expect(links.object(at: 99) == nil)
                    case .listWrite:
                        links.setObject(at: 99, replacement._dynamicObject._ref)
                    case .metadata:
                        _ = try? outer.insertLocalMetadataIfAbsent(String(repeating: "x", count: 65_537),
                                                                   namespace: "checked.nesting", key: "oversized")
                    }
                    firstFailure = outer.lastQueryError()
                    #expect(firstFailure != nil)
                    // A successful query must not erase A's latched error,
                    // and that error must not be attributed to inner B.
                    #expect(links.size == 1)
                    #expect(outer.lastQueryError() == nil)
                    innerItem.increment("value")
                }
            }
        } catch {
            #expect(error is LatticeError)
            transactionFailure = String(describing: error)
        }
        #expect(entered)
        let recorded = try #require(firstFailure)
        #expect(transactionFailure?.contains(recorded) == true)
        outer.retireAllGenerations(); inner.retireAllGenerations()
        #expect(outer.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 0)
        #expect(owner.items.snapshot().map { $0.globalId } == [original.globalId])
        #expect(value(inner) == 71)
        #expect(try outer.localMetadata(namespace: "checked.nesting", key: "oversized") == nil)
        try outer.withTransaction { owner.value = 2 }
        outer.retireAllGenerations()
        #expect(outer.object(CheckedTransactionListOwner.self, globalId: ownerID)?.value == 2)
    }

    enum StoreAlias: CaseIterable { case samePath, symbolicLink, hardLink }

    @Test(arguments: StoreAlias.allCases)
    func samePhysicalStoreAliasIsRejectedBeforeBegin(_ kind: StoreAlias) throws {
        let (seed, url) = try database()
        try seed.add(CheckedTransactionItem())
        seed.close()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let aliasURL = kind == .samePath ? url : url.deletingLastPathComponent()
            .appendingPathComponent("checked-alias-\(UUID().uuidString).sqlite")
        switch kind {
        case .samePath: break
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: url)
        case .hardLink:
            try FileManager.default.linkItem(at: url, to: aliasURL)
        }
        defer {
            if aliasURL != url { try? Lattice.delete(for: .init(fileURL: aliasURL)) }
        }
        let outer = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self,
                                configuration: .init(fileURL: url, busyTimeoutMs: 100))
        defer { outer.close() }
        let alias = try Lattice(independentFor: [CheckedTransactionItem.self, CheckedTransactionListOwner.self],
                                configuration: .init(fileURL: aliasURL, busyTimeoutMs: 100))
        defer { alias.close() }
        #expect(outer.backend.identityHash != alias.backend.identityHash)
        let item = try #require(outer.objects(CheckedTransactionItem.self).first)
        var entered = false
        var rejection: String?
        try outer.withTransaction {
            item.value = 5
            do {
                try alias.withTransaction { entered = true }
            } catch {
                #expect(error is LatticeError)
                rejection = String(describing: error)
            }
            #expect(!entered)
            // A SQLITE_BUSY failure would also avoid the body. Require the
            // intentional admission refusal rather than waiting for BEGIN.
            #expect(rejection?.localizedCaseInsensitiveContains("nested") == true)
            item.increment("value")
        }
        outer.retireAllGenerations()
        #expect(value(outer) == 6)
        #expect(!Lattice._threadHoldsExplicitTransaction(identityHash: alias.backend.identityHash))
    }

    @Test func unrelatedSameFileHandleFailureDoesNotPoisonCheckedOwner() throws {
        let (outer, url) = try database()
        defer { outer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let item = CheckedTransactionItem()
        try outer.add(item)
        let other = try Lattice(independentFor: [CheckedTransactionItem.self, CheckedTransactionListOwner.self],
                                configuration: .init(fileURL: url, busyTimeoutMs: 100))
        defer { other.close() }
        #expect(outer.backend.identityHash != other.backend.identityHash)
        try outer.withTransaction {
            item.value = 4
            _ = other.backend.count(table: "CheckedTransactionItem", where: "missing_column = 1",
                                    groupBy: nil, distinctBy: nil, params: [])
            #expect(other.lastQueryError() != nil)
            item.increment("value")
        }
        outer.retireAllGenerations()
        #expect(value(outer) == 5)
    }

    @Test func checkedOtherStoreDoesNotAuthorizeLegacyMetadataTransaction() throws {
        try withTwoDatabases { outer, inner in
            let outerItem = CheckedTransactionItem()
            let innerItem = CheckedTransactionItem()
            try outer.add(outerItem); try inner.add(innerItem)
            try outer.withTransaction {
                outerItem.value = 4
                try inner.transaction {
                    #expect(Lattice._threadHoldsExplicitTransaction(identityHash: inner.backend.identityHash))
                    #expect(throws: LatticeError.self) {
                        try inner.insertLocalMetadataIfAbsent("forbidden", namespace: "checked.nesting", key: "receipt")
                    }
                    innerItem.value = 6
                }
                #expect(try outer.insertLocalMetadataIfAbsent("allowed", namespace: "checked.nesting", key: "receipt"))
            }
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(value(outer) == 4)
            #expect(value(inner) == 6)
            #expect(try inner.localMetadata(namespace: "checked.nesting", key: "receipt") == nil)
            #expect(try outer.localMetadata(namespace: "checked.nesting", key: "receipt") == "allowed")
        }
    }

    @Test func uncaughtInnerFailureRollsBackBothOwnersAndRestoresScopes() throws {
        try withTwoDatabases { outer, inner in
            let outerItem = CheckedTransactionItem()
            let innerItem = CheckedTransactionItem()
            try outer.add(outerItem); try inner.add(innerItem)
            var entered = false
            #expect(throws: LatticeError.self) {
                try outer.withTransaction {
                    outerItem.value = 3
                    try inner.withTransaction {
                        entered = true
                        innerItem.value = 4
                        innerItem.increment("missing_column")
                        _ = innerItem.value
                    }
                }
            }
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(entered)
            #expect(value(outer) == 0)
            #expect(value(inner) == 0)
            try outer.withTransaction {
                outerItem.value = 5
                try inner.withTransaction { innerItem.value = 6 }
            }
            outer.retireAllGenerations(); inner.retireAllGenerations()
            #expect(value(outer) == 5)
            #expect(value(inner) == 6)
        }
    }

    @Test func caughtInnerCommitFailureRollsBackInnerAndAllowsBothStoresToRecover() throws {
        let (outer, outerURL) = try database()
        defer { outer.close(); try? Lattice.delete(for: .init(fileURL: outerURL)) }
        let (inner, innerURL) = try database()
        defer { inner.close(); try? Lattice.delete(for: .init(fileURL: innerURL)) }
        let outerItem = CheckedTransactionItem()
        let innerItem = CheckedTransactionItem()
        try outer.add(outerItem); try inner.add(innerItem)
        try sqlite(innerURL) { connection in
            try sql(connection, "CREATE TABLE commit_guard (id INTEGER PRIMARY KEY, globalId TEXT, parent INTEGER REFERENCES CheckedTransactionItem(id) DEFERRABLE INITIALLY DEFERRED)")
            try sql(connection, "CREATE TRIGGER fail_commit AFTER UPDATE OF value ON CheckedTransactionItem BEGIN INSERT INTO commit_guard (parent) VALUES (-1); END")
        }
        var bodyCompleted = false
        var failure: String?
        try outer.withTransaction {
            outerItem.value = 5
            do {
                try inner.withTransaction {
                    innerItem.value = 99
                    bodyCompleted = true
                }
            } catch {
                #expect(error is LatticeError)
                failure = String(describing: error)
            }
            #expect(bodyCompleted)
            #expect(failure?.localizedCaseInsensitiveContains("foreign key") == true)
            outerItem.increment("value")
        }
        outer.retireAllGenerations(); inner.retireAllGenerations()
        #expect(value(outer) == 6)
        #expect(value(inner) == 0)
        try sqlite(innerURL) { try sql($0, "DROP TRIGGER fail_commit") }
        try outer.withTransaction {
            outerItem.value = 7
            try inner.withTransaction { innerItem.value = 8 }
        }
        outer.retireAllGenerations(); inner.retireAllGenerations()
        #expect(value(outer) == 7)
        #expect(value(inner) == 8)
    }

    @Test func namedMemoryAliasIsRejectedBeforeBegin() throws {
        let configuration = Lattice.Configuration(storage: .memory(named: "checked-shared-\(UUID().uuidString)"),
                                                   busyTimeoutMs: 100)
        let outer = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self, configuration: configuration)
        defer { outer.close() }
        let alias = try Lattice(independentFor: [CheckedTransactionItem.self, CheckedTransactionListOwner.self],
                                configuration: configuration)
        defer { alias.close() }
        #expect(outer.backend.identityHash != alias.backend.identityHash)
        let item = CheckedTransactionItem()
        try outer.add(item)
        var entered = false
        var rejection: String?
        try outer.withTransaction {
            item.value = 3
            do {
                try alias.withTransaction { entered = true }
            } catch {
                #expect(error is LatticeError)
                rejection = String(describing: error)
            }
            #expect(!entered)
            #expect(rejection?.localizedCaseInsensitiveContains("nested") == true)
            item.increment("value")
        }
        outer.retireAllGenerations()
        #expect(value(outer) == 4)
    }

    @Test func differentNamedMemoryStoresCanNestAndCommit() throws {
        let outer = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self,
                                configuration: .init(storage: .memory(named: "checked-outer-\(UUID().uuidString)")))
        defer { outer.close() }
        let inner = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self,
                                configuration: .init(storage: .memory(named: "checked-inner-\(UUID().uuidString)")))
        defer { inner.close() }
        let outerItem = CheckedTransactionItem()
        let innerItem = CheckedTransactionItem()
        try outer.add(outerItem); try inner.add(innerItem)
        try outer.withTransaction {
            outerItem.value = 1
            try inner.withTransaction { innerItem.value = 2 }
        }
        outer.retireAllGenerations(); inner.retireAllGenerations()
        #expect(value(outer) == 1)
        #expect(value(inner) == 2)
    }

    @Test func structuralPreparationAndSyncAuthorizationStillRequireTheirOwnScope() throws {
        try withTwoDatabases { outer, inner in
            let item = CheckedTransactionItem()
            try outer.add(item)
            var authorizationEntered = false
            try outer.withTransaction {
                item.value = 4
                #expect(throws: LatticeError.self) { try inner.prepareForAuditedWrites() }
                let authorized = inner._authorizeSyncWrite {
                    authorizationEntered = true
                    return true
                }
                #expect(!authorized)
                #expect(!authorizationEntered)
                item.increment("value")
            }
            outer.retireAllGenerations()
            #expect(value(outer) == 5)
            #expect(!(try inner.prepareForAuditedWrites()))
            var nestedBodyEntered = false
            let syncAuthorized = outer._authorizeSyncWrite {
                #expect(throws: LatticeError.self) {
                    try inner.withTransaction { nestedBodyEntered = true }
                }
                return true
            }
            #expect(syncAuthorized)
            #expect(!nestedBodyEntered)
        }
    }

    @Test func attachmentStateIsSharedWithEarlierFacadeCopiesAndDetachRestoresNesting() throws {
        var (outer, outerURL) = try database()
        defer { outer.close(); try? Lattice.delete(for: .init(fileURL: outerURL)) }
        let (attached, attachedURL) = try database()
        defer { attached.close(); try? Lattice.delete(for: .init(fileURL: attachedURL)) }
        let (inner, innerURL) = try database()
        defer { inner.close(); try? Lattice.delete(for: .init(fileURL: innerURL)) }
        let copiedBeforeAttach = outer
        let innerItem = CheckedTransactionItem()
        try inner.add(innerItem)
        try outer.attach(lattice: attached)
        var enteredFromAttachedParent = false
        try copiedBeforeAttach.withTransaction {
            #expect(throws: LatticeError.self) {
                try inner.withTransaction { enteredFromAttachedParent = true }
            }
        }
        var enteredAttachedChild = false
        try inner.withTransaction {
            #expect(throws: LatticeError.self) {
                try copiedBeforeAttach.withTransaction { enteredAttachedChild = true }
            }
            innerItem.value = 3
        }
        #expect(!enteredFromAttachedParent)
        #expect(!enteredAttachedChild)
        inner.retireAllGenerations()
        #expect(value(inner) == 3)
        try outer.detach(lattice: attached)
        var nestedAfterDetach = false
        try copiedBeforeAttach.withTransaction {
            try inner.withTransaction {
                nestedAfterDetach = true
                innerItem.value = 4
            }
        }
        #expect(nestedAfterDetach)
        inner.retireAllGenerations()
        #expect(value(inner) == 4)
    }

    @MainActor private final class ConcurrentOpenResult {
        var store: Lattice?
    }

    private final class WeakCheckedBackend {
        weak var value: (any LatticeBackend)?
        init(_ value: any LatticeBackend) { self.value = value }
    }

    @Test @MainActor func concurrentCachedOpensShareAttachmentAdmission() async throws {
        let url = testTemporaryDirectory.appendingPathComponent("checked-concurrent-\(UUID().uuidString).sqlite")
        let configuration = Lattice.Configuration(fileURL: url, busyTimeoutMs: 100)
        let firstResult = ConcurrentOpenResult(), secondResult = ConcurrentOpenResult()
        defer {
            firstResult.store?.close(); secondResult.store?.close()
            try? Lattice.delete(for: configuration)
        }
        // Both opens use the same destination actor/scheduler and configuration,
        // the cache-sharing contract exercised by AsyncLocalOpenTests.
        let firstOpen = Task { @MainActor in
            firstResult.store = try await Lattice.openLocal(
                for: [CheckedTransactionItem.self, CheckedTransactionListOwner.self], configuration: configuration)
        }
        let secondOpen = Task { @MainActor in
            secondResult.store = try await Lattice.openLocal(
                for: [CheckedTransactionItem.self, CheckedTransactionListOwner.self], configuration: configuration)
        }
        // Join both real opens, including on failure, before any close/cleanup.
        let firstOutcome = await firstOpen.result
        let secondOutcome = await secondOpen.result
        try firstOutcome.get(); try secondOutcome.get()
        var first = try #require(firstResult.store)
        let second = try #require(secondResult.store)
        #expect(first.isolation === MainActor.shared)
        #expect(second.isolation === MainActor.shared)
        #expect(first.backend.identityHash == second.backend.identityHash)
        let (attached, attachedURL) = try database()
        defer { attached.close(); try? Lattice.delete(for: .init(fileURL: attachedURL)) }
        let (independent, independentURL) = try database()
        defer { independent.close(); try? Lattice.delete(for: .init(fileURL: independentURL)) }
        let independentItem = CheckedTransactionItem()
        try independent.add(independentItem)
        try first.attach(lattice: attached)
        var enteredWhileAttached = false
        try second.withTransaction {
            #expect(throws: LatticeError.self) {
                try independent.withTransaction { enteredWhileAttached = true }
            }
        }
        #expect(!enteredWhileAttached)
        try first.detach(lattice: attached)
        var enteredAfterDetach = false
        try second.withTransaction {
            try independent.withTransaction {
                enteredAfterDetach = true
                independentItem.value = 8
            }
        }
        independent.retireAllGenerations()
        #expect(enteredAfterDetach)
        #expect(value(independent) == 8)
    }

    @Test func managedObjectRetainsAttachedCoreAcrossFacadeExpirationAndRecovery() throws {
        let url = testTemporaryDirectory.appendingPathComponent("checked-recovered-\(UUID().uuidString).sqlite")
        let configuration = Lattice.Configuration(fileURL: url, busyTimeoutMs: 100)
        defer { try? Lattice.delete(for: configuration) }
        let (attached, attachedURL) = try database()
        defer { attached.close(); try? Lattice.delete(for: .init(fileURL: attachedURL)) }
        let (independent, independentURL) = try database()
        defer { independent.close(); try? Lattice.delete(for: .init(fileURL: independentURL)) }
        let independentItem = CheckedTransactionItem()
        try independent.add(independentItem)
        func retainOnlyManagedObject() throws -> (CheckedTransactionItem, Int64, WeakCheckedBackend) {
            var owner = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self,
                                    configuration: configuration)
            let item = CheckedTransactionItem(); item.value = 7
            try owner.add(item)
            try owner.attach(lattice: attached)
            // Deliberately do not close: the managed object retains Core's
            // shared_ptr while every Swift facade and its StoreState expires.
            return (item, owner.backend.identityHash, WeakCheckedBackend(owner.backend))
        }
        let (retainedItem, nativeIdentity, expiredBackend) = try retainOnlyManagedObject()
        #expect(expiredBackend.value == nil, "the test must release all Swift facades before cached recovery")
        try withExtendedLifetime(retainedItem) {
            var recovered = try Lattice(CheckedTransactionItem.self, CheckedTransactionListOwner.self,
                                        configuration: configuration)
            defer { recovered.close() }
            #expect(recovered.backend.identityHash == nativeIdentity)
            var enteredWhileAttached = false
            try recovered.withTransaction {
                #expect(throws: LatticeError.self) {
                    try independent.withTransaction { enteredWhileAttached = true }
                }
            }
            #expect(!enteredWhileAttached)
            // Real detach updates retained attachment metadata even though the
            // recovered facade did not itself perform the original attach.
            try recovered.detach(lattice: attached)
            var enteredAfterDetach = false
            try recovered.withTransaction {
                try independent.withTransaction {
                    enteredAfterDetach = true
                    independentItem.value = 9
                }
            }
            independent.retireAllGenerations()
            #expect(enteredAfterDetach)
            #expect(value(independent) == 9)
        }
    }
}
