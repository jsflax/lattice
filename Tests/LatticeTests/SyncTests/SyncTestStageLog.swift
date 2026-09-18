import Foundation

/// Bounded fixture-local facts only: no changedFields or model payloads.
final class SyncTestStageLog: @unchecked Sendable {
    private struct Event {
        let stage: String
        let uptime: UInt64
        let phase: Int
        let frame: UUID?
        let count: Int?
        let auditIDs: [UUID]
        let rowIDs: [UUID]
        let detail: String
    }
    private let lock = NSLock()
    private let maximumEvents = 512
    private let label: String
    private let store: String
    let id = UUID()
    private var events: [Event] = []
    private var dropped = 0
    private var closed = false

    init(label: String, store: String) {
        self.label = label
        self.store = store
        events.reserveCapacity(maximumEvents)
    }

    func record(_ stage: String, phase: Int = 0, frame: UUID? = nil, count: Int? = nil,
                auditIDs: [UUID] = [], rowIDs: [UUID] = [], detail: String = "") {
        let event = Event(stage: String(stage.prefix(80)), uptime: DispatchTime.now().uptimeNanoseconds,
                          phase: phase, frame: frame, count: count,
                          auditIDs: Array(auditIDs.prefix(8)), rowIDs: Array(rowIDs.prefix(8)),
                          detail: String(detail.prefix(256)))
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard events.count < maximumEvents else { dropped += 1; return }
        events.append(event)
    }

    /// Freeze once; cancellation can report the last phase even if a native
    /// call or detached task has not unwound. Output never holds this lock.
    func emit(reason: StaticString) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let snapshot = events
        let droppedCount = dropped
        let cutoff = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        print("DIAGNOSTIC SyncTestStages: fixture=\(id) label=\(label) store=\(store) reason=\(reason)"
              + " events=\(snapshot.count) dropped=\(droppedCount) cutoff_ns=\(cutoff) frozen=true late_events_unobserved=true")
        for (index, event) in snapshot.enumerated() {
            let audit = event.auditIDs.map(\.uuidString).joined(separator: ",")
            let rows = event.rowIDs.map(\.uuidString).joined(separator: ",")
            print("DIAGNOSTIC SyncTestStage: fixture=\(id) index=\(index) stage=\(event.stage)"
                  + " phase=\(event.phase) uptime_ns=\(event.uptime) frame=\(event.frame?.uuidString ?? "none")"
                  + " count=\(event.count.map { String($0) } ?? "none") audit_ids=[\(audit)] row_ids=[\(rows)] detail=\(event.detail)")
        }
    }
}
