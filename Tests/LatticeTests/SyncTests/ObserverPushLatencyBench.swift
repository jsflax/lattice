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

        try await withPushHarness { harness in
            let watcher = try await harness.connect(pathSuffix: "watch/group/bench", user: UUID())
            let co = try harness.coWriter("bench")

            // Warmup: prove the pipeline (watcher group, pump, socket) is live
            // before measuring, so the numbers are commit→frame latency — not
            // connection/open/first-group latency.
            try co.add(SimpleSyncObject(value: -1, floatValue: 0))
            let warmed = await watcher.wait(timeout: 30) { $0.receivedGlobalIds.count >= 1 }
            try #require(warmed, "warmup commit never reached the watch socket")

            var samples: [Double] = []
            samples.reserveCapacity(n)
            for i in 0..<n {
                let t0 = DispatchTime.now()
                try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
                let gid = try #require(
                    Array(co.eventsAfter(globalId: nil)).last?.globalId?.uuidString.lowercased())
                let arrived = await watcher.wait(timeout: 10) { $0.arrivalTime(of: gid) != nil }
                try #require(arrived, "commit \(i) never reached the watch socket")
                let t1 = try #require(watcher.arrivalTime(of: gid))
                samples.append(Double(t1.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6)
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
