import Foundation

/// A process-local snapshot of the latest-state scheduler, sampled under its
/// state lock. It contains fixed metadata, never queued payloads or database
/// values. Reading it does not run a query or create asynchronous work.
/// Only the last completed turn is retained; there is no event history or
/// cumulative counter collection.
///
/// Pending, ready and admitted counts overlap: a notification received during
/// an admitted turn makes that subscription pending again. A ready subscription
/// can be parked behind another admitted turn from its store. Dirty latest-state
/// streams without demand are not necessarily notified to this scheduler.
///
/// All durations use a monotonic clock. These are scheduler boundaries, not
/// commit latency, continuation resumption or execution of the async consumer.
/// Boundaries are recorded under the state lock; notification timing starts
/// when the scheduler accepts it, excluding the caller's wait to enter that lock.
public struct ObservationSchedulerDiagnostics: Sendable, Equatable {
    public let workerCount: Int
    public let maxSubscriptions: Int
    /// Includes cancelled subscriptions whose admitted turn is still draining.
    public let subscriptions: Int
    public let pendingSubscriptions: Int
    public let readySubscriptions: Int
    public let pendingWhileAdmitted: Int
    public let admittedTurns: Int
    public let bodiesRunning: Int
    /// Bodies that returned while their completion token remains unacknowledged.
    public let awaitingAcknowledgement: Int

    /// Ages are nil when there is no matching work. Coalescing notifications
    /// does not reset the first pending timestamp.
    public let oldestPendingAgeNanoseconds: UInt64?
    public let oldestReadyAgeNanoseconds: UInt64?
    public let oldestAdmittedAgeNanoseconds: UInt64?
    /// Measured from body return, not admission.
    public let oldestAwaitingAcknowledgementAgeNanoseconds: UInt64?

    /// Most recently settled turn under the state lock. Settlement requires
    /// both body return and acknowledgement; it does not imply successful
    /// snapshot publication. Cancelled admitted turns also settle normally.
    public let lastCompletedTurn: CompletedTurn?

    public struct CompletedTurn: Sendable, Equatable {
        public let subscriptionID: UUID
        public let turnID: UUID
        /// Starts at the first notification in this turn's coalesced window.
        public let notificationToAdmissionNanoseconds: UInt64
        public let notificationToCompletionNanoseconds: UInt64
        public let admittedToBodyReturnNanoseconds: UInt64
        /// Can be shorter than body return when a token is acknowledged early.
        public let admittedToAcknowledgementNanoseconds: UInt64
        public let admittedToCompletionNanoseconds: UInt64
    }
}
