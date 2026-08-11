import Foundation
import Testing
import Vapor
import NIOWebSocket
import WebSocketKit
import Lattice
import LatticeServerKit

// ============================================================================
// A1.5 — server-side ack-latency bench.
//
// Measures time-to-FIRST-ack and time-to-LAST-ack for ONE uploaded frame of
// N audit entries against the REAL `configureSyncRelay` relay
// (Sources/LatticeServerKit/LatticeServerKit.swift), in-process on an
// ephemeral port, with a raw WebSocket client sending a donor-lattice-
// produced frame (the ServerRelayTests harness pattern — deterministic
// control over exactly what crosses the wire, no client sync-engine timing).
//
// Today the relay applies the whole frame synchronously on the socket's NIO
// event loop inside `processFrame` and sends a single ack only after
// `lattice.receive(data)` returns, so first_ack == last_ack. The upcoming
// fixes (apply off the event loop; progressive per-chunk acks) should pull
// first_ack_ms down sharply while last_ack_ms keeps tracking total apply
// time. This bench provides the before/after numbers.
//
//   BENCH ServerAckLatency: n=1000 first_ack_ms=<X> last_ack_ms=<Y>
//
// N defaults to 1000; LATTICE_BENCH_FULL=1 raises it to 5000.
// ============================================================================

/// Records ack arrivals with monotonic timestamps. first = the first ack
/// frame after arming; covered = the ack at which the expected id set was
/// fully acked (with today's single whole-frame ack the two coincide).
private final class AckLatencyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var socket: WebSocket?
    private var expected: Set<UUID> = []
    private var acked: Set<UUID> = []
    private var firstAckAt: DispatchTime?
    private var coveredAt: DispatchTime?
    private var rejectedFrames: [String] = []

    func attach(_ ws: WebSocket) {
        socket = ws
        ws.onBinary { [weak self] _, bb in
            guard let self else { return }
            let now = DispatchTime.now()
            let data = Data(buffer: bb)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = root["kind"] as? String else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            switch kind {
            case "ack":
                if self.firstAckAt == nil { self.firstAckAt = now }
                if let ids = root["ack"] as? [String] {
                    self.acked.formUnion(ids.compactMap(UUID.init(uuidString:)))
                }
                if self.coveredAt == nil, !self.expected.isEmpty,
                   self.expected.isSubset(of: self.acked) {
                    self.coveredAt = now
                }
            case "rejected":
                self.rejectedFrames.append(String(decoding: data, as: UTF8.self))
            default:
                break
            }
        }
    }

    /// Arms a fresh measurement window: clears prior acks/timestamps and
    /// installs the id set whose full coverage defines "last ack".
    func beginMeasurement(expecting ids: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        expected = ids
        acked = []
        firstAckAt = nil
        coveredAt = nil
    }

    var measurement: (first: DispatchTime?, covered: DispatchTime?, ackedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (firstAckAt, coveredAt, acked.intersection(expected).count)
    }

    var rejections: [String] {
        lock.lock()
        defer { lock.unlock() }
        return rejectedFrames
    }
}

/// Minimal in-process relay running the REAL `configureSyncRelay` on an
/// ephemeral port with a fresh storage dir (fresh channel database). Same
/// shape as ServerRelayTests.RelayHarness, which is private to that file.
private final class BenchRelayHarness: @unchecked Sendable {
    let app: Application
    let storageURL: URL
    let port: Int

    init(schema: [any Lattice.Model.Type]) async throws {
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "ack-bench-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        Lattice.configureSyncRelay(
            on: app.routes, path: ["sync"], for: schema, storageURL: storageURL,
            channelExtractor: { req in
                guard let raw = req.headers.first(name: "X-Test-User"),
                      let uid = UUID(uuidString: raw) else { throw Abort(.unauthorized) }
                return SyncChannel(id: "bench", userId: uid)
            })
        try await app.startup()
        guard let assigned = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "no port")
        }
        port = assigned
    }

    func connect(user: UUID) async throws -> AckLatencyCollector {
        let collector = AckLatencyCollector()
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-User", value: user.uuidString)
        // The single ack for N ids (~45 bytes each) blows past WebSocketKit's
        // 16KB default client maxFrameSize at N=1000 — raise it.
        var config = WebSocketClient.Configuration()
        config.maxFrameSize = 1 << 27
        let once = AtomicOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            WebSocket.connect(
                to: "ws://127.0.0.1:\(port)/sync",
                headers: headers,
                configuration: config,
                on: app.eventLoopGroup
            ) { ws in
                collector.attach(ws)
                if once.tryFire() { cont.resume() }
            }.whenFailure { error in
                if once.tryFire() { cont.resume(throwing: error) }
            }
        }
        return collector
    }

    func shutdown() async {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: storageURL)
    }
}

/// Wire-true upload frame: exactly what a syncing client sends.
private func makeBenchFrame(entries: [AuditLog]) throws -> [UInt8] {
    Array(try JSONEncoder().encode(ServerSentEvent.auditLog(entries)))
}

/// Polls `predicate` every 20ms until it holds or `timeout` elapses.
private func poll(timeout: TimeInterval, _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate()
}

@Suite("ServerAckLatencyBench", .timeLimit(.minutes(5)))
final class ServerAckLatencyBench: BaseTest {

    @Test func ackLatencyForSingleUploadedFrame() async throws {
        let n = ProcessInfo.processInfo.environment["LATTICE_BENCH_FULL"] == "1" ? 5000 : 1000

        // Donor lattice produces the audit entries (INSERTs of the sync
        // tests' SimpleSyncObject). One warmup entry first, then N bench
        // entries, split by globalId watermark.
        let donor = try testLattice(SimpleSyncObject.self)
        try donor.add(SimpleSyncObject(value: -1, floatValue: 0))
        let warmupEntries = Array(donor.eventsAfter(globalId: nil))
        let warmupIds = Set(warmupEntries.compactMap(\.globalId))
        try #require(!warmupEntries.isEmpty)
        let warmupWatermark = try #require(warmupEntries.last?.globalId)

        for i in 0..<n {
            try donor.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }
        let benchEntries = Array(donor.eventsAfter(globalId: warmupWatermark))
        let benchIds = Set(benchEntries.compactMap(\.globalId))
        #expect(benchEntries.count == n,
                "expected \(n) audit entries, donor produced \(benchEntries.count)")
        try #require(benchIds.count == benchEntries.count)

        let harness = try await BenchRelayHarness(schema: [SimpleSyncObject.self])
        defer { Task { [harness] in await harness.shutdown() } }

        let client = try await harness.connect(user: UUID())

        // Warmup: the relay opens its per-channel lattice lazily after the
        // upgrade and buffers frames until then. One acked warmup entry
        // guarantees the pipeline is live, so the measured window is frame
        // apply+ack latency — not connection/open latency.
        client.beginMeasurement(expecting: warmupIds)
        try await client.socket!.send(try makeBenchFrame(entries: warmupEntries))
        let warmedUp = await poll(timeout: 30) { client.measurement.covered != nil }
        try #require(warmedUp,
                     "warmup frame was never acked; rejections=\(client.rejections)")

        // Measured upload: ONE frame carrying all N entries. Encode before
        // t0 so serialization cost stays out of the measurement.
        let frame = try makeBenchFrame(entries: benchEntries)
        client.beginMeasurement(expecting: benchIds)
        let t0 = DispatchTime.now()
        try await client.socket!.send(frame)

        let deadline: TimeInterval = 120
        let allAcked = await poll(timeout: deadline) { client.measurement.covered != nil }
        let m = client.measurement
        #expect(allAcked,
                "only \(m.ackedCount)/\(benchEntries.count) entries acked within \(Int(deadline))s; rejections=\(client.rejections)")

        if let first = m.first, let covered = m.covered {
            let firstMs = Double(first.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
            let lastMs = Double(covered.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
            print("BENCH ServerAckLatency: n=\(benchEntries.count) "
                  + "first_ack_ms=\(String(format: "%.1f", firstMs)) "
                  + "last_ack_ms=\(String(format: "%.1f", lastMs))")
        }
    }
}
