import Foundation
import Testing
@testable import LatticeServerKit
#if canImport(Darwin)
import Darwin
#endif

@Suite("Dedicated relay execution")
struct RelayExecutionTests {
    @Test(.timeLimit(.minutes(1)))
    func blockedStoreLeavesSecondWorkerAndPreservesItsFIFO() async throws {
        let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.parallel")
        let gate = RelayTestGate(), done = RelayTestSignal(), other = RelayTestSignal()
        let values = RelayTestBox<[Int]>([]), stack = RelayTestBox(false)
        defer { gate.release.signal() }
        pool.submitRequired(for: "A") { gate.entered.signal(); gate.wait() }
        for i in 0..<80 {
            pool.submitRequired(for: "A") {
                values.withLock { $0.append(i) }
                if i == 79 { done.send() }
            }
        }
        let overlapped = RelayTestBox(false)
        pool.submitRequired(for: "B") {
            // Observe/release from the independent native worker. Generic test
            // task resumption must not consume the blocker's five-second gate.
            defer { gate.release.signal() }
            let entered = gate.entered.wait(timeout: .now() + 5) == .success
            overlapped.withLock { $0 = entered && values.withLock { $0.isEmpty } }
            #if canImport(Darwin)
            stack.withLock { $0 = pthread_get_stacksize_np(pthread_self()) >= RelayExecutionPool.stackSize }
            #else
            stack.withLock { $0 = true }
            #endif
            other.send()
        }
        try await other.wait()
        try await done.wait()
        await pool.shutdown()
        try #require(overlapped.withLock { $0 })
        try #require(stack.withLock { $0 })
        try #require(values.withLock { $0 } == Array(0..<80))
        try #require(!gate.timedOut)
        try #require(pool.snapshot.liveWorkers == 0)
        try #require(pool.snapshot.startedWorkers == 2)
        try #require(pool.snapshot.queued == 0 && pool.snapshot.running == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func oneWorkerRotatesStoresWithoutReorderingAStore() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.rotation")
        let gate = RelayTestGate(), done = RelayTestSignal()
        let values = RelayTestBox<[Int]>([])
        defer { gate.release.signal() }
        pool.submitRequired(for: "A") { gate.entered.signal(); gate.wait() }
        for i in 1...3 { pool.submitRequired(for: "A") { values.withLock { $0.append(i) } } }
        for i in 11...12 { pool.submitRequired(for: "B") { values.withLock { $0.append(i) } } }
        pool.submitRequired(for: "A") { done.send() }
        gate.release.signal()
        try await done.wait()
        await pool.shutdown()
        try #require(values.withLock { $0 } == [11, 1, 12, 2, 3])
        try #require(!gate.timedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func finalCaptureReleaseCanSubmitWithoutOwningTheQueueLock() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.release")
        let gate = RelayTestGate(), done = RelayTestSignal()
        let releasedOffLock = RelayTestBox(false)
        defer { gate.release.signal() }
        pool.submitRequired(for: "A") { gate.entered.signal(); gate.wait() }
        func submitCapture() {
            let capture = RelayTestLifetime {
                // A regression must fail promptly instead of deadlocking the
                // Swift test process. A separate thread attempts admission;
                // the deinitializer waits at most 0.5 s for that admission.
                let admitted = DispatchSemaphore(value: 0)
                Thread {
                    pool.submitRequired(for: "A") { done.send() }
                    admitted.signal()
                }.start()
                let available = admitted.wait(timeout: .now() + 0.5) == .success
                releasedOffLock.withLock { $0 = available }
            }
            pool.submitRequired(for: "A") { withExtendedLifetime(capture) {} }
        }
        submitCapture()
        gate.release.signal()
        try await done.wait()
        await pool.shutdown()
        try #require(releasedOffLock.withLock { $0 })
        try #require(!gate.timedOut)
    }

    #if canImport(Darwin)
    @Test(.timeLimit(.minutes(1)))
    func autoreleasedObjectsDrainBetweenJobsAndCanEnqueueDuringDeinit() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.autorelease")
        let drained = RelayTestSignal()
        let released = RelayTestBox(0), beforeNextJob = RelayTestBox(-1)
        let releasedOffLock = RelayTestBox(false)
        pool.submitRequired(for: "A") {
            for _ in 0..<32 {
                _ = Unmanaged.passRetained(RelayAutoreleaseSentinel {
                    released.withLock { $0 += 1 }
                }).autorelease()
            }
            _ = Unmanaged.passRetained(RelayAutoreleaseSentinel {
                released.withLock { $0 += 1 }
                // A lock regression fails without hanging the test process.
                let admitted = DispatchSemaphore(value: 0)
                Thread {
                    _ = pool.submit(for: "A") { drained.send() }
                    admitted.signal()
                }.start()
                releasedOffLock.withLock {
                    $0 = admitted.wait(timeout: .now() + 0.5) == .success
                }
            }).autorelease()
        }
        pool.submitRequired(for: "A") { beforeNextJob.withLock { $0 = released.withLock { $0 } } }
        // In the red implementation the deinitializer cannot run until worker
        // shutdown. Observe the second job independently, then stop the pool;
        // never make shutdown depend on the autoreleased callback firing.
        let secondJob = RelayTestSignal()
        pool.submitRequired(for: "A") { secondJob.send() }
        try await secondJob.wait()
        let releasedBeforeShutdown = beforeNextJob.withLock { $0 }
        // Drain is expected before this point; cancellation of admission here
        // must not race a delayed reentrant enqueue in the failing case.
        if releasedBeforeShutdown == 33 {
            try await drained.wait()
        }
        await pool.shutdown()
        try #require(releasedBeforeShutdown == 33)
        try #require(releasedOffLock.withLock { $0 })
    }
    #endif

    @Test(.timeLimit(.minutes(1)))
    func shutdownClosesAdmissionAndDrainsAnAlreadyAdmittedBody() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.test.shutdown")
        let gate = RelayTestGate(), closed = RelayTestBox(false)
        let observed = RelayTestSignal()
        let enteredBeforeStop = RelayTestBox(false), stoppedWhileHeld = RelayTestBox(false)
        let rejectedNewWork = RelayTestBox(false)
        defer { gate.release.signal() }
        // Task admission may be delayed. Start the timed native fixture only
        // once this task begins, then enter shutdown without another await.
        let shutdown = Task {
            pool.submitRequired(for: "A") { gate.entered.signal(); gate.wait() }
            Thread {
                let entered = gate.entered.wait(timeout: .now() + 5) == .success
                enteredBeforeStop.withLock { $0 = entered }
                let deadline = ContinuousClock.now + .seconds(3)
                while !pool.snapshot.stopping && ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                let snapshot = pool.snapshot
                stoppedWhileHeld.withLock {
                    $0 = snapshot.stopping && snapshot.running == 1 && !closed.withLock { $0 }
                }
                let accepted = pool.submit(for: "B") {}
                rejectedNewWork.withLock { $0 = !accepted }
                gate.release.signal()
                observed.send()
            }.start()
            await pool.shutdown()
            closed.withLock { $0 = true }
        }
        try await observed.wait()
        await shutdown.value
        try #require(enteredBeforeStop.withLock { $0 })
        try #require(stoppedWhileHeld.withLock { $0 })
        try #require(rejectedNewWork.withLock { $0 })
        try #require(closed.withLock { $0 })
        try #require(pool.snapshot.liveWorkers == 0 && !gate.timedOut)
        // Repeated completed shutdown does not leak or double-resume a waiter.
        await pool.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeHintsCoalesceAndDirtyDuringDeliverySchedulesOneNextTurn() async throws {
        let done = RelayTestSignal()
        var owner: RelaySignalOwner? = await RelaySignalOwner(done: done)
        weak var weakOwner = owner
        let signal = await owner!.makeSignal()
        defer { signal.cancel() }
        // This is a short, synchronous fixture turn. It queues a burst before
        // the delivery turn, without sleeping or parking the shared actor.
        await Task { @RelayControlActor in
            for value in UInt64(1)...200 { signal.signal(callback: value) }
        }.value
        try await done.wait()
        let delivered = await owner!.values
        try #require(delivered == [200, 202])
        await Task { @RelayControlActor in
            signal.signal(callback: 203)
            signal.cancel()
        }.value
        // The prior queued delivery has either observed cancellation already
        // or runs before this actor barrier; it must not publish callback203.
        let afterCancel = await owner!.values
        try #require(afterCancel == [200, 202])
        signal.signal(callback: 204) // a copied/late native callback is inert
        owner = nil
        try #require(weakOwner == nil, "stored signal operation must not retain its owner")
    }

    @Test
    func reconcileTimerDelayHandlesFullDurationRangeWithoutOverflow() throws {
        try #require(RelayReconcileInterval(seconds: Int64.max, attoseconds: 0).delayNanoseconds == 86_400_000_000_000)
        try #require(RelayReconcileInterval(seconds: Int64.min, attoseconds: 0).delayNanoseconds == 1)
        try #require(RelayReconcileInterval(seconds: 0, attoseconds: 0).delayNanoseconds == 1)
        try #require(RelayReconcileInterval(seconds: 0, attoseconds: 1).delayNanoseconds == 1)
        try #require(RelayReconcileInterval(seconds: 0, attoseconds: 25_000_000_000_000_000).delayNanoseconds == 25_000_000)
        var long = RelayReconcileInterval(seconds: Int64.max, attoseconds: 1)
        let longElapsed = long.consume(elapsedNanoseconds: 86_400_000_000_000)
        try #require(!longElapsed)
        try #require(long.seconds == UInt64(Int64.max) - 86_400 && long.nanoseconds == 1)
        var carry = RelayReconcileInterval(seconds: 1, attoseconds: 1)
        let firstElapsed = carry.consume(elapsedNanoseconds: 2)
        try #require(!firstElapsed)
        try #require(carry.seconds == 0 && carry.nanoseconds == 999_999_999)
        let finalElapsed = carry.consume(elapsedNanoseconds: 999_999_999)
        try #require(finalElapsed)
    }

    @Test(.timeLimit(.minutes(1)))
    func reconcileOnlyTimerSignalsAndCancellationReleasesOwner() async throws {
        let done = RelayTestSignal()
        var owner: RelayTimerOwner? = await RelayTimerOwner(done: done)
        weak var weakOwner = owner
        let signal = await owner!.makeSignal()
        var timer: RelayReconcileTimer? = RelayReconcileTimer(seconds: 0, attoseconds: 10_000_000_000_000_000, signal: signal)
        weak var weakTimer = timer
        defer { signal.cancel(); timer?.cancel() }
        try await done.wait()
        // Match last-subscriber teardown: invalidate delivery before stopping
        // the timer, so a callback already copied by Dispatch is inert.
        signal.cancel()
        timer?.cancel()
        timer?.cancel()
        timer = nil
        let afterCancel = await owner!.count
        try #require(afterCancel >= 1)
        signal.signal(callback: nil)
        let afterLateTick = await owner!.count
        try #require(afterLateTick == afterCancel)
        // cancel() is not a Dispatch callback join; an already-running tick
        // may briefly retain the timer until its synchronous body returns.
        let releaseDeadline = ContinuousClock.now + .seconds(3)
        while weakTimer != nil && ContinuousClock.now < releaseDeadline {
            try Task.checkCancellation()
            await Task.yield()
        }
        try #require(weakTimer == nil)
        owner = nil
        try #require(weakOwner == nil)
    }
}

private final class RelayTestSignal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send() { continuation.yield(()); continuation.finish() }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }
}

private final class RelayTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }; return try body(&value)
    }
}

private final class RelayTestGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let expired = RelayTestBox(false)
    var timedOut: Bool { expired.withLock { $0 } }
    func wait() {
        let timedOut = release.wait(timeout: .now() + 5) != .success
        expired.withLock { $0 = timedOut }
    }
}

private final class RelayTestLifetime: Sendable {
    let onRelease: @Sendable () -> Void
    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

@RelayControlActor private final class RelaySignalOwner {
    let done: RelayTestSignal
    var values: [UInt64] = []
    init(done: RelayTestSignal) { self.done = done }
    func makeSignal() -> RelayCoalescedSignal {
        let signal = RelayCoalescedSignal()
        signal.install { @RelayControlActor [weak self, weak signal] in
            guard let self, let signal, let callback = signal.take(), let callback else { return }
            defer { signal.finish() }
            self.values.append(callback)
            if callback == 200 {
                signal.signal(callback: 201)
                signal.signal(callback: 202)
            }
            if callback == 202 { self.done.send() }
        }
        return signal
    }
}

@RelayControlActor private final class RelayTimerOwner {
    let done: RelayTestSignal
    var count = 0
    init(done: RelayTestSignal) { self.done = done }
    func makeSignal() -> RelayCoalescedSignal {
        let signal = RelayCoalescedSignal()
        signal.install { @RelayControlActor [weak self, weak signal] in
            guard let self, let signal else { return }
            defer { signal.finish() }
            guard signal.take() != nil else { return }
            count += 1
            done.send()
        }
        return signal
    }
}

#if canImport(Darwin)
private final class RelayAutoreleaseSentinel: NSObject {
    let onRelease: @Sendable () -> Void
    init(_ onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
        super.init()
    }
    deinit { onRelease() }
}
#endif
