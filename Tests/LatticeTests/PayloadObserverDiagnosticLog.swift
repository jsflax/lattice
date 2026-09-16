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

    func emit() {
        lock.lock()
        closed = true
        let snapshot = events
        let droppedEvents = dropped
        lock.unlock()
        // Formatting/output are deferred until the existing test unwinds.
        // Closure does not wait for cancellation/termination or late callbacks.
        print("DIAGNOSTIC PayloadObserverCapture: test=\(label) events=\(snapshot.count)"
              + " dropped_events=\(droppedEvents) max_events=\(maximumEvents) max_batch_ids=1024"
              + " clock=dispatch_uptime capture_closed=true late_events_unobserved=true")
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
