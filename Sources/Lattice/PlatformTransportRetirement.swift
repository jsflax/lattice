import Foundation
import LatticeSwiftCppBridge

// A configured native owner issues this receipt before adapter construction.
// Legacy clients do not construct or install a retirement helper.
internal final class PlatformTransportRetirement: @unchecked Sendable {
    private let receipt: lattice.platform_retirement_receipt
    let drain = PlatformRetirementDrain()

    init?(_ receipt: lattice.platform_retirement_receipt) {
        guard receipt.valid() else { return nil }
        self.receipt = receipt
    }

    @discardableResult
    func request(_ requested: lattice.platform_retirement_receipt) -> Bool {
        guard receipt.matches(requested), requested.retirement_requested() else { return false }
        return drain.request { [self] error in
            // Acceptance records an adapter fact only. Native custody and its
            // separate off-callback collection still gate replacement.
            _ = receipt.complete_adapter_cleanup(error)
        }
    }

    func reportAdmissionFailure(_ callbacks: PlatformTransportCallbacks) {
        guard let notification = drain.takeAdmissionFailureNotification() else { return }
        defer { withExtendedLifetime(notification) {} }
        callbacks.error("Platform transport retirement admission capacity exhausted")
    }
}

// A bounded per-adapter drain, separate from authority and native capacity.
// Uses retain the drain through actual bridge calls; pending uses retain it
// through asynchronous callback lifetimes. Neither substitutes for the actual
// platform completion passed to stop(). A missing completion remains pending.
internal final class PlatformRetirementDrain: @unchecked Sendable {
    typealias Completion = @Sendable (Int32) -> Void
    typealias Cleanup = @Sendable (@escaping Completion) -> Void
    // Independent SDK record ceilings, not an aggregate payload-byte budget or
    // an inference from a native send window. One additional fixed Use is
    // reserved for the once-only failure notification after ordinary admission
    // is exhausted; it cannot start a dial or enqueue asynchronous work.
    // Code 3 keeps the native attempt quarantined after actual cleanup. These
    // limits apply only to the new opt-in adapter; legacy adapters are unchanged.
    static let maximumUses = 128
    static let maximumPending = 4096
    static let capacityError: Int32 = 3

    private struct State {
        var stopped = false
        var claimedDial = false
        var uses = 0
        var pending = 0
        var admissionFailure: Int32?
        var admissionFailureNotified = false
        var cleanup: Cleanup?
        var cleanupStarted = false
        var cleanupReturned = false
        var platformResult: Int32?
        var requested = false
        var completion: Completion?
        var signaled = false
    }
    private let state = UnfairLock(initialState: State())

    var admissionFailure: Int32? { state.withLockUnchecked { $0.admissionFailure } }

    func takeAdmissionFailureNotification() -> Use? {
        state.withLockUnchecked { state in
            guard state.admissionFailure != nil, !state.admissionFailureNotified else { return nil }
            state.admissionFailureNotified = true
            // Once cleanup has started, only its retained error result reports
            // capacity failure. Never begin a new callback after that boundary.
            guard !state.cleanupStarted else { return nil }
            state.uses += 1
            return Use(self, notification: true)
        }
    }

    final class Use: @unchecked Sendable {
        fileprivate let owner: PlatformRetirementDrain
        fileprivate let notification: Bool
        fileprivate init(_ owner: PlatformRetirementDrain, notification: Bool = false) {
            self.owner = owner
            self.notification = notification
        }
        deinit { owner.releaseUse() }
    }

    final class Pending: @unchecked Sendable {
        private let owner: PlatformRetirementDrain
        fileprivate init(_ owner: PlatformRetirementDrain) { self.owner = owner }
        deinit { owner.releasePending() }
    }

    func admit() -> Use? {
        state.withLockUnchecked { state in
            guard !state.stopped, state.admissionFailure == nil else { return nil }
            guard state.uses < Self.maximumUses else {
                state.admissionFailure = Self.capacityError
                return nil
            }
            state.uses += 1
            return Use(self)
        }
    }

    // Protected adapters have one physical dial, even if disconnect is called.
    // A late bridge call already admitted before stop remains tracked below.
    func claimDial(_ use: Use) -> Bool {
        guard use.owner === self, !use.notification else { return false }
        return state.withLockUnchecked { state in
            guard !state.claimedDial else { return false }
            state.claimedDial = true
            return true
        }
    }

    func pending(_ use: Use) -> Pending? {
        guard use.owner === self, !use.notification else { return nil }
        return state.withLockUnchecked { state in
            guard state.admissionFailure == nil else { return nil }
            guard state.pending < Self.maximumPending else {
                state.admissionFailure = Self.capacityError
                return nil
            }
            state.pending += 1
            return Pending(self)
        }
    }

    @discardableResult
    func request(_ completion: @escaping Completion) -> Bool {
        let accepted = state.withLockUnchecked { state in
            guard !state.requested else { return false }
            state.requested = true
            state.completion = completion
            return true
        }
        progress()
        return accepted
    }

    func stop(_ cleanup: @escaping Cleanup) {
        state.withLockUnchecked { state in
            guard !state.stopped else { return }
            state.stopped = true
            state.cleanup = cleanup
        }
        progress()
    }

    private func releaseUse() {
        state.withLockUnchecked { $0.uses -= 1 }
        progress()
    }

    private func releasePending() {
        state.withLockUnchecked { $0.pending -= 1 }
        progress()
    }

    private func platformCompleted(_ error: Int32) {
        state.withLockUnchecked { state in
            guard state.platformResult == nil else { return }
            state.platformResult = error
        }
        progress()
    }

    private func progress() {
        // Move callbacks to local ownership before clearing the leaf's copy;
        // arbitrary captured owners are never destroyed under this lock.
        let cleanup: Cleanup? = state.withLockUnchecked { state in
            guard state.stopped, state.uses == 0, !state.cleanupStarted else { return nil }
            let cleanup = state.cleanup
            state.cleanup = nil
            state.cleanupStarted = true
            return cleanup
        }
        if let cleanup {
            cleanup { [self] error in platformCompleted(error) }
            state.withLockUnchecked { $0.cleanupReturned = true }
        }
        let signal: (Completion, Int32)? = state.withLockUnchecked { state in
            guard state.requested, !state.signaled, state.cleanupReturned,
                  state.uses == 0, state.pending == 0,
                  let result = state.platformResult, let completion = state.completion else { return nil }
            state.signaled = true
            state.completion = nil
            return (completion, state.admissionFailure ?? result)
        }
        if let signal { signal.0(signal.1) }
    }
}

internal protocol RetiringSystemTLSPlatformTransportClient: SystemTLSPlatformTransportClient {
    @discardableResult func requestRetirement(_ receipt: lattice.platform_retirement_receipt) -> Bool
}
