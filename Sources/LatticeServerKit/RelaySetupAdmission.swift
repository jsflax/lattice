import Foundation
import NIOConcurrencyHelpers

/// Pure bookkeeping for one automatic, pre-effect capture episode. Nanoseconds
/// are in the SDK's Dispatch uptime domain only; no epoch crosses into Core.
struct RelaySetupAdmissionBudget: Sendable {
    static let maximumAttempts = 32
    static let retryNanoseconds: UInt64 = 100_000_000
    static let durationNanoseconds: UInt64 = 5_000_000_000
    let startedAt: UInt64
    let deadline: UInt64
    private(set) var attempts = 0
    private(set) var inFlight = false
    private(set) var nextEligible: UInt64
    private(set) var cancelled = false
    private(set) var completed = false

    init(now: UInt64) {
        startedAt = now; nextEligible = now
        let sum = now.addingReportingOverflow(Self.durationNanoseconds)
        deadline = sum.overflow ? UInt64.max : sum.partialValue
    }
    func admissible(now: UInt64) -> Bool {
        !cancelled && !completed && now >= startedAt && now < deadline
    }
    mutating func beginAttempt(now: UInt64) -> Bool {
        guard admissible(now: now), !inFlight, attempts < Self.maximumAttempts, now >= nextEligible else { return false }
        attempts += 1; inFlight = true; return true
    }
    mutating func busyReturned(now: UInt64) -> UInt64? {
        guard inFlight else { return nil }
        inFlight = false
        guard admissible(now: now), attempts > 0, attempts < Self.maximumAttempts else { return nil }
        let sum = now.addingReportingOverflow(Self.retryNanoseconds)
        nextEligible = min(sum.overflow ? UInt64.max : sum.partialValue, deadline)
        return nextEligible
    }
    mutating func cancel() { cancelled = true }
    mutating func complete() { completed = true; inFlight = false }
}

/// Deadline/cancellation facts only: never captures a store, socket, work token,
/// route authority or setup owner. Core may synchronously consult it off locks.
final class RelaySetupAdmission: @unchecked Sendable {
    private struct State { var cancelled = false; var budget: RelaySetupAdmissionBudget? }
    private let state = NIOLockedValueBox(State())
    func start() {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLockedValue { s in
            precondition(s.budget == nil)
            var budget = RelaySetupAdmissionBudget(now: now)
            if s.cancelled { budget.cancel() }
            s.budget = budget
        }
    }
    var snapshot: RelaySetupAdmissionBudget? { state.withLockedValue { $0.budget } }
    var isCancelled: Bool { state.withLockedValue { $0.cancelled } }
    func admissible() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return state.withLockedValue { !$0.cancelled && $0.budget?.admissible(now: now) == true }
    }
    func beginAttempt() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return state.withLockedValue { s in
            guard !s.cancelled else { return false }
            return s.budget?.beginAttempt(now: now) == true
        }
    }
    func busyReturned() -> UInt64? {
        let now = DispatchTime.now().uptimeNanoseconds
        return state.withLockedValue { s in
            guard !s.cancelled else { return nil }
            return s.budget?.busyReturned(now: now)
        }
    }
    func cancel() { state.withLockedValue { $0.cancelled = true; $0.budget?.cancel() } }
    func complete() { state.withLockedValue { $0.budget?.complete() } }
}

/// One armed one-shot per waiting episode. Fire and explicit cancel both wait
/// for the real GCD cancellation handler before notifying control. Captures
/// (including the mount work charge) remain owned through that actual callback.
/// This queue never performs native work or waits for another executor.
final class RelaySetupAdmissionTimer: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "lattice.relay.setup-admission")
    private let source: DispatchSourceTimer
    init(deadline: UInt64, drained: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: Self.queue)
        source.setEventHandler { [weak self] in self?.cancel() }
        source.setCancelHandler(handler: drained)
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
        source.activate()
    }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

/// Exact-route scalar observations only. No callback can replace the native
/// attempt result or change the policy/clock. The mount hook is absent by default.
struct RelaySetupAdmissionObservation: Sendable {
    enum Stage: Sendable { case stopCallbackReturning, ownerOpened, attemptQueued, attemptEntered, busy, waiting, timerDrained, admitted, failed, ownerReleased }
    let observedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
    let connectionID: UUID
    let stage: Stage
    let owner: ObjectIdentifier?
    let budget: RelaySetupAdmissionBudget?
    let onIO: Bool
}
