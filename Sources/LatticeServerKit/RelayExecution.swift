import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Portable actor execution: no TaskExecutor preference (iOS18/macOS15) is
/// required. Worker count is fixed; pending storage is proportional to live
/// actors/operations and their callers, NOT a fixed global memory cap.
/// Runtime jobs cannot be rejected or dropped. Admission is at the relay's
/// one-open/group, one-pump/subscription and coalesced-signal boundaries.
final class RelayExecutionPool: Sendable {
    static let control = RelayExecutionPool(workerCount: 1, name: "lattice.relay.control")
    static let io = RelayExecutionPool(workerCount: 2, name: "lattice.relay.io")
    static let stackSize = 8 << 20
    private let state: RelayExecutionState
    private let workerIdentity: String
    private static let workerIdentityKey = "lattice.relay.worker-identity"

    init(workerCount: Int, name: String) {
        precondition((1...8).contains(workerCount))
        state = RelayExecutionState(workerCount: workerCount)
        let identity = UUID().uuidString
        workerIdentity = identity
        for index in 0..<workerCount {
            let state = state
            let thread = Thread {
                Thread.current.threadDictionary[Self.workerIdentityKey] = identity
                state.work()
                Thread.current.threadDictionary.removeObject(forKey: Self.workerIdentityKey)
            }
            thread.name = "\(name).\(index)"
            thread.stackSize = Self.stackSize
            thread.start()
        }
    }

    deinit { state.stop() }

    func executor(for store: String) -> RelaySerialExecutor? {
        guard state.admitExecutor() else { return nil }
        return RelaySerialExecutor(state: state, store: store)
    }

    /// Existing actors must finish and be released before this completes.
    /// Closing admission never discards a runtime continuation already owned
    /// by an actor. Do not await shutdown from one of this pool's operations.
    func shutdown() async {
        await withCheckedContinuation { state.stop(waiter: $0) }
    }

    var snapshot: RelayExecutionSnapshot { state.snapshot }
    /// Synchronous diagnostic; verifies actual execution on this pool's worker.
    var isCurrentWorker: Bool {
        Thread.current.threadDictionary[Self.workerIdentityKey] as? String == workerIdentity
    }

    /// Native work is synchronous. Callers arrange their completion callback;
    /// workers never wait for a socket promise or another Swift task.
    @discardableResult
    func submit(for store: String, _ body: @escaping @Sendable () -> Void) -> Bool {
        state.enqueue(store: store, requiresAdmission: true, body)
    }

    /// Process-lived pools are never stopped by the relay. Rejecting one of
    /// their ownership/continuation jobs would strand work, so fail explicitly
    /// if a future internal caller violates that lifecycle contract.
    func submitRequired(for store: String, _ body: @escaping @Sendable () -> Void) {
        guard submit(for: store, body) else { fatalError("Relay execution pool admission is closed") }
    }
}

/// A statically isolated task body preserves initial executor metadata even
/// where a dynamic actor-method reference conversion erases that metadata.
/// This uses only the legacy serial-executor surface supported on iOS 15.
@globalActor actor RelayControlActor {
    static let shared = RelayControlActor()
    nonisolated let executor = RelayExecutionPool.control.executor(for: "relay-control")!
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
}

/// The legacy UnownedJob witness keeps the iOS15 deployment surface valid.
/// A store has at most one executing synchronous turn across all endpoints;
/// awaiting IO releases the worker and the store's turn for another ready job.
final class RelaySerialExecutor: SerialExecutor {
    private let state: RelayExecutionState
    private let store: String
    fileprivate init(state: RelayExecutionState, store: String) {
        self.state = state
        self.store = store
    }
    deinit { state.releaseExecutor() }
    func enqueue(_ job: UnownedJob) {
        state.enqueue(store: store, requiresAdmission: false) { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}

struct RelayExecutionSnapshot: Sendable {
    let liveWorkers: Int
    let startedWorkers: Int
    let executors: Int
    let queued: Int
    let running: Int
    let stopping: Bool
}

private struct RelayFIFO<Element> {
    private var values: [Element?] = []
    private var head = 0
    var isEmpty: Bool { head == values.count }
    mutating func append(_ value: Element) { values.append(value) }
    mutating func pop() -> Element? {
        guard head < values.count else { return nil }
        let value = values[head]!
        values[head] = nil
        head += 1
        if head == values.count { values = []; head = 0 }
        else if head >= 64 && head >= values.count - head {
            values.removeFirst(head); head = 0
        }
        return value
    }
}

private final class RelayExecutionState: @unchecked Sendable {
    private final class Store {
        var queue = RelayFIFO<@Sendable () -> Void>()
        var running = false
    }
    private let condition = NSCondition()
    private var stores: [String: Store] = [:]
    private var ready = RelayFIFO<String>()
    private var liveWorkers: Int
    private var startedWorkers = 0
    private var executors = 0
    private var queued = 0
    private var running = 0
    private var stopping = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(workerCount: Int) { liveWorkers = workerCount }
    func admitExecutor() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !stopping else { return false }
        executors += 1
        return true
    }
    func releaseExecutor() {
        condition.lock()
        executors -= 1
        condition.broadcast()
        condition.unlock()
    }
    @discardableResult
    func enqueue(store key: String, requiresAdmission: Bool, _ body: @escaping @Sendable () -> Void) -> Bool {
        condition.lock()
        guard !requiresAdmission || !stopping else { condition.unlock(); return false }
        // An endpoint retains this state through every pending runtime job.
        precondition(liveWorkers > 0)
        let store: Store
        if let existing = stores[key] { store = existing }
        else { store = Store(); stores[key] = store }
        if store.queue.isEmpty && !store.running { ready.append(key) }
        store.queue.append(body)
        queued += 1
        condition.signal()
        condition.unlock()
        return true
    }
    var snapshot: RelayExecutionSnapshot {
        condition.lock(); defer { condition.unlock() }
        return .init(liveWorkers: liveWorkers, startedWorkers: startedWorkers,
                     executors: executors, queued: queued, running: running, stopping: stopping)
    }
    func stop(waiter: CheckedContinuation<Void, Never>? = nil) {
        condition.lock()
        stopping = true
        let finished = liveWorkers == 0
        if let waiter, !finished { waiters.append(waiter) }
        condition.broadcast()
        condition.unlock()
        if finished { waiter?.resume() }
    }
    func work() {
        #if canImport(Darwin)
        precondition(pthread_get_stacksize_np(pthread_self()) >= RelayExecutionPool.stackSize)
        #endif
        condition.lock()
        startedWorkers += 1
        condition.unlock()
        while true {
            condition.lock()
            while ready.isEmpty {
                if stopping && executors == 0 && running == 0 {
                    liveWorkers -= 1
                    let completed = liveWorkers == 0 ? waiters : []
                    if liveWorkers == 0 { waiters = [] }
                    condition.broadcast()
                    condition.unlock()
                    for waiter in completed { waiter.resume() }
                    return
                }
                condition.wait()
            }
            let key = ready.pop()!
            let store = stores[key]!
            var body = store.queue.pop()!
            store.running = true
            queued -= 1
            running += 1
            condition.unlock()
            // Final captured owners and Darwin autoreleased objects drain
            // outside the queue lock; their deinitializers may enqueue work.
            #if canImport(Darwin)
            autoreleasepool {
                body()
                body = {}
            }
            #else
            body()
            body = {}
            #endif
            condition.lock()
            store.running = false
            running -= 1
            if store.queue.isEmpty { stores.removeValue(forKey: key) }
            else { ready.append(key) }
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// Payload-free signals keep only the latest diagnostic callback identity.
/// Coalescing is safe because the pump reads every retained audit row by cursor.
final class RelayCoalescedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private final class Operation: Sendable {
        let body: @RelayControlActor @Sendable () async -> Void
        init(_ body: @escaping @RelayControlActor @Sendable () async -> Void) { self.body = body }
    }
    private var operation: Operation?
    private var callback: UInt64?
    private var dirty = false
    private var scheduled = false
    private var cancelled = false

    func install(_ operation: @escaping @RelayControlActor @Sendable () async -> Void) {
        let retained = Operation(operation)
        lock.lock()
        precondition(self.operation == nil && !cancelled)
        self.operation = retained
        lock.unlock()
    }
    func signal(callback: UInt64?) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        self.callback = callback
        dirty = true
        let next = scheduled ? nil : operation
        if next != nil { scheduled = true }
        lock.unlock()
        if let next { Task(operation: next.body) }
    }
    /// Outer optional distinguishes no turn from a turn without diagnostics.
    func take() -> UInt64?? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, dirty else { return nil }
        dirty = false
        return .some(callback)
    }
    func finish() {
        lock.lock()
        let next = !cancelled && dirty ? operation : nil
        if next == nil { scheduled = false }
        lock.unlock()
        if let next { Task(operation: next.body) }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        dirty = false
        let released = operation
        operation = nil
        lock.unlock()
        withExtendedLifetime(released) {}
    }
}

/// One timer per live watch group, serviced by one shared GCD callback queue
/// in addition to the three fixed Foundation workers. A tick only signals the
/// coalescer; it never awaits Swift task resumption or performs native work.
/// Long intervals are armed in bounded chunks without overflowing Dispatch's
/// nanosecond representation. Nonpositive intervals remain immediate ticks.
final class RelayReconcileTimer: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "lattice.relay.reconcile")
    private let source: DispatchSourceTimer
    private let signal: RelayCoalescedSignal
    private let interval: RelayReconcileInterval
    private let lock = NSLock()
    private var remaining: RelayReconcileInterval
    private var armedAt: UInt64
    private var cancelled = false

    init(seconds: Int64, attoseconds: Int64, signal: RelayCoalescedSignal) {
        let interval = RelayReconcileInterval(seconds: seconds, attoseconds: attoseconds)
        self.interval = interval
        self.remaining = interval
        self.signal = signal
        self.armedAt = DispatchTime.now().uptimeNanoseconds
        self.source = DispatchSource.makeTimerSource(queue: Self.queue)
        source.setEventHandler { [weak self] in self?.tick() }
        source.schedule(deadline: .now() + .nanoseconds(interval.delayNanoseconds))
        source.activate()
    }

    deinit { cancel() }

    func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { source.cancel() }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        let elapsed = now >= armedAt ? now - armedAt : 0
        let due = remaining.consume(elapsedNanoseconds: elapsed)
        if due { remaining = interval }
        let delay = remaining.delayNanoseconds
        armedAt = now
        lock.unlock()
        // A concurrent cancellation may leave this already-admitted tick.
        // Group teardown cancels the signal first, making that tick inert.
        if due { signal.signal(callback: nil) }
        source.schedule(deadline: .now() + .nanoseconds(delay))
    }
}

// Integer components keep the executor helper usable on iOS15; Duration itself
// is iOS16+. The server passes canonical Duration.components. Subnanoseconds
// round up once, and arbitrarily long positive intervals retain whole seconds.
struct RelayReconcileInterval: Sendable {
    private(set) var seconds: UInt64
    private(set) var nanoseconds: UInt32

    init(seconds: Int64, attoseconds: Int64) {
        precondition((-1_000_000_000_000_000_000..<1_000_000_000_000_000_000).contains(attoseconds))
        guard seconds >= 0, seconds > 0 || attoseconds > 0 else {
            self.seconds = 0; self.nanoseconds = 0; return
        }
        var whole = UInt64(seconds)
        var fraction = attoseconds
        if fraction < 0 { whole -= 1; fraction += 1_000_000_000_000_000_000 }
        let rounded = UInt64((fraction + 999_999_999) / 1_000_000_000)
        self.seconds = whole + rounded / 1_000_000_000
        self.nanoseconds = UInt32(rounded % 1_000_000_000)
    }

    var delayNanoseconds: Int {
        guard seconds < 86_400 else { return 86_400_000_000_000 }
        return max(1, Int(seconds) * 1_000_000_000 + Int(nanoseconds))
    }

    /// Returns true once the interval has elapsed; no absolute DispatchTime
    /// addition or total-nanoseconds conversion is needed for large values.
    mutating func consume(elapsedNanoseconds elapsed: UInt64) -> Bool {
        let whole = elapsed / 1_000_000_000
        let fraction = UInt32(elapsed % 1_000_000_000)
        if whole > seconds || (whole == seconds && fraction >= nanoseconds) {
            seconds = 0; nanoseconds = 0; return true
        }
        if fraction > nanoseconds {
            seconds -= whole + 1
            nanoseconds = 1_000_000_000 + nanoseconds - fraction
        } else {
            seconds -= whole
            nanoseconds -= fraction
        }
        return false
    }
}
