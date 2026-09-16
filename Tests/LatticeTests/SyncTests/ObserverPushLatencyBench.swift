import Foundation
import Testing
import Vapor
import Lattice
@testable import LatticeServerKit

// ============================================================================
// Observer-push latency bench: co-process write → watch-socket frame arrival
// over loopback, against the REAL push-enabled `configureSyncRelay` mount.
//
// This is the number that replaces the app-level redial: the pre-1.7 web
// observer polls every 5s and measured a 4.63s p95 write→visibility gap in
// prod. Push targets p95 < 250ms. Reconcile is DISABLED so the measurement
// is the push path (commit observer → nudge → pump → awaited send), not the
// safety-net tick.
//
//   BENCH ObserverPushLatency: n=<N> p50_ms=<X> p95_ms=<Y> p99_ms=<Z>
//
// N defaults to 30 iterations; LATTICE_BENCH_FULL=1 raises it to 200.
//
// GATE POLICY. The 250ms design target is RECORDED, not enforced. This bench
// shares the machine with the whole parallel `swift test` run, where the
// measured p95 ranged 5.4–95.9ms with excursions to ~96ms on a loaded
// laptop — a hard 250ms gate with that little headroom is a CI flake
// generator, not a regression detector. The assertion is therefore a
// generous soft gate (`softGateMs` = 1000ms): ~10× the worst p95 measured
// under full-suite parallel load (95.9ms) and still ~4.6× under the redial
// p95 it replaces, so a real regression — push degrading to tick or redial
// latency — fails while scheduling noise does not. A CI leg that runs
// benches alongside a parallel load should set LATTICE_BENCH_PARALLEL_LOAD=1,
// which records the numbers and skips the gate entirely.
// ============================================================================

@Suite("ObserverPushLatencyBench", .timeLimit(.minutes(5)))
final class ObserverPushLatencyBench: BaseTest {
    /// The design goal — recorded on every run, never asserted.
    private let designTargetMs = 250.0
    /// The asserted bound. Generous on purpose (see GATE POLICY above).
    private let softGateMs = 1000.0

    @Test func coProcessWriteToWatchSocketLatency() async throws {
        let n = ProcessInfo.processInfo.environment["LATTICE_BENCH_FULL"] == "1" ? 200 : 30

        let sendLog = PushLatencySendLog()
        let pipelineLog = PushLatencyPipelineLog()
        let pipeline = ObserverSendBoundaryProbe.Pipeline { event, uptime in
            pipelineLog.record(event: event, uptime: uptime)
        }
        let probe = ObserverSendBoundaryProbe(channelID: "group-bench", pipeline: pipeline) { route, ids, uptime in
            sendLog.record(route: route, ids: ids, uptime: uptime)
        }
        let push = SyncObserverPush(
            copying: SyncObserverPush(reconcileInterval: nil), sendBoundaryProbe: probe)
        try await withPushHarness(push: push) { harness in
            var sendSamples: [PushLatencySendSample] = []
            sendSamples.reserveCapacity(n)
            // Runs after measurement ends, including an incomplete/throwing run.
            defer {
                // Close the pipeline capture before either recorder formats.
                // No waiting for callbacks/pumps that outlive this snapshot.
                let pipelineSnapshot = pipelineLog.close()
                sendLog.emit(samples: sendSamples)
                pipelineLog.emit(pipelineSnapshot)
            }
            let watcher = try await harness.connect(pathSuffix: "watch/group/bench", user: UUID())
            let co = try harness.coWriter("bench")

            // Keep the existing first-frame warmup. That frame can arrive via
            // catch-up: it is NOT an activation barrier. The pipeline trace
            // separately records the actual activate(cursor:) call.
            try co.add(SimpleSyncObject(value: -1, floatValue: 0))
            let warmed = await watcher.wait(timeout: 30) { $0.receivedGlobalIds.count >= 1 }
            try #require(warmed, "warmup commit never reached the watch socket")

            var samples: [Double] = []
            samples.reserveCapacity(n)
            // Diagnostic stages do not replace the full commit-to-frame gate.
            var stageSamples: [(writeMs: Double, lookupMs: Double, frameMs: Double)] = []
            stageSamples.reserveCapacity(n)
            for i in 0..<n {
                let t0 = DispatchTime.now()
                try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
                let writeReturned = DispatchTime.now()
                let gid = try #require(
                    Array(co.eventsAfter(globalId: nil)).last?.globalId?.uuidString.lowercased())
                let lookupReturned = DispatchTime.now()
                let arrived = await watcher.wait(timeout: 10) { $0.arrivalTime(of: gid) != nil }
                if !arrived {
                    // Failure-only diagnostics: this is an incomplete iteration,
                    // not a callback latency sample or a completed p95 run.
                    // The wait duration includes polling and scheduling.
                    let waitReturned = DispatchTime.now()
                    let writeMs = Double(writeReturned.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
                    let lookupMs = Double(lookupReturned.uptimeNanoseconds &- writeReturned.uptimeNanoseconds) / 1e6
                    let waitMs = Double(waitReturned.uptimeNanoseconds &- lookupReturned.uptimeNanoseconds) / 1e6
                    print("BENCH ObserverPushLatencyIncomplete: iteration=\(i)"
                          + " completed_n=\(samples.count) requested_n=\(n)"
                          + " write_ms=" + String(format: "%.1f", writeMs)
                          + " lookup_ms=" + String(format: "%.1f", lookupMs)
                          + " arrival_wait_ms=" + String(format: "%.1f", waitMs)
                          + " arrived=false frame_ms=missing partial=true p95_available=false")
                    sendSamples.append(.init(iteration: i, id: gid,
                                             writeStart: t0.uptimeNanoseconds, callback: nil))
                }
                try #require(arrived, "commit \(i) never reached the watch socket")
                let t1 = try #require(watcher.arrivalTime(of: gid))
                samples.append(Double(t1.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6)
                stageSamples.append((
                    writeMs: Double(writeReturned.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6,
                    lookupMs: Double(lookupReturned.uptimeNanoseconds &- writeReturned.uptimeNanoseconds) / 1e6,
                    frameMs: Double(t1.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
                ))
                sendSamples.append(.init(iteration: i, id: gid,
                                         writeStart: t0.uptimeNanoseconds,
                                         callback: t1.uptimeNanoseconds))
            }

            samples.sort()
            func pct(_ p: Double) -> Double {
                samples[min(samples.count - 1, Int(Double(samples.count) * p))]
            }
            let p50 = pct(0.50), p95 = pct(0.95), p99 = pct(0.99)
            let underParallelLoad =
                ProcessInfo.processInfo.environment["LATTICE_BENCH_PARALLEL_LOAD"] == "1"
            let ms: (Double) -> String = { String(format: "%.1f", $0) }
            var line = "BENCH ObserverPushLatency: n=\(n)"
            line += " p50_ms=" + ms(p50)
            line += " p95_ms=" + ms(p95)
            line += " p99_ms=" + ms(p99)
            line += " target_ms=\(Int(designTargetMs))"
            line += " soft_gate_ms=\(Int(softGateMs))"
            line += " parallel_load=\(underParallelLoad)"
            print(line)
            // Emit only after measurement, retaining iteration order so slow
            // writes, event-ID lookups and frame arrivals remain distinguishable.
            print("BENCH ObserverPushLatencyHost: processors=\(ProcessInfo.processInfo.processorCount)"
                  + " active_processors=\(ProcessInfo.processInfo.activeProcessorCount)")
            for (iteration, sample) in stageSamples.enumerated() {
                print("BENCH ObserverPushLatencySample: iteration=\(iteration)"
                      + " write_ms=" + ms(sample.writeMs)
                      + " lookup_ms=" + ms(sample.lookupMs)
                      + " frame_ms=" + ms(sample.frameMs))
            }
            // The design target is reported, never asserted: it is a
            // performance goal measured against a shared machine, and the
            // recorded number is what a regression review reads.
            if p95 >= designTargetMs {
                print("BENCH ObserverPushLatency: NOTE p95 " + ms(p95)
                      + "ms is above the \(Int(designTargetMs))ms design target"
                      + " (contended run?)")
            }
            // Soft gate: ~10× the worst p95 seen under parallel load and
            // still far under the 4.63s redial p95 push replaces, so it
            // catches real degradation without failing on scheduler noise.
            if underParallelLoad {
                print("BENCH ObserverPushLatency: gate skipped "
                      + "(LATTICE_BENCH_PARALLEL_LOAD=1) — numbers recorded only")
            } else {
                let breach = "push p95 " + ms(p95) + "ms breaches the "
                    + "\(Int(softGateMs))ms soft gate — push is no longer beating "
                    + "the redial path it replaces"
                #expect(p95 < softGateMs, "\(breach)")
            }
        }
    }
}


/// No global state: one recorder belongs to this benchmark's mount/channel.
private struct PushLatencySendSample {
    let iteration: Int
    let id: String
    let writeStart: UInt64
    let callback: UInt64?
}

private final class PushLatencySendLog: @unchecked Sendable {
    private struct Page {
        let route: ObserverSendBoundaryProbe.Route
        let ids: [UUID?]
        let uptime: UInt64
    }
    private let lock = NSLock()
    private let maximumPages = 256
    private let maximumIDsPerPage = 1000
    private var pages: [Page] = []
    private var droppedPages = 0
    private var closed = false

    init() { pages.reserveCapacity(maximumPages) }

    func record(route: ObserverSendBoundaryProbe.Route, ids: [UUID?], uptime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        guard pages.count < maximumPages, ids.count <= maximumIDsPerPage else {
            droppedPages += 1
            return
        }
        pages.append(Page(route: route, ids: ids, uptime: uptime))
    }

    func emit(samples: [PushLatencySendSample]) {
        lock.lock()
        closed = true
        let snapshot = pages
        let dropped = droppedPages
        lock.unlock()
        // Formatting, ID matching and output are entirely after measurement.
        // Late attempts after this snapshot are unobserved, not proof of no send.
        print("BENCH ObserverPushLatencySendCapture: pages=\(snapshot.count) dropped_pages=\(dropped)"
              + " max_pages=\(maximumPages) max_ids_per_page=\(maximumIDsPerPage)"
              + " clock=dispatch_uptime same_process=true send_attempt_only=true"
              + " capture_closed=true late_attempts_unobserved=true")
        for (index, page) in snapshot.enumerated() {
            let ids = page.ids.map { $0?.uuidString.lowercased() ?? "nil" }.joined(separator: ",")
            print("BENCH ObserverPushLatencySendPage: page=\(index) route=\(page.route.rawValue)"
                  + " send_uptime_ns=\(page.uptime) page_count=\(page.ids.count)"
                  + " page_audit_ids=[\(ids)]")
        }
        func deltaMs(_ later: UInt64, _ earlier: UInt64) -> String {
            let value = later >= earlier
                ? Double(later - earlier) / 1e6 : -Double(earlier - later) / 1e6
            return String(format: "%.3f", value)
        }
        for sample in samples {
            let id = UUID(uuidString: sample.id)
            let matches = snapshot.enumerated().filter { _, page in
                guard let id else { return false }
                return page.ids.contains { $0 == id }
            }
            // Earliest timestamp, not lock-acquisition/append order. Retain all
            // page rows above so coalescing/repeated send attempts stay visible.
            let first = matches.min { $0.element.uptime < $1.element.uptime }
            var line = "BENCH ObserverPushLatencySendMatch: iteration=\(sample.iteration)"
                + " audit_id=\(sample.id) matching_pages=\(matches.count)"
                + " write_start_uptime_ns=\(sample.writeStart)"
                + " callback_uptime_ns=\(sample.callback.map { String($0) } ?? "missing")"
            if let first {
                line += " route=\(first.element.route.rawValue) page=\(first.offset)"
                    + " send_uptime_ns=\(first.element.uptime)"
                    + " write_to_send_ms=" + deltaMs(first.element.uptime, sample.writeStart)
                if let callback = sample.callback {
                    line += " send_to_callback_ms=" + deltaMs(callback, first.element.uptime)
                } else {
                    line += " send_to_callback_ms=missing"
                }
            } else {
                line += " route=unobserved page=missing send_uptime_ns=missing"
                    + " write_to_send_ms=missing send_to_callback_ms=missing"
            }
            print(line)
        }
    }
}


/// Passive, bounded per-benchmark metadata. Row IDs are append order under the
/// lock; their uptime timestamps were taken BEFORE this lock and may interleave.
/// Parent/related edges describe control scopes, never callback→audit causation.
private final class PushLatencyPipelineLog: @unchecked Sendable {
    fileprivate struct Row {
        let event: ObserverSendBoundaryProbe.Pipeline.Event
        let uptime: UInt64
    }
    struct Snapshot {
        fileprivate let rows: [Row]
        fileprivate let dropped: Int
        fileprivate let retainedIDs: Int
    }
    private let lock = NSLock()
    private let maximumRows = 8192
    private let maximumIDsPerRow = 1000
    private let maximumTotalIDs = 65536
    private var rows: [Row] = []
    private var retainedIDs = 0
    private var dropped = 0
    private var closed = false

    init() { rows.reserveCapacity(maximumRows) }

    func record(event: ObserverSendBoundaryProbe.Pipeline.Event, uptime: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        guard rows.count < maximumRows, event.auditIDs.count <= maximumIDsPerRow,
              event.auditIDs.count <= maximumTotalIDs - retainedIDs else {
            if dropped < Int.max { dropped += 1 }
            return nil
        }
        let token = UInt64(rows.count)
        rows.append(Row(event: event, uptime: uptime))
        retainedIDs += event.auditIDs.count
        return token
    }

    func close() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return Snapshot(rows: rows, dropped: dropped, retainedIDs: retainedIDs)
    }

    func emit(_ snapshot: Snapshot) {
        // Formatting/output only after capture closes; there is no scheduling
        // wait for late work. An incomplete snapshot cannot prove a missing event.
        print("BENCH ObserverPushLatencyPipelineCapture: rows=\(snapshot.rows.count)"
              + " dropped_rows=\(snapshot.dropped) retained_ids=\(snapshot.retainedIDs)"
              + " max_rows=\(maximumRows) max_ids_per_row=\(maximumIDsPerRow)"
              + " max_total_ids=\(maximumTotalIDs) channel=group-bench clock=dispatch_uptime"
              + " same_process=true capture_closed=true late_events_unobserved=true"
              + " overhead_subtracted=false callback_audit_causality=false warmup_activation_barrier=false")
        func number<T: BinaryInteger>(_ value: T?) -> String {
            value.map { String($0) } ?? "missing"
        }
        func flag(_ value: Bool?) -> String { value.map { String($0) } ?? "missing" }
        for (index, row) in snapshot.rows.enumerated() {
            let event = row.event
            let ids = event.auditIDs.map { $0?.uuidString.lowercased() ?? "nil" }.joined(separator: ",")
            print("BENCH ObserverPushLatencyPipelineRow: event=\(index) stage=\(event.stage.rawValue)"
                  + " uptime_ns=\(row.uptime) parent=\(number(event.parent)) related=\(number(event.related))"
                  + " cursor=\(number(event.cursor)) count=\(number(event.count)) last_pk=\(number(event.lastPK))"
                  + " active=\(flag(event.active)) dirty=\(flag(event.dirty)) pumping=\(flag(event.pumping))"
                  + " callback_covered=\(flag(event.callbackCovered)) page_audit_ids=[\(ids)]")
        }
    }
}
