import Foundation
import Dispatch
import Testing
@testable import Lattice

@Model private final class LatestStateItem {
    @Property(name: "stored_rank") var rank: Int = 0
}

private final class LatestStateTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private enum LatestStateTestError: Error { case gateTimedOut }

private final class LatestStateTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw LatestStateTestError.gateTimedOut
        }
    }
}

private final class LatestStateCleanupGate: @unchecked Sendable {
    private struct State {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LatestStateTestBox(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let opened = state.withLock { value in
                if !value.opened { value.waiters.append(continuation) }
                return value.opened
            }
            if opened { continuation.resume() }
        }
    }
    func open() {
        let waiters = state.withLock { value in
            value.opened = true
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class LatestStateHints: CoarseInvalidationBackend, @unchecked Sendable {
    struct State {
        var added = 0
        var removed = 0
        var failAdd = false
        var failRemove = false
        var callbacks: [UInt64: @Sendable (InvalidationReason) -> Void] = [:]
    }
    let state = LatestStateTestBox(State())
    var beforeAdd: @Sendable () throws -> Void = {}

    func _addCoarseInvalidationHook(_ signal: @escaping @Sendable (InvalidationReason) -> Void) throws -> UInt64 {
        try beforeAdd()
        return try state.withLock { value in
            if value.failAdd { throw CoarseInvalidationError.registrationFailed }
            value.added += 1
            let token = UInt64(value.added)
            value.callbacks[token] = signal
            return token
        }
    }
    func _removeCoarseInvalidationHook(_ token: UInt64) throws {
        try state.withLock { value in
            value.removed += 1
            if value.failRemove { throw CoarseInvalidationError.removalFailed }
            value.callbacks.removeValue(forKey: token)
        }
    }
    func fire() {
        let callbacks = state.withLock { Array($0.callbacks.values) }
        callbacks.forEach { $0(.commit) }
    }
}

private final class LatestStateOperation: ProjectionReadOperation, @unchecked Sendable {
    struct State { var steps = 0; var cancels = 0; var closes = 0; var cleanupWaits = 0 }
    let state = LatestStateTestBox(State())
    private let step: @Sendable () throws -> ProjectionReadBatch
    private let delayedCleanup: Bool
    private let cleanup = LatestStateCleanupGate()

    init(delayedCleanup: Bool = false, step: @escaping @Sendable () throws -> ProjectionReadBatch) {
        self.delayedCleanup = delayedCleanup
        self.step = step
    }
    convenience init(rows: [Int]) {
        self.init { .init(rows: rows.map { [.int64(Int64($0))] }, isComplete: true) }
    }
    func nextBatch(maxRows: Int) throws -> ProjectionReadBatch {
        state.withLock { $0.steps += 1 }
        let batch = try step()
        if batch.isComplete { cleanup.open() }
        return batch
    }
    func cancel() { state.withLock { $0.cancels += 1 } }
    func close() {
        state.withLock { $0.closes += 1 }
        if !delayedCleanup { cleanup.open() }
    }
    func waitUntilClosed() async {
        state.withLock { $0.cleanupWaits += 1 }
        await cleanup.wait()
    }
    func acknowledgeCleanup() { cleanup.open() }
}

@Suite("Demand-driven latest-state projected snapshots", .serialized)
struct LatestStateSnapshotsTests {
    private func store() throws -> Lattice {
        // Schema/descriptors only. Every projection operation below is injected.
        try Lattice(LatestStateItem.self, configuration: .init(storage: .memory()))
    }
    private func limits() throws -> ProjectionReadLimits {
        try ProjectionReadLimits(maxRows: 20, maxBytes: 4096, timeout: 10)
    }
    private func projection(_ db: Lattice, _ executor: ProjectionReadExecutor,
                            factory: @escaping ProjectionOperationFactory) throws -> ProjectedResults<Int> {
        let definition = try db.objects(LatestStateItem.self).project(\.rank)
        return ProjectedResults(descriptor: definition.descriptor, columns: definition.columns,
            executor: executor, factory: factory, decode: definition.decode)
    }
    private func sequence(_ projection: ProjectedResults<Int>, _ scheduler: ObservationScheduler,
                          _ hints: LatestStateHints, interval: TimeInterval = 60,
                          limit: Int? = nil) throws -> LatestStateSnapshots<Int> {
        try LatestStateSnapshots(projection: projection, scheduler: scheduler, limits: limits(),
            reconciliationInterval: interval, limit: limit, hints: hints)
    }
    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !condition() {
            try #require(DispatchTime.now().uptimeNanoseconds < end, "latest-state test did not settle")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private func expectCancelled<Value>(_ result: Result<Value, any Error>) {
        switch result {
        case .success: Issue.record("Expected cancelled latest-state read")
        case .failure(let error): #expect(error as? ProjectionReadError == .cancelled)
        }
    }

    @Test func initialHookPrecedesReadAndBurstsOnlyReadOnDemand() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let values = LatestStateTestBox([1, 2])
        let requests = LatestStateTestBox<[ProjectionReadRequest]>([])
        let projection = try projection(db, executor) { request in
            #expect(hints.state.withLock { $0.callbacks.count } == 1)
            requests.withLock { $0.append(request) }
            return LatestStateOperation(rows: values.withLock { $0 })
        }
        let sequence = try sequence(projection, scheduler, hints, limit: 7)
        var iterator = sequence.makeAsyncIterator()
        #expect(hints.state.withLock { $0.added } == 0)
        #expect(try await iterator.next() == [1, 2])
        values.withLock { $0 = [3, 4] }
        for _ in 0..<10_000 { hints.fire() }
        #expect(requests.withLock { $0.count } == 1)
        #expect(scheduler.turns.snapshot.readySubscriptions == 0)
        #expect(try await iterator.next() == [3, 4])
        let captured = requests.withLock { $0 }
        try #require(captured.count == 2)
        #expect(captured.allSatisfy { $0.selectedColumns == ["stored_rank"] && $0.effectiveLimit == 7 })
        #expect(captured[0].operationID != captured[1].operationID)
        #expect(captured[0].deadlineNanoseconds < captured[1].deadlineNanoseconds)
        let copiedCallbacks = hints.state.withLock { Array($0.callbacks.values) }
        try await iterator.cancelAndWait()
        copiedCallbacks.forEach { $0(.advance) } // Already copied by a native caller before removal.
        #expect(hints.state.withLock { $0.callbacks.isEmpty })
        #expect(scheduler.turns.snapshot.subscriptions == 0)
        #expect(requests.withLock { $0.count } == 2)
        await executor.shutdown()
    }

    @Test func everyReconciliationPreservesCapturedPredicateSortGroupDistinctAndCap() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let results = db.objects(LatestStateItem.self).where { $0.rank.in(Array(0..<80)) }
            .group(by: \.rank).distinct(by: \.rank).sortedBy(\.rank, order: .reverse)
        results._fetchLimit = 5
        let definition = try results.project(\.rank)
        let requests = LatestStateTestBox<[ProjectionReadRequest]>([])
        let projection = ProjectedResults(descriptor: definition.descriptor, columns: definition.columns,
            executor: executor, factory: { request in
                requests.withLock { $0.append(request) }
                return LatestStateOperation(rows: [2, 1])
            }, decode: definition.decode)
        var iterator = try sequence(projection, scheduler, hints, limit: 7).makeAsyncIterator()
        results._fetchLimit = 1 // Subsequent facade mutation cannot alter the captured shape.
        #expect(try await iterator.next() == [2, 1])
        hints.fire()
        #expect(try await iterator.next() == [2, 1])
        for request in requests.withLock({ $0 }) {
            #expect(request.descriptor.whereSQL == definition.descriptor.whereSQL)
            #expect(request.descriptor.bindings == definition.descriptor.bindings)
            #expect(request.descriptor.groupBy == "stored_rank")
            #expect(request.descriptor.distinctBy == "stored_rank")
            #expect(request.descriptor.orderBySQL == "stored_rank DESC, id ASC")
            #expect(request.effectiveLimit == 5)
        }
        try await iterator.cancelAndWait()
        await executor.shutdown()
    }

    @Test func periodicFullReadRecoversMissedHintsWithoutPrefetch() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let values = LatestStateTestBox([1])
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: values.withLock { $0 })
        }
        var iterator = try sequence(projection, scheduler, hints, interval: 0.01).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        values.withLock { $0 = [2, 3] } // Simulates a missed cross-process/attached hint.
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(reads.withLock { $0 } == 1)
        #expect(try await iterator.next() == [2, 3])
        #expect(try await iterator.next() == [2, 3]) // Unchanged snapshots are allowed.
        #expect(reads.withLock { $0 } == 3)
        try await iterator.cancelAndWait()
        await executor.shutdown()
    }

    @Test func dirtyDuringTurnSurvivesAndConcurrentConsumerIsRejected() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 2, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let gate = LatestStateTestGate()
        defer { gate.open() }
        let calls = LatestStateTestBox(0)
        let first = LatestStateOperation {
            try gate.wait()
            return .init(rows: [[.int64(1)]], isComplete: true)
        }
        let projection = try projection(db, executor) { _ in
            let index = calls.withLock { $0 += 1; return $0 }
            return index == 1 ? first : LatestStateOperation(rows: [2])
        }
        let sequence = try sequence(projection, scheduler, hints)
        let iterator = sequence.makeAsyncIterator()
        var duplicate = sequence.makeAsyncIterator()
        await #expect(throws: ProjectionReadError.self) { try await duplicate.next() }
        let read = Task { var copy = iterator; return try await copy.next() }
        try await waitUntil { first.state.withLock { $0.steps } == 1 }
        var concurrent = iterator
        await #expect(throws: ProjectionReadError.self) { try await concurrent.next() }
        for _ in 0..<1000 { hints.fire() }
        #expect(calls.withLock { $0 } == 1)
        #expect(scheduler.turns.snapshot.admittedTurns == 1)
        gate.open()
        #expect(try await read.value == [1])
        #expect(try await concurrent.next() == [2])
        try await iterator.cancelAndWait()
        await executor.shutdown()
    }

    @Test func runningCancellationWaitsForNativeAcknowledgementAndDrainsOnce() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let body = LatestStateTestGate()
        defer { body.open() }
        let operation = LatestStateOperation(delayedCleanup: true) {
            try body.wait()
            throw ProjectionReadError.cancelled
        }
        defer { operation.acknowledgeCleanup() }
        let projection = try projection(db, executor) { _ in operation }
        let iterator = try sequence(projection, scheduler, hints).makeAsyncIterator()
        let finished = LatestStateTestBox(0)
        let read = Task { () -> Result<[Int]?, any Error> in
            defer { finished.withLock { $0 += 1 } }
            do { var copy = iterator; return .success(try await copy.next()) }
            catch { return .failure(error) }
        }
        try await waitUntil { operation.state.withLock { $0.steps } == 1 }
        read.cancel()
        let drainA = Task { try await iterator.cancelAndWait(); finished.withLock { $0 += 1 } }
        let drainB = Task { try await iterator.cancelAndWait(); finished.withLock { $0 += 1 } }
        try await waitUntil { operation.state.withLock { $0.cancels } > 0 }
        body.open()
        try await waitUntil { operation.state.withLock { $0.cleanupWaits } > 0 }
        #expect(finished.withLock { $0 } == 0)
        #expect(scheduler.turns.snapshot.admittedTurns == 1)
        operation.acknowledgeCleanup()
        expectCancelled(await read.value)
        try await drainA.value
        try await drainB.value
        #expect(finished.withLock { $0 } == 3)
        #expect(hints.state.withLock { $0.removed } == 1)
        #expect(scheduler.turns.snapshot.admittedTurns == 0)
        var copy = iterator
        #expect(try await copy.next() == nil)
        await executor.shutdown()
    }

    @Test func queuedCancellationDoesNotCreateSnapshotTaskOrNativeOperation() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 1, maxSubscriptions: 2)
        let body = LatestStateTestGate()
        defer { body.open() }
        let entered = LatestStateTestBox(false)
        let blocker = try scheduler.turns.register(storeID: 0) { _, _ in
            entered.withLock { $0 = true }
            do { try body.wait() } catch { Issue.record(error) }
        }
        blocker.notify(revision: 0)
        try await waitUntil { entered.withLock { $0 } }
        let hints = LatestStateHints()
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: [1])
        }
        let iterator = try sequence(projection, scheduler, hints).makeAsyncIterator()
        let read = Task { () -> Result<[Int]?, any Error> in
            do { var copy = iterator; return .success(try await copy.next()) }
            catch { return .failure(error) }
        }
        try await waitUntil { scheduler.turns.snapshot.readySubscriptions == 1 }
        try await iterator.cancelAndWait()
        expectCancelled(await read.value)
        #expect(reads.withLock { $0 } == 0)
        #expect(hints.state.withLock { $0.removed } == 1)
        body.open()
        await blocker.cancelAndWait()
        await executor.shutdown()
    }

    @Test func cancellingParkedDemandDoesNotStartAnotherSnapshot() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: [1])
        }
        var iterator = try sequence(projection, scheduler, hints).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        let copy = iterator
        let read = Task { () -> Result<[Int]?, any Error> in
            do { var iterator = copy; return .success(try await iterator.next()) }
            catch { return .failure(error) }
        }
        // Both pre-install and already-parked task cancellation are valid;
        // neither may schedule a read without a new dirty signal.
        read.cancel()
        expectCancelled(await read.value)
        try await iterator.cancelAndWait()
        #expect(reads.withLock { $0 } == 1)
        #expect(hints.state.withLock { $0.removed } == 1)
        #expect(scheduler.turns.snapshot.subscriptions == 0)
        await executor.shutdown()
    }

    @Test func cancellationDuringRegistrationRemovesReturnedHookBeforeDrain() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let gate = LatestStateTestGate()
        defer { gate.open() }
        let entered = LatestStateTestBox(false)
        hints.beforeAdd = { entered.withLock { $0 = true }; try gate.wait() }
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: [1])
        }
        let iterator = try sequence(projection, scheduler, hints).makeAsyncIterator()
        let read = Task { () -> Result<[Int]?, any Error> in
            do { var copy = iterator; return .success(try await copy.next()) }
            catch { return .failure(error) }
        }
        try await waitUntil { entered.withLock { $0 } }
        iterator.cancel()
        #expect(scheduler.turns.snapshot.subscriptions == 1)
        let drained = LatestStateTestBox(false)
        let drain = Task { try await iterator.cancelAndWait(); drained.withLock { $0 = true } }
        #expect(!drained.withLock { $0 })
        gate.open()
        try await drain.value
        expectCancelled(await read.value)
        #expect(hints.state.withLock { $0.added == 1 && $0.removed == 1 && $0.callbacks.isEmpty })
        #expect(reads.withLock { $0 } == 0)
        #expect(scheduler.turns.snapshot.subscriptions == 0)
        await executor.shutdown()
    }

    @Test func failedRemovalPoisonsFutureAdmissionBeforeCapacityIsFreed() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: [1])
        }
        var iterator = try sequence(projection, scheduler, hints).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        hints.state.withLock { $0.failRemove = true }
        let expected = ProjectionReadError.database("latest-state invalidation removal failed: removalFailed")
        do { try await iterator.cancelAndWait(); Issue.record("Expected hook removal error") }
        catch { #expect(error as? ProjectionReadError == expected) }
        #expect(scheduler.turns.snapshot.subscriptions == 0)
        for _ in 0..<20 {
            var replacement = try sequence(projection, scheduler, hints).makeAsyncIterator()
            do { _ = try await replacement.next(); Issue.record("Poisoned scheduler admitted a stream") }
            catch { #expect(error as? ProjectionReadError == expected) }
        }
        hints.fire() // Retained native hook is weak and inert after cancellation.
        #expect(hints.state.withLock { $0.added == 1 && $0.callbacks.count == 1 })
        #expect(reads.withLock { $0 } == 1)
        await executor.shutdown()
    }

    private func consumeAndDrop(_ sequence: LatestStateSnapshots<Int>) async throws -> [Int]? {
        var iterator = sequence.makeAsyncIterator()
        return try await iterator.next()
    }

    @Test func droppingIteratorRemovesHookWhileSequenceRemainsRetained() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: [1])
        }
        let sequence = try sequence(projection, scheduler, hints, interval: 0.01)
        #expect(try await consumeAndDrop(sequence) == [1])
        try await waitUntil { hints.state.withLock { $0.callbacks.isEmpty } }
        withExtendedLifetime(sequence) {
            #expect(hints.state.withLock { $0.removed } == 1)
            #expect(reads.withLock { $0 } == 1)
        }
        await executor.shutdown()
    }

    @Test func sourceRegistrationFailureFreesCapacityAndIsExplicit() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        hints.state.withLock { $0.failAdd = true }
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            return LatestStateOperation(rows: [1])
        }
        var failed = try sequence(projection, scheduler, hints).makeAsyncIterator()
        await #expect(throws: ProjectionReadError.self) { try await failed.next() }
        #expect(reads.withLock { $0 } == 0)
        #expect(scheduler.turns.snapshot.subscriptions == 0)
        hints.state.withLock { $0.failAdd = false }
        var replacement = try sequence(projection, scheduler, hints).makeAsyncIterator()
        #expect(try await replacement.next() == [1])
        try await replacement.cancelAndWait()
        await executor.shutdown()
    }

    @Test func parkedSubscriptionsChargeCapacityUntilCancellation() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let projection = try projection(db, executor) { _ in LatestStateOperation(rows: [1]) }
        var first = try sequence(projection, scheduler, hints).makeAsyncIterator()
        #expect(try await first.next() == [1])
        var excess = try sequence(projection, scheduler, hints).makeAsyncIterator()
        do { _ = try await excess.next(); Issue.record("Expected bounded admission") }
        catch { #expect(error as? ProjectionReadError == .resourceBusy) }
        #expect(hints.state.withLock { $0.added } == 1)
        try await first.cancelAndWait()
        var replacement = try sequence(projection, scheduler, hints).makeAsyncIterator()
        #expect(try await replacement.next() == [1])
        #expect(hints.state.withLock { $0.added } == 2)
        try await replacement.cancelAndWait()
        await executor.shutdown()
    }

    @Test func closedSourceIsDiscoveredByDemandedReadWithoutLifecyclePushClaim() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 1)
        let hints = LatestStateHints()
        let closed = LatestStateTestBox(false)
        let reads = LatestStateTestBox(0)
        let projection = try projection(db, executor) { _ in
            reads.withLock { $0 += 1 }
            if closed.withLock({ $0 }) { throw ProjectionReadError.snapshotExpired }
            return LatestStateOperation(rows: [1])
        }
        var iterator = try sequence(projection, scheduler, hints, interval: 0.01).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        closed.withLock { $0 = true }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(reads.withLock { $0 } == 1)
        do { _ = try await iterator.next(); Issue.record("Expected expired source") }
        catch { #expect(error as? ProjectionReadError == .snapshotExpired) }
        #expect(hints.state.withLock { $0.callbacks.isEmpty })
        #expect(scheduler.turns.snapshot.subscriptions == 0)
        #expect(try await iterator.next() == nil)
        await executor.shutdown()
    }

    @Test func explicitResourceAndReconciliationBoundsRejectInvalidValues() throws {
        #expect(throws: ProjectionReadError.self) { try ObservationScheduler(workerCount: 0, maxSubscriptions: 1) }
        #expect(throws: ProjectionReadError.self) { try ObservationScheduler(workerCount: 9, maxSubscriptions: 1) }
        #expect(throws: ProjectionReadError.self) { try ObservationScheduler(workerCount: 1, maxSubscriptions: 0) }
        let db = try store()
        defer { db.close() }
        let definition = try db.objects(LatestStateItem.self).project(\.rank)
        let scheduler = try ObservationScheduler(workerCount: 1, maxSubscriptions: 1)
        let hints = LatestStateHints()
        for interval in [0, -1, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            #expect(throws: ProjectionReadError.self) { try sequence(definition, scheduler, hints, interval: interval) }
        }
        #expect(hints.state.withLock { $0.added } == 0)
    }
}
