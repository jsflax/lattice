import Foundation
import Testing
import NIOCore
import NIOConcurrencyHelpers
@testable import LatticeServerKit
#if canImport(Darwin)
import Darwin
#endif

private final class ApplyTestGate: Sendable {
    let entered = NIOLockedValueBox(false)
    let release = DispatchSemaphore(value: 0)
    let timedOut = NIOLockedValueBox(false)
    func block() {
        entered.withLockedValue { $0 = true }
        timedOut.withLockedValue { $0 = release.wait(timeout: .now() + 5) != .success }
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

@Suite(.timeLimit(.minutes(1)))
struct RelayApplyAdmissionTests {
    private func until(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !predicate() {
            try #require(DispatchTime.now().uptimeNanoseconds < deadline, "bounded state wait expired")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func rejected(_ service: RelayApplyAdmission, bytes: [UInt8],
                          expected: RelayApplyAdmissionError) async {
        do {
            try await service.withAdmission(for: "reject", buffer: ByteBuffer(bytes: bytes), operation: { _ in
                Issue.record("rejected work executed")
            }, completion: { _ in Issue.record("rejected work published") })
            Issue.record("expected admission rejection")
        } catch { #expect(error as? RelayApplyAdmissionError == expected) }
    }

    @Test func countAndOwnedInputCapsIncludeDelayedPublication() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-caps")
        let service = RelayApplyAdmission(pool: pool, maxRequests: 2, maxInputBytes: 4)
        let hold = ApplyTestSignal(), holdEmpty = ApplyTestSignal()
        defer { hold.signal(); holdEmpty.signal() }
        let first = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1, 2, 3, 4]),
                                            operation: { data in data.count },
                                            completion: { count in #expect(count == 4); await hold.wait() })
        }
        try await until { service.snapshot.publishing == 1 }
        #expect(service.snapshot.inputBytes == 4)
        await rejected(service, bytes: [5], expected: .overloaded)
        let empty = Task {
            try await service.withAdmission(for: "B", buffer: ByteBuffer(), operation: { _ in 0 },
                                            completion: { _ in await holdEmpty.wait() })
        }
        try await until { service.snapshot.publishing == 2 }
        await rejected(service, bytes: [], expected: .overloaded)
        hold.signal(); holdEmpty.signal()
        try await first.value; try await empty.value
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        await service.closeAdmissionAndDrain(); await pool.shutdown()
    }

    @Test func smallSliceBecomesOwnedBytesAndRunsOnTheExistingWorker() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-copy")
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 32)
        var backing = ByteBufferAllocator().buffer(capacity: 1 << 20)
        backing.writeRepeatingByte(42, count: 1 << 20)
        let slice = try #require(backing.getSlice(at: 1024, length: 32))
        let borrowedAddress = slice.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress!) }
        try await service.withAdmission(for: "A", buffer: slice, operation: { data in
            #expect(pool.isCurrentWorker)
            #expect(data == Data(repeating: 42, count: 32))
            #expect(data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } != borrowedAddress)
            #if canImport(Darwin)
            #expect(pthread_get_stacksize_np(pthread_self()) >= RelayExecutionPool.stackSize)
            #endif
            return data.count
        }, completion: { count in #expect(count == 32) })
        #expect(service.snapshot.requests == 0)
        await service.closeAdmissionAndDrain(); await pool.shutdown()
        #expect(pool.snapshot.startedWorkers == 2 && pool.snapshot.liveWorkers == 0)
    }

    @Test func slowCopyKeepsItsFIFOPositionWhileAnotherFileProgresses() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-prepare")
        let gate = ApplyTestGate()
        let copies = NIOLockedValueBox(0)
        let service = RelayApplyAdmission(pool: pool, beforeCopyForTesting: {
            if copies.withLockedValue({ $0 += 1; return $0 }) == 1 { gate.block() }
        })
        let order = NIOLockedValueBox<[Int]>([])
        defer { gate.release.signal() }
        let first = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                order.withLockedValue { $0.append(1) }
            }, completion: { _ in })
        }
        try await until { gate.entered.withLockedValue { $0 } }
        let second = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [2]), operation: { _ in
                order.withLockedValue { $0.append(2) }
            }, completion: { _ in })
        }
        try await until { service.snapshot.preparing == 1 && service.snapshot.queued == 1 }
        try await service.withAdmission(for: "B", buffer: ByteBuffer(), operation: { _ in
            #expect(pool.isCurrentWorker)
            #expect(order.withLockedValue { $0.isEmpty })
            gate.release.signal()
        }, completion: { _ in })
        try await first.value; try await second.value
        #expect(order.withLockedValue { $0 } == [1, 2])
        #expect(!gate.timedOut.withLockedValue { $0 })
        await service.closeAdmissionAndDrain(); await pool.shutdown()
    }

    @Test func queuedCancellationRemovesOnlyItsRequestAndPreservesFollowingOrder() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-queued")
        let service = RelayApplyAdmission(pool: pool)
        let gate = ApplyTestGate(), order = NIOLockedValueBox<[Int]>([])
        defer { gate.release.signal() }
        let first = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                gate.block(); order.withLockedValue { $0.append(1) }
            }, completion: { _ in })
        }
        try await until { service.snapshot.running == 1 }
        let cancelled = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [2]), operation: { _ in
                Issue.record("cancelled queued body ran")
            }, completion: { _ in Issue.record("cancelled queued body published") })
        }
        try await until { service.snapshot.queued == 1 }
        let third = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [3]), operation: { _ in
                order.withLockedValue { $0.append(3) }
            }, completion: { _ in })
        }
        try await until { service.snapshot.queued == 2 }
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("queued cancellation succeeded") }
        catch { #expect(error as? RelayApplyAdmissionError == .cancelled) }
        #expect(service.snapshot.requests == 2 && service.snapshot.inputBytes == 2)
        gate.release.signal()
        try await first.value; try await third.value
        #expect(order.withLockedValue { $0 } == [1, 3])
        #expect(!gate.timedOut.withLockedValue { $0 })
        await service.closeAdmissionAndDrain(); await pool.shutdown()
    }

    @Test func submittedCancellationKeepsATombstoneUntilItsIOTurn() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.apply-tombstone")
        let gate = ApplyTestGate()
        pool.submitRequired(for: "occupied") { gate.block() }
        defer { gate.release.signal() }
        try await until { gate.entered.withLockedValue { $0 } }
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 1)
        let request = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                Issue.record("submitted cancelled body ran")
            }, completion: { _ in Issue.record("submitted cancelled body published") })
        }
        try await until { service.snapshot.submitted == 1 }
        request.cancel()
        #expect(service.snapshot.requests == 1)
        await rejected(service, bytes: [], expected: .overloaded)
        gate.release.signal()
        do { try await request.value; Issue.record("submitted cancellation succeeded") }
        catch { #expect(error as? RelayApplyAdmissionError == .cancelled) }
        #expect(service.snapshot.requests == 0)
        #expect(!gate.timedOut.withLockedValue { $0 })
        await service.closeAdmissionAndDrain(); await pool.shutdown()
    }

    @Test func runningCancellationPreservesResultAndDrainWaitsForPublication() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-running")
        let service = RelayApplyAdmission(pool: pool)
        let gate = ApplyTestGate(), publishing = ApplyTestSignal()
        let actual = NIOLockedValueBox<Int?>(nil), drained = NIOLockedValueBox(false)
        defer { gate.release.signal(); publishing.signal() }
        let request = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [9]), operation: { _ in
                gate.block(); return 41
            }, completion: { value in actual.withLockedValue { $0 = value }; await publishing.wait() })
        }
        try await until { service.snapshot.running == 1 }
        request.cancel()
        let drain = Task { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
        try await until { service.snapshot.closed }
        await rejected(service, bytes: [], expected: .shutdown)
        #expect(!drained.withLockedValue { $0 })
        gate.release.signal()
        try await until { service.snapshot.publishing == 1 && actual.withLockedValue { $0 == 41 } }
        #expect(actual.withLockedValue { $0 } == 41)
        #expect(service.snapshot.inputBytes == 1 && !drained.withLockedValue { $0 })
        publishing.signal()
        try await request.value; await drain.value
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        #expect(!gate.timedOut.withLockedValue { $0 })
        await pool.shutdown()
    }

    @Test func cancellationDuringPreparingNeverRunsAndClosesCleanly() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-copy-cancel")
        let gate = ApplyTestGate()
        let service = RelayApplyAdmission(pool: pool, beforeCopyForTesting: { gate.block() })
        defer { gate.release.signal() }
        let request = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [9]), operation: { _ in
                Issue.record("cancelled preparation ran")
            }, completion: { _ in Issue.record("cancelled preparation published") })
        }
        try await until { gate.entered.withLockedValue { $0 } }
        request.cancel()
        #expect(service.snapshot.preparing == 1 && service.snapshot.inputBytes == 1)
        gate.release.signal()
        do { try await request.value; Issue.record("preparation cancellation succeeded") }
        catch { #expect(error as? RelayApplyAdmissionError == .cancelled) }
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        await service.closeAdmissionAndDrain(); await pool.shutdown()
    }

    @Test func stoppedWorkerPoolRejectsWithoutLeavingAReservation() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.apply-stopped")
        await pool.shutdown()
        let service = RelayApplyAdmission(pool: pool)
        await rejected(service, bytes: [1], expected: .shutdown)
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        await service.closeAdmissionAndDrain()
    }

    @Test(arguments: [false, true])
    func pendingSubmittedShutdownKeepsItsChargeAndFirstStopReason(cancelFirst: Bool) async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.apply-pending-stop")
        let gate = ApplyTestGate()
        pool.submitRequired(for: "occupied") { gate.block() }
        defer { gate.release.signal() }
        try await until { gate.entered.withLockedValue { $0 } }
        let cancellation = NIOLockedValueBox<RelayApplyTestCancellation?>(nil)
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 1,
            didReserveForTesting: { handle in cancellation.withLockedValue { $0 = handle } })
        let drained = NIOLockedValueBox(false), returned = NIOLockedValueBox(false)
        let request = Task {
            defer { returned.withLockedValue { $0 = true } }
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                Issue.record("pending shutdown body ran")
            }, completion: { _ in Issue.record("pending shutdown body published") })
        }
        try await until { service.snapshot.submitted == 1 }
        // Invoke the task-handler transition synchronously to establish its
        // order before close, rather than relying on task scheduling timing.
        if cancelFirst { try #require(cancellation.withLockedValue { $0 }).cancel() }
        let drain = Task { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
        try await until { service.snapshot.closed }
        #expect(service.snapshot.submitted == 1)
        #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 1)
        #expect(!drained.withLockedValue { $0 } && !returned.withLockedValue { $0 })
        await rejected(service, bytes: [], expected: .shutdown)
        gate.release.signal()
        let expected: RelayApplyAdmissionError = cancelFirst ? .cancelled : .shutdown
        do { try await request.value; Issue.record("pending shutdown succeeded") }
        catch { #expect(error as? RelayApplyAdmissionError == expected) }
        await drain.value
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        #expect(!gate.timedOut.withLockedValue { $0 })
        cancellation.withLockedValue { $0 = nil }
        await pool.shutdown()
    }

    @Test func pendingPreparationShutdownWaitsForCopySettlement() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-preparing-stop")
        let gate = ApplyTestGate(), drained = NIOLockedValueBox(false)
        let service = RelayApplyAdmission(pool: pool, beforeCopyForTesting: { gate.block() })
        defer { gate.release.signal() }
        let request = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [9]), operation: { _ in
                Issue.record("preparing shutdown body ran")
            }, completion: { _ in Issue.record("preparing shutdown body published") })
        }
        try await until { gate.entered.withLockedValue { $0 } }
        let drain = Task { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
        try await until { service.snapshot.closed }
        #expect(service.snapshot.preparing == 1)
        #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 1)
        #expect(!drained.withLockedValue { $0 })
        gate.release.signal()
        do { try await request.value; Issue.record("preparing shutdown succeeded") }
        catch { #expect(error as? RelayApplyAdmissionError == .shutdown) }
        await drain.value
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        #expect(!gate.timedOut.withLockedValue { $0 })
        await pool.shutdown()
    }

    @Test func pendingQueuedShutdownRejectsWithoutDiscardingItsRunningPredecessor() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-queued-stop")
        let service = RelayApplyAdmission(pool: pool)
        let gate = ApplyTestGate(), drained = NIOLockedValueBox(false)
        let firstResult = NIOLockedValueBox<Int?>(nil)
        defer { gate.release.signal() }
        let first = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1]), operation: { _ in
                gate.block(); return 17
            }, completion: { value in firstResult.withLockedValue { $0 = value } })
        }
        try await until { service.snapshot.running == 1 }
        let queued = Task {
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [2]), operation: { _ in
                Issue.record("queued shutdown body ran")
            }, completion: { _ in Issue.record("queued shutdown body published") })
        }
        try await until { service.snapshot.queued == 1 }
        let drain = Task { await service.closeAdmissionAndDrain(); drained.withLockedValue { $0 = true } }
        do { try await queued.value; Issue.record("queued shutdown succeeded") }
        catch { #expect(error as? RelayApplyAdmissionError == .shutdown) }
        #expect(service.snapshot.closed && service.snapshot.running == 1)
        #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 1)
        #expect(!drained.withLockedValue { $0 })
        gate.release.signal()
        try await first.value; await drain.value
        #expect(firstResult.withLockedValue { $0 } == 17)
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        #expect(!gate.timedOut.withLockedValue { $0 })
        await pool.shutdown()
    }

    @Test func resumedInputAliasStaysChargedUntilWorkerAndConsumerBothRelease() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.apply-publication")
        let gate = ApplyTestGate()
        let service = RelayApplyAdmission(pool: pool, maxRequests: 1, maxInputBytes: 3,
                                          afterResumeForTesting: { gate.block() })
        let consumed = NIOLockedValueBox(false), returned = NIOLockedValueBox(false)
        defer { gate.release.signal() }
        let request = Task {
            // Return an alias of the charged input to expose publication custody.
            try await service.withAdmission(for: "A", buffer: ByteBuffer(bytes: [1, 2, 3]), operation: { $0 },
                                            completion: { bytes in
                #expect(bytes == Data([1, 2, 3])); consumed.withLockedValue { $0 = true }
            })
            returned.withLockedValue { $0 = true }
        }
        try await until { gate.entered.withLockedValue { $0 } && consumed.withLockedValue { $0 } }
        #expect(!returned.withLockedValue { $0 })
        #expect(service.snapshot.requests == 1 && service.snapshot.inputBytes == 3)
        await rejected(service, bytes: [], expected: .overloaded)
        gate.release.signal()
        try await request.value
        #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        #expect(!gate.timedOut.withLockedValue { $0 })
        await service.closeAdmissionAndDrain(); await pool.shutdown()
    }
}
