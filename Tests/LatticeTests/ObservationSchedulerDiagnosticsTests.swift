import Foundation
import Dispatch
import Testing
@testable import Lattice

private final class ObservationDiagnosticsClock: Sendable {
    private let value = LockedBox<UInt64>(100)

    func now() -> UInt64 { value.withLock { $0 } }
    func set(_ time: UInt64) {
        value.withLock {
            precondition(time >= $0)
            $0 = time
        }
    }
}

private final class ObservationDiagnosticsGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
}

@Suite("Observation scheduler diagnostics", .serialized)
struct ObservationSchedulerDiagnosticsTests {
    private typealias Completion = ObservationTurnScheduler.Completion

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            try #require(DispatchTime.now().uptimeNanoseconds < end, "diagnostic fixture did not settle")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test func publicSnapshotReportsConfiguredBoundsAndNoInventedAges() async throws {
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 3)
        let snapshot = scheduler.diagnostics
        #expect(snapshot.workerCount == 2)
        #expect(snapshot.maxSubscriptions == 3)
        #expect(snapshot.subscriptions == 0)
        #expect(snapshot.pendingSubscriptions == 0)
        #expect(snapshot.readySubscriptions == 0)
        #expect(snapshot.pendingWhileAdmitted == 0)
        #expect(snapshot.admittedTurns == 0)
        #expect(snapshot.bodiesRunning == 0)
        #expect(snapshot.awaitingAcknowledgement == 0)
        #expect(snapshot.oldestPendingAgeNanoseconds == nil)
        #expect(snapshot.oldestReadyAgeNanoseconds == nil)
        #expect(snapshot.oldestAdmittedAgeNanoseconds == nil)
        #expect(snapshot.oldestAwaitingAcknowledgementAgeNanoseconds == nil)
        #expect(snapshot.lastCompletedTurn == nil)
        await scheduler.turns.shutdown()
    }

    @Test func coalescingPreservesFirstPendingAgeAndQueuedCancellationClearsIt() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 2, now: { clock.now() })
        let gate = ObservationDiagnosticsGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let timedOut = LockedBox(false)
        let unexpectedRuns = LockedBox(0)
        let blocker = try scheduler.register(storeID: 1) { _, _ in
            // Diagnostics must remain callable from an admitted body.
            _ = scheduler.diagnostics
            entered.withLock { $0 = true }
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        let queued = try scheduler.register(storeID: 2) { _, _ in unexpectedRuns.withLock { $0 += 1 } }
        blocker.notify(revision: 0)
        try await waitUntil { entered.withLock { $0 } }
        clock.set(110)
        queued.notify(revision: 7)
        clock.set(120)
        queued.notify(revision: 7)
        clock.set(130)
        queued.notify(revision: 1) // Revisions remain opaque arrival values.
        clock.set(140)
        let snapshot = scheduler.diagnostics
        #expect(snapshot.pendingSubscriptions == 1)
        #expect(snapshot.readySubscriptions == 1)
        #expect(snapshot.pendingWhileAdmitted == 0)
        #expect(snapshot.oldestPendingAgeNanoseconds == 30)
        #expect(snapshot.oldestReadyAgeNanoseconds == 30)
        #expect(snapshot.admittedTurns == 1)
        #expect(snapshot.bodiesRunning == 1)
        #expect(snapshot.awaitingAcknowledgement == 0)
        #expect(snapshot.oldestAdmittedAgeNanoseconds == 40)
        #expect(snapshot.lastCompletedTurn == nil)

        await queued.cancelAndWait()
        queued.cancel()
        queued.notify(revision: 9)
        let cancelled = scheduler.diagnostics
        #expect(cancelled.subscriptions == 1)
        #expect(cancelled.pendingSubscriptions == 0)
        #expect(cancelled.readySubscriptions == 0)
        #expect(cancelled.oldestPendingAgeNanoseconds == nil)
        #expect(cancelled.oldestReadyAgeNanoseconds == nil)
        #expect(cancelled.oldestAdmittedAgeNanoseconds == 40)
        clock.set(150)
        gate.open()
        await blocker.cancelAndWait()
        #expect(unexpectedRuns.withLock { $0 } == 0)
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func dirtyHeldTurnRetainsPendingAgeThroughFairRequeueAndAcknowledgement() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 2, now: { clock.now() })
        let held = LockedBox<[Completion]>([])
        defer { held.withLock { $0.removeAll() } }
        let gate = ObservationDiagnosticsGate()
        defer { gate.open() }
        let parkedEntered = LockedBox(false)
        let timedOut = LockedBox(false)
        let revisions = LockedBox<[UInt64]>([])
        let observed = try scheduler.register(storeID: 1) { revision, completion in
            revisions.withLock { $0.append(revision) }
            held.withLock { $0.append(completion) }
        }
        let parked = try scheduler.register(storeID: 1) { _, _ in
            parkedEntered.withLock { $0 = true }
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        observed.notify(revision: 1)
        try await waitUntil { held.withLock { $0.count == 1 } && scheduler.diagnostics.bodiesRunning == 0 }
        clock.set(110)
        parked.notify(revision: 1)
        clock.set(120)
        observed.notify(revision: 2)
        clock.set(130)
        observed.notify(revision: 2)
        clock.set(140)
        let heldSnapshot = scheduler.diagnostics
        #expect(heldSnapshot.pendingSubscriptions == 2)
        #expect(heldSnapshot.readySubscriptions == 1)
        #expect(heldSnapshot.pendingWhileAdmitted == 1)
        #expect(heldSnapshot.admittedTurns == 1)
        #expect(heldSnapshot.bodiesRunning == 0)
        #expect(heldSnapshot.awaitingAcknowledgement == 1)
        #expect(heldSnapshot.oldestPendingAgeNanoseconds == 30)
        #expect(heldSnapshot.oldestReadyAgeNanoseconds == 30)
        #expect(heldSnapshot.oldestAdmittedAgeNanoseconds == 40)
        #expect(heldSnapshot.oldestAwaitingAcknowledgementAgeNanoseconds == 40)

        clock.set(150)
        held.withLock { $0[0] }.acknowledge()
        try await waitUntil { parkedEntered.withLock { $0 } }
        clock.set(160)
        let requeued = scheduler.diagnostics
        #expect(requeued.pendingSubscriptions == 1)
        #expect(requeued.readySubscriptions == 1)
        #expect(requeued.pendingWhileAdmitted == 0)
        #expect(requeued.oldestPendingAgeNanoseconds == 40)
        #expect(requeued.oldestReadyAgeNanoseconds == 10)
        #expect(requeued.oldestAdmittedAgeNanoseconds == 10)
        #expect(requeued.awaitingAcknowledgement == 0)
        let first = try #require(requeued.lastCompletedTurn)
        #expect(first.notificationToAdmissionNanoseconds == 0)
        #expect(first.notificationToCompletionNanoseconds == 50)
        #expect(first.admittedToBodyReturnNanoseconds == 0)
        #expect(first.admittedToAcknowledgementNanoseconds == 50)
        #expect(first.admittedToCompletionNanoseconds == 50)

        clock.set(170)
        gate.open()
        try await waitUntil { held.withLock { $0.count == 2 } && scheduler.diagnostics.bodiesRunning == 0 }
        clock.set(180)
        let secondWaiting = scheduler.diagnostics
        #expect(secondWaiting.pendingSubscriptions == 0)
        #expect(secondWaiting.readySubscriptions == 0)
        #expect(secondWaiting.oldestPendingAgeNanoseconds == nil)
        #expect(secondWaiting.oldestReadyAgeNanoseconds == nil)
        #expect(secondWaiting.admittedTurns == 1)
        #expect(secondWaiting.oldestAdmittedAgeNanoseconds == 10)
        #expect(secondWaiting.oldestAwaitingAcknowledgementAgeNanoseconds == 10)
        clock.set(190)
        let secondCompletion = held.withLock { $0[1] }
        secondCompletion.acknowledge()
        let second = try #require(scheduler.diagnostics.lastCompletedTurn)
        #expect(second.subscriptionID == first.subscriptionID)
        #expect(second.turnID != first.turnID)
        #expect(second.notificationToAdmissionNanoseconds == 50)
        #expect(second.notificationToCompletionNanoseconds == 70)
        #expect(second.admittedToBodyReturnNanoseconds == 0)
        #expect(second.admittedToAcknowledgementNanoseconds == 20)
        #expect(second.admittedToCompletionNanoseconds == 20)
        secondCompletion.acknowledge()
        #expect(scheduler.diagnostics.lastCompletedTurn == second)
        #expect(revisions.withLock { $0 } == [1, 2])
        await observed.cancelAndWait()
        await parked.cancelAndWait()
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func earlyAcknowledgementAndCancellationKeepAdmittedBodyVisibleUntilReturn() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 1, now: { clock.now() })
        let gate = ObservationDiagnosticsGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let timedOut = LockedBox(false)
        let observed = try scheduler.register(storeID: 1) { _, completion in
            completion.acknowledge()
            completion.acknowledge()
            entered.withLock { $0 = true }
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        observed.notify(revision: 1)
        try await waitUntil { entered.withLock { $0 } }
        clock.set(130)
        observed.notify(revision: 2)
        let running = scheduler.diagnostics
        #expect(running.admittedTurns == 1)
        #expect(running.bodiesRunning == 1)
        #expect(running.awaitingAcknowledgement == 0)
        #expect(running.pendingWhileAdmitted == 1)
        #expect(running.oldestPendingAgeNanoseconds == 0)
        #expect(running.oldestAdmittedAgeNanoseconds == 30)
        #expect(running.oldestAwaitingAcknowledgementAgeNanoseconds == nil)
        #expect(running.lastCompletedTurn == nil)
        clock.set(150)
        observed.cancel()
        observed.cancel()
        let draining = scheduler.diagnostics
        #expect(draining.subscriptions == 1)
        #expect(draining.pendingSubscriptions == 0)
        #expect(draining.pendingWhileAdmitted == 0)
        #expect(draining.oldestPendingAgeNanoseconds == nil)
        #expect(draining.admittedTurns == 1)
        #expect(draining.bodiesRunning == 1)
        #expect(draining.oldestAdmittedAgeNanoseconds == 50)
        clock.set(170)
        gate.open()
        await observed.cancelAndWait()
        let drained = scheduler.diagnostics
        #expect(drained.subscriptions == 0)
        #expect(drained.admittedTurns == 0)
        #expect(drained.oldestAdmittedAgeNanoseconds == nil)
        let completed = try #require(drained.lastCompletedTurn)
        #expect(completed.notificationToAdmissionNanoseconds == 0)
        #expect(completed.notificationToCompletionNanoseconds == 70)
        #expect(completed.admittedToBodyReturnNanoseconds == 70)
        #expect(completed.admittedToAcknowledgementNanoseconds == 0)
        #expect(completed.admittedToCompletionNanoseconds == 70)
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func shutdownRetainsHeldAcknowledgementAgeAfterWorkersExit() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 1, now: { clock.now() })
        let held = LockedBox<Completion?>(nil)
        defer { held.withLock { $0 = nil } }
        let observed = try scheduler.register(storeID: 1) { _, completion in held.withLock { $0 = completion } }
        observed.notify(revision: 1)
        try await waitUntil { held.withLock { $0 != nil } && scheduler.diagnostics.bodiesRunning == 0 }
        clock.set(120)
        observed.notify(revision: 2)
        let shutdown = Task { await scheduler.shutdown() }
        try await waitUntil { scheduler.snapshot.isShutdown && scheduler.snapshot.liveWorkers == 0 }
        clock.set(160)
        let draining = scheduler.diagnostics
        #expect(draining.subscriptions == 1)
        #expect(draining.pendingSubscriptions == 0)
        #expect(draining.readySubscriptions == 0)
        #expect(draining.oldestPendingAgeNanoseconds == nil)
        #expect(draining.oldestReadyAgeNanoseconds == nil)
        #expect(draining.admittedTurns == 1)
        #expect(draining.awaitingAcknowledgement == 1)
        #expect(draining.oldestAdmittedAgeNanoseconds == 60)
        #expect(draining.oldestAwaitingAcknowledgementAgeNanoseconds == 60)
        #expect(draining.lastCompletedTurn == nil)
        clock.set(180)
        held.withLock { $0 = nil } // Dropping the final token acknowledges.
        await shutdown.value
        let drained = scheduler.diagnostics
        #expect(drained.subscriptions == 0)
        #expect(drained.admittedTurns == 0)
        #expect(drained.awaitingAcknowledgement == 0)
        #expect(drained.oldestAwaitingAcknowledgementAgeNanoseconds == nil)
        let completed = try #require(drained.lastCompletedTurn)
        #expect(completed.admittedToBodyReturnNanoseconds == 0)
        #expect(completed.admittedToAcknowledgementNanoseconds == 80)
        #expect(completed.admittedToCompletionNanoseconds == 80)
        await observed.cancelAndWait()
    }
}
