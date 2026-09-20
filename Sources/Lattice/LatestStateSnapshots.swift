import Foundation
import Dispatch

/// Single-consumer, demand-driven snapshots of a captured projection. Native
/// invalidations are hints. The configured periodic reconciliation marks the
/// stream dirty even when a cross-process or attached-store hint was missed.
/// The next consumer demand then reads the FULL projection; unchanged values
/// may be emitted. No snapshots or payload buffers accumulate while paused.
///
/// Database close is discovered on the next demanded reconciliation/snapshot,
/// not as an immediate lifecycle push. Every read has a fresh limits.timeout;
/// snapshot query shape, resource budgets, and backend support are unchanged.
public struct LatestStateSnapshots<Output: Sendable>: AsyncSequence, Sendable {
    public typealias Element = [Output]
    private let source: LatestStateSource<Output>

    init(projection: ProjectedResults<Output>, scheduler: ObservationScheduler,
         limits: ProjectionReadLimits, reconciliationInterval: TimeInterval,
         limit: Int?, hints: any CoarseInvalidationBackend) throws {
        // Validate without retaining this request's deadline across future reads.
        _ = try ProjectionReadRequest(descriptor: projection.descriptor,
            selectedColumns: projection.columns, limits: limits, limit: limit)
        let nanoseconds = (reconciliationInterval * 1_000_000_000).rounded(.up)
        guard reconciliationInterval.isFinite, reconciliationInterval > 0,
              nanoseconds.isFinite, nanoseconds >= 1, nanoseconds < Double(Int.max) else {
            throw ProjectionReadError.invalidRequest("reconciliationInterval must be positive, finite, and representable")
        }
        let interval = Int(nanoseconds)
        guard !DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(interval)).overflow else {
            throw ProjectionReadError.invalidRequest("reconciliation deadline overflows monotonic time")
        }
        source = LatestStateSource(projection: projection, scheduler: scheduler, limits: limits,
            interval: interval, limit: limit, hints: hints)
    }

    public func makeAsyncIterator() -> Iterator { Iterator(lease: source.claim()) }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        fileprivate let lease: LatestStateIteratorLease<Output>?

        public mutating func next() async throws -> [Output]? {
            guard let lease else {
                throw ProjectionReadError.invalidRequest("latest-state snapshots allow only one iterator")
            }
            return try await lease.state.next()
        }

        /// Stops admission immediately. An already selected value may still be
        /// handed to its consumer; cancellation cannot revoke that handoff.
        public func cancel() { lease?.state.cancel() }

        /// Waits for registration/removal, native snapshot cleanup, and the
        /// admitted scheduler turn. Task cancellation does not abandon cleanup.
        /// A native hook removal failure is reported and disables new stream
        /// registrations on this ObservationScheduler; its stale hook is inert.
        /// Concurrent cleanup callers each retain their own wait continuation;
        /// the subscription cap does not bound that caller-created fanout.
        public func cancelAndWait() async throws { try await lease?.state.cancelAndWait() }
    }
}

private final class LatestStateSource<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private let projection: ProjectedResults<Output>
    private let scheduler: ObservationScheduler
    private let limits: ProjectionReadLimits
    private let interval: Int
    private let limit: Int?
    private let hints: any CoarseInvalidationBackend

    init(projection: ProjectedResults<Output>, scheduler: ObservationScheduler,
         limits: ProjectionReadLimits, interval: Int, limit: Int?, hints: any CoarseInvalidationBackend) {
        self.projection = projection
        self.scheduler = scheduler
        self.limits = limits
        self.interval = interval
        self.limit = limit
        self.hints = hints
    }

    func claim() -> LatestStateIteratorLease<Output>? {
        lock.lock()
        let first = !claimed
        claimed = true
        lock.unlock()
        guard first else { return nil }
        return LatestStateIteratorLease(LatestStateIteratorState(projection: projection,
            scheduler: scheduler, limits: limits, interval: interval, limit: limit, hints: hints))
    }
}

/// A task may retain state while reading. This separate lease makes dropping
/// the final iterator copy cancel that task rather than waiting for state deinit.
fileprivate final class LatestStateIteratorLease<Output: Sendable>: Sendable {
    let state: LatestStateIteratorState<Output>
    init(_ state: LatestStateIteratorState<Output>) { self.state = state }
    deinit { state.cancel() }
}

private enum LatestStateBegin {
    case wait, finished
    case terminal(any Error)
}

private typealias LatestStateAction = @Sendable () -> Void

/// One timer per admitted registration, all carrying fixed-size dirty signals.
/// Dispatch coalesces timer events; no event launches a task or reads SQLite.
private let latestStateReconciliationQueue = DispatchQueue(
    label: "lattice.latest-state.reconciliation", qos: .utility)

fileprivate final class LatestStateIteratorState<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let projection: ProjectedResults<Output>
    private let scheduler: ObservationScheduler
    private let limits: ProjectionReadLimits
    private let interval: Int
    private let limit: Int?
    private let hints: any CoarseInvalidationBackend
    private var nextInFlight = false
    private var pending: CheckedContinuation<[Output]?, any Error>?
    private var starting = false
    private var started = false
    private var stopped = false
    private var terminalDelivered = false
    private var terminalError: (any Error)?
    private var cleanupError: (any Error)?
    private var revision: UInt64 = 0
    private var dirty = true
    private var scheduled = false
    private var turnActive = false
    private var taskStarting = false
    private var task: Task<Void, Never>?
    private var subscription: ObservationTurnScheduler.Subscription?
    private var hook: UInt64?
    private var timer: (any DispatchSourceTimer)?
    private var removalInFlight = false
    private var sourceCleanupFinished = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(projection: ProjectedResults<Output>, scheduler: ObservationScheduler,
         limits: ProjectionReadLimits, interval: Int, limit: Int?, hints: any CoarseInvalidationBackend) {
        self.projection = projection
        self.scheduler = scheduler
        self.limits = limits
        self.interval = interval
        self.limit = limit
        self.hints = hints
    }

    deinit { cancel() }

    func next() async throws -> [Output]? {
        switch try beginNext() {
        case .finished: return nil
        case .terminal(let error):
            try await cancelAndWait()
            throw error
        case .wait: break
        }
        do {
            return try await withTaskCancellationHandler {
                if Task.isCancelled { cancel() }
                return try await withCheckedThrowingContinuation { installDemand($0) }
            } onCancel: { cancel() }
        } catch {
            try await cancelAndWait()
            throw error
        }
    }

    private func beginNext() throws -> LatestStateBegin {
        lock.lock()
        defer { lock.unlock() }
        guard !nextInFlight else {
            throw ProjectionReadError.invalidRequest("concurrent next calls on one latest-state iterator")
        }
        if stopped {
            guard !terminalDelivered else { return .finished }
            terminalDelivered = true
            return .terminal(cleanupError ?? terminalError ?? ProjectionReadError.cancelled)
        }
        nextInFlight = true
        return .wait
    }

    private func installDemand(_ continuation: CheckedContinuation<[Output]?, any Error>) {
        lock.lock()
        precondition(pending == nil)
        pending = continuation
        let shouldStart = !stopped && !started && !starting
        if shouldStart { starting = true }
        let notify = notificationLocked()
        let actions = settleStoppedLocked()
        lock.unlock()
        actions.forEach { $0() }
        if shouldStart { start() }
        if let notify { notify.0.notify(revision: notify.1) }
    }

    private func start() {
        var failure: (any Error)?
        do {
            let identity = UInt64(bitPattern: projection.descriptor.backend.identityHash)
            let subscription = try scheduler.register(storeID: identity) { [weak self] _, completion in
                self?.admit(completion)
            }
            locked { self.subscription = subscription }
            if !locked({ stopped }) {
                let token: UInt64
                do { token = try hints._addCoarseInvalidationHook { [weak self] _ in self?.signal() } }
                catch { throw ProjectionReadError.database("latest-state invalidation registration failed: \(error)") }
                locked { hook = token }
                if !locked({ stopped }) {
                    let timer = DispatchSource.makeTimerSource(queue: latestStateReconciliationQueue)
                    timer.setEventHandler { [weak self] in self?.signal() }
                    timer.schedule(deadline: .now() + .nanoseconds(interval), repeating: .nanoseconds(interval))
                    timer.resume()
                    locked { self.timer = timer }
                }
            }
        } catch { failure = error }
        lock.lock()
        starting = false
        started = true
        if let failure, !stopped {
            stopped = true
            terminalError = failure
        }
        let shouldClean = stopped
        let notify = notificationLocked()
        lock.unlock()
        if shouldClean { beginCleanup() }
        if let notify { notify.0.notify(revision: notify.1) }
    }

    private func signal() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        revision &+= 1 // Opaque arrival sequence; dirty, not numeric order, drives work.
        dirty = true
        let notify = notificationLocked()
        lock.unlock()
        if let notify { notify.0.notify(revision: notify.1) }
    }

    private func notificationLocked() -> (ObservationTurnScheduler.Subscription, UInt64)? {
        guard !stopped, started, !starting, pending != nil, dirty,
              !scheduled, !turnActive, let subscription else { return nil }
        scheduled = true
        return (subscription, revision)
    }

    private func admit(_ completion: ObservationTurnScheduler.Completion) {
        lock.lock()
        scheduled = false
        guard !stopped, pending != nil, dirty, !turnActive else {
            lock.unlock()
            return // Worker's token drop acknowledges this cancelled/stale turn.
        }
        dirty = false
        turnActive = true
        taskStarting = true
        lock.unlock()
        // Publish the task handle before it can finish or enter native work.
        // This closes cancellation racing Task creation without polling/tasks.
        let startGate = LatestStateTaskStartGate()
        let task = Task { [self, completion] in
            await startGate.wait()
            let result: Result<[Output], any Error>
            if Task.isCancelled || locked({ stopped }) {
                result = .failure(ProjectionReadError.cancelled)
            } else {
                do { result = .success(try await projection.snapshot(limit: limit, limits: limits)) }
                catch { result = .failure(error) }
            }
            snapshotFinished(result, completion: completion)
        }
        lock.lock()
        self.task = task
        taskStarting = false
        let cancel = stopped
        lock.unlock()
        if cancel { task.cancel() }
        startGate.open()
    }

    private func snapshotFinished(_ result: Result<[Output], any Error>,
                                  completion: ObservationTurnScheduler.Completion) {
        lock.lock()
        task = nil
        turnActive = false
        var actions: [LatestStateAction] = []
        if !stopped {
            switch result {
            case .success(let rows):
                // Successful publication linearizes here. A later cancel may
                // not revoke this already selected handoff; no success can be
                // selected after stopped closes admission under the same lock.
                if let pending {
                    self.pending = nil
                    nextInFlight = false
                    actions.append { pending.resume(returning: rows) }
                }
            case .failure(let error):
                stopped = true
                terminalError = error
            }
        }
        let shouldClean = stopped
        actions += settleStoppedLocked()
        lock.unlock()
        // snapshot() has returned only after its native cleanup acknowledgement.
        completion.acknowledge()
        if shouldClean { beginCleanup() }
        actions.forEach { $0() }
    }

    func cancel() {
        lock.lock()
        if !stopped {
            stopped = true
            terminalError = ProjectionReadError.cancelled
        }
        dirty = false
        lock.unlock()
        beginCleanup()
    }

    private func beginCleanup() {
        lock.lock()
        let task = task
        let timer = timer
        self.timer = nil
        let remove = stopped && !starting && !removalInFlight && !sourceCleanupFinished
        let hook = remove ? self.hook : nil
        let subscription = remove ? self.subscription : nil
        if remove {
            removalInFlight = true
            self.hook = nil
        }
        lock.unlock()
        timer?.cancel()
        task?.cancel()
        guard remove else { return }

        var failure: (any Error)?
        if let hook {
            do { try hints._removeCoarseInvalidationHook(hook) }
            catch {
                let error = ProjectionReadError.database("latest-state invalidation removal failed: \(error)")
                failure = error
                scheduler.rejectFutureRegistrations(after: error)
            }
        }
        // Source removal or scheduler poisoning MUST precede capacity release.
        subscription?.cancel()
        lock.lock()
        removalInFlight = false
        sourceCleanupFinished = true
        if let failure, cleanupError == nil { cleanupError = failure }
        let actions = settleStoppedLocked()
        lock.unlock()
        actions.forEach { $0() }
    }

    func cancelAndWait() async throws {
        cancel()
        await withCheckedContinuation { continuation in
            lock.lock()
            drainWaiters.append(continuation)
            let actions = settleStoppedLocked()
            lock.unlock()
            actions.forEach { $0() }
        }
        if let subscription = locked({ subscription }) { await subscription.cancelAndWait() }
        if let error = locked({ cleanupError }) { throw error }
    }

    private func settleStoppedLocked() -> [LatestStateAction] {
        guard stopped, !starting, !removalInFlight, sourceCleanupFinished,
              !turnActive, !taskStarting else { return [] }
        var actions: [LatestStateAction] = []
        if let pending {
            self.pending = nil
            nextInFlight = false
            terminalDelivered = true
            let error = cleanupError ?? terminalError ?? ProjectionReadError.cancelled
            actions.append { pending.resume(throwing: error) }
        }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        actions += waiters.map { waiter in { waiter.resume() } }
        return actions
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Exactly one task waits on this creation handshake. Cancellation cannot
/// abandon it; the synchronous creator always opens it after installing the task.
private final class LatestStateTaskStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let opened = opened
            if !opened { waiter = continuation }
            lock.unlock()
            if opened { continuation.resume() }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}
