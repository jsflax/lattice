import Foundation
import Dispatch
import LatticeSwiftCppBridge

/// The C++ value owns one shared atomic flag. Swift may copy the value, but all
/// copies cancel the same attempt; a successor always receives a fresh value.
private final class NativeSyncCancellation: @unchecked Sendable {
    let value = lattice.swift_sync_cancellation()
}

extension CxxBackend: BackgroundSyncBackend {
    func closeBackgroundSyncMember() { Lattice._closeBackgroundMember(backend: self) }

    func performBackgroundSync(
        _ command: BackgroundTaskCommand,
        cancellation: SyncWorkCancellation
    ) throws -> Lattice.SyncOnceResult {
        if case .suspend = command {
            retireBackgroundReadGenerations()
            let generation = ref.current_background_sync_generation()
            try checkBackgroundSyncBridgeError()
            guard generation != 0 else { return .completed }
            let settled = ref.suspend_background_sync(generation)
            try checkBackgroundSyncBridgeError()
            guard settled else {
                throw Lattice.Error.databaseError("Background sync suspension did not confirm settlement of its generation.")
            }
            return .completed
        }

        let nativeCancellation = NativeSyncCancellation()
        let budgetCancellation = SyncWorkCancellation()
        budgetCancellation.install { nativeCancellation.value.cancel() }
        cancellation.install { nativeCancellation.value.cancel() }
        if cancellation.isCancelled { throw CancellationError() }
        let duration: TimeInterval?
        switch command {
        case let .refresh(seconds): duration = seconds
        case .resume: duration = nil
        case .suspend: preconditionFailure("Suspension was handled above")
        }

        // Start the budget before connection setup. The timer only requests
        // cancellation; this function still waits for complete native cleanup.
        let deadline = duration.map { seconds -> DispatchTime in
            let nanoseconds = seconds * 1_000_000_000
            return nanoseconds < Double(Int64.max / 2)
                ? .now() + .nanoseconds(Int(nanoseconds)) : .distantFuture
        }
        let deadlineTimer: DispatchSourceTimer?
        if let deadline {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: deadline)
            timer.setEventHandler { budgetCancellation.cancel() }
            timer.resume()
            deadlineTimer = timer
        } else {
            deadlineTimer = nil
        }
        defer { deadlineTimer?.cancel() }

        let start = ref.resume_background_sync(nativeCancellation.value, duration != nil)
        try checkBackgroundSyncBridgeError()
        if duration != nil && start.generation != 0 && ref.is_background_sync_managed() {
            retireBackgroundReadGenerations()
        }
        switch start.admission {
        case .started: break
        case .already_running:
            if case .resume = command { try resumeReadGenerationsAfterSyncConnect() }
            return .alreadyRunning
        case .cancelled:
            if cancellation.isCancelled { throw CancellationError() }
            return .budgetExhausted
        case .not_owner, .closed: return .unavailable
        case .unsupported:
            throw Lattice.Error.databaseError("Finite background sync requires a writable file store, a WSS endpoint and nonempty token, and no unmanaged IPC targets.")
        default:
            throw Lattice.Error.databaseError("Unknown native background sync admission result.")
        }

        var needsSettlement = duration != nil
        defer {
            // A bridge/status failure still releases this attempt. The Core
            // generation check prevents this cleanup from touching a successor.
            if needsSettlement { _ = ref.suspend_background_sync(start.generation) }
        }
        guard duration != nil else {
            if nativeCancellation.value.is_cancelled() || !cancellation.disarmIfNotCancelled() {
                needsSettlement = true
                throw CancellationError()
            }
            GenerationCoordinatorRegistry.existingCoordinator(identityHash: identityHash)?.resumeGenerations()
            return .completed
        }

        var outcome: Lattice.SyncOnceResult = .budgetExhausted
        while true {
            // Dispatch delivery may be delayed. The monotonic clock defines
            // expiration; the timer additionally interrupts blocking setup.
            if let deadline, DispatchTime.now() >= deadline { budgetCancellation.cancel() }
            if nativeCancellation.value.is_cancelled() {
                _ = ref.cancel_background_sync(start.generation)
                try checkBackgroundSyncBridgeError()
                break
            }
            let status = ref.get_background_sync_status(start.generation)
            try checkBackgroundSyncBridgeError()
            switch status.phase {
            case .running:
                Thread.sleep(forTimeInterval: 0.02)
                continue
            case .work_complete:
                outcome = .completed
            case .cancelled:
                outcome = .budgetExhausted
            case .inactive:
                outcome = .unavailable
            case .failed:
                throw Lattice.Error.databaseError("The finite sync attempt failed before confirming its upload and replay work.")
            default:
                throw Lattice.Error.databaseError("Unknown native finite sync state.")
            }
            break
        }

        let settled = ref.suspend_background_sync(start.generation)
        try checkBackgroundSyncBridgeError()
        needsSettlement = false
        guard settled else { return .unavailable }
        if cancellation.isCancelled { throw CancellationError() }
        // Expiration can win while a completed work receipt is settling.
        if budgetCancellation.isCancelled || deadline.map({ DispatchTime.now() >= $0 }) == true {
            return .budgetExhausted
        }
        return outcome
    }

    private func checkBackgroundSyncBridgeError() throws {
        if let message = lastQueryError() { throw Lattice.Error.databaseError(message) }
    }

    /// A sibling may own WSS while this foreground handle owns only local
    /// observation/read maintenance. Both allow normal read generations.
    func resumeReadGenerationsAfterSyncConnect() throws {
        let generation = ref.current_background_sync_generation()
        try checkBackgroundSyncBridgeError()
        if generation != 0 || isSyncAgent() {
            GenerationCoordinatorRegistry.existingCoordinator(identityHash: identityHash)?.resumeGenerations()
        }
    }

    private func retireBackgroundReadGenerations() {
        GenerationCoordinatorRegistry.existingCoordinator(identityHash: identityHash)?.retireAllGenerations()
        retireAllReadGenerations()
    }
}
