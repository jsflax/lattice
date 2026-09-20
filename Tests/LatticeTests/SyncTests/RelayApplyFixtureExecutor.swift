import Foundation
import _Concurrency

/// Test-only executor for one bounded admission fixture. Thirty-two pending
/// slots are a checked fixture invariant, not a
/// new production queue policy. Runtime jobs are never dropped or coalesced.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
final class RelayApplyFixtureExecutor: TaskExecutor, @unchecked Sendable {
    struct Snapshot: Sendable {
        let pending: Int
        let peakPending: Int
        let running: Int
        let liveWorkers: Int
        let stopped: Bool
        let completedTurns: Int
    }
    private struct Work {
        let job: UnownedJob
        let executor: RelayApplyFixtureExecutor
    }
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        let threadKey = "lattice.test.apply-fixture.\(UUID().uuidString)"
        var slots: [Work?] = Array(repeating: nil, count: 32)
        var head = 0
        var pending = 0
        var peak = 0
        var running = 0
        var live = 1
        var stopping = false
        var stopped = false
        var shutdownWaiter: CheckedContinuation<Void, Never>?
        var completedTurns = 0
        var suspendedTurn: CheckedContinuation<Bool, Never>?

        func enqueue(_ work: Work) {
            condition.lock()
            precondition(!stopping && pending < slots.count,
                         "test executor admission exceeds its reviewed scope")
            slots[(head + pending) % slots.count] = work
            pending += 1; peak = max(peak, pending)
            condition.signal()
            condition.unlock()
        }
        func take() -> Work? {
            condition.lock()
            while pending == 0 && !stopping { condition.wait() }
            guard pending > 0 else { condition.unlock(); return nil }
            let work = slots[head]!
            slots[head] = nil // local retains the job/executor before clearing.
            head = (head + 1) % slots.count; pending -= 1; running = 1
            condition.unlock()
            return work
        }
        func completedTurn() -> CheckedContinuation<Bool, Never>? {
            condition.lock()
            running = 0; completedTurns += 1
            let turn = suspendedTurn
            suspendedTurn = nil
            condition.unlock()
            return turn
        }
        func suspendOneTurn(_ continuation: CheckedContinuation<Bool, Never>) {
            condition.lock()
            precondition(running == 1 && !stopping && suspendedTurn == nil)
            suspendedTurn = continuation
            condition.unlock()
        }
        func stop(_ waiter: CheckedContinuation<Void, Never>?) {
            var immediate: CheckedContinuation<Void, Never>?
            condition.lock()
            if stopped { immediate = waiter }
            else {
                if let waiter {
                    precondition(shutdownWaiter == nil, "one scoped shutdown waiter")
                    shutdownWaiter = waiter
                }
                stopping = true; condition.broadcast()
            }
            condition.unlock()
            immediate?.resume()
        }
        func finished() {
            condition.lock()
            precondition(pending == 0 && running == 0)
            stopped = true; live = 0
            let waiter = shutdownWaiter
            shutdownWaiter = nil
            condition.unlock()
            waiter?.resume()
        }
        func snapshot() -> Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(pending: pending, peakPending: peak, running: running,
                            liveWorkers: live, stopped: stopped, completedTurns: completedTurns)
        }
        func work() {
            Thread.current.threadDictionary[threadKey] = true
            defer {
                Thread.current.threadDictionary.removeObject(forKey: threadKey)
                finished()
            }
            while true {
                var item = take()
                guard item != nil else { return }
                #if canImport(ObjectiveC)
                autoreleasepool {
                    item!.job.runSynchronously(on: item!.executor.asUnownedTaskExecutor())
                }
                #else
                item!.job.runSynchronously(on: item!.executor.asUnownedTaskExecutor())
                #endif
                let suspended = completedTurn()
                item = nil // final capture release is outside the condition lock.
                // Test seam: resume only after the former runtime job returned,
                // proving a real suspension. No callbacks run under the lock.
                suspended?.resume(returning: true)
            }
        }
    }
    private let state: State
    init() {
        let state = State()
        self.state = state
        let worker = Thread { state.work() }
        worker.name = "lattice.test.apply-fixture"
        worker.stackSize = 8 * 1024 * 1024
        worker.start()
    }
    deinit { state.stop(nil) }
    func enqueue(_ job: consuming ExecutorJob) {
        state.enqueue(Work(job: UnownedJob(job), executor: self))
    }
    var isCurrent: Bool { Thread.current.threadDictionary[state.threadKey] as? Bool == true }
    var snapshot: Snapshot { state.snapshot() }
    /// Retained from the shared executor pattern for an explicit suspension
    /// witness; ordinary admission fixtures do not install this continuation.
    func suspendOneTurnForTesting() async -> Bool {
        guard isCurrent else { return false }
        return await withCheckedContinuation { state.suspendOneTurn($0) }
    }
    func shutdown() async {
        await withCheckedContinuation { state.stop($0) }
    }
}
