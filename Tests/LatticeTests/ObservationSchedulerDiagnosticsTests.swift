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

/// The controller owns release. Wall-clock scheduling delays must never
/// silently return a body whose admitted state the fixture is inspecting.
private final class ObservationDiagnosticsGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }
}

/// Cleanup retires the sink so an already-admitted body cannot publish a
/// completion after cleanup took its first snapshot and strand shutdown.
private final class ObservationDiagnosticsCompletions: Sendable {
    private struct State {
        var retired = false
        var values: [ObservationTurnScheduler.Completion] = []
    }
    private let state = LockedBox(State())

    var count: Int { state.withLock { $0.values.count } }
    private enum LookupFailure: Error { case missingCompletion(Int) }

    func completion(at index: Int) throws -> ObservationTurnScheduler.Completion {
        // Decide under the holder lock: cancellation can retire the sink after
        // a caller observed its count, so a separate bounds check is not safe.
        let result: Result<ObservationTurnScheduler.Completion, Error> = state.withLock {
            if $0.retired { return .failure(CancellationError()) }
            guard $0.values.indices.contains(index) else {
                return .failure(LookupFailure.missingCompletion(index))
            }
            return .success($0.values[index])
        }
        return try result.get()
    }

    func append(_ completion: ObservationTurnScheduler.Completion) {
        let retired = state.withLock {
            if $0.retired { return true }
            $0.values.append(completion)
            return false
        }
        if retired { completion.acknowledge() }
    }

    func removeAll() {
        let removed = state.withLock {
            let values = $0.values
            $0.values.removeAll()
            return values
        }
        // Dropping the final token acknowledges outside the holder lock.
        withExtendedLifetime(removed) {}
    }

    func retire() {
        let removed = state.withLock {
            $0.retired = true
            let values = $0.values
            $0.values.removeAll()
            return values
        }
        // A local copy may still retain a token: cleanup acknowledges it too.
        for completion in removed { completion.acknowledge() }
    }
}

/// Test-only cleanup. Cancel queued work before opening a held worker, release
/// tokens outside locks, then await the scheduler's existing drain mechanism.
private final class ObservationDiagnosticsFixture: Sendable {
    private struct State {
        var closing = false
        var subscriptions: [ObservationTurnScheduler.Subscription] = []
    }
    let scheduler: ObservationTurnScheduler
    private let gates: [ObservationDiagnosticsGate]
    private let completions: [ObservationDiagnosticsCompletions]
    private let state = LockedBox(State())

    init(_ scheduler: ObservationTurnScheduler,
         gates: [ObservationDiagnosticsGate] = [],
         completions: [ObservationDiagnosticsCompletions] = []) {
        self.scheduler = scheduler
        self.gates = gates
        self.completions = completions
    }

    func register(storeID: UInt64, delivery: @escaping ObservationTurnScheduler.Delivery) throws -> ObservationTurnScheduler.Subscription {
        let subscription = try scheduler.register(storeID: storeID, delivery: delivery)
        let closing = state.withLock {
            if $0.closing { return true }
            $0.subscriptions.append(subscription)
            return false
        }
        if closing { subscription.cancel() }
        return subscription
    }

    private func release() {
        let subscriptions = state.withLock { value -> [ObservationTurnScheduler.Subscription]? in
            if value.closing { return nil }
            value.closing = true
            let subscriptions = value.subscriptions
            value.subscriptions.removeAll()
            return subscriptions
        }
        // Only the first caller performs the ordered release. A concurrent
        // cleanup must not open a gate before that caller cancels queued work.
        guard let subscriptions else { return }
        for subscription in subscriptions { subscription.cancel() }
        for holder in completions { holder.retire() }
        for gate in gates { gate.open() }
    }

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        defer { release() }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
            } catch {
                release()
                await scheduler.shutdown()
                throw error
            }
            release()
            await scheduler.shutdown()
        } onCancel: {
            release()
        }
    }
}

@Suite("Observation scheduler diagnostics", .serialized)
struct ObservationSchedulerDiagnosticsTests: Sendable {
    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        try Task.checkCancellation()
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            try #require(DispatchTime.now().uptimeNanoseconds < end, "diagnostic fixture did not settle")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try Task.checkCancellation()
    }

    @Test func publicSnapshotReportsConfiguredBoundsAndNoInventedAges() async throws {
        let scheduler = try ObservationScheduler(workerCount: 2, maxSubscriptions: 3)
        let fixture = ObservationDiagnosticsFixture(scheduler.turns)
        try await fixture.run {
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
        }
    }

    @Test func coalescingPreservesFirstPendingAgeAndQueuedCancellationClearsIt() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 2, now: { clock.now() })
        let gate = ObservationDiagnosticsGate()
        let entered = LockedBox(false)
        let returned = LockedBox(false)
        let unexpectedRuns = LockedBox(0)
        let fixture = ObservationDiagnosticsFixture(scheduler, gates: [gate])
        try await fixture.run {
            let blocker = try fixture.register(storeID: 1) { _, _ in
                // Diagnostics must remain callable from an admitted body.
                _ = scheduler.diagnostics
                entered.withLock { $0 = true }
                gate.wait()
                returned.withLock { $0 = true }
            }
            let queued = try fixture.register(storeID: 2) { _, _ in unexpectedRuns.withLock { $0 += 1 } }
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
            #expect(!returned.withLock { $0 })
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
            #expect(returned.withLock { $0 })
        }
    }

    @Test func dirtyHeldTurnRetainsPendingAgeThroughFairRequeueAndAcknowledgement() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 2, now: { clock.now() })
        let held = ObservationDiagnosticsCompletions()
        let gate = ObservationDiagnosticsGate()
        let parkedEntered = LockedBox(false)
        let returned = LockedBox(false)
        let revisions = LockedBox<[UInt64]>([])
        let fixture = ObservationDiagnosticsFixture(scheduler, gates: [gate], completions: [held])
        try await fixture.run {
            let observed = try fixture.register(storeID: 1) { revision, completion in
                revisions.withLock { $0.append(revision) }
                held.append(completion)
            }
            let parked = try fixture.register(storeID: 1) { _, _ in
                parkedEntered.withLock { $0 = true }
                gate.wait()
                returned.withLock { $0 = true }
            }
            observed.notify(revision: 1)
            try await waitUntil { held.count == 1 && scheduler.diagnostics.bodiesRunning == 0 }
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
            try held.completion(at: 0).acknowledge()
            try await waitUntil { parkedEntered.withLock { $0 } }
            clock.set(160)
            let requeued = scheduler.diagnostics
            #expect(!returned.withLock { $0 })
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
            try await waitUntil { held.count == 2 && scheduler.diagnostics.bodiesRunning == 0 }
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
            let secondCompletion = try held.completion(at: 1)
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
            #expect(returned.withLock { $0 })
        }
    }

    @Test func earlyAcknowledgementAndCancellationKeepAdmittedBodyVisibleUntilReturn() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 1, now: { clock.now() })
        let gate = ObservationDiagnosticsGate()
        let entered = LockedBox(false)
        let returned = LockedBox(false)
        let fixture = ObservationDiagnosticsFixture(scheduler, gates: [gate])
        try await fixture.run {
            let observed = try fixture.register(storeID: 1) { _, completion in
                completion.acknowledge()
                completion.acknowledge()
                entered.withLock { $0 = true }
                gate.wait()
                returned.withLock { $0 = true }
            }
            observed.notify(revision: 1)
            try await waitUntil { entered.withLock { $0 } }
            clock.set(130)
            observed.notify(revision: 2)
            let running = scheduler.diagnostics
            #expect(!returned.withLock { $0 })
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
            #expect(returned.withLock { $0 })
        }
    }

    @Test func shutdownRetainsHeldAcknowledgementAgeAfterWorkersExit() async throws {
        let clock = ObservationDiagnosticsClock()
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 1, now: { clock.now() })
        let held = ObservationDiagnosticsCompletions()
        let fixture = ObservationDiagnosticsFixture(scheduler, completions: [held])
        try await fixture.run {
            let observed = try fixture.register(storeID: 1) { _, completion in held.append(completion) }
            observed.notify(revision: 1)
            try await waitUntil { held.count == 1 && scheduler.diagnostics.bodiesRunning == 0 }
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
            held.removeAll() // Dropping the final token acknowledges.
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

    private enum FixtureFailure: Error { case controller }

    @Test func controllerThrowReleasesHeldBodyWithoutRunningQueuedWork() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 2)
        let gate = ObservationDiagnosticsGate()
        let fixture = ObservationDiagnosticsFixture(scheduler, gates: [gate])
        let entered = LockedBox(false)
        let returned = LockedBox(false)
        let queuedRuns = LockedBox(0)
        do {
            try await fixture.run {
                let blocker = try fixture.register(storeID: 1) { _, _ in
                    entered.withLock { $0 = true }
                    gate.wait()
                    returned.withLock { $0 = true }
                }
                let queued = try fixture.register(storeID: 2) { _, _ in
                    queuedRuns.withLock { $0 += 1 }
                }
                blocker.notify(revision: 1)
                try await waitUntil { entered.withLock { $0 } }
                queued.notify(revision: 1)
                #expect(scheduler.diagnostics.bodiesRunning == 1)
                #expect(scheduler.diagnostics.readySubscriptions == 1)
                #expect(!returned.withLock { $0 })
                throw FixtureFailure.controller
            }
            Issue.record("Controller failure was lost")
        } catch FixtureFailure.controller {
            // Cleanup must preserve the original failure, not replace it.
        }
        #expect(returned.withLock { $0 })
        #expect(queuedRuns.withLock { $0 } == 0)
        #expect(scheduler.snapshot.subscriptions == 0)
        #expect(scheduler.snapshot.admittedTurns == 0)
        #expect(scheduler.snapshot.bodiesRunning == 0)
        #expect(scheduler.snapshot.liveWorkers == 0)
    }

    @Test func controllerCancellationReleasesHeldBodyAndAcknowledgement() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 1)
        let gate = ObservationDiagnosticsGate()
        let held = ObservationDiagnosticsCompletions()
        let fixture = ObservationDiagnosticsFixture(scheduler, gates: [gate], completions: [held])
        let entered = LockedBox(false)
        let returned = LockedBox(false)
        let controllerWaiting = LockedBox(false)
        let controller = Task {
            try await fixture.run {
                let observed = try fixture.register(storeID: 1) { _, completion in
                    held.append(completion)
                    entered.withLock { $0 = true }
                    gate.wait()
                    returned.withLock { $0 = true }
                }
                observed.notify(revision: 1)
                try await waitUntil { entered.withLock { $0 } }
                #expect(scheduler.diagnostics.bodiesRunning == 1)
                #expect(held.count == 1)
                #expect(!returned.withLock { $0 })
                controllerWaiting.withLock { $0 = true }
                while true { try await Task.sleep(nanoseconds: 1_000_000) }
            }
        }
        do {
            try await waitUntil { controllerWaiting.withLock { $0 } }
        } catch {
            controller.cancel()
            // Join even when the parent's readiness watchdog fails.
            _ = await controller.result
            throw error
        }
        controller.cancel()
        do {
            try await controller.value
            Issue.record("Controller cancellation was lost")
        } catch is CancellationError {
            // Cancellation is reported only after the existing scheduler drains.
        }
        #expect(returned.withLock { $0 })
        #expect(held.count == 0)
        do {
            _ = try held.completion(at: 0)
            Issue.record("A retired completion holder allowed lookup")
        } catch is CancellationError {
            // A racing controller lookup takes the throwing cleanup path.
        }
        #expect(scheduler.snapshot.subscriptions == 0)
        #expect(scheduler.snapshot.admittedTurns == 0)
        #expect(scheduler.snapshot.bodiesRunning == 0)
        #expect(scheduler.snapshot.liveWorkers == 0)
    }

}
