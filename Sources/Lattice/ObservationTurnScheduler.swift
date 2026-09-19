import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

internal enum ObservationTurnSchedulerError: Error, Sendable, Equatable {
    case capacityExceeded
    case shutdown
}

/// Internal scheduling foundation used by the opt-in latest-state API.
/// Legacy observer APIs keep their existing scheduling behavior.
/// Callers select both resource caps explicitly. Notifications carry only an
/// opaque revision; a subscription stores one delivery closure and never a
/// queue of payloads. Ready stores and their subscriptions take turns fairly.
///
/// A delivery may hand its Completion to an actor. The subscription remains
/// admitted until the synchronous body returns AND that token is acknowledged
/// or dropped. The scheduler itself creates no asynchronous tasks. Each
/// store admits at most one turn, including its actor acknowledgement, so one
/// blocked store leaves other configured workers available. One worker, blocked
/// distinct stores occupying all workers, or a shared target actor cannot
/// provide independent progress.
///
/// The caps bound registrations, ready IDs, and admitted turns. Independently
/// created callers awaiting cancelAndWait/shutdown each retain a continuation;
/// the registration cap does not bound that caller-controlled wait fanout.
internal final class ObservationTurnScheduler: @unchecked Sendable {
    static let requiredStackSize = 8 << 20
    static let maximumWorkerCount = 8
    typealias Delivery = @Sendable (_ revision: UInt64, _ completion: Completion) -> Void

    private let state: ObservationTurnState

    // Internal clock seam for deterministic diagnostics tests. It must be
    // monotonic, nonblocking and must not reenter the scheduler.
    init(workerCount: Int, maxSubscriptions: Int,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        precondition((1...Self.maximumWorkerCount).contains(workerCount))
        precondition(maxSubscriptions > 0)
        state = ObservationTurnState(workerCount: workerCount, maxSubscriptions: maxSubscriptions, now: now)
        state.startWorkers(count: workerCount)
    }

    deinit { state.shutdown(waiter: nil) }

    /// Store IDs are opaque values, not references to databases or their owners.
    /// Delivery captures have their normal caller-defined ownership; capture an
    /// owner weakly if registration must not keep that owner alive.
    func register(storeID: UInt64, delivery: @escaping Delivery) throws -> Subscription {
        let id = try state.register(storeID: storeID, delivery: delivery)
        return Subscription(state: state, id: id)
    }

    /// Stops admission and waits for worker exit plus all admitted actor turns.
    /// Caller cancellation does not abandon this cleanup acknowledgement.
    /// It does not guarantee deinitialization of caller-owned closure captures.
    /// Never synchronously wait from an admitted body. An actor retaining its
    /// completion must acknowledge it before awaiting global shutdown as well.
    func shutdown() async {
        await withCheckedContinuation { state.shutdown(waiter: $0) }
    }

    struct Snapshot: Sendable {
        let subscriptions: Int
        let readyStores: Int
        let readySubscriptions: Int
        let admittedTurns: Int
        let bodiesRunning: Int
        let drainWaiters: Int
        let liveWorkers: Int
        let verifiedWorkers: Int
        let isShutdown: Bool
    }

    var snapshot: Snapshot { state.snapshot }

    var diagnostics: ObservationSchedulerDiagnostics { state.diagnostics }

    final class Subscription: @unchecked Sendable {
        private let state: ObservationTurnState
        private let id: UUID

        fileprivate init(state: ObservationTurnState, id: UUID) {
            self.state = state
            self.id = id
        }

        deinit { cancel() }

        /// Latest means arrival order under the scheduler lock, never numeric
        /// revision order. Even equal revisions mark an admitted turn dirty.
        func notify(revision: UInt64) { state.notify(id, revision: revision) }

        /// Safe from inside this subscription's synchronous delivery body.
        /// Already admitted work retains its normal body/completion lifetime.
        func cancel() { state.cancel(id, waiter: nil) }

        /// Do not synchronously wait on this from its own delivery body. An
        /// actor continuation must acknowledge its turn before awaiting its
        /// own drain; otherwise it would wait for its own acknowledgement.
        /// Drain covers body return and acknowledgement, not deinitialization
        /// of closure captures still held by a worker or by caller code.
        func cancelAndWait() async {
            await withCheckedContinuation { state.cancel(id, waiter: $0) }
        }
    }

    final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var state: ObservationTurnState?
        private let subscriptionID: UUID
        private let turnID: UUID

        fileprivate init(state: ObservationTurnState, subscriptionID: UUID, turnID: UUID) {
            self.state = state
            self.subscriptionID = subscriptionID
            self.turnID = turnID
        }

        deinit { acknowledge() }

        /// Idempotent and safe before the body returns. Retaining an already
        /// acknowledged token does not retain scheduler state or any closure.
        func acknowledge() {
            lock.lock()
            let state = state
            self.state = nil
            lock.unlock()
            state?.acknowledge(subscriptionID, turnID: turnID)
        }
    }
}

private typealias ObservationTurnAction = @Sendable () -> Void

private final class ObservationDeliveryBox: Sendable {
    let deliver: ObservationTurnScheduler.Delivery
    init(_ deliver: @escaping ObservationTurnScheduler.Delivery) { self.deliver = deliver }
}

/// Amortized FIFO removal; cancelling a token compacts immediately. Only IDs
/// live here. Empty queues release their storage, and consumed prefixes are
/// copied away, so churn cannot retain the peak capacity of every former queue.
private struct ObservationReadyQueue<Value: Equatable> {
    private var values: [Value] = []
    private var head = 0
    var count: Int { values.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ value: Value) { values.append(value) }

    mutating func popFirst() -> Value? {
        guard head < values.count else { return nil }
        let result = values[head]
        head += 1
        if head == values.count {
            values = []
            head = 0
        } else if head >= 64 && head >= values.count / 2 {
            values = Array(values[head...])
            head = 0
        }
        return result
    }

    mutating func remove(_ value: Value) {
        values = values[head...].filter { $0 != value }
        head = 0
    }
}

/// All mutable registration/store fields belong to ObservationTurnState's lock.
private final class ObservationTurnRecord {
    let id: UUID
    let storeID: UInt64
    var delivery: ObservationDeliveryBox?
    var revision: UInt64 = 0
    var dirty = false
    var ready = false
    var cancelled = false
    var turnID: UUID?
    var bodyReturned = false
    var acknowledged = false
    var pendingSince: UInt64?
    var readySince: UInt64?
    var timing: ObservationTurnTiming?
    var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: UUID, storeID: UInt64, delivery: ObservationDeliveryBox) {
        self.id = id
        self.storeID = storeID
        self.delivery = delivery
    }
}

private struct ObservationTurnTiming {
    let notifiedAt: UInt64
    let admittedAt: UInt64
    var bodyReturnedAt: UInt64?
    var acknowledgedAt: UInt64?
}

private func observationElapsed(from start: UInt64, to end: UInt64) -> UInt64 {
    precondition(end >= start, "observation diagnostics clock must be monotonic")
    return end - start
}

private final class ObservationStoreQueue {
    var subscriptions = 0
    var ready = ObservationReadyQueue<UUID>()
    var enqueued = false
    var admitted = false
}

private struct ObservationAdmittedTurn {
    let subscriptionID: UUID
    let turnID: UUID
    let revision: UInt64
    let delivery: ObservationDeliveryBox
}

/// Workers/tokens retain this state, never the scheduler wrapper. Cancellation
/// drops the registered closure off-lock, even while an actor holds its token.
private final class ObservationTurnState: @unchecked Sendable {
    private let condition = NSCondition()
    private let workerCount: Int
    private let maxSubscriptions: Int
    private let now: @Sendable () -> UInt64
    private var lastCompletedTurn: ObservationSchedulerDiagnostics.CompletedTurn?
    private var records: [UUID: ObservationTurnRecord] = [:]
    private var stores: [UInt64: ObservationStoreQueue] = [:]
    private var readyStores = ObservationReadyQueue<UInt64>()
    private var stopping = false
    private var liveWorkers: Int
    private var verifiedWorkers = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(workerCount: Int, maxSubscriptions: Int, now: @escaping @Sendable () -> UInt64) {
        self.workerCount = workerCount
        self.liveWorkers = workerCount
        self.maxSubscriptions = maxSubscriptions
        self.now = now
    }

    func startWorkers(count: Int) {
        for index in 0..<count {
            let thread = Thread { [self] in
                #if canImport(Darwin)
                let actual = pthread_get_stacksize_np(pthread_self())
                precondition(actual >= ObservationTurnScheduler.requiredStackSize,
                             "observation turn worker has an undersized native stack: \(actual)")
                #endif
                condition.lock()
                verifiedWorkers += 1
                condition.unlock()
                while let turn = nextTurn() {
                    #if canImport(Darwin)
                    autoreleasepool { deliver(turn) }
                    #else
                    deliver(turn)
                    #endif
                }
                workerExited()
            }
            thread.name = "lattice.observation-turn.\(index)"
            #if canImport(Darwin)
            thread.qualityOfService = .utility
            #endif
            thread.stackSize = ObservationTurnScheduler.requiredStackSize
            thread.start()
        }
    }

    var snapshot: ObservationTurnScheduler.Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return .init(subscriptions: records.count, readyStores: readyStores.count,
                     readySubscriptions: records.values.filter(\.ready).count,
                     admittedTurns: records.values.filter { $0.turnID != nil }.count,
                     bodiesRunning: records.values.filter { $0.turnID != nil && !$0.bodyReturned }.count,
                     drainWaiters: records.values.reduce(0) { $0 + $1.drainWaiters.count },
                     liveWorkers: liveWorkers, verifiedWorkers: verifiedWorkers, isShutdown: stopping)
    }

    var diagnostics: ObservationSchedulerDiagnostics {
        condition.lock()
        defer { condition.unlock() }
        let sampledAt = now()
        var pending = 0, ready = 0, pendingWhileAdmitted = 0
        var admitted = 0, running = 0, awaitingAcknowledgement = 0
        var oldestPending: UInt64?, oldestReady: UInt64?
        var oldestAdmitted: UInt64?, oldestAcknowledgement: UInt64?
        func include(_ startedAt: UInt64, in oldest: inout UInt64?) {
            let age = observationElapsed(from: startedAt, to: sampledAt)
            oldest = max(oldest ?? 0, age)
        }
        for record in records.values {
            if record.dirty {
                pending += 1
                include(record.pendingSince!, in: &oldestPending)
                if record.turnID != nil { pendingWhileAdmitted += 1 }
            }
            if record.ready {
                ready += 1
                include(record.readySince!, in: &oldestReady)
            }
            if let timing = record.timing {
                admitted += 1
                include(timing.admittedAt, in: &oldestAdmitted)
                if !record.bodyReturned { running += 1 }
                else if !record.acknowledged {
                    awaitingAcknowledgement += 1
                    include(timing.bodyReturnedAt!, in: &oldestAcknowledgement)
                }
            }
        }
        return .init(workerCount: workerCount, maxSubscriptions: maxSubscriptions,
                     subscriptions: records.count, pendingSubscriptions: pending,
                     readySubscriptions: ready, pendingWhileAdmitted: pendingWhileAdmitted,
                     admittedTurns: admitted, bodiesRunning: running,
                     awaitingAcknowledgement: awaitingAcknowledgement,
                     oldestPendingAgeNanoseconds: oldestPending,
                     oldestReadyAgeNanoseconds: oldestReady,
                     oldestAdmittedAgeNanoseconds: oldestAdmitted,
                     oldestAwaitingAcknowledgementAgeNanoseconds: oldestAcknowledgement,
                     lastCompletedTurn: lastCompletedTurn)
    }

    func register(storeID: UInt64, delivery: @escaping ObservationTurnScheduler.Delivery) throws -> UUID {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping else { throw ObservationTurnSchedulerError.shutdown }
        guard records.count < maxSubscriptions else { throw ObservationTurnSchedulerError.capacityExceeded }
        let id = UUID()
        records[id] = ObservationTurnRecord(id: id, storeID: storeID, delivery: ObservationDeliveryBox(delivery))
        let store = stores[storeID] ?? ObservationStoreQueue()
        store.subscriptions += 1
        stores[storeID] = store
        return id
    }

    func notify(_ id: UUID, revision: UInt64) {
        condition.lock()
        if !stopping, let record = records[id], !record.cancelled {
            record.revision = revision
            if !record.dirty { record.pendingSince = now() }
            record.dirty = true
            if record.turnID == nil && !record.ready { enqueueLocked(record) }
        }
        condition.unlock()
    }

    private func enqueueLocked(_ record: ObservationTurnRecord) {
        precondition(!record.ready && record.turnID == nil && !record.cancelled)
        let store = stores[record.storeID]!
        record.ready = true
        record.readySince = now()
        store.ready.append(record.id)
        makeStoreReadyLocked(record.storeID, store: store)
    }

    private func makeStoreReadyLocked(_ id: UInt64, store: ObservationStoreQueue) {
        guard !stopping, !store.admitted, !store.enqueued, !store.ready.isEmpty else { return }
        store.enqueued = true
        readyStores.append(id)
        condition.signal()
    }

    private func nextTurn() -> ObservationAdmittedTurn? {
        condition.lock()
        defer { condition.unlock() }
        while readyStores.isEmpty && !stopping { condition.wait() }
        guard !stopping, let storeID = readyStores.popFirst() else { return nil }
        let store = stores[storeID]!
        precondition(!store.admitted)
        store.enqueued = false
        store.admitted = true
        let id = store.ready.popFirst()!
        let record = records[id]!
        precondition(record.ready && record.turnID == nil && !record.cancelled)
        // Remaining subscriptions stay parked until this store's complete
        // turn (body AND actor acknowledgement) settles.
        record.timing = .init(notifiedAt: record.pendingSince!, admittedAt: now())
        record.pendingSince = nil
        record.readySince = nil
        record.ready = false
        record.dirty = false
        let turnID = UUID()
        record.turnID = turnID
        record.bodyReturned = false
        record.acknowledged = false
        return .init(subscriptionID: id, turnID: turnID, revision: record.revision, delivery: record.delivery!)
    }

    private func deliver(_ turn: ObservationAdmittedTurn) {
        let completion = ObservationTurnScheduler.Completion(state: self,
            subscriptionID: turn.subscriptionID, turnID: turn.turnID)
        turn.delivery.deliver(turn.revision, completion)
        // Dropping the body's local reference acknowledges only after its
        // return was recorded. Actors may retain an independent reference.
        withExtendedLifetime(completion) {
            bodyReturned(turn.subscriptionID, turnID: turn.turnID)
        }
    }

    private func bodyReturned(_ id: UUID, turnID: UUID) {
        condition.lock()
        var actions: [ObservationTurnAction] = []
        if let record = records[id], record.turnID == turnID {
            if !record.bodyReturned { record.timing?.bodyReturnedAt = now() }
            record.bodyReturned = true
            actions = settleLocked(record)
        }
        condition.unlock()
        actions.forEach { $0() }
    }

    func acknowledge(_ id: UUID, turnID: UUID) {
        condition.lock()
        var actions: [ObservationTurnAction] = []
        if let record = records[id], record.turnID == turnID {
            if !record.acknowledged { record.timing?.acknowledgedAt = now() }
            record.acknowledged = true
            actions = settleLocked(record)
        }
        condition.unlock()
        actions.forEach { $0() }
    }

    private func settleLocked(_ record: ObservationTurnRecord) -> [ObservationTurnAction] {
        guard record.bodyReturned && record.acknowledged else { return [] }
        let timing = record.timing!
        let completedAt = now()
        lastCompletedTurn = .init(subscriptionID: record.id, turnID: record.turnID!,
            notificationToAdmissionNanoseconds: observationElapsed(from: timing.notifiedAt, to: timing.admittedAt),
            notificationToCompletionNanoseconds: observationElapsed(from: timing.notifiedAt, to: completedAt),
            admittedToBodyReturnNanoseconds: observationElapsed(from: timing.admittedAt, to: timing.bodyReturnedAt!),
            admittedToAcknowledgementNanoseconds: observationElapsed(from: timing.admittedAt, to: timing.acknowledgedAt!),
            admittedToCompletionNanoseconds: observationElapsed(from: timing.admittedAt, to: completedAt))
        record.timing = nil
        let store = stores[record.storeID]!
        precondition(store.admitted)
        store.admitted = false
        record.turnID = nil
        var actions: [ObservationTurnAction] = []
        if record.cancelled { actions = removeLocked(record) }
        else if record.dirty { enqueueLocked(record) }
        if let store = stores[record.storeID] {
            // Rotates this store behind other stores already ready. Within
            // the store, a dirty returning subscription goes after parked IDs.
            makeStoreReadyLocked(record.storeID, store: store)
        }
        return actions
    }

    func cancel(_ id: UUID, waiter: CheckedContinuation<Void, Never>?) {
        condition.lock()
        var actions: [ObservationTurnAction] = []
        if let record = records[id] {
            if let waiter { record.drainWaiters.append(waiter) }
            actions = cancelLocked(record)
        } else if let waiter {
            actions = [{ waiter.resume() }]
        }
        condition.unlock()
        actions.forEach { $0() }
    }

    private func cancelLocked(_ record: ObservationTurnRecord) -> [ObservationTurnAction] {
        record.cancelled = true
        record.dirty = false
        record.pendingSince = nil
        record.readySince = nil
        var actions: [ObservationTurnAction] = []
        if let delivery = record.delivery {
            record.delivery = nil
            // Releasing a captured user object can execute its deinitializer.
            // Keep the closure alive until these actions run after unlock.
            actions.append { withExtendedLifetime(delivery) {} }
        }
        if record.ready {
            record.ready = false
            let store = stores[record.storeID]!
            store.ready.remove(record.id)
            if store.ready.isEmpty && store.enqueued {
                store.enqueued = false
                readyStores.remove(record.storeID)
            }
        }
        if record.turnID == nil { actions += removeLocked(record) }
        return actions
    }

    private func removeLocked(_ record: ObservationTurnRecord) -> [ObservationTurnAction] {
        precondition(record.cancelled && record.turnID == nil && !record.ready && record.delivery == nil)
        records.removeValue(forKey: record.id)
        let store = stores[record.storeID]!
        store.subscriptions -= 1
        if store.subscriptions == 0 {
            precondition(store.ready.isEmpty && !store.enqueued && !store.admitted)
            stores.removeValue(forKey: record.storeID)
        }
        let waiters = record.drainWaiters
        record.drainWaiters.removeAll()
        return waiters.map { waiter in { waiter.resume() } } + shutdownCompletionsLocked()
    }

    func shutdown(waiter: CheckedContinuation<Void, Never>?) {
        condition.lock()
        if let waiter { shutdownWaiters.append(waiter) }
        var actions: [ObservationTurnAction] = []
        if !stopping {
            stopping = true
            // Bulk clear IDs once: cancelling each ready record separately
            // would repeatedly compact the same store queue (quadratic work).
            readyStores = ObservationReadyQueue()
            for store in stores.values {
                store.ready = ObservationReadyQueue()
                store.enqueued = false
            }
            for record in records.values { record.ready = false }
            for record in Array(records.values) { actions += cancelLocked(record) }
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

    private func shutdownCompletionsLocked() -> [ObservationTurnAction] {
        guard stopping, liveWorkers == 0, records.isEmpty else { return [] }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        return waiters.map { waiter in { waiter.resume() } }
    }
}
