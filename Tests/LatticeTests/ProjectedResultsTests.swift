import Foundation
import Dispatch
import Testing
@testable import Lattice

@Model private final class ProjectedFacadeItem {
    @Property(name: "stored_rank") var rank: Int = 0
    var title: String = ""
    var score: Double = 0
    var enabled: Bool = false
    var touched: Date = Date(timeIntervalSince1970: 0)
    var payload: Data = Data()
    var computedRank: Int { rank + 1 }
}

private enum ProjectedFacadeTestError: Error { case gateTimedOut, unexpectedStep }

private final class ProjectedTestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class ProjectedBlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw ProjectedFacadeTestError.gateTimedOut
        }
    }
}

/// Models an asynchronous native cleanup receipt without occupying a worker.
private final class ProjectedCleanupGate: @unchecked Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let lock = NSLock()
    private var state = State()

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let open = state.open
            if !open { state.waiters.append(continuation) }
            lock.unlock()
            if open { continuation.resume() }
        }
    }

    func open() {
        lock.lock()
        state.open = true
        let waiters = state.waiters
        state.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

private final class ProjectedFakeOperation: ProjectionReadOperation, @unchecked Sendable {
    struct State: Sendable {
        var steps = 0
        var batchSizes: [Int] = []
        var cancelCalls = 0
        var closeCalls = 0
        var cleanupWaits = 0
        var closed = false
    }
    private let state = ProjectedTestBox(State())
    private let batches: [ProjectionReadBatch]
    private let beforeStep: @Sendable (Int) throws -> Void
    private let delaysCleanup: Bool
    private let cleanup = ProjectedCleanupGate()

    init(_ batches: [ProjectionReadBatch], delaysCleanup: Bool = false,
         beforeStep: @escaping @Sendable (Int) throws -> Void = { _ in }) {
        self.batches = batches
        self.delaysCleanup = delaysCleanup
        self.beforeStep = beforeStep
    }

    var snapshot: State { state.withLock { $0 } }

    func nextBatch(maxRows: Int) throws -> ProjectionReadBatch {
        let index = state.withLock { value in
            value.batchSizes.append(maxRows)
            let index = value.steps
            value.steps += 1
            return index
        }
        try beforeStep(index)
        guard index < batches.count else { throw ProjectedFacadeTestError.unexpectedStep }
        let batch = batches[index]
        // A completed native step has already finalized its lease.
        if batch.isComplete { acknowledgeCleanup() }
        return batch
    }

    func cancel() { state.withLock { $0.cancelCalls += 1 } }

    func close() {
        state.withLock { $0.closeCalls += 1 }
        if !delaysCleanup { acknowledgeCleanup() }
    }

    func waitUntilClosed() async {
        state.withLock { $0.cleanupWaits += 1 }
        await cleanup.wait()
    }

    func acknowledgeCleanup() {
        state.withLock { $0.closed = true }
        cleanup.open()
    }
}

@Suite("Projected values facade", .serialized)
struct ProjectedResultsTests {
    private func store() throws -> Lattice {
        // The store supplies schema/query descriptors only. All projected SQL
        // operations below are injected fakes, not native projection tests.
        try Lattice(ProjectedFacadeItem.self, configuration: .init(storage: .memory()))
    }

    private func limits() throws -> ProjectionReadLimits {
        try ProjectionReadLimits(maxRows: 20, maxBytes: 4096, timeout: 10)
    }

    private func inject<Value: Sendable>(
        _ definition: ProjectedResults<Value>, executor: ProjectionReadExecutor,
        operation: ProjectedFakeOperation,
        requests: ProjectedTestBox<[ProjectionReadRequest]> = ProjectedTestBox([])
    ) -> ProjectedResults<Value> {
        ProjectedResults(descriptor: definition.descriptor, columns: definition.columns,
            executor: executor, factory: { request in
                requests.withLock { $0.append(request) }
                return operation
            }, decode: definition.decode)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !condition() {
            try #require(DispatchTime.now().uptimeNanoseconds < deadline, "facade test state did not settle")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func expectCancelled<Value>(_ result: Result<Value, any Error>) {
        switch result {
        case .success: Issue.record("Expected cancellation")
        case .failure(let error): #expect(error as? ProjectionReadError == .cancelled)
        }
    }

    @Test func snapshotClosesBeforeCallingValueDecoder() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([
            .init(rows: [[.int64(7)]], isComplete: false),
            .init(rows: [[.int64(8)]], isComplete: true),
        ])
        let definition = try db.objects(ProjectedFacadeItem.self).project(\.rank)
        let decoded = ProjectedTestBox(0)
        let projection = ProjectedResults<Int>(descriptor: definition.descriptor, columns: definition.columns,
            executor: executor, factory: { _ in operation }) { row in
                #expect(operation.snapshot.closeCalls > 0)
                #expect(operation.snapshot.closed)
                decoded.withLock { $0 += 1 }
                return try Int.decodeProjectionValue(row[0])
            }
        #expect(try await projection.snapshot(limits: limits()) == [7, 8])
        #expect(decoded.withLock { $0 } == 2)
        #expect(operation.snapshot.steps == 2)
        await executor.shutdown()
    }

    @Test func eachNextRequestsExactlyOneBatchWithoutPrefetch() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([
            .init(rows: [[.int64(1)]], isComplete: false),
            .init(rows: [[.int64(2)]], isComplete: true),
        ])
        let requests = ProjectedTestBox<[ProjectionReadRequest]>([])
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank),
            executor: executor, operation: operation, requests: requests)
        let sequence = try projection.batches(of: 1, limits: limits())
        #expect(requests.withLock { $0.isEmpty })
        var iterator = sequence.makeAsyncIterator()
        #expect(requests.withLock { $0.isEmpty })
        #expect(try await iterator.next() == [1])
        #expect(operation.snapshot.steps == 1)
        #expect(operation.snapshot.closeCalls == 0)
        #expect(executor.snapshot.pending == 0 && executor.snapshot.running == 0)
        #expect(try await iterator.next() == [2])
        #expect(try await iterator.next() == nil)
        #expect(operation.snapshot.steps == 2)
        #expect(operation.snapshot.batchSizes == [1, 1])
        #expect(requests.withLock { $0.count } == 1)
        await executor.shutdown()
    }

    private func consumeOneAndDrop(_ sequence: ProjectedBatches<Int>) async throws -> [Int]? {
        var iterator = sequence.makeAsyncIterator()
        return try await iterator.next()
    }

    @Test func droppingIteratorClosesWhileSequenceRemainsRetained() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([.init(rows: [[.int64(1)]], isComplete: false)])
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank), executor: executor, operation: operation)
        let sequence = try projection.batches(of: 1, limits: limits())
        #expect(try await consumeOneAndDrop(sequence) == [1])
        try await waitUntil { operation.snapshot.closeCalls > 0 }
        withExtendedLifetime(sequence) {
            #expect(operation.snapshot.closed)
            #expect(operation.snapshot.steps == 1)
        }
        await executor.shutdown()
    }

    @Test func sequenceCopiesRejectSecondConsumerAndIteratorCopiesRejectConcurrentNext() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 2, maxPendingJobs: 2)
        let gate = ProjectedBlockingGate()
        defer { gate.open() }
        let operation = ProjectedFakeOperation([
            .init(rows: [[.int64(1)]], isComplete: false),
            .init(rows: [[.int64(2)]], isComplete: true),
        ], beforeStep: { if $0 == 0 { try gate.wait() } })
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank), executor: executor, operation: operation)
        let sequence = try projection.batches(of: 1, limits: limits())
        let iterator = sequence.makeAsyncIterator()
        let sequenceCopy = sequence
        var secondConsumer = sequenceCopy.makeAsyncIterator()
        await #expect(throws: ProjectionReadError.self) { try await secondConsumer.next() }
        let first = Task { var copy = iterator; return try await copy.next() }
        try await waitUntil { operation.snapshot.steps == 1 }
        var concurrentCopy = iterator
        await #expect(throws: ProjectionReadError.self) { try await concurrentCopy.next() }
        #expect(operation.snapshot.cancelCalls == 0)
        gate.open()
        #expect(try await first.value == [1])
        #expect(try await concurrentCopy.next() == [2])
        #expect(operation.snapshot.steps == 2)
        await executor.shutdown()
    }

    @Test func nullAndWrongTypeThrowWithoutSubstitutingModelDefaults() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let definition = try db.objects(ProjectedFacadeItem.self).project(\.rank)
        for (cell, expected) in [
            (ColumnValue.null, ProjectionDecodingError.unexpectedNull(expected: "Int")),
            (.text("8"), .typeMismatch(expected: "Int", actual: "TEXT")),
        ] {
            let operation = ProjectedFakeOperation([.init(rows: [[cell]], isComplete: true)])
            let projection = inject(definition, executor: executor, operation: operation)
            await #expect(throws: expected) { try await projection.snapshot(limits: limits()) }
            #expect(operation.snapshot.closeCalls > 0)
        }
        #expect(throws: ProjectionReadError.self) {
            try db.objects(ProjectedFacadeItem.self).project(\.computedRank)
        }
        await executor.shutdown()
    }

    @Test func malformedCellsAndEmptyNonfinalBatchFailBeforeDecoder() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let descriptor = try db.objects(ProjectedFacadeItem.self)._projectionDescriptor
        for malformed in [
            ProjectionReadBatch(rows: [[]], isComplete: true),
            ProjectionReadBatch(rows: [[.int64(1), .text("extra")]], isComplete: true),
            ProjectionReadBatch(rows: [], isComplete: false),
        ] {
            let operation = ProjectedFakeOperation([malformed])
            let calls = ProjectedTestBox(0)
            let projection = ProjectedResults<Int>(descriptor: descriptor, columns: ["stored_rank"], executor: executor,
                factory: { _ in operation }) { _ in calls.withLock { $0 += 1 }; return 0 }
            await #expect(throws: ProjectionReadError.database("malformed projected batch")) {
                try await projection.snapshot(limits: limits())
            }
            #expect(calls.withLock { $0 } == 0)
            #expect(operation.snapshot.closeCalls > 0)
        }
        await executor.shutdown()
    }

    @Test func explicitIteratorCancellationAfterPartialDeliveryClosesAndDoesNotStepAgain() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([.init(rows: [[.int64(1)]], isComplete: false)])
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank), executor: executor, operation: operation)
        var iterator = try projection.batches(of: 1, limits: limits()).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        iterator.cancel()
        await #expect(throws: ProjectionReadError.cancelled) { try await iterator.next() }
        #expect(operation.snapshot.cancelCalls > 0)
        #expect(operation.snapshot.closed)
        #expect(operation.snapshot.steps == 1)
        await executor.shutdown()
    }

    @Test func cancellingQueuedLaterBatchWaitsForNativeCleanupAcknowledgement() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([.init(rows: [[.int64(1)]], isComplete: false)], delaysCleanup: true)
        defer { operation.acknowledgeCleanup() }
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank), executor: executor, operation: operation)
        var iterator = try projection.batches(of: 1, limits: limits()).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        let gate = ProjectedBlockingGate()
        defer { gate.open() }
        let entered = ProjectedTestBox(false)
        let blocker = Task {
            try await executor.submit { entered.withLock { $0 = true }; try gate.wait(); return 1 }
        }
        try await waitUntil { entered.withLock { $0 } }
        let copy = iterator
        let returned = ProjectedTestBox(false)
        let queued = Task {
            defer { returned.withLock { $0 = true } }
            var iterator = copy
            return try await iterator.next()
        }
        try await waitUntil { executor.snapshot.pending == 1 }
        queued.cancel()
        try await waitUntil { operation.snapshot.closeCalls > 0 && operation.snapshot.cleanupWaits > 0 }
        #expect(!returned.withLock { $0 })
        #expect(!operation.snapshot.closed)
        #expect(operation.snapshot.steps == 1)
        #expect(executor.snapshot.running == 1, "cleanup acknowledgement must not need the blocked SQL worker")
        operation.acknowledgeCleanup()
        expectCancelled(await queued.result)
        #expect(operation.snapshot.closed)
        gate.open()
        #expect(try await blocker.value == 1)
        await executor.shutdown()
    }

    @Test func explicitZeroLimitIsForwardedAndDoesNotDecodeAnyRow() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([.init(rows: [], isComplete: true)])
        let requests = ProjectedTestBox<[ProjectionReadRequest]>([])
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank),
            executor: executor, operation: operation, requests: requests)
        #expect(try await projection.snapshot(limit: 0, limits: limits()).isEmpty)
        #expect(requests.withLock { $0.count } == 1)
        #expect(requests.withLock { $0.first?.effectiveLimit } == 0)
        #expect(operation.snapshot.closed)
        await executor.shutdown()
    }

    @Test func fullQueueOnLaterBatchWaitsForCleanupBeforeReportingResourceBusy() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let operation = ProjectedFakeOperation([.init(rows: [[.int64(1)]], isComplete: false)], delaysCleanup: true)
        defer { operation.acknowledgeCleanup() }
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank), executor: executor, operation: operation)
        var iterator = try projection.batches(of: 1, limits: limits()).makeAsyncIterator()
        #expect(try await iterator.next() == [1])
        let gate = ProjectedBlockingGate()
        defer { gate.open() }
        let entered = ProjectedTestBox(false)
        let blocker = Task {
            try await executor.submit { entered.withLock { $0 = true }; try gate.wait(); return 1 }
        }
        try await waitUntil { entered.withLock { $0 } }
        let filler = Task { try await executor.submit { 2 } }
        try await waitUntil { executor.snapshot.pending == 1 }
        let copy = iterator
        let returned = ProjectedTestBox(false)
        let rejected = Task {
            defer { returned.withLock { $0 = true } }
            var iterator = copy
            return try await iterator.next()
        }
        try await waitUntil { operation.snapshot.cleanupWaits > 0 }
        #expect(!returned.withLock { $0 })
        #expect(!operation.snapshot.closed)
        #expect(operation.snapshot.steps == 1)
        operation.acknowledgeCleanup()
        switch await rejected.result {
        case .success: Issue.record("Expected queue admission failure")
        case .failure(let error): #expect(error as? ProjectionReadError == .resourceBusy)
        }
        #expect(operation.snapshot.closed)
        gate.open()
        #expect(try await blocker.value == 1)
        #expect(try await filler.value == 2)
        await executor.shutdown()
    }

    @Test func decoderFailureInPartialBatchWaitsForCleanupAcknowledgement() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let operation = ProjectedFakeOperation([.init(rows: [[.null]], isComplete: false)], delaysCleanup: true)
        defer { operation.acknowledgeCleanup() }
        let projection = inject(try db.objects(ProjectedFacadeItem.self).project(\.rank), executor: executor, operation: operation)
        let sequence = try projection.batches(of: 1, limits: limits())
        let returned = ProjectedTestBox(false)
        let read = Task {
            defer { returned.withLock { $0 = true } }
            var iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }
        try await waitUntil { operation.snapshot.cleanupWaits > 0 }
        #expect(operation.snapshot.closeCalls > 0)
        #expect(!returned.withLock { $0 })
        #expect(!operation.snapshot.closed)
        operation.acknowledgeCleanup()
        switch await read.result {
        case .success: Issue.record("Required Int must not default for NULL")
        case .failure(let error):
            #expect(error as? ProjectionDecodingError == .unexpectedNull(expected: "Int"))
        }
        #expect(operation.snapshot.closed)
        await executor.shutdown()
    }

    @Test func typedOverloadsKeepFieldOrderThroughSixScalars() async throws {
        let db = try store()
        defer { db.close() }
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let results = db.objects(ProjectedFacadeItem.self)
        let text = "é\u{0}漢字"
        let data = Data([0, 255, 0, 65])
        let cells: [ColumnValue] = [.int64(9), .text(text), .real(1.25), .int64(1), .real(42.5), .blob(data)]
        #expect(try results.project(\.rank).decode(Array(cells.prefix(1))) == 9)
        #expect(try results.project(\.rank, \.title).decode(Array(cells.prefix(2))).1 == text)
        #expect(try results.project(\.rank, \.title, \.score).decode(Array(cells.prefix(3))).2 == 1.25)
        #expect(try results.project(\.rank, \.title, \.score, \.enabled).decode(Array(cells.prefix(4))).3 == true)
        #expect(try results.project(\.rank, \.title, \.score, \.enabled, \.touched).decode(Array(cells.prefix(5))).4 == Date(timeIntervalSince1970: 42.5))
        let definition = try results.project(\.rank, \.title, \.score, \.enabled, \.touched, \.payload)
        #expect(definition.columns == ["stored_rank", "title", "score", "enabled", "touched", "payload"])
        let operation = ProjectedFakeOperation([.init(rows: [cells], isComplete: true)])
        let projection = inject(definition, executor: executor, operation: operation)
        let rows = try await projection.snapshot(limits: limits())
        let row = try #require(rows.first)
        #expect(row.0 == 9 && row.1 == text && row.2 == 1.25 && row.3 == true)
        #expect(row.4 == Date(timeIntervalSince1970: 42.5) && row.5 == data)
        #expect(operation.snapshot.closed)
        await executor.shutdown()
    }
}
