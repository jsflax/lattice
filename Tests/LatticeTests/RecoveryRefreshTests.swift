import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice
#if canImport(Combine)
import Combine
#endif

@Model private final class RefreshItem {
    var name: String = ""
    var rank: Int = 0
}

/// This fixture commits through a bare SQLite connection: no Core owner,
/// notifier post, local invalidation hook, or outgoing audit entry. It tests
/// the refresh consumer/worker contract, not the recovery controller itself.
@Suite("Recovery refresh consumers", .serialized)
struct RecoveryRefreshTests {
    private func database() throws -> (Lattice, URL) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let directory = URL(fileURLWithPath: home).appendingPathComponent("localdev/lattice-recovery-sdk-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).sqlite")
        var config = Lattice.Configuration(fileURL: url, busyTimeoutMs: 100)
        config.resultsTuning.crossProcessBeltIntervalMs = nil
        config.resultsTuning.generationTTLSeconds = 60
        let store = try Lattice(RefreshItem.self, configuration: config)
        try foreign(url, """
            CREATE TABLE _lattice_recovery_witness(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,incarnation BLOB NOT NULL,generation INTEGER NOT NULL) WITHOUT ROWID;
            INSERT INTO _lattice_recovery_witness VALUES(1,1,randomblob(16),1);
            INSERT INTO RefreshItem(globalId,name,rank) VALUES('aaaaaaaa-0000-0000-0000-000000000001','before',1);
            """)
        return (store, url)
    }

    private func foreign(_ url: URL, _ sql: String) throws {
        var raw: OpaquePointer?
        let opened = sqlite3_open(url.path, &raw)
        guard opened == SQLITE_OK, let db = raw else {
            sqlite3_close(raw)
            throw LatticeError.transactionError("fixture SQLite open failed")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        guard sqlite3_create_function(db, "sync_disabled", 0, SQLITE_UTF8, nil,
            { context, _, _ in sqlite3_result_int(context, 1) }, nil, nil) == SQLITE_OK else {
            throw LatticeError.transactionError("fixture suppression registration failed")
        }
        if sqlite3_exec(db, "BEGIN IMMEDIATE;" + sql + ";COMMIT;", nil, nil, nil) != SQLITE_OK {
            throw LatticeError.transactionError(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func changed(_ url: URL) throws {
        try foreign(url, "UPDATE RefreshItem SET name='after',rank=2; UPDATE _lattice_recovery_witness SET generation=generation+1 WHERE id=1")
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(predicate())
    }

    @Test func payloadFreeWakeRefreshesWithoutAnAuditEventAndCancellationStopsNewWakes() async throws {
        let (store, url) = try database()
        defer { store.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let calls = LockedBox(0), audits = LockedBox(0)
        let audit = store.observeCommits { audits.withLock { $0 += 1 } }
        defer { audit.cancel() }
        var token: AnyCancellable? = store.observeRecovery { calls.withLock { $0 += 1 } }
        defer { token?.cancel() }
        try await eventually { calls.withLock { $0 } >= 1 }
        let before = calls.withLock { $0 }
        try changed(url)
        try await eventually { calls.withLock { $0 } > before }
        #expect(store.objects(RefreshItem.self).first?.name == "after")
        #expect(audits.withLock { $0 } == 0)
        token?.cancel(); token = nil
        let successorCalls = LockedBox(0)
        let successor = store.observeRecovery { successorCalls.withLock { $0 += 1 } }
        defer { successor.cancel() }
        try await eventually { successorCalls.withLock { $0 } >= 1 }
        let afterCancel = calls.withLock { $0 }, successorBefore = successorCalls.withLock { $0 }
        try foreign(url, "UPDATE _lattice_recovery_witness SET generation=generation+1 WHERE id=1")
        try await eventually { successorCalls.withLock { $0 } > successorBefore }
        #expect(calls.withLock { $0 } == afterCancel)
    }

    @Test func cachedCountRefreshesWithBeltDisabledAndNoExplicitListener() async throws {
        let (store, url) = try database()
        defer { store.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let results = store.objects(RefreshItem.self).where { $0.rank == 1 }
        #expect(results.count == 1)
        // Count does not hydrate a Swift model; coordinator activation alone
        // must refresh its shape after the raw foreign commit.
        try changed(url)
        try await eventually { results.count == 0 }
        // A second distinct commit cannot be satisfied by the initial wake.
        try foreign(url, "UPDATE RefreshItem SET rank=1; UPDATE _lattice_recovery_witness SET generation=generation+1 WHERE id=1")
        try await eventually { results.count == 1 }
    }

    @Test func heldModelOnlyGetsFreshPropertyWithBeltDisabled() async throws {
        let (store, url) = try database()
        defer { store.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let held = try #require(store.object(RefreshItem.self, globalId: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!))
        let seen = LockedBox<[String]>([])
        let token = held.observe(\.name) { value in seen.withLock { $0.append(value) } }
        defer { token.cancel() }
        try changed(url)
        try await eventually { seen.withLock { $0.contains("after") } }
        #expect(held.name == "after")
        try foreign(url, "UPDATE RefreshItem SET name='final'; UPDATE _lattice_recovery_witness SET generation=generation+1 WHERE id=1")
        try await eventually { seen.withLock { $0.contains("final") } }
        #expect(held.name == "final")
    }

    @Test func rejectedOrCancelledSwiftCallbackReleasesItsContext() throws {
        // Memory owners never launch a witness worker, so no admitted callback
        // is racing this deterministic context-custody assertion.
        let store = try Lattice(RefreshItem.self, configuration: .init(storage: .memory()))
        defer { store.close() }
        final class Capture: @unchecked Sendable {}
        var capture: Capture? = Capture()
        weak var weakCapture = capture
        var token: AnyCancellable? = store.observeRecovery { [retained = capture!] in _ = retained }
        capture = nil
        #expect(weakCapture != nil)
        token?.cancel(); token = nil
        #expect(weakCapture == nil)
        store.close()
        var refused: Capture? = Capture()
        weak var weakRefused = refused
        let rejected = store.observeRecovery { [retained = refused!] in _ = retained }
        refused = nil
        #expect(weakRefused == nil)
        rejected.cancel()
    }

#if canImport(Combine)
    @Test func resultsRecoveryUsesTheOrdinaryDeliveryQueueAndCancelFencesQueuedWake() async throws {
        let (store, url) = try database()
        defer { store.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let results = store.objects(RefreshItem.self)
        let calls = LockedBox(0), entered = LockedBox(false), wakes = LockedBox(0)
        let publication = results.objectWillChange.sink { calls.withLock { $0 += 1 } }
        let signal = store.observeRecovery { wakes.withLock { $0 += 1 } }
        defer { publication.cancel(); signal.cancel() }
        try await eventually { calls.withLock { $0 } >= 1 && wakes.withLock { $0 } >= 1 }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        ObserverDeliveryWorker.shared.enqueue(kind: .collection, table: RefreshItem.entityName, storeIdentity: store.backend.identityHash, batchID: nil) {
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 8)
        }
        try await eventually { entered.withLock { $0 } }
        let before = calls.withLock { $0 }, beforeWake = wakes.withLock { $0 }
        try changed(url)
        try await eventually { wakes.withLock { $0 } > beforeWake }
        #expect(calls.withLock { $0 } == before)
        publication.cancel()
        let drained = LockedBox(false)
        ObserverDeliveryWorker.shared.enqueue(kind: .collection, table: RefreshItem.entityName,
                                               storeIdentity: store.backend.identityHash, batchID: nil) {
            drained.withLock { $0 = true }
        }
        gate.signal()
        try await eventually { drained.withLock { $0 } }
        #expect(calls.withLock { $0 } == before)
        #expect(results.first?.name == "after")
    }

    @Test func cancellationDuringRegistrationCancelsReturnedTokens() {
        final class Subscriber: Combine.Subscriber {
            typealias Input = Void
            typealias Failure = Never
            var subscription: (any Combine.Subscription)?
            var values = 0
            func receive(subscription: any Combine.Subscription) { self.subscription = subscription; subscription.request(.unlimited) }
            func receive(_ input: Void) -> Subscribers.Demand { values += 1; subscription?.cancel(); return .none }
            func receive(completion: Subscribers.Completion<Never>) {}
        }
        let cancelled = LockedBox(0)
        let publisher = ResultsChangePublisher(subscribeRefresh: { callback in
            callback()
            return AnyCancellable { cancelled.withLock { $0 += 1 } }
        }, subscribe: { callback in
            callback(.update(1))
            return AnyCancellable { cancelled.withLock { $0 += 1 } }
        })
        let subscriber = Subscriber()
        publisher.receive(subscriber: subscriber)
        #expect(subscriber.values == 1)
        #expect(cancelled.withLock { $0 } == 2)
        subscriber.subscription = nil
    }
#endif
}
