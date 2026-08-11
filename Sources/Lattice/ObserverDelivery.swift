import Foundation

/// Dedicated delivery thread for observer change batches (crash fix C0a,
/// Aug 2026 SIGBUS incident).
///
/// Observer delivery used to spawn one unbounded `Task.detached` per change
/// batch. Two properties of that arrangement killed the visualizer under
/// daemon sync bursts (Engram-2026-08-10-113510.ips, frame-fingerprinted):
///
/// 1. Cooperative-pool threads carry 512KB stacks. The delivery path runs
///    SQL prepares (membership re-checks, per-row hydration) beneath
///    user-supplied closure chains; Apple's libsqlite3 compiles
///    SQLITE_ENABLE_STMT_SCANSTATUS, fattening every prepare. The observed
///    crash was the stack guard page, ~6K closure-thunk frames deep, inside
///    `sqlite3WhereAddExplainText`.
/// 2. A 700K-row table syncing fans out THOUSANDS of concurrent detached
///    tasks — unbounded concurrency for work that is inherently serial per
///    observer.
///
/// One process-wide worker thread with an EXPLICIT 8MB stack replaces both:
/// jobs run FIFO, so cross-batch order is at least as strong as before, and
/// every statement the observe machinery prepares gets a deep stack. Darwin
/// secondary threads default to the same 512KB as the cooperative pool — the
/// explicit `stackSize` is the load-bearing line, and the run loop asserts it
/// took effect so a regression turns tests red.
final class ObserverDeliveryWorker: @unchecked Sendable {
    static let shared = ObserverDeliveryWorker()

    static let requiredStackSize = 8 << 20

    private let condition = NSCondition()
    private var queue: [@Sendable () -> Void] = []
    private var started = false

    func enqueue(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        queue.append(job)
        if !started {
            started = true
            startThread()
        }
        condition.signal()
        condition.unlock()
    }

    /// Test hook: true once the worker thread verified its enlarged stack.
    private let stackVerified = NIOLockedValueBoxCompat<Bool>(false)
    var isStackVerified: Bool { stackVerified.withLocked { $0 } }

    private func startThread() {
        let thread = Thread { [self] in
            let actual = pthread_get_stacksize_np(pthread_self())
            precondition(actual >= Self.requiredStackSize,
                         "observer delivery worker got a \(actual)-byte stack — " +
                         "the 512KB default is the SIGBUS class this thread exists to prevent")
            stackVerified.withLocked { $0 = true }
            while true {
                condition.lock()
                while queue.isEmpty { condition.wait() }
                let job = queue.removeFirst()
                condition.unlock()
                job()
            }
        }
        thread.name = "lattice.observer-delivery"
        thread.qualityOfService = .utility
        thread.stackSize = Self.requiredStackSize
        thread.start()
    }
}

/// Minimal locked box (avoids importing NIO into the core module for one flag).
final class NIOLockedValueBoxCompat<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLocked<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
