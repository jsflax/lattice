import Foundation
import Dispatch
import Testing
@testable import Lattice
#if canImport(Darwin)
import Darwin
#endif

private final class ObservationTurnTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
}

@Suite("Bounded fair observation turns", .serialized)
struct ObservationTurnSchedulerTests {
    private typealias Completion = ObservationTurnScheduler.Completion
    private typealias Subscription = ObservationTurnScheduler.Subscription

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            try #require(DispatchTime.now().uptimeNanoseconds < end, "observation scheduler did not settle")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func expectRegistrationFailure(_ scheduler: ObservationTurnScheduler,
                                           _ expected: ObservationTurnSchedulerError) {
        do {
            _ = try scheduler.register(storeID: 999) { _, _ in }
            Issue.record("Expected registration failure: \(expected)")
        } catch {
            #expect(error as? ObservationTurnSchedulerError == expected)
        }
    }

    @Test func burstKeepsOneReadyTokenAndLatestArrivalRevision() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 2)
        let gate = ObservationTurnTestGate()
        defer { gate.open() }
        let timedOut = LockedBox(false)
        let revisions = LockedBox<[UInt64]>([])
        let blocker = try scheduler.register(storeID: 99) { _, _ in
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        blocker.notify(revision: 0)
        let observed = try scheduler.register(storeID: 1) { revision, _ in
            revisions.withLock { $0.append(revision) }
        }
        for revision in 0..<10_000 { observed.notify(revision: UInt64(revision)) }
        observed.notify(revision: 7) // Latest arrival is not the numeric maximum.
        let queued = scheduler.snapshot
        // Blocker is first in the sole worker's FIFO. Account for both legal
        // admission states without awaiting cooperative task resumption.
        #expect((0...1).contains(queued.admittedTurns))
        #expect(queued.readySubscriptions + queued.admittedTurns == 2)
        #expect(queued.readyStores + queued.admittedTurns == 2)
        #expect(revisions.withLock { $0.isEmpty })
        gate.open()
        try await waitUntil { revisions.withLock { $0.count == 1 } }
        await observed.cancelAndWait()
        await blocker.cancelAndWait()
        #expect(revisions.withLock { $0 } == [7])
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func readyStoresThenTheirSubscriptionsTakeRoundRobinTurns() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 6)
        let gate = ObservationTurnTestGate()
        defer { gate.open() }
        let timedOut = LockedBox(false)
        let order = LockedBox<[String]>([])
        let blocker = try scheduler.register(storeID: 99) { _, _ in
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        blocker.notify(revision: 0)
        // Queue the blocker first on the sole worker. There is no need to
        // suspend on the cooperative executor before preparing the ready set:
        // it either waits below or consumes the signal after all five are queued.
        var subscriptions: [Subscription] = []
        for (store, name) in [(UInt64(1), "A1"), (1, "A2"), (1, "A3"), (2, "B1"), (2, "B2")] {
            let subscription = try scheduler.register(storeID: store) { _, _ in
                order.withLock { $0.append(name) }
            }
            subscriptions.append(subscription)
            subscription.notify(revision: 1)
        }
        let queued = scheduler.snapshot
        // The first worker may or may not have admitted the blocker yet.
        // Both states must contain exactly the same six turns and three stores.
        #expect((0...1).contains(queued.admittedTurns))
        #expect(queued.readyStores + queued.admittedTurns == 3)
        #expect(queued.readySubscriptions + queued.admittedTurns == 6)
        #expect(order.withLock { $0.isEmpty })
        gate.open()
        try await waitUntil { order.withLock { $0.count == 5 } }
        #expect(order.withLock { $0 } == ["A1", "B1", "A2", "B2", "A3"])
        for subscription in subscriptions { await subscription.cancelAndWait() }
        await blocker.cancelAndWait()
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func registrationCapacityIsExplicitAndReusableAfterCancellation() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 2)
        let first = try scheduler.register(storeID: 1) { _, _ in }
        let second = try scheduler.register(storeID: 2) { _, _ in }
        expectRegistrationFailure(scheduler, .capacityExceeded)
        #expect(scheduler.snapshot.subscriptions == 2)
        await first.cancelAndWait()
        let replacement = try scheduler.register(storeID: 3) { _, _ in }
        #expect(scheduler.snapshot.subscriptions == 2)
        await second.cancelAndWait()
        await replacement.cancelAndWait()
        await scheduler.shutdown()
        expectRegistrationFailure(scheduler, .shutdown)
    }

    @Test func blockedStoreLeavesAnotherConfiguredNativeWorkerAvailable() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 3)
        let gate = ObservationTurnTestGate()
        let secondGate = ObservationTurnTestGate()
        defer { gate.open(); secondGate.open() }
        let entered = LockedBox(false)
        let secondEntered = LockedBox(false)
        let timedOut = LockedBox(false)
        let probe = LockedBox<(bytes: Int, main: Bool)?>(nil)
        let blocked = try scheduler.register(storeID: 1) { _, _ in
            entered.withLock { $0 = true }
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        let sameStore = try scheduler.register(storeID: 1) { _, _ in
            secondEntered.withLock { $0 = true }
            if !secondGate.wait() { timedOut.withLock { $0 = true } }
        }
        let other = try scheduler.register(storeID: 2) { _, _ in
            _ = scheduler.snapshot // Delivery must run outside the state lock.
            #if canImport(Darwin)
            let bytes = Int(pthread_get_stacksize_np(pthread_self()))
            #else
            let bytes = Thread.current.stackSize
            #endif
            probe.withLock { $0 = (bytes, Thread.isMainThread) }
        }
        blocked.notify(revision: 1)
        try await waitUntil { entered.withLock { $0 } }
        sameStore.notify(revision: 1)
        #expect(scheduler.snapshot.readySubscriptions == 1)
        #expect(scheduler.snapshot.readyStores == 0, "The blocked store must remain parked")
        other.notify(revision: 1)
        try await waitUntil { probe.withLock { $0 != nil } }
        let measured = try #require(probe.withLock { $0 })
        #expect(!measured.main)
        #if canImport(Darwin)
        #expect(measured.bytes >= ObservationTurnScheduler.requiredStackSize)
        #endif
        #expect(scheduler.snapshot.verifiedWorkers == 2)
        #expect(scheduler.snapshot.bodiesRunning >= 1)
        #expect(!secondEntered.withLock { $0 }, "A second A turn must not consume B's worker")
        gate.open()
        secondGate.open()
        await blocked.cancelAndWait()
        await sameStore.cancelAndWait()
        await other.cancelAndWait()
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
        #expect(scheduler.snapshot.liveWorkers == 0)
    }

    @Test func dirtyDuringBodyCoalescesIntoOneFollowingTurn() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 1)
        let gate = ObservationTurnTestGate()
        defer { gate.open() }
        let revisions = LockedBox<[UInt64]>([])
        let timedOut = LockedBox(false)
        let concurrency = LockedBox((active: 0, peak: 0))
        let observed = try scheduler.register(storeID: 1) { revision, _ in
            concurrency.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            let first = revisions.withLock { values in
                values.append(revision)
                return values.count == 1
            }
            if first && !gate.wait() { timedOut.withLock { $0 = true } }
            concurrency.withLock { $0.active -= 1 }
        }
        observed.notify(revision: 1)
        try await waitUntil { revisions.withLock { $0 == [1] } }
        for revision in 2...500 { observed.notify(revision: UInt64(revision)) }
        #expect(scheduler.snapshot.readySubscriptions == 0)
        #expect(scheduler.snapshot.admittedTurns == 1)
        gate.open()
        try await waitUntil { revisions.withLock { $0.count == 2 } }
        await observed.cancelAndWait()
        #expect(revisions.withLock { $0 } == [1, 500])
        #expect(concurrency.withLock { $0.peak } == 1)
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func heldActorAcknowledgementParksSameStoreAndRotatesItsDirtySubscription() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 3)
        let held = LockedBox<Completion?>(nil)
        defer { held.withLock { $0 = nil } }
        let events = LockedBox<[String]>([])
        let first = try scheduler.register(storeID: 1) { revision, completion in
            events.withLock { $0.append("A1-\(revision)") }
            if revision == 1 { held.withLock { $0 = completion } }
        }
        let sameStore = try scheduler.register(storeID: 1) { _, _ in events.withLock { $0.append("A2") } }
        let otherStore = try scheduler.register(storeID: 2) { _, _ in events.withLock { $0.append("B") } }
        first.notify(revision: 1)
        try await waitUntil { held.withLock { $0 != nil } && scheduler.snapshot.bodiesRunning == 0 }
        sameStore.notify(revision: 1)
        first.notify(revision: 2)
        otherStore.notify(revision: 1)
        try await waitUntil { events.withLock { $0.contains("B") } }
        #expect(events.withLock { $0 } == ["A1-1", "B"])
        #expect(scheduler.snapshot.readySubscriptions == 1)
        #expect(scheduler.snapshot.readyStores == 0)
        let completion = try #require(held.withLock { $0 })
        completion.acknowledge()
        try await waitUntil { events.withLock { $0.count == 4 } }
        #expect(events.withLock { $0 } == ["A1-1", "B", "A2", "A1-2"])
        await first.cancelAndWait()
        await sameStore.cancelAndWait()
        await otherStore.cancelAndWait()
        await scheduler.shutdown()
    }

    @Test func heldActorAcknowledgementBoundsEqualRevisionNotifications() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 1)
        let held = LockedBox<Completion?>(nil)
        defer { held.withLock { $0 = nil } }
        let revisions = LockedBox<[UInt64]>([])
        let observed = try scheduler.register(storeID: 1) { revision, completion in
            let first = revisions.withLock { values in
                values.append(revision)
                return values.count == 1
            }
            if first { held.withLock { $0 = completion } }
        }
        observed.notify(revision: 7)
        try await waitUntil { held.withLock { $0 != nil } && scheduler.snapshot.bodiesRunning == 0 }
        for _ in 0..<10_000 { observed.notify(revision: 7) }
        #expect(revisions.withLock { $0 } == [7])
        #expect(scheduler.snapshot.admittedTurns == 1)
        #expect(scheduler.snapshot.readySubscriptions == 0)
        let completion = try #require(held.withLock { $0 })
        completion.acknowledge()
        completion.acknowledge()
        try await waitUntil { revisions.withLock { $0.count == 2 } }
        await observed.cancelAndWait()
        #expect(revisions.withLock { $0 } == [7, 7], "Dirty state must not compare revision numbers")
        await scheduler.shutdown()
    }

    @Test func earlyAcknowledgementCannotOverlapSynchronousBodies() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 1)
        let gate = ObservationTurnTestGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let revisions = LockedBox<[UInt64]>([])
        let timedOut = LockedBox(false)
        let concurrency = LockedBox((active: 0, peak: 0))
        let observed = try scheduler.register(storeID: 1) { revision, completion in
            concurrency.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            revisions.withLock { $0.append(revision) }
            completion.acknowledge()
            completion.acknowledge()
            if revision == 1 {
                entered.withLock { $0 = true }
                if !gate.wait() { timedOut.withLock { $0 = true } }
            }
            concurrency.withLock { $0.active -= 1 }
        }
        observed.notify(revision: 1)
        try await waitUntil { entered.withLock { $0 } }
        observed.notify(revision: 2)
        #expect(scheduler.snapshot.admittedTurns == 1)
        #expect(scheduler.snapshot.bodiesRunning == 1)
        #expect(scheduler.snapshot.readySubscriptions == 0)
        #expect(revisions.withLock { $0 } == [1])
        gate.open()
        try await waitUntil { revisions.withLock { $0.count == 2 } }
        await observed.cancelAndWait()
        #expect(revisions.withLock { $0 } == [1, 2])
        #expect(concurrency.withLock { $0.peak } == 1)
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func queuedCancellationRemovesAdmissionWithoutWaitingForBlockedWorker() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 1, maxSubscriptions: 2)
        let gate = ObservationTurnTestGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let cancelledRuns = LockedBox(0)
        let timedOut = LockedBox(false)
        let blocker = try scheduler.register(storeID: 1) { _, _ in
            entered.withLock { $0 = true }
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        blocker.notify(revision: 0)
        try await waitUntil { entered.withLock { $0 } }
        let queued = try scheduler.register(storeID: 2) { _, _ in cancelledRuns.withLock { $0 += 1 } }
        queued.notify(revision: 1)
        #expect(scheduler.snapshot.readySubscriptions == 1)
        await queued.cancelAndWait()
        queued.notify(revision: 2)
        #expect(scheduler.snapshot.readySubscriptions == 0)
        #expect(scheduler.snapshot.readyStores == 0)
        #expect(scheduler.snapshot.subscriptions == 1)
        #expect(scheduler.snapshot.bodiesRunning == 1)
        gate.open()
        await blocker.cancelAndWait()
        #expect(cancelledRuns.withLock { $0 } == 0)
        #expect(!timedOut.withLock { $0 })
        await scheduler.shutdown()
    }

    @Test func bodyCanCancelItselfButDrainWaitsForBodyAndActorAcknowledgement() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 1)
        let gate = ObservationTurnTestGate()
        defer { gate.open() }
        let control = LockedBox<Subscription?>(nil)
        let held = LockedBox<Completion?>(nil)
        defer { held.withLock { $0 = nil } }
        let entered = LockedBox(false)
        let timedOut = LockedBox(false)
        let drained = LockedBox(0)
        let runs = LockedBox(0)
        let observed = try scheduler.register(storeID: 1) { _, completion in
            control.withLock { $0 }?.cancel()
            held.withLock { $0 = completion }
            runs.withLock { $0 += 1 }
            entered.withLock { $0 = true }
            if !gate.wait() { timedOut.withLock { $0 = true } }
        }
        control.withLock { $0 = observed }
        observed.notify(revision: 1)
        try await waitUntil { entered.withLock { $0 } }
        observed.notify(revision: 2)
        let firstDrain = Task { await observed.cancelAndWait(); drained.withLock { $0 += 1 } }
        let secondDrain = Task { await observed.cancelAndWait(); drained.withLock { $0 += 1 } }
        firstDrain.cancel() // Task cancellation must not abandon resource drain.
        try await waitUntil { scheduler.snapshot.drainWaiters == 2 }
        #expect(drained.withLock { $0 } == 0)
        expectRegistrationFailure(scheduler, .capacityExceeded)
        gate.open()
        try await waitUntil { scheduler.snapshot.bodiesRunning == 0 }
        #expect(drained.withLock { $0 } == 0)
        #expect(scheduler.snapshot.admittedTurns == 1)
        let completion = try #require(held.withLock { $0 })
        completion.acknowledge()
        completion.acknowledge()
        await firstDrain.value
        await secondDrain.value
        await observed.cancelAndWait()
        #expect(drained.withLock { $0 } == 2)
        #expect(scheduler.snapshot.subscriptions == 0)
        #expect(runs.withLock { $0 } == 1)
        #expect(!timedOut.withLock { $0 })
        let replacement = try scheduler.register(storeID: 2) { _, _ in }
        await replacement.cancelAndWait()
        await scheduler.shutdown()
    }

    @Test func shutdownWaitsForDroppedActorTokenAfterAllWorkersExit() async throws {
        let scheduler = ObservationTurnScheduler(workerCount: 2, maxSubscriptions: 1)
        let held = LockedBox<Completion?>(nil)
        defer { held.withLock { $0 = nil } }
        let stopped = LockedBox(false)
        let observed = try scheduler.register(storeID: 1) { _, completion in
            held.withLock { $0 = completion }
        }
        observed.notify(revision: 1)
        try await waitUntil { held.withLock { $0 != nil } && scheduler.snapshot.bodiesRunning == 0 }
        let shutdown = Task { await scheduler.shutdown(); stopped.withLock { $0 = true } }
        try await waitUntil { scheduler.snapshot.isShutdown && scheduler.snapshot.liveWorkers == 0 }
        #expect(!stopped.withLock { $0 })
        #expect(scheduler.snapshot.admittedTurns == 1)
        expectRegistrationFailure(scheduler, .shutdown)
        observed.notify(revision: 2)
        #expect(scheduler.snapshot.readySubscriptions == 0)
        // Dropping the actor's last token reference must acknowledge the turn.
        held.withLock { $0 = nil }
        await shutdown.value
        await scheduler.shutdown()
        await observed.cancelAndWait()
        #expect(stopped.withLock { $0 })
        #expect(scheduler.snapshot.subscriptions == 0)
        #expect(scheduler.snapshot.admittedTurns == 0)
        #expect(scheduler.snapshot.liveWorkers == 0)
    }
}
