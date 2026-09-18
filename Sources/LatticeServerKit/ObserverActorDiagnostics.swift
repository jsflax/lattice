import Foundation
import Dispatch

/// Opt-in, process-wide observation of FileWatchManager's synchronous actor
/// chunks. No paths, native handles, closures, models or subscriber payloads.
/// Intervals include descheduling and diagnostic overhead: they do not measure
/// CPU time or prove a native lock owner. Unrecorded/evicted time is UNKNOWN.
final class ObserverActorDiagnostics: @unchecked Sendable {
    static let shared = ObserverActorDiagnostics(enabled:
        ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1")

    enum Operation: String, Sendable {
        case hasGroup, subscriberCount, watcherOpenCount
        case subscribeCanonicalization, subscribePublish, resolveGroupSetup, resolveGroupReturn
        case installGroup, activate, unsubscribe, nudge, beginPass, advance, finishPass, clearPumping
    }
    enum Phase: String, Sendable {
        case actorBody, canonicalization, observerRegistration, observerRemoval
        case tokenRelease, reconcileCancellation, reconcileRelease, watcherReleaseHandoff
    }
    enum Reason: String, Sendable { case warmupTimeout, incompleteIteration, p95Gate, thrownFailure }
    struct Scope: Sendable { fileprivate let id: UInt64 }
    private struct Record: Sendable {
        let id: UInt64
        let scope: UInt64
        var group: UInt64?
        let operation: Operation
        let phase: Phase
        let entered: UInt64
        var exited: UInt64?
        var duration: UInt64 { (exited ?? entered) >= entered ? (exited ?? entered) - entered : 0 }
    }

    private let enabled: Bool
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var nextGroup: UInt64 = 0
    private var current: Record?
    private var recent: [Record] = []
    private var longest: [Record] = []
    private var completed: UInt64 = 0
    private var recentEvictions: UInt64 = 0
    private var longestNotRetained: UInt64 = 0
    private var overlappingScopes: UInt64 = 0
    private var identifierExhausted = false
    private var snapshots = 0
    private static let recentLimit = 32
    private static let longestLimit = 32
    private static let snapshotLimit = 3

    // Internal constructor also permits deterministic, native-free recorder
    // tests. Explicit timestamps are test inputs, never wall-clock dates.
    init(enabled: Bool) { self.enabled = enabled }

    func groupID() -> UInt64? {
        guard enabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard nextGroup < UInt64.max else { identifierExhausted = true; return nil }
        nextGroup += 1
        return nextGroup
    }

    func begin(_ operation: Operation, group: UInt64? = nil, at timestamp: UInt64? = nil) -> Scope? {
        guard enabled else { return nil }
        let now = timestamp ?? DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        // Scopes must not cross await or nest. A second manager instance or an
        // instrumentation mistake remains explicit; never overwrite its owner.
        guard current == nil else { overlappingScopes &+= 1; return nil }
        guard nextID < UInt64.max else { identifierExhausted = true; return nil }
        nextID += 1
        current = Record(id: nextID, scope: nextID, group: group, operation: operation,
                         phase: .actorBody, entered: now)
        return Scope(id: nextID)
    }

    func phase(_ scope: Scope?, _ phase: Phase, group: UInt64? = nil, at timestamp: UInt64? = nil) {
        guard enabled, let scope else { return }
        let now = timestamp ?? DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard var previous = current, previous.scope == scope.id else { return }
        previous.exited = now
        retainCompleted(previous)
        guard nextID < UInt64.max else {
            identifierExhausted = true
            current = nil
            return
        }
        nextID += 1
        current = Record(id: nextID, scope: scope.id, group: group ?? previous.group,
                         operation: previous.operation, phase: phase, entered: now)
    }

    func end(_ scope: Scope?, at timestamp: UInt64? = nil) {
        guard enabled, let scope else { return }
        let now = timestamp ?? DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard var record = current, record.scope == scope.id else { return }
        record.exited = now
        retainCompleted(record)
        current = nil
    }

    // Only fixed-size scalar records and at most 33-element sorting under lock.
    // No native/user callout, filesystem access, formatting, logging or await.
    private func retainCompleted(_ record: Record) {
        completed &+= 1
        if recent.count == Self.recentLimit {
            recent.removeFirst()
            recentEvictions &+= 1
        }
        recent.append(record)
        longest.append(record)
        longest.sort {
            $0.duration == $1.duration ? $0.id > $1.id : $0.duration > $1.duration
        }
        if longest.count > Self.longestLimit {
            longest.removeLast()
            longestNotRetained &+= 1
        }
    }

    /// Synchronous/nonisolated access; callers never need to enter the possibly
    /// stalled actor. <= 66 lines/snapshot, <= 3 snapshots/process. Formatting
    /// occurs after unlock. Recent+longest union has <= 64 rows, current <= 1.
    /// A marker's return does NOT acknowledge implicit ARC/native cleanup.
    func snapshotLines(reason: Reason, at timestamp: UInt64? = nil) -> [String] {
        guard enabled else { return [] }
        lock.lock()
        guard snapshots < Self.snapshotLimit else { lock.unlock(); return [] }
        snapshots += 1
        let number = snapshots
        let now = timestamp ?? DispatchTime.now().uptimeNanoseconds
        let active = current
        let recentCopy = recent
        let longestCopy = longest
        let completedCopy = completed
        let evictions = recentEvictions
        let notRetained = longestNotRetained
        let overlaps = overlappingScopes
        let exhausted = identifierExhausted
        lock.unlock()

        var records = recentCopy
        let recentIDs = Set(recentCopy.map(\.id))
        records.append(contentsOf: longestCopy.filter { !recentIDs.contains($0.id) })
        records.sort { $0.id < $1.id }
        func line(_ record: Record, state: String) -> String {
            let stop = record.exited ?? now
            let elapsed = stop >= record.entered ? stop - record.entered : 0
            return "DIAGNOSTIC ObserverActorPhase: snapshot=\(number) state=\(state)"
                + " record=\(record.id) scope=\(record.scope) group=\(record.group.map(String.init) ?? "unknown")"
                + " operation=\(record.operation.rawValue) phase=\(record.phase.rawValue)"
                + " entered_ns=\(record.entered) exited_ns=\(record.exited.map(String.init) ?? "unknown")"
                + " elapsed_ns=\(elapsed) phase_age_ns=\(record.exited == nil ? String(elapsed) : "not_current")"
        }
        var lines = ["DIAGNOSTIC ObserverActorSnapshot: reason=\(reason.rawValue) snapshot=\(number)"
            + " uptime_ns=\(now) completed_phases=\(completedCopy) recent_evictions=\(evictions)"
            + " longest_not_retained=\(notRetained) overlapping_scopes=\(overlaps) identifier_exhausted=\(exhausted)"
            + " current_scope=\(active.map { String($0.scope) } ?? "none")"
            + " recent_limit=32 longest_limit=32 snapshot_limit=3 maximum_lines=66"
            + " clock=dispatch_uptime same_process=true overhead_subtracted=false"
            + " missing_intervals=unknown outside_scope=unknown native_cleanup_ack=false"]
        if let active { lines.append(line(active, state: "current")) }
        lines.append(contentsOf: records.map { line($0, state: "completed") })
        return lines
    }
}
