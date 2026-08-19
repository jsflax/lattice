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
// ============================================================================

@Suite("ObserverPushLatencyBench", .timeLimit(.minutes(5)))
final class ObserverPushLatencyBench: BaseTest {

    @Test func coProcessWriteToWatchSocketLatency() async throws {
        let n = ProcessInfo.processInfo.environment["LATTICE_BENCH_FULL"] == "1" ? 200 : 30

        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

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
        print("BENCH ObserverPushLatency: n=\(n) "
              + "p50_ms=\(String(format: "%.1f", p50)) "
              + "p95_ms=\(String(format: "%.1f", p95)) "
              + "p99_ms=\(String(format: "%.1f", p99))")

        // Target: p95 well under the measured 4.63s redial p95 — the design
        // asks for < 250ms; loopback push is single-digit ms in practice.
        #expect(p95 < 250, "push p95 \(p95)ms breaches the 250ms target")
    }
}
