import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Dedicated delivery thread for observer change batches (crash fix C0a,
/// Aug 2026 SIGBUS incident).
///
/// Observer delivery used to spawn one unbounded `Task.detached` per change
/// batch. Two properties of that arrangement killed the visualizer under
/// daemon sync bursts (Engram-2026-08-10-113510.ips, frame-fingerprinted):
///
/// 1. Cooperative-pool threads carry 512KB stacks. The delivery path runs
///    SQL prepares (membership re-checks, per-row hydration) beneath
///    user-supplied closure chains; Apple's libsqlite3 compiles
///    SQLITE_ENABLE_STMT_SCANSTATUS, fattening every prepare. The observed
///    crash was the stack guard page, ~6K closure-thunk frames deep, inside
///    `sqlite3WhereAddExplainText`.
/// 2. A 700K-row table syncing fans out THOUSANDS of concurrent detached
///    tasks — unbounded concurrency for work that is inherently serial per
///    observer.
///
/// One process-wide worker thread with an EXPLICIT 8MB stack replaces both:
/// jobs run FIFO, so cross-batch order is at least as strong as before, and
/// every statement the observe machinery prepares gets a deep stack. Darwin
/// secondary threads default to the same 512KB as the cooperative pool — the
/// explicit `stackSize` is the load-bearing line, and the run loop asserts it
/// took effect so a regression turns tests red.
///
/// CONTRACT (new, and the one behavioral cost of this change): an observer
/// block delivered without an `isolation` runs ON this shared worker, and
/// delivery is serialized across every Lattice in the process. A block that
/// BLOCKS — waits on a semaphore, joins a thread, or synchronously awaits
/// work that itself needs observer delivery to progress — now stalls all
/// observers instead of only its own batch. Observer blocks must return
/// promptly: do the read, hand the result to a queue/actor, return. Blocks
/// bound to an isolation are unaffected (they hop to their actor per batch).
final class ObserverDeliveryWorker: @unchecked Sendable {
    static let shared = ObserverDeliveryWorker()

    static let requiredStackSize = 8 << 20

    private let condition = NSCondition()
    private var queue: [@Sendable () -> Void] = []
    private var started = false

    enum DiagnosticKind: String, Sendable { case audit, stream, headers, collection }
    enum DiagnosticPhase: String, Sendable {
        case entered, auditHydration, userCallback, streamStateDelivery
        case headersStateDelivery, collectionResolve, collectionDecisions, actorHandoff
        case bodyReturnedBeforeNextLoop
    }
    private struct DiagnosticMetadata: Sendable {
        let kind: DiagnosticKind
        let table: String
        let storeIdentity: Int64
        let batchID: UUID?
        let enqueuedAt: UInt64
    }
    private struct DiagnosticRecord: Sendable {
        let id: UInt64
        let metadata: DiagnosticMetadata?
        let startedAt: UInt64
        var phase: DiagnosticPhase = .entered
        var phaseAt: UInt64
        var nextLoopAt: UInt64 = 0
    }
    private let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1"
    private static let pendingMetadataLimit = 64
    private static let recentLimit = 32
    private static let snapshotLimit = 5
    // Protected by condition. The dictionary is capped independently of the
    // existing unbounded closure queue. No diagnostic retains a model/handle/
    // closure. Untracked ordinals remain explicit; counters wrap at UInt64.max.
    private var pendingMetadata: [UInt64: DiagnosticMetadata] = [:]
    private var currentRecord: DiagnosticRecord?
    private var recentRecords: [DiagnosticRecord] = []
    private var enqueuedJobs: UInt64 = 0
    private var startedJobs: UInt64 = 0
    private var completedJobs: UInt64 = 0
    private var droppedMetadata: UInt64 = 0
    private var recentEvictions: UInt64 = 0
    private var peakQueuedJobs = 0
    private var emittedSnapshots = 0

    func enqueue(kind: DiagnosticKind, table: String, storeIdentity: Int64,
                 batchID: UUID?, _ job: @escaping @Sendable () -> Void) {
        // At most 64 ASCII bytes; no paths, SQL, row values or unbounded labels.
        let boundedTable = diagnosticsEnabled ? String(decoding: table.utf8.prefix(64).map {
            (($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
             ($0 >= 97 && $0 <= 122) || $0 == 95) ? $0 : UInt8(95)
        }, as: UTF8.self) : ""
        condition.lock()
        if diagnosticsEnabled {
            enqueuedJobs &+= 1
            if pendingMetadata.count < Self.pendingMetadataLimit {
                pendingMetadata[enqueuedJobs] = DiagnosticMetadata(
                    kind: kind, table: boundedTable, storeIdentity: storeIdentity,
                    batchID: batchID, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
            } else {
                droppedMetadata &+= 1
            }
        }
        queue.append(job)
        if diagnosticsEnabled { peakQueuedJobs = max(peakQueuedJobs, queue.count) }
        if !started {
            started = true
            startThread()
        }
        condition.signal()
        condition.unlock()
    }

    /// Called only from the existing worker body, never actor tasks.
    /// condition is released before native work or user callbacks.
    func diagnosticPhase(_ phase: DiagnosticPhase) {
        guard diagnosticsEnabled else { return }
        condition.lock()
        if currentRecord != nil {
            currentRecord?.phase = phase
            currentRecord?.phaseAt = DispatchTime.now().uptimeNanoseconds
        }
        condition.unlock()
    }

    // Called under condition at the NEXT loop entry. The previous record
    // stays current across capture destruction or thread descheduling at
    // the end of its scope; the phase does not prove which one occurred.
    private func diagnosticEnteredNextLoop() {
        guard diagnosticsEnabled, var record = currentRecord else { return }
        record.nextLoopAt = DispatchTime.now().uptimeNanoseconds
        if recentRecords.count == Self.recentLimit {
            recentRecords.removeFirst()
            recentEvictions &+= 1
        }
        recentRecords.append(record)
        completedJobs &+= 1
        currentRecord = nil
    }

    /// Failure callers format/print after releasing condition. At most five
    /// snapshots per process, <= 35 lines each. Pending metadata <= 64,
    /// current <= 1, recent <= 32, independently of the existing FIFO size.
    /// queued_jobs excludes current. Ages use this process's Dispatch clock.
    func diagnosticSnapshotLines(reason: StaticString) -> [String] {
        guard diagnosticsEnabled else { return [] }
        condition.lock()
        guard emittedSnapshots < Self.snapshotLimit else { condition.unlock(); return [] }
        emittedSnapshots += 1
        let snapshotNumber = emittedSnapshots
        let now = DispatchTime.now().uptimeNanoseconds
        let current = currentRecord
        let oldestID = queue.isEmpty ? nil : Optional(startedJobs &+ 1)
        let oldest = oldestID.map {
            DiagnosticRecord(id: $0, metadata: pendingMetadata[$0], startedAt: 0, phaseAt: 0)
        }
        let queued = queue.count
        let trackedPending = pendingMetadata.count
        let peak = peakQueuedJobs
        let enqueued = enqueuedJobs
        let started = startedJobs
        let completed = completedJobs
        let dropped = droppedMetadata
        let evictions = recentEvictions
        let recent = recentRecords
        condition.unlock()

        func age(_ timestamp: UInt64) -> UInt64 { now >= timestamp ? now - timestamp : 0 }
        func line(_ record: DiagnosticRecord, state: String) -> String {
            let metadata = record.metadata
            let queuedAge = metadata.map { String(age($0.enqueuedAt)) } ?? "unknown"
            let stop = record.nextLoopAt == 0 ? now : record.nextLoopAt
            let run = record.startedAt == 0 || stop < record.startedAt ? 0 : stop - record.startedAt
            return "DIAGNOSTIC ObserverWorkerJob: snapshot=\(snapshotNumber) state=\(state)"
                + " id=\(record.id) metadata=\(metadata == nil ? "missing" : "present")"
                + " kind=\(metadata?.kind.rawValue ?? "unknown") table=\(metadata?.table ?? "unknown")"
                + " store_identity=\(metadata.map { String($0.storeIdentity) } ?? "unknown")"
                + " batch=\(metadata?.batchID?.uuidString.lowercased() ?? "unknown")"
                + " enqueued_ns=\(metadata.map { String($0.enqueuedAt) } ?? "unknown")"
                + " started_ns=\(record.startedAt) phase=\(record.startedAt == 0 ? "queued" : record.phase.rawValue)"
                + " phase_ns=\(record.phaseAt) next_loop_ns=\(record.nextLoopAt)"
                + " enqueued_age_ns=\(queuedAge) run_ns=\(run)"
                + " phase_age_ns=\(record.phaseAt == 0 ? 0 : age(record.phaseAt))"
        }
        var lines = ["DIAGNOSTIC ObserverWorkerSnapshot: reason=\(reason) snapshot=\(snapshotNumber)"
            + " uptime_ns=\(now) queued_jobs=\(queued) tracked_pending=\(trackedPending) peak_queued_jobs=\(peak)"
            + " enqueued=\(enqueued) started=\(started) completed=\(completed)"
            + " dropped_metadata=\(dropped) recent_evictions=\(evictions)"
            + " current_id=\(current.map { String($0.id) } ?? "none")"
            + " pending_metadata_limit=\(Self.pendingMetadataLimit)"
            + " recent_limit=\(Self.recentLimit) snapshot_limit=\(Self.snapshotLimit)"
            + " clock=dispatch_uptime same_process=true overhead_subtracted=false"]
        if let current { lines.append(line(current, state: "current")) }
        if let oldest { lines.append(line(oldest, state: "oldest_queued")) }
        lines.append(contentsOf: recent.map { line($0, state: "recent") })
        return lines
    }

    /// Test hook: true once the worker thread verified its enlarged stack.
    private let stackVerified = NIOLockedValueBoxCompat<Bool>(false)
    var isStackVerified: Bool { stackVerified.withLocked { $0 } }

    private func startThread() {
        let thread = Thread { [self] in
            // Stack-size verification is Darwin-only on purpose:
            // pthread_get_stacksize_np does not exist in Glibc, and Darwin is
            // where the SIGBUS this thread exists to prevent actually happened
            // (512KB cooperative-pool stacks + Apple's scanstatus-fattened
            // prepares). Foundation honors `stackSize` on both platforms; only
            // the assertion is platform-gated, never the sizing itself.
            #if canImport(Darwin)
            let actual = pthread_get_stacksize_np(pthread_self())
            precondition(actual >= Self.requiredStackSize,
                         "observer delivery worker got a \(actual)-byte stack — " +
                         "the 512KB default is the SIGBUS class this thread exists to prevent")
            #endif
            stackVerified.withLocked { $0 = true }
            while true {
                condition.lock()
                diagnosticEnteredNextLoop()
                while queue.isEmpty { condition.wait() }
                let job = queue.removeFirst()
                if diagnosticsEnabled {
                    startedJobs &+= 1
                    let now = DispatchTime.now().uptimeNanoseconds
                    currentRecord = DiagnosticRecord(
                        id: startedJobs, metadata: pendingMetadata.removeValue(forKey: startedJobs),
                        startedAt: now, phaseAt: now)
                }
                condition.unlock()
                if diagnosticsEnabled {
                    // Ensure this closure reference survives through the
                    // marker even when optimized ARC ends other uses early.
                    withExtendedLifetime(job) {
                        job()
                        diagnosticPhase(.bodyReturnedBeforeNextLoop)
                    }
                } else {
                    job()
                }
            }
        }
        thread.name = "lattice.observer-delivery"
        // QualityOfService is a Darwin scheduling concept; swift-corelibs-
        // foundation does not surface it on Thread.
        #if canImport(Darwin)
        thread.qualityOfService = .utility
        #endif
        thread.stackSize = Self.requiredStackSize
        thread.start()
    }
}

/// Minimal locked box (avoids importing NIO into the core module for one flag).
final class NIOLockedValueBoxCompat<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLocked<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

// Internal, per-observer diagnostics for selected tests. Public entry points
// pass nil. No process-global hook, new task or worker scheduling is involved.
struct PayloadObserverDiagnosticEvent: Sendable {
    let observer: String
    let batch: UUID?
    let stage: String
    let uptime: UInt64
    let rowIDs: [Int64]
    let operations: [String]
    let omittedRows: Int
    let count: Int?
}

struct PayloadObserverDiagnostic: Sendable {
    let observer: String
    let capture: @Sendable (PayloadObserverDiagnosticEvent) -> Void

    func record(_ stage: String, batch: UUID? = nil, count: Int? = nil) {
        capture(.init(observer: observer, batch: batch, stage: stage,
                      uptime: DispatchTime.now().uptimeNanoseconds,
                      rowIDs: [], operations: [], omittedRows: 0, count: count))
    }

    func begin(_ changes: [TableChangeEvent]) -> PayloadObserverDiagnosticBatch {
        let uptime = DispatchTime.now().uptimeNanoseconds
        let batch = UUID()
        let retainIDs = changes.count <= 1024
        capture(.init(observer: observer, batch: batch, stage: "callback_entry",
                      uptime: uptime,
                      rowIDs: retainIDs ? changes.map { $0.rowId } : [],
                      operations: retainIDs ? changes.map { $0.operation } : [],
                      omittedRows: retainIDs ? 0 : changes.count, count: changes.count))
        return .init(diagnostic: self, id: batch)
    }
}

struct PayloadObserverDiagnosticBatch: Sendable {
    let diagnostic: PayloadObserverDiagnostic
    let id: UUID

    func record(_ stage: String, count: Int? = nil) {
        diagnostic.record(stage, batch: id, count: count)
    }
}
