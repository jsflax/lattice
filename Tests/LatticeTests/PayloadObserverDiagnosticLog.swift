import Foundation
#if canImport(Combine)
import Combine
#endif
@testable import Lattice

// Test-local and bounded. Row identities/operations only; never model payloads.
final class PayloadObserverDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private let maximumEvents = 2048
    private var events: [PayloadObserverDiagnosticEvent] = []
    private var dropped = 0
    private var closed = false

    init(_ label: String) {
        self.label = label
        events.reserveCapacity(maximumEvents)
    }

    func diagnostic(_ observer: String) -> PayloadObserverDiagnostic {
        .init(observer: observer, capture: { [self] event in record(event) })
    }

    func observeCollection<T: Model>(_ modelType: T.Type, on lattice: Lattice,
                                     block: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        lattice._observeCollection(modelType, diagnostic: diagnostic("collection"), block: block)
    }

    private func record(_ event: PayloadObserverDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard events.count < maximumEvents else { dropped += 1; return }
        events.append(event)
    }

    // Selected synchronous MainActor fixture scopes only. Fixed call-site
    // labels and scalar timestamps; this is not exhaustive actor occupancy.
    private static let mainActorPhaseDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1"

    static func beginMainActorPhase(_ site: StaticString) -> UInt64? {
        guard mainActorPhaseDiagnosticsEnabled else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        print("DIAGNOSTIC MainActorSyncPhase: site=\(site) event=begin"
              + " pid=\(ProcessInfo.processInfo.processIdentifier) started_ns=\(started) uptime_ns=\(started)")
        return started
    }

    static func endMainActorPhase(_ site: StaticString, started: UInt64?) {
        guard let started else { return }
        let ended = DispatchTime.now().uptimeNanoseconds
        print("DIAGNOSTIC MainActorSyncPhase: site=\(site) event=end"
              + " pid=\(ProcessInfo.processInfo.processIdentifier) started_ns=\(started) uptime_ns=\(ended)"
              + " elapsed_ns=\(ended &- started)")
    }

    static func emitWorkerSnapshot(reason: StaticString) {
        for line in ObserverDeliveryWorker.shared.diagnosticSnapshotLines(reason: reason) {
            print(line)
        }
    }

    func emit() {
        lock.lock()
        closed = true
        let snapshot = events
        let droppedEvents = dropped
        lock.unlock()
        Self.emitCaptured(snapshot, label: label, dropped: droppedEvents, captureClosed: true)
    }

    // Also formats an already-captured routing snapshot on failure. Keep
    // output bounded even if a regression produced far more than 25 events.
    static func emitCaptured(_ events: [PayloadObserverDiagnosticEvent], label: String,
                             dropped: Int = 0, captureClosed: Bool = false) {
        let maximumEvents = 2048
        let snapshot = events.prefix(maximumEvents)
        let droppedEvents = dropped + max(0, events.count - maximumEvents)
        // Formatting/output are deferred until the existing test unwinds.
        // Closure does not wait for cancellation/termination or late callbacks.
        print("DIAGNOSTIC PayloadObserverCapture: test=\(label) events=\(snapshot.count)"
              + " dropped_events=\(droppedEvents) max_events=\(maximumEvents) max_batch_ids=1024"
              + " clock=dispatch_uptime capture_closed=\(captureClosed) snapshot_frozen=true late_events_unobserved=true")
        for (index, event) in snapshot.enumerated() {
            let batch = event.batch?.uuidString.lowercased() ?? "none"
            let ids = event.rowIDs.map { String($0) }.joined(separator: ",")
            let operations = event.operations.joined(separator: ",")
            let count = event.count.map { String($0) } ?? "none"
            print("DIAGNOSTIC PayloadObserverEvent: test=\(label) index=\(index) observer=\(event.observer)"
                  + " batch=\(batch) stage=\(event.stage) uptime_ns=\(event.uptime) count=\(count)"
                  + " omitted_rows=\(event.omittedRows) row_ids=[\(ids)] operations=[\(operations)]")
        }
    }
}
