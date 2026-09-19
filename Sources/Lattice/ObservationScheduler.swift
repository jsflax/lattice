import Foundation

/// Explicit resources for latest-state projected observations. Share one
/// instance across streams that should share the same admission/fairness caps.
/// Streams retain it; there is no public shutdown that could strand a parked
/// iterator. Cancel the iterators to drain their work.
/// Worker count bounds delivery bodies; maxSubscriptions also bounds held
/// asynchronous snapshot turns. Projected SQL uses its separate read executor.
///
/// Fairness uses the receiving backend's identity. Distinct configurations,
/// handles, and attachment aliases are not promised process-wide fairness for
/// the same physical file. With one worker, a blocked body blocks all delivery.
public final class ObservationScheduler: @unchecked Sendable {
    let turns: ObservationTurnScheduler
    private let lock = NSLock()
    private var registrationFailure: (any Error)?

    public init(workerCount: Int, maxSubscriptions: Int) throws {
        guard (1...ObservationTurnScheduler.maximumWorkerCount).contains(workerCount),
              maxSubscriptions > 0 else {
            throw ProjectionReadError.invalidRequest("observation scheduler needs 1...8 workers and positive maxSubscriptions")
        }
        turns = ObservationTurnScheduler(workerCount: workerCount, maxSubscriptions: maxSubscriptions)
    }

    /// Current scheduler work and monotonic ages, plus the last settled turn.
    /// Samples fixed metadata in O(current subscriptions), bounded by this
    /// scheduler's registration cap. No user callback or query runs here.
    public var diagnostics: ObservationSchedulerDiagnostics { turns.diagnostics }

    func register(storeID: UInt64, delivery: @escaping ObservationTurnScheduler.Delivery)
        throws -> ObservationTurnScheduler.Subscription {
        lock.lock()
        defer { lock.unlock() }
        if let registrationFailure { throw registrationFailure }
        do { return try turns.register(storeID: storeID, delivery: delivery) }
        catch ObservationTurnSchedulerError.capacityExceeded { throw ProjectionReadError.resourceBusy }
        catch { throw ProjectionReadError.executorStopped }
    }

    /// Called BEFORE releasing a subscription whose native hook could not be
    /// removed. Existing streams can drain, but failed native hooks cannot
    /// accumulate through cancel/free-capacity/register cycles on this owner.
    func rejectFutureRegistrations(after error: any Error) {
        lock.lock()
        if registrationFailure == nil { registrationFailure = error }
        lock.unlock()
    }
}
