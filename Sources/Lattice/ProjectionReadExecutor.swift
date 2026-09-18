import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

internal enum ProjectionReadExecutorError: Error, Sendable, Equatable {
    case queueFull
    case deadlineExceeded
    case shutdown
}

/// Bounded execution for synchronous native reads. These are explicit resource
/// caps, not measured throughput defaults. SQL runs only on the worker threads;
/// the single timer merely expires waiting work and signals running operations.
///
/// Cancellation/deadline/shutdown discard a running result only AFTER the
/// synchronous operation returns, including its own cleanup. Resources retained
/// across submissions (for example, a cursor between batches) belong to the
/// caller, which must separately await their cleanup before reporting failure.
/// `onCancel` must be a
/// prompt, thread-safe interrupt signal: it may race the operation's cleanup,
/// but is invoked at most once, outside the state lock. It must not run SQL,
/// wait for the operation, or synchronously wait for this executor to stop.
internal final class ProjectionReadExecutor: @unchecked Sendable {
    static let shared = ProjectionReadExecutor()
    static let requiredStackSize = 8 << 20
    static let defaultWorkerCount = 2
    static let defaultMaxPendingJobs = 64
    static let maximumWorkerCount = 8
    static let maximumPendingJobs = 1_024

    private let state: ProjectionExecutorState

    init(workerCount: Int = defaultWorkerCount, maxPendingJobs: Int = defaultMaxPendingJobs) {
        precondition((1...Self.maximumWorkerCount).contains(workerCount))
        precondition((1...Self.maximumPendingJobs).contains(maxPendingJobs))
        state = ProjectionExecutorState(workerCount: workerCount, maxPendingJobs: maxPendingJobs)
        state.startWorkers(count: workerCount)
    }

    deinit { state.shutdown(waiter: nil) }

    func submit<Value: Sendable>(
        deadline: UInt64? = nil,
        onCancel: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let job = ProjectionExecutorJob(deadline: deadline, onCancel: onCancel, operation: operation)
        let state = state
        return try await withTaskCancellationHandler {
            if Task.isCancelled { state.cancel(job) }
            return try await withCheckedThrowingContinuation { continuation in
                state.enqueue(job, continuation: continuation)
            }
        } onCancel: {
            state.cancel(job)
        }
    }

    /// Reject new work, cancel pending/running work, and await worker exit.
    /// Running operations must cooperate with their interrupt signal; shutdown
    /// cannot preempt arbitrary native code or return before its cleanup.
    func shutdown() async {
        await withCheckedContinuation { state.shutdown(waiter: $0) }
    }

    struct Snapshot: Sendable {
        let pending: Int
        let running: Int
        let liveWorkers: Int
        let verifiedWorkers: Int
        let isShutdown: Bool
    }

    var snapshot: Snapshot { state.snapshot }
}

private enum ProjectionExecutorStop: Sendable {
    case cancelled, deadline, shutdown

    var error: any Error {
        switch self {
        case .cancelled: CancellationError()
        case .deadline: ProjectionReadExecutorError.deadlineExceeded
        case .shutdown: ProjectionReadExecutorError.shutdown
        }
    }
}

private typealias ProjectionExecutorAction = @Sendable () -> Void
private typealias ProjectionExecutorCompletion = @Sendable (ProjectionExecutorStop?) -> Void

/// Mutable fields below belong exclusively to ProjectionExecutorState's lock.
private class ProjectionExecutorAnyJob: @unchecked Sendable {
    enum Phase: Equatable { case created, queued, running, finished }
    let id = UUID()
    let deadline: UInt64?
    let onCancel: @Sendable () -> Void
    var phase: Phase = .created
    var stopped: ProjectionExecutorStop?
    var cancellationInFlight = false
    var completion: ProjectionExecutorCompletion?

    init(deadline: UInt64?, onCancel: @escaping @Sendable () -> Void) {
        self.deadline = deadline
        self.onCancel = onCancel
    }

    func execute() -> ProjectionExecutorCompletion { preconditionFailure("abstract job") }
    func rejection(_ error: any Error) -> ProjectionExecutorAction { preconditionFailure("abstract job") }
}

private final class ProjectionExecutorJob<Value: Sendable>: ProjectionExecutorAnyJob, @unchecked Sendable {
    let operation: @Sendable () throws -> Value
    // Set once under the state lock before publishing to a worker.
    var continuation: CheckedContinuation<Value, any Error>?

    init(deadline: UInt64?, onCancel: @escaping @Sendable () -> Void,
         operation: @escaping @Sendable () throws -> Value) {
        self.operation = operation
        super.init(deadline: deadline, onCancel: onCancel)
    }

    override func execute() -> ProjectionExecutorCompletion {
        let result = Result { try operation() }
        let continuation = continuation!
        let deadline = deadline
        return { stopped in
            if let stopped { continuation.resume(throwing: stopped.error) }
            else if let deadline, deadline <= DispatchTime.now().uptimeNanoseconds {
                // Recheck immediately before resume as well: the worker may
                // have been descheduled after the locked completion decision.
                continuation.resume(throwing: ProjectionReadExecutorError.deadlineExceeded)
            }
            else { continuation.resume(with: result) }
        }
    }

    override func rejection(_ error: any Error) -> ProjectionExecutorAction {
        let continuation = continuation!
        return { continuation.resume(throwing: error) }
    }
}

/// Worker closures retain this state, not the executor. Releasing an idle test
/// executor therefore initiates shutdown instead of leaking waiting threads.
private final class ProjectionExecutorState: @unchecked Sendable {
    private let condition = NSCondition()
    private let maxPendingJobs: Int
    private var queue: [ProjectionExecutorAnyJob] = []
    private var active: [UUID: ProjectionExecutorAnyJob] = [:]
    private var stopping = false
    private var liveWorkers: Int
    private var verifiedWorkers = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private let timer: any DispatchSourceTimer

    init(workerCount: Int, maxPendingJobs: Int) {
        self.liveWorkers = workerCount
        self.maxPendingJobs = maxPendingJobs
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
            label: "lattice.projection-read.deadlines", qos: .utility))
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.expireDeadlines() }
        timer.resume()
    }

    func startWorkers(count: Int) {
        for index in 0..<count {
            let thread = Thread { [self] in
                #if canImport(Darwin)
                let actual = pthread_get_stacksize_np(pthread_self())
                precondition(actual >= ProjectionReadExecutor.requiredStackSize,
                             "projection read worker has an undersized native stack: \(actual)")
                #endif
                condition.lock()
                verifiedWorkers += 1
                condition.unlock()
                while let job = nextJob() {
                    let completion = job.execute()
                    finish(job, completion: completion)
                }
                workerExited()
            }
            thread.name = "lattice.projection-read.\(index)"
            #if canImport(Darwin)
            thread.qualityOfService = .utility
            #endif
            thread.stackSize = ProjectionReadExecutor.requiredStackSize
            thread.start()
        }
    }

    var snapshot: ProjectionReadExecutor.Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return .init(pending: queue.count, running: active.count - queue.count,
                     liveWorkers: liveWorkers, verifiedWorkers: verifiedWorkers, isShutdown: stopping)
    }

    func enqueue<Value: Sendable>(_ job: ProjectionExecutorJob<Value>,
                        continuation: CheckedContinuation<Value, any Error>) {
        var actions: [ProjectionExecutorAction] = []
        condition.lock()
        job.continuation = continuation
        if let stopped = job.stopped {
            job.phase = .finished
            actions.append(job.rejection(stopped.error))
        } else if stopping {
            job.phase = .finished
            actions.append(job.rejection(ProjectionReadExecutorError.shutdown))
        } else if let deadline = job.deadline, deadline <= DispatchTime.now().uptimeNanoseconds {
            job.phase = .finished
            actions.append(job.rejection(ProjectionReadExecutorError.deadlineExceeded))
        } else if queue.count >= maxPendingJobs {
            job.phase = .finished
            actions.append(job.rejection(ProjectionReadExecutorError.queueFull))
        } else {
            job.phase = .queued
            queue.append(job)
            active[job.id] = job
            rescheduleTimerLocked()
            condition.signal()
        }
        condition.unlock()
        actions.forEach { $0() }
    }

    func cancel(_ job: ProjectionExecutorAnyJob) {
        condition.lock()
        let actions = stopLocked(job, reason: .cancelled)
        rescheduleTimerLocked()
        condition.unlock()
        actions.forEach { $0() }
    }

    private func nextJob() -> ProjectionExecutorAnyJob? {
        while true {
            condition.lock()
            while queue.isEmpty && !stopping { condition.wait() }
            guard !queue.isEmpty else { condition.unlock(); return nil }
            let job = queue[0]
            if let deadline = job.deadline, deadline <= DispatchTime.now().uptimeNanoseconds {
                let actions = stopLocked(job, reason: .deadline)
                rescheduleTimerLocked()
                condition.unlock()
                actions.forEach { $0() }
                continue
            }
            queue.removeFirst()
            job.phase = .running
            condition.unlock()
            return job
        }
    }

    private func finish(_ job: ProjectionExecutorAnyJob, completion: @escaping ProjectionExecutorCompletion) {
        condition.lock()
        job.completion = completion
        // Keep this worker's slot until the interrupt signal has returned.
        // Otherwise slow signals could leave an unbounded set of completed
        // jobs behind while the same workers keep accepting new operations.
        // NSCondition.wait releases the lock; it never blocks the callback.
        while job.cancellationInFlight { condition.wait() }
        let actions = finalizeIfReadyLocked(job)
        rescheduleTimerLocked()
        condition.unlock()
        actions.forEach { $0() }
    }

    private func cancellationFinished(_ job: ProjectionExecutorAnyJob) {
        condition.lock()
        job.cancellationInFlight = false
        let actions = finalizeIfReadyLocked(job)
        rescheduleTimerLocked()
        condition.broadcast()
        condition.unlock()
        actions.forEach { $0() }
    }

    /// First stop reason wins. Queued work is removed immediately; running
    /// work keeps its continuation until both operation and signal return.
    private func stopLocked(_ job: ProjectionExecutorAnyJob, reason: ProjectionExecutorStop)
        -> [ProjectionExecutorAction] {
        guard job.phase != .finished, job.stopped == nil else { return [] }
        job.stopped = reason
        switch job.phase {
        case .created:
            return [] // Cancellation may precede continuation installation.
        case .queued:
            queue.removeAll { $0 === job }
            active.removeValue(forKey: job.id)
            job.phase = .finished
            return [job.rejection(reason.error)] + shutdownCompletionsLocked()
        case .running:
            job.cancellationInFlight = true
            return [{ [self, job] in
                job.onCancel()
                cancellationFinished(job)
            }]
        case .finished:
            return []
        }
    }

    private func finalizeIfReadyLocked(_ job: ProjectionExecutorAnyJob) -> [ProjectionExecutorAction] {
        guard job.phase == .running, !job.cancellationInFlight,
              let completion = job.completion else { return [] }
        // Check at publication, even if the deadline timer was delayed or the
        // operation ignored its interrupt and returned an otherwise good value.
        if job.stopped == nil, let deadline = job.deadline,
           deadline <= DispatchTime.now().uptimeNanoseconds { job.stopped = .deadline }
        let stopped = job.stopped
        job.completion = nil
        job.phase = .finished
        active.removeValue(forKey: job.id)
        return [{ completion(stopped) }] + shutdownCompletionsLocked()
    }

    private func expireDeadlines() {
        condition.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let expired = active.values.filter { $0.stopped == nil && ($0.deadline.map { $0 <= now } ?? false) }
        // Resume queued callers before invoking any running interrupt signals.
        var actions: [ProjectionExecutorAction] = []
        for job in expired where job.phase == .queued { actions += stopLocked(job, reason: .deadline) }
        for job in expired where job.phase == .running { actions += stopLocked(job, reason: .deadline) }
        rescheduleTimerLocked()
        condition.unlock()
        actions.forEach { $0() }
    }

    private func rescheduleTimerLocked() {
        guard !stopping else { return }
        let deadline = active.values.filter { $0.stopped == nil }.compactMap(\.deadline).min()
        timer.schedule(deadline: deadline.map { DispatchTime(uptimeNanoseconds: $0) } ?? .distantFuture)
    }

    func shutdown(waiter: CheckedContinuation<Void, Never>?) {
        condition.lock()
        if let waiter { shutdownWaiters.append(waiter) }
        var actions: [ProjectionExecutorAction] = []
        if !stopping {
            stopping = true
            timer.cancel()
            let jobs = Array(active.values)
            for job in jobs where job.phase == .queued { actions += stopLocked(job, reason: .shutdown) }
            for job in jobs where job.phase == .running { actions += stopLocked(job, reason: .shutdown) }
            condition.broadcast()
        }
        actions += shutdownCompletionsLocked()
        condition.unlock()
        actions.forEach { $0() }
    }

    private func workerExited() {
        condition.lock()
        liveWorkers -= 1
        let actions = shutdownCompletionsLocked()
        condition.unlock()
        actions.forEach { $0() }
    }

    private func shutdownCompletionsLocked() -> [ProjectionExecutorAction] {
        guard stopping, liveWorkers == 0, active.isEmpty else { return [] }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        return waiters.map { waiter in { waiter.resume() } }
    }
}
