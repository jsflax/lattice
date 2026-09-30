import Foundation

// Internal, per-instance test observation only. Events are emitted at actual
// platform boundaries and cannot replace work, choose its result, or signal a
// receipt. Ordinary factories use nil and install no observer/rendezvous.
internal enum PlatformRetirementLifecycleEvent: Sendable, Equatable {
    case dnsWorkReturned
    case dnsNotifyEnqueued
    case dnsQueriesPublished
    case nioGroupShutdown(Int32)
    case appleSessionInvalidated(Int32)
    case appleInvalidationFence(Int32)
}
internal typealias PlatformRetirementLifecycleObserver = @Sendable (PlatformRetirementLifecycleEvent) -> Void
