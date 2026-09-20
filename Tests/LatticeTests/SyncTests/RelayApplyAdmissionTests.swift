import Foundation
import Testing
import NIOCore
import NIOConcurrencyHelpers
@testable import LatticeServerKit
#if canImport(Darwin)
import Darwin
#endif

private final class ApplyTestGate: Sendable {
    struct State: Sendable {
        var enteredNS: UInt64?
        var releasedNS: UInt64?
        var finishedNS: UInt64?
        var timedOut = false
        var held: Bool {
            guard let enteredNS else { return false }
            return releasedNS == nil && finishedNS == nil
                && DispatchTime.now().uptimeNanoseconds - enteredNS < 5_000_000_000
        }
    }
    private struct Storage: Sendable {
        var facts = State()
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = NIOLockedValueBox(Storage())
    private let release = DispatchSemaphore(value: 0)
    var snapshot: State { state.withLockedValue { $0.facts } }
    func open() {
        let waiter = state.withLockedValue { value in
            if value.facts.releasedNS == nil { value.facts.releasedNS = DispatchTime.now().uptimeNanoseconds }
            let waiter = value.waiter
            value.waiter = nil
            if waiter != nil { value.facts.finishedNS = DispatchTime.now().uptimeNanoseconds }
            return waiter
        }
        release.signal()
        waiter?.resume()
    }
    // Only genuine synchronous IO-worker operations use this blocking gate.
    func block() {
        state.withLockedValue { $0.facts.enteredNS = DispatchTime.now().uptimeNanoseconds }
        let timedOut = release.wait(timeout: .now() + 5) != .success
        state.withLockedValue {
            $0.facts.timedOut = timedOut
            $0.facts.finishedNS = DispatchTime.now().uptimeNanoseconds
        }
    }
    // Preparation runs on a Swift task. Suspend it without occupying that
    // cooperative executor. Cancellation deliberately does not open this gate:
    // the tests must observe the product's cancellation/close transition while
    // preparation still owns its FIFO position and input reservation.
    func waitForPreparation() async {
        await withCheckedContinuation { continuation in
            let waiting = state.withLockedValue { value in
                precondition(value.facts.enteredNS == nil)
                value.facts.enteredNS = DispatchTime.now().uptimeNanoseconds
                if value.facts.releasedNS != nil {
                    value.facts.finishedNS = DispatchTime.now().uptimeNanoseconds
                    return false
                }
                value.waiter = continuation
                return true
            }
            if waiting {
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
                    self?.preparationDeadlineExpired()
                }
            } else { continuation.resume() }
        }
    }
    private func preparationDeadlineExpired() {
        let waiter = state.withLockedValue { value in
            guard let waiter = value.waiter else { return nil as CheckedContinuation<Void, Never>? }
            value.waiter = nil
            value.facts.timedOut = true
            value.facts.finishedNS = DispatchTime.now().uptimeNanoseconds
            return waiter
        }
        waiter?.resume()
    }
}

private final class ApplyTestSignal: Sendable {
    private struct State {
        var signalled = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = NIOLockedValueBox(State())
    func signal() {
        let waiter = state.withLockedValue { value in
            value.signalled = true
            let waiter = value.waiter; value.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    // Deliberately not task-cancellable: tests must verify actual settlement,
    // rather than cancelled AsyncStream.next returning before the release gate.
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLockedValue { value in
                if value.signalled { return true }
                precondition(value.waiter == nil)
                value.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class ApplyUnexpectedCallbacks: Sendable {
    let label: String
    private let counts = NIOLockedValueBox((operation: 0, publication: 0))
    init(_ label: String) { self.label = label }
    func operation() { counts.withLockedValue { $0.operation += 1 } }
    func publication() { counts.withLockedValue { $0.publication += 1 } }
    var snapshot: (operation: Int, publication: Int) { counts.withLockedValue { $0 } }
}

private struct ApplyTestTask: Sendable {
    let label: String
    let task: Task<Result<Void, any Error>, Never>
    let joined: Task<Void, Never>
    let outcome: NIOLockedValueBox<Result<Void, any Error>?>
    func cancel() { task.cancel() }
}

private enum ApplyFixtureError: Error { case cleanupUnconfirmed }

/// File-local ownership for this suite only. The cleanup task retains this
/// fixture and every handle until it settles, even if the five-second observer
/// reports unconfirmed cleanup. No cancellation is presented as thread cleanup.
private final class ApplyTestFixture: Sendable {
    let service: RelayApplyAdmission
    let pool: RelayExecutionPool
    private let name: String
    private let gates: [ApplyTestGate]
    private let signals: [ApplyTestSignal]
    private let tasks = NIOLockedValueBox<[ApplyTestTask]>([])
    private let unexpected = NIOLockedValueBox<[ApplyUnexpectedCallbacks]>([])
    private struct CleanupState: Sendable {
        var confirmed = false
        var observerReturned = false
        var errors: [String] = []
        var phase = "not started"
    }
    private let cleanupState = NIOLockedValueBox(CleanupState())

    init(name: String, service: RelayApplyAdmission, pool: RelayExecutionPool,
         gates: [ApplyTestGate], signals: [ApplyTestSignal]) {
        self.name = name; self.service = service; self.pool = pool; self.gates = gates; self.signals = signals
    }
    func start(_ label: String, _ operation: @escaping @Sendable () async throws -> Void) -> ApplyTestTask {
        let outcome = NIOLockedValueBox<Result<Void, any Error>?>(nil)
        let task = Task<Result<Void, any Error>, Never> {
            do { try await operation(); return .success(()) }
            catch { return .failure(error) }
        }
        // Publish only after joining the actual request task. A flag written
        // inside its body would precede task termination and weaken .value.
        let joined = Task {
            let result = await task.value
            outcome.withLockedValue { $0 = result }
        }
        let handle = ApplyTestTask(label: label, task: task, joined: joined, outcome: outcome)
        tasks.withLockedValue { $0.append(handle) }
        return handle
    }
    func forbidCallbacks(_ label: String) -> ApplyUnexpectedCallbacks {
        let value = ApplyUnexpectedCallbacks(label)
        unexpected.withLockedValue { $0.append(value) }
        return value
    }
    var diagnostic: String {
        let s = service.snapshot
        let pending = tasks.withLockedValue { $0 }.filter { $0.outcome.withLockedValue { $0 == nil } }.map(\.label)
        return "test=\(name) requests=\(s.requests) bytes=\(s.inputBytes) preparing=\(s.preparing) queued=\(s.queued) "
            + "submitted=\(s.submitted) running=\(s.running) publishing=\(s.publishing) closed=\(s.closed) "
            + "pending=\(pending) gates=\(gates.map { String(describing: $0.snapshot) })"
    }
    func until(_ label: String, holding gate: ApplyTestGate? = nil,
               details: @escaping @Sendable () -> String = { "" }, _ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !predicate() {
            try #require(DispatchTime.now().uptimeNanoseconds < deadline,
                         Comment(rawValue: "\(label): bounded state wait expired; \(details()); \(diagnostic)"))
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        if let gate {
            try #require(gate.snapshot.held,
                         Comment(rawValue: "\(label): prerequisite gate no longer held; \(details()); \(diagnostic)"))
        }
    }
    func result(_ handle: ApplyTestTask) async throws -> Result<Void, any Error> {
        try await until("task settled: \(handle.label)") { handle.outcome.withLockedValue { $0 != nil } }
        return try #require(handle.outcome.withLockedValue { $0 })
    }
    func value(_ handle: ApplyTestTask) async throws {
        let outcome = try await result(handle)
        try outcome.get()
    }
    func cleanup() async -> Bool {
        for gate in gates { gate.open() }
        for signal in signals { signal.signal() }
        let handles = tasks.withLockedValue { $0 }
        // One shared five-second observation window for all handles, drain and
        // shutdown, not a fresh timeout per join. The joined task is not cancelled
        // or forgotten when the observer expires; it retains self and its errors.
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        Task { [self] in
            var errors: [String] = []
            for handle in handles {
                cleanupState.withLockedValue { $0.phase = "joining \(handle.label)" }
                let outcome = await handle.task.value
                await handle.joined.value
                if case .failure(let error) = outcome {
                    errors.append("\(handle.label): \(error)")
                    cleanupState.withLockedValue { $0.errors = errors }
                }
            }
            cleanupState.withLockedValue { $0.phase = "service drain" }
            await service.closeAdmissionAndDrain()
            cleanupState.withLockedValue { $0.phase = "pool shutdown" }
            await pool.shutdown()
            let reportLate = cleanupState.withLockedValue {
                $0.errors = errors; $0.confirmed = true; $0.phase = "settled"; return $0.observerReturned
            }
            if reportLate {
                let callbacks = unexpected.withLockedValue { $0 }.map { "\($0.label)=\($0.snapshot)" }
                print("RelayApply \(name) fixture cleanup settled after observer returned; task outcomes=\(errors); callbacks=\(callbacks)")
            }
        }
        while !cleanupState.withLockedValue({ $0.confirmed }) && DispatchTime.now().uptimeNanoseconds < deadline {
            // Cleanup observation must also progress after task cancellation;
            // Task.sleep would immediately throw and turn this into a spin loop.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { continuation.resume() }
            }
        }
        return cleanupState.withLockedValue { $0.observerReturned = true; return $0.confirmed }
    }
    func assertCallbackOracles() {
        for observation in unexpected.withLockedValue({ $0 }) {
            let counts = observation.snapshot
            #expect(counts.operation == 0, Comment(rawValue: "\(observation.label): forbidden work executed"))
            #expect(counts.publication == 0, Comment(rawValue: "\(observation.label): forbidden work published"))
        }
    }
    var cleanupErrors: [String] { cleanupState.withLockedValue { $0.errors } }
    var cleanupDiagnostic: String { cleanupState.withLockedValue { "phase=\($0.phase) outcomes=\($0.errors)" } }
}

@Suite(.timeLimit(.minutes(1)))
struct RelayApplyAdmissionTests {
    private func withFixture(_ pool: RelayExecutionPool, _ service: RelayApplyAdmission,
                             gates: [ApplyTestGate] = [], signals: [ApplyTestSignal] = [],
                             name: String = #function, _ body: (ApplyTestFixture) async throws -> Void) async throws {
        let fixture = ApplyTestFixture(name: name, service: service, pool: pool, gates: gates, signals: signals)
        var primary: (any Error)?
        do { try await body(fixture) } catch { primary = error }
        let confirmed = await fixture.cleanup()
        if confirmed {
            fixture.assertCallbackOracles()
        } else {
            Issue.record(Comment(rawValue: "cleanup unconfirmed after one shared five-second observation; "
                + "cleanup task/handles remain outstanding, following-case isolation is not established; \(fixture.diagnostic)"))
            print("RelayApply fixture cleanup: \(fixture.cleanupDiagnostic)")
        }
        if let primary {
            print("RelayApply fixture retained task outcomes: \(fixture.cleanupErrors)")
            throw primary
        }
        if !confirmed { throw ApplyFixtureError.cleanupUnconfirmed }
    }
    private func expectFailure(_ fixture: ApplyTestFixture, _ handle: ApplyTestTask,
                               _ expected: RelayApplyAdmissionError, _ message: String) async throws {
        // Keep observation timeout/cancellation errors outside the expected
        // product-error branch so cleanup can preserve the original error.
        switch try await fixture.result(handle) {
        case .success: Issue.record(Comment(rawValue: message))
        case .failure(let error): #expect(error as? RelayApplyAdmissionError == expected)
        }
    }
    private func rejected(_ fixture: ApplyTestFixture, bytes: [UInt8],
                          expected: RelayApplyAdmissionError) async throws {
        let observation = fixture.forbidCallbacks("rejected \(expected)")
        let service = fixture.service
        let attempt = fixture.start("rejected \(expected)") {
            try await service.withAdmission(for: "reject", buffer: ByteBuffer(bytes: bytes),
                operation: { _ in observation.operation() }, completion: { _ in observation.publication() })
        }
        try await expectFailure(fixture, attempt, expected, "expected admission rejection")
    }

    @Test func countAndOwnedInputCapsIncludeDelayedPublication() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-caps")
        let service = RelayApplyAdmission(pool: pool, maxRequests: 2, maxInputBytes: 4)
        let hold = ApplyTestSignal(), holdEmpty = ApplyTestSignal(), actual = NIOLockedValueBox<Int?>(nil)
        try await withFixture(pool, service, signals: [hold, holdEmpty]) { fixture in
            let first = fixture.start("first") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1, 2, 3, 4]),
                    operation: { $0.count }, completion: { count in actual.withLockedValue { $0 = count }; await hold.wait() })
            }
            try await fixture.until("first publication callback", details: { "actual=\(String(describing: actual.withLockedValue { $0 }))" }) { service.snapshot.publishing == 1 && actual.withLockedValue { $0 != nil } }
            #expect(actual.withLockedValue { $0 } == 4)
            #expect(service.snapshot.inputBytes == 4)
            try await rejected(fixture, bytes: [5], expected: .overloaded)
            let empty = fixture.start("empty") {
                try await service.withAdmission(for: "B", buffer: ByteBuffer(), operation: { _ in 0 },
                                                completion: { _ in await holdEmpty.wait() })
            }
            try await fixture.until("two publications") { service.snapshot.publishing == 2 }
            try await rejected(fixture, bytes: [], expected: .overloaded)
            hold.signal(); holdEmpty.signal()
            try await fixture.value(first); try await fixture.value(empty)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        }
    }

    @Test func smallSliceBecomesOwnedBytesAndRunsOnTheExistingWorker() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-copy")
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 32)
        try await withFixture(pool, service) { fixture in
            var backing = ByteBufferAllocator().buffer(capacity: 1 << 20)
            backing.writeRepeatingByte(42, count: 1 << 20)
            let slice = try #require(backing.getSlice(at: 1024, length: 32))
            let borrowedAddress = slice.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress!) }
            let facts = NIOLockedValueBox((worker: false, bytes: false, distinct: false, stack: false))
            let count = NIOLockedValueBox<Int?>(nil)
            let request = fixture.start("owned slice") {
                try await service.withAdmission(for: "A", buffer: slice, operation: { data in
                    var stack = true
                    #if canImport(Darwin)
                    stack = pthread_get_stacksize_np(pthread_self()) >= RelayExecutionPool.stackSize
                    #endif
                    facts.withLockedValue {
                        $0 = (pool.isCurrentWorker, data == Data(repeating: 42, count: 32),
                              data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } != borrowedAddress, stack)
                    }
                    return data.count
                }, completion: { value in count.withLockedValue { $0 = value } })
            }
            try await fixture.value(request)
            let observed = facts.withLockedValue { $0 }
            #expect(observed.worker); #expect(observed.bytes); #expect(observed.distinct)
            #if canImport(Darwin)
            #expect(observed.stack)
            #endif
            #expect(count.withLockedValue { $0 } == 32)
            #expect(service.snapshot.requests == 0)
        }
        #expect(pool.snapshot.startedWorkers == 2 && pool.snapshot.liveWorkers == 0)
    }

    @Test func slowCopyKeepsItsFIFOPositionWhileAnotherFileProgresses() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-prepare")
        let gate = ApplyTestGate(), copies = NIOLockedValueBox(0)
        let service = RelayApplyAdmission(pool: pool, beforeCopyForTesting: {
            if copies.withLockedValue({ $0 += 1; return $0 }) == 1 { await gate.waitForPreparation() }
        })
        let order = NIOLockedValueBox<[Int]>([]), facts = NIOLockedValueBox((worker: false, noOvertake: false))
        try await withFixture(pool, service, gates: [gate]) { fixture in
            let first = fixture.start("first") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]),
                    operation: { _ in order.withLockedValue { $0.append(1) } }, completion: { _ in })
            }
            try await fixture.until("first copy entered", holding: gate) { gate.snapshot.enteredNS != nil }
            let second = fixture.start("second") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [2]),
                    operation: { _ in order.withLockedValue { $0.append(2) } }, completion: { _ in })
            }
            try await fixture.until("same-file copy queued", holding: gate) { service.snapshot.preparing == 1 && service.snapshot.queued == 1 }
            let other = fixture.start("other file") {
                try await service.withAdmission(for: "B", buffer: ByteBuffer(), operation: { _ in
                    facts.withLockedValue { $0 = (pool.isCurrentWorker, order.withLockedValue { $0.isEmpty }) }
                    gate.open()
                }, completion: { _ in })
            }
            try await fixture.value(other)
            #expect(facts.withLockedValue { $0.worker }); #expect(facts.withLockedValue { $0.noOvertake })
            try await fixture.value(first); try await fixture.value(second)
            #expect(order.withLockedValue { $0 } == [1, 2])
            #expect(!gate.snapshot.timedOut)
        }
    }

    @Test func queuedCancellationRemovesOnlyItsRequestAndPreservesFollowingOrder() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-queued")
        let service = RelayApplyAdmission(pool: pool)
        let gate = ApplyTestGate(), order = NIOLockedValueBox<[Int]>([])
        try await withFixture(pool, service, gates: [gate]) { fixture in
            let first = fixture.start("first") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                    gate.block(); order.withLockedValue { $0.append(1) }
                }, completion: { _ in })
            }
            try await fixture.until("first running", holding: gate) { service.snapshot.running == 1 && gate.snapshot.enteredNS != nil }
            let forbidden = fixture.forbidCallbacks("cancelled queued")
            let cancelled = fixture.start("cancelled queued") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [2]),
                    operation: { _ in forbidden.operation() }, completion: { _ in forbidden.publication() })
            }
            try await fixture.until("second queued", holding: gate) { service.snapshot.queued == 1 }
            let third = fixture.start("third") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [3]),
                    operation: { _ in order.withLockedValue { $0.append(3) } }, completion: { _ in })
            }
            try await fixture.until("two queued", holding: gate) { service.snapshot.queued == 2 }
            cancelled.cancel()
            try await expectFailure(fixture, cancelled, .cancelled, "queued cancellation succeeded")
            try #require(gate.snapshot.held, Comment(rawValue: fixture.diagnostic))
            #expect(service.snapshot.requests == 2 && service.snapshot.inputBytes == 2)
            gate.open()
            try await fixture.value(first); try await fixture.value(third)
            #expect(order.withLockedValue { $0 } == [1, 3])
            #expect(!gate.snapshot.timedOut)
        }
    }

    @Test func submittedCancellationKeepsATombstoneUntilItsIOTurn() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.apply-tombstone")
        let gate = ApplyTestGate()
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 1)
        try await withFixture(pool, service, gates: [gate]) { fixture in
            pool.submitRequired(for: "occupied") { gate.block() }
            try await fixture.until("occupied worker entered", holding: gate) { gate.snapshot.enteredNS != nil }
            let forbidden = fixture.forbidCallbacks("submitted cancelled")
            let request = fixture.start("submitted cancelled") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]),
                    operation: { _ in forbidden.operation() }, completion: { _ in forbidden.publication() })
            }
            try await fixture.until("submitted tombstone", holding: gate) { service.snapshot.submitted == 1 }
            request.cancel()
            #expect(service.snapshot.requests == 1)
            try await rejected(fixture, bytes: [], expected: .overloaded)
            try #require(gate.snapshot.held, Comment(rawValue: fixture.diagnostic))
            gate.open()
            try await expectFailure(fixture, request, .cancelled, "submitted cancellation succeeded")
            #expect(service.snapshot.requests == 0)
            #expect(!gate.snapshot.timedOut)
        }
    }

    @Test func runningCancellationPreservesResultAndDrainWaitsForPublication() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-running")
        let service = RelayApplyAdmission(pool: pool)
        let gate = ApplyTestGate(), publishing = ApplyTestSignal()
        let actual = NIOLockedValueBox<Int?>(nil), drained = NIOLockedValueBox(false)
        try await withFixture(pool, service, gates: [gate], signals: [publishing]) { fixture in
            let request = fixture.start("running request") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [9]), operation: { _ in
                    gate.block(); return 41
                }, completion: { value in actual.withLockedValue { $0 = value }; await publishing.wait() })
            }
            try await fixture.until("request running", holding: gate) { service.snapshot.running == 1 && gate.snapshot.enteredNS != nil }
            request.cancel()
            let drain = fixture.start("drain") { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
            try await fixture.until("admission closed", holding: gate) { service.snapshot.closed }
            try await rejected(fixture, bytes: [], expected: .shutdown)
            try #require(gate.snapshot.held, Comment(rawValue: fixture.diagnostic))
            #expect(!drained.withLockedValue { $0 })
            gate.open()
            try await fixture.until("actual publication callback", details: { "actual=\(String(describing: actual.withLockedValue { $0 }))" }) { service.snapshot.publishing == 1 && actual.withLockedValue { $0 == 41 } }
            #expect(actual.withLockedValue { $0 } == 41)
            #expect(service.snapshot.inputBytes == 1 && !drained.withLockedValue { $0 })
            publishing.signal()
            try await fixture.value(request); try await fixture.value(drain)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
            #expect(!gate.snapshot.timedOut)
        }
    }

    @Test func cancellationDuringPreparingNeverRunsAndClosesCleanly() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-copy-cancel")
        let gate = ApplyTestGate()
        let service = RelayApplyAdmission(pool: pool, beforeCopyForTesting: { await gate.waitForPreparation() })
        try await withFixture(pool, service, gates: [gate]) { fixture in
            let forbidden = fixture.forbidCallbacks("cancelled preparation")
            let request = fixture.start("cancelled preparation") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [9]),
                    operation: { _ in forbidden.operation() }, completion: { _ in forbidden.publication() })
            }
            try await fixture.until("preparation entered", holding: gate) { gate.snapshot.enteredNS != nil }
            request.cancel()
            #expect(service.snapshot.preparing == 1 && service.snapshot.inputBytes == 1)
            gate.open()
            try await expectFailure(fixture, request, .cancelled, "preparation cancellation succeeded")
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        }
    }

    @Test func stoppedWorkerPoolRejectsWithoutLeavingAReservation() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.apply-stopped")
        let service = RelayApplyAdmission(pool: pool)
        try await withFixture(pool, service) { fixture in
            let stop = fixture.start("stop empty pool") { await pool.shutdown() }
            try await fixture.value(stop)
            try await rejected(fixture, bytes: [1], expected: .shutdown)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        }
    }

    @Test(arguments: [false, true])
    func pendingSubmittedShutdownKeepsItsChargeAndFirstStopReason(cancelFirst: Bool) async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.apply-pending-stop")
        let gate = ApplyTestGate(), cancellation = NIOLockedValueBox<RelayApplyTestCancellation?>(nil)
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 1,
            didReserveForTesting: { handle in cancellation.withLockedValue { $0 = handle } })
        let drained = NIOLockedValueBox(false), returned = NIOLockedValueBox(false)
        try await withFixture(pool, service, gates: [gate]) { fixture in
            pool.submitRequired(for: "occupied") { gate.block() }
            try await fixture.until("occupied worker entered", holding: gate) { gate.snapshot.enteredNS != nil }
            let forbidden = fixture.forbidCallbacks("pending shutdown cancelFirst=\(cancelFirst)")
            let request = fixture.start("pending shutdown") {
                defer { returned.withLockedValue { $0 = true } }
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]),
                    operation: { _ in forbidden.operation() }, completion: { _ in forbidden.publication() })
            }
            try await fixture.until("request submitted", holding: gate) { service.snapshot.submitted == 1 }
            // The same synchronous task-handler transition establishes first reason.
            if cancelFirst { try #require(cancellation.withLockedValue { $0 }).cancel() }
            let drain = fixture.start("drain") { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
            try await fixture.until("admission closed", holding: gate) { service.snapshot.closed }
            #expect(service.snapshot.submitted == 1)
            #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 1)
            #expect(!drained.withLockedValue { $0 } && !returned.withLockedValue { $0 })
            try await rejected(fixture, bytes: [], expected: .shutdown)
            try #require(gate.snapshot.held, Comment(rawValue: fixture.diagnostic))
            gate.open()
            let expected: RelayApplyAdmissionError = cancelFirst ? .cancelled : .shutdown
            try await expectFailure(fixture, request, expected, "pending shutdown succeeded")
            try await fixture.value(drain)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
            #expect(!gate.snapshot.timedOut)
        }
        cancellation.withLockedValue { $0 = nil }
    }

    @Test func pendingPreparationShutdownWaitsForCopySettlement() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-preparing-stop")
        let gate = ApplyTestGate(), drained = NIOLockedValueBox(false)
        let service = RelayApplyAdmission(pool: pool, beforeCopyForTesting: { await gate.waitForPreparation() })
        try await withFixture(pool, service, gates: [gate]) { fixture in
            let forbidden = fixture.forbidCallbacks("preparing shutdown")
            let request = fixture.start("preparing shutdown") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [9]),
                    operation: { _ in forbidden.operation() }, completion: { _ in forbidden.publication() })
            }
            try await fixture.until("preparation entered", holding: gate) { gate.snapshot.enteredNS != nil }
            let drain = fixture.start("drain") { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
            try await fixture.until("admission closed", holding: gate) { service.snapshot.closed }
            #expect(service.snapshot.preparing == 1)
            #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 1)
            #expect(!drained.withLockedValue { $0 })
            gate.open()
            try await expectFailure(fixture, request, .shutdown, "preparing shutdown succeeded")
            try await fixture.value(drain)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
            #expect(!gate.snapshot.timedOut)
        }
    }

    @Test func pendingQueuedShutdownRejectsWithoutDiscardingItsRunningPredecessor() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-queued-stop")
        let service = RelayApplyAdmission(pool: pool)
        let gate = ApplyTestGate(), drained = NIOLockedValueBox(false), firstResult = NIOLockedValueBox<Int?>(nil)
        try await withFixture(pool, service, gates: [gate]) { fixture in
            let first = fixture.start("running predecessor") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                    gate.block(); return 17
                }, completion: { value in firstResult.withLockedValue { $0 = value } })
            }
            try await fixture.until("predecessor running", holding: gate) { service.snapshot.running == 1 && gate.snapshot.enteredNS != nil }
            let forbidden = fixture.forbidCallbacks("queued shutdown")
            let queued = fixture.start("queued shutdown") {
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [2]),
                    operation: { _ in forbidden.operation() }, completion: { _ in forbidden.publication() })
            }
            try await fixture.until("successor queued", holding: gate) { service.snapshot.queued == 1 }
            let drain = fixture.start("drain") { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
            try await expectFailure(fixture, queued, .shutdown, "queued shutdown succeeded")
            try #require(gate.snapshot.held, Comment(rawValue: fixture.diagnostic))
            #expect(service.snapshot.closed && service.snapshot.running == 1)
            #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 1)
            #expect(!drained.withLockedValue { $0 })
            gate.open()
            try await fixture.value(first); try await fixture.value(drain)
            #expect(firstResult.withLockedValue { $0 } == 17)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
            #expect(!gate.snapshot.timedOut)
        }
    }

    @Test func resumedInputAliasStaysChargedUntilWorkerAndConsumerBothRelease() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-publication")
        let gate = ApplyTestGate()
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 3,
                                          afterResumeForTesting: { gate.block() })
        let consumed = NIOLockedValueBox(false), returned = NIOLockedValueBox(false), exactBytes = NIOLockedValueBox(false)
        try await withFixture(pool, service, gates: [gate]) { fixture in
            let request = fixture.start("input alias") {
                // Return an alias, but record only its equality result in the
                // consumer: the test must not retain another Data alias.
                try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1, 2, 3]), operation: { $0 },
                    completion: { bytes in
                        exactBytes.withLockedValue { $0 = bytes == Data([1, 2, 3]) }
                        consumed.withLockedValue { $0 = true }
                    })
                returned.withLockedValue { $0 = true }
            }
            try await fixture.until("worker held and consumer completed", holding: gate, details: {
                "consumed=\(consumed.withLockedValue { $0 }) returned=\(returned.withLockedValue { $0 }) exactBytes=\(exactBytes.withLockedValue { $0 })"
            }) {
                gate.snapshot.enteredNS != nil && consumed.withLockedValue { $0 }
            }
            #expect(exactBytes.withLockedValue { $0 })
            #expect(!returned.withLockedValue { $0 })
            #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 3)
            try await rejected(fixture, bytes: [], expected: .overloaded)
            try #require(gate.snapshot.held, Comment(rawValue: fixture.diagnostic))
            gate.open()
            try await fixture.value(request)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
            #expect(!gate.snapshot.timedOut)
        }
    }
}
