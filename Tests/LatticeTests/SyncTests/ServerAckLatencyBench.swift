import Foundation
import Testing
import Vapor
import NIOWebSocket
import WebSocketKit
import Lattice
@testable import LatticeServerKit

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
    let ackPath: ACKPathConnection?
    private(set) var socket: WebSocket?
    private var expected: Set<UUID> = []
    private var acked: Set<UUID> = []
    private var firstAckAt: DispatchTime?
    private var coveredAt: DispatchTime?
    // Scalar-only connection diagnostics: no frame bodies, error strings or
    // extra ID sets are retained. ACK coverage stores only expected IDs.
    private var binaryFrames = 0
    private var malformedFrames = 0
    private var ackFrames = 0
    private var nonmatchingAckIDCount = 0
    private var incompleteAckFrames = 0
    private var nackFrames = 0
    private var nackIDCount = 0
    private var matchingNackIDCount = 0
    private var rejectedFrames = 0
    private var otherFrames = 0
    private var textFrames = 0
    private var firstBinaryUptime: UInt64?
    private var closeUptime: UInt64?
    private var closeFailed = false

    init(ackPath: ACKPathConnection? = nil) {
        self.ackPath = ackPath
    }

    private static func adding(_ value: Int, _ increment: Int = 1) -> Int {
        let (result, overflow) = value.addingReportingOverflow(increment)
        return overflow ? Int.max : result
    }

    func attach(_ ws: WebSocket) {
        socket = ws
        ws.onBinary { [weak self, ackPath = self.ackPath] _, bb in
            guard let self else { return }
            let now = DispatchTime.now()
            ackPath?.record(.clientBinaryEntered, bytes: bb.readableBytes)
            self.lock.lock()
            self.binaryFrames = Self.adding(self.binaryFrames)
            if self.firstBinaryUptime == nil { self.firstBinaryUptime = now.uptimeNanoseconds }
            self.lock.unlock()
            let data = Data(buffer: bb)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = root["kind"] as? String else {
                self.lock.lock()
                self.malformedFrames = Self.adding(self.malformedFrames)
                self.lock.unlock()
                ackPath?.record(.clientDecodeError)
                return
            }
            switch kind {
            case "ack":
                let rawIDs = root["ack"] as? [String]
                let ids = (rawIDs ?? []).compactMap(UUID.init(uuidString:))
                ackPath?.record(.clientDecodedAck, count: ids.count, matching: ids)
                if ackPath?.containsWarmID(ids) == true {
                    ackPath?.record(.clientWarmAckMatch, count: ids.count, matching: ids)
                }
                self.lock.lock()
                if rawIDs == nil || ids.count != rawIDs?.count {
                    self.malformedFrames = Self.adding(self.malformedFrames)
                }
                self.ackFrames = Self.adding(self.ackFrames)
                if self.firstAckAt == nil { self.firstAckAt = now }
                self.nonmatchingAckIDCount = Self.adding(
                    self.nonmatchingAckIDCount, ids.filter { !self.expected.contains($0) }.count)
                self.acked.formUnion(ids.filter { self.expected.contains($0) })
                if self.coveredAt == nil, !self.expected.isEmpty,
                   self.expected.isSubset(of: self.acked) {
                    self.coveredAt = now
                }
                if !self.expected.isSubset(of: self.acked) {
                    self.incompleteAckFrames = Self.adding(self.incompleteAckFrames)
                }
                self.lock.unlock()
                ackPath?.record(.clientAckStored, count: ids.count, matching: ids)
            case "nack":
                let rawIDs = root["nack"] as? [String]
                let ids = (rawIDs ?? []).compactMap(UUID.init(uuidString:))
                self.lock.lock()
                if rawIDs == nil || ids.count != rawIDs?.count {
                    self.malformedFrames = Self.adding(self.malformedFrames)
                }
                self.nackFrames = Self.adding(self.nackFrames)
                self.nackIDCount = Self.adding(self.nackIDCount, ids.count)
                self.matchingNackIDCount = Self.adding(
                    self.matchingNackIDCount, ids.filter { self.expected.contains($0) }.count)
                self.lock.unlock()
                ackPath?.record(.clientDecodedNack, count: ids.count, matching: ids)
            case "rejected":
                self.lock.lock()
                self.rejectedFrames = Self.adding(self.rejectedFrames)
                self.lock.unlock()
                ackPath?.record(.clientDecodedRejected)
            default:
                self.lock.lock()
                self.otherFrames = Self.adding(self.otherFrames)
                self.lock.unlock()
                ackPath?.record(kind == "auditLog" ? .clientDecodedAudit : .clientDecodedOther)
            }
        }
        ws.onText { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            self.textFrames = Self.adding(self.textFrames)
            self.lock.unlock()
        }
        ws.onClose.whenComplete { [weak self] result in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.lock.lock()
            if self.closeUptime == nil { self.closeUptime = now }
            if case .failure = result { self.closeFailed = true }
            self.lock.unlock()
        }
        ackPath?.record(.clientHandlersAttached)
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

    var rejectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rejectedFrames
    }

    /// Connection counters are cumulative; expected/covered describe the
    /// currently armed window. Only fixed labels, counts and uptime values
    /// are printed, and formatting runs after releasing the client lock.
    func emitDiagnostics(phase: String) {
        lock.lock()
        let counts = (binaryFrames, malformedFrames, ackFrames, incompleteAckFrames,
                      nackFrames, nackIDCount, matchingNackIDCount, rejectedFrames,
                      otherFrames, textFrames, expected.count, acked.count, nonmatchingAckIDCount)
        let times = (firstBinaryUptime, closeUptime, closeFailed,
                     firstAckAt?.uptimeNanoseconds, coveredAt?.uptimeNanoseconds,
                     DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
        print("ACK_BENCH_CLIENT_DIAGNOSTIC test=\(ackPath?.recorder.testRunID.uuidString ?? "unknown")"
              + " connection=\(ackPath?.id.uuidString ?? "unknown") phase=\(phase) counters=cumulative"
              + " cutoff_ns=\(times.5)"
              + " binary=\(counts.0) malformed=\(counts.1) ack_frames=\(counts.2)"
              + " incomplete_ack_frames=\(counts.3) nack_frames=\(counts.4)"
              + " nack_ids=\(counts.5) matching_nack_ids=\(counts.6) rejected=\(counts.7)"
              + " other_binary=\(counts.8) text=\(counts.9)"
              + " expected=\(counts.10) covered_ids=\(counts.11)"
              + " nonmatching_ack_ids=\(counts.12)"
              + " first_binary_ns=\(times.0.map(String.init) ?? "unknown")"
              + " close_ns=\(times.1.map(String.init) ?? "unknown") close_failed=\(times.2)"
              + " first_ack_ns=\(times.3.map(String.init) ?? "unknown")"
              + " covered_ns=\(times.4.map(String.init) ?? "unknown")")
    }
}

/// Minimal in-process relay running the REAL `configureSyncRelay` on an
/// ephemeral port with a fresh storage dir (fresh channel database). Same
/// shape as ServerRelayTests.RelayHarness, which is private to that file.
private final class BenchRelayHarness: @unchecked Sendable {
    let app: Application
    let storageURL: URL
    let port: Int
    private let ackPathRecorder: ACKPathRecorder?

    init(schema: [any Lattice.Model.Type], ackPathRecorder: ACKPathRecorder? = nil) async throws {
        self.ackPathRecorder = ackPathRecorder
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "ack-bench-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        let diagnosticMount = storageURL
        var initialized = false
        if let ackPathRecorder { ACKPathDiagnostics.install(ackPathRecorder, for: diagnosticMount) }
        defer {
            if !initialized, let ackPathRecorder {
                ACKPathDiagnostics.remove(ackPathRecorder, for: diagnosticMount)
            }
        }
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
        initialized = true
    }

    func connect(user: UUID) async throws -> AckLatencyCollector {
        let ackPath = ackPathRecorder?.registerConnection(id: user, role: .uploader)
        let collector = AckLatencyCollector(ackPath: ackPath)
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-User", value: user.uuidString)
        // The single ack for N ids (~45 bytes each) blows past WebSocketKit's
        // 16KB default client maxFrameSize at N=1000 — raise it.
        var config = WebSocketClient.Configuration()
        config.maxFrameSize = 1 << 27
        let once = AtomicOnce()
        ackPath?.record(.connectBegin)
        do {
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
            ackPath?.record(.connectEnd)
        } catch {
            ackPath?.record(.connectError)
            throw error
        }
        return collector
    }

    func removeACKPathRecorder() {
        if let ackPathRecorder { ACKPathDiagnostics.remove(ackPathRecorder, for: storageURL) }
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
        let recorder = ProcessInfo.processInfo.environment["LATTICE_ACK_PATH_DIAGNOSTICS"] == "1"
            ? ACKPathRecorder(testRunID: UUID()) : nil
        var failurePhase: String? = "setup"
        var diagnosticClient: AckLatencyCollector?
        var finishedDiagnostics = false
        func finishDiagnostics() {
            guard !finishedDiagnostics, let recorder else { return }
            finishedDiagnostics = true
            if let failurePhase {
                diagnosticClient?.emitDiagnostics(phase: failurePhase)
                recorder.emitSnapshot(partial: true)
            } else {
                _ = recorder.closeSnapshot(partial: false)
            }
        }
        defer { finishDiagnostics() }

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

        let harness = try await BenchRelayHarness(schema: [SimpleSyncObject.self], ackPathRecorder: recorder)
        defer {
            // Freeze failure evidence before asynchronous teardown can add a
            // close event. The outer defer also covers failures before init.
            finishDiagnostics()
            Task { [harness] in await harness.shutdown() }
        }
        defer { harness.removeACKPathRecorder() }

        let client = try await harness.connect(user: UUID())
        diagnosticClient = client

        // Warmup: the relay opens its per-channel lattice lazily after the
        // upgrade and buffers frames until then. One acked warmup entry
        // guarantees the pipeline is live, so the measured window is frame
        // apply+ack latency — not connection/open latency.
        failurePhase = "warmup"
        client.beginMeasurement(expecting: warmupIds)
        if let warmID = warmupEntries.first?.globalId {
            client.ackPath?.selectWarmID(warmID, entryCount: warmupEntries.count)
        }
        client.ackPath?.record(.warmEncodeBegin, count: warmupEntries.count)
        let warmupFrame: [UInt8]
        do {
            warmupFrame = try makeBenchFrame(entries: warmupEntries)
            client.ackPath?.record(.warmEncodeEnd, bytes: warmupFrame.count, count: warmupEntries.count)
        } catch {
            client.ackPath?.record(.warmEncodeError)
            throw error
        }
        client.ackPath?.record(.warmSendBegin, bytes: warmupFrame.count, count: warmupEntries.count)
        do {
            try await client.socket!.send(warmupFrame)
            client.ackPath?.record(.warmSendReturn)
        } catch {
            client.ackPath?.record(.warmSendError)
            throw error
        }
        client.ackPath?.record(.pollBegin)
        let warmedUp = await poll(timeout: 30) { client.measurement.covered != nil }
        client.ackPath?.record(.pollEnd, result: warmedUp)
        if !warmedUp { finishDiagnostics() }
        try #require(warmedUp,
                     "warmup frame was never acked; rejected_frames=\(client.rejectionCount)")

        // Measured upload: ONE frame carrying all N entries. Encode before
        // t0 so serialization cost stays out of the measurement.
        failurePhase = "measured"
        let frame = try makeBenchFrame(entries: benchEntries)
        client.beginMeasurement(expecting: benchIds)
        let t0 = DispatchTime.now()
        try await client.socket!.send(frame)

        let deadline: TimeInterval = 120
        let allAcked = await poll(timeout: deadline) { client.measurement.covered != nil }
        let m = client.measurement
        if !allAcked { finishDiagnostics() }
        #expect(allAcked,
                "only \(m.ackedCount)/\(benchEntries.count) entries acked within \(Int(deadline))s; rejected_frames=\(client.rejectionCount)")

        if let first = m.first, let covered = m.covered {
            let firstMs = Double(first.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
            let lastMs = Double(covered.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
            print("BENCH ServerAckLatency: n=\(benchEntries.count) "
                  + "first_ack_ms=\(String(format: "%.1f", firstMs)) "
                  + "last_ack_ms=\(String(format: "%.1f", lastMs))")
        }
        if allAcked { failurePhase = nil }
    }
}
