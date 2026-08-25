import Foundation
import Testing
import Vapor
import NIOWebSocket
import NIOConcurrencyHelpers
import WebSocketKit
@testable import Lattice
@testable import LatticeServerKit

// ============================================================================
// JoyJet incident regression harness — "a live-socket upload is invisible on
// the server for 40+ seconds, then vanishes".
//
// What the forensics established (all citations against the PINNED core,
// LatticeCore 1.4.2 / 36b8288 at .build/checkouts/LatticeCore — NOT the local
// ~/localdev/LatticeCore working copy, which diverges on exactly this code):
//
//   * The relay opened channel stores with the library default
//     `busyTimeoutMs = 30_000`, and `database::begin_transaction` (db.cpp:758)
//     uses the configured busy timeout as the BEGIN-acquisition BUDGET. One
//     contended apply therefore parked 30s, hit the core's contained
//     chunk-retry (+50ms), parked another 30s, and returned an EMPTY id list
//     WITHOUT throwing.
//   * The relay acked only a non-empty id list and had no other output path,
//     so the frame produced no ack, no nack, and no log line — it never even
//     reached the `print("Error:")` catch.
//   * A catch-up ack burst is NOT read-only server-side: every per-page client
//     ack re-enters `receive()` → `mark_audit_entries_synced` → BEGIN +
//     UPDATEs (chunked at 100, the B3.7 fix).
//
// These tests run the REAL `configureSyncRelay` in-process with raw WebSocket
// clients that reproduce the client engine's ack behavior (sync.cpp:836 — ack
// every applied page). Post-1.7.1 they pin the FIXED behavior: bounded busy
// budget, bounded retry, explicit nack, per-file serialization.
//
// Env knobs for full-scale forensic runs:
//   FORENSIC_N       seeded audit entries for the burst tests (default 4000)
//   FORENSIC_HOLD_S  external write-lock hold, seconds (default 12)
// ============================================================================

/// A raw relay client that behaves like the real client engine for the
/// behaviors that matter here: it acks every `auditLog` page it receives
/// (sync.cpp:836) and records ack/nack arrivals with monotonic timestamps.
private final class ForensicClient: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var socket: WebSocket?
    /// Reproduce the client engine's per-page ack (the server-side write burst).
    let autoAck: Bool
    let label: String

    private var ackedIds: Set<UUID> = []
    private var ackFrameCount = 0
    private var catchUpPages = 0
    private var catchUpEntries = 0
    private var ackArrival: [UUID: DispatchTime] = [:]
    private var nackArrival: [UUID: DispatchTime] = [:]
    private var nackReasons: [String] = []
    private var rejections: [String] = []

    init(label: String, autoAck: Bool) {
        self.label = label
        self.autoAck = autoAck
    }

    func attach(_ ws: WebSocket) {
        socket = ws
        ws.onBinary { [weak self] ws, bb in
            guard let self else { return }
            let now = DispatchTime.now()
            let data = Data(buffer: bb)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = root["kind"] as? String else { return }
            switch kind {
            case "ack":
                let ids = (root["ack"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
                self.lock.lock()
                self.ackFrameCount += 1
                for id in ids where self.ackArrival[id] == nil { self.ackArrival[id] = now }
                self.ackedIds.formUnion(ids)
                self.lock.unlock()
            case "nack":
                let ids = (root["nack"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
                self.lock.lock()
                for id in ids where self.nackArrival[id] == nil { self.nackArrival[id] = now }
                self.nackReasons.append(root["nackReason"] as? String ?? "")
                self.lock.unlock()
            case "auditLog":
                let logs = root["auditLog"] as? [[String: Any]] ?? []
                let ids = logs.compactMap { $0["globalId"] as? String }
                    .compactMap(UUID.init(uuidString:))
                self.lock.lock()
                self.catchUpPages += 1
                self.catchUpEntries += logs.count
                self.lock.unlock()
                // The write burst: the real client acks every applied page,
                // and the relay turns each ack into a write transaction on
                // the shared channel file.
                if self.autoAck, !ids.isEmpty,
                   let encoded = try? JSONEncoder().encode(ServerSentEvent.ack(ids)) {
                    ws.send(ByteBuffer(data: encoded))
                }
            case "rejected":
                self.lock.lock()
                self.rejections.append(String(decoding: data, as: UTF8.self))
                self.lock.unlock()
            default:
                break
            }
        }
    }

    func ackTime(for id: UUID) -> DispatchTime? { lock.withLock { ackArrival[id] } }
    func nackTime(for id: UUID) -> DispatchTime? { lock.withLock { nackArrival[id] } }
    var pages: Int { lock.withLock { catchUpPages } }
    var entries: Int { lock.withLock { catchUpEntries } }
    var ackFrames: Int { lock.withLock { ackFrameCount } }
    var rejected: [String] { lock.withLock { rejections } }
    var nacks: [String] { lock.withLock { nackReasons } }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock(); defer { unlock() }
        return body()
    }
}

/// In-process relay running the REAL `configureSyncRelay`, one channel.
private final class ForensicsRelayHarness: @unchecked Sendable {
    let app: Application
    let storageURL: URL
    let port: Int
    let channelId: String
    let channelFileName: String

    var channelFileURL: URL { storageURL.appending(path: channelFileName) }

    /// `channelId` is scoped per harness where a test installs a process-global
    /// fault (`_applyFaultForTesting`): suites run in parallel, so a fault must
    /// only fire for its own channel.
    init(schema: [any Lattice.Model.Type], channelId: String = "forensics") async throws {
        self.channelId = channelId
        self.channelFileName = "\(channelId).sqlite"
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "busy-forensics-\(String.random(length: 12))")
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        let fileName = channelFileName
        let id = channelId
        Lattice.configureSyncRelay(
            on: app.routes, path: ["sync"], for: schema, storageURL: storageURL,
            channelExtractor: { req in
                guard let raw = req.headers.first(name: "X-Test-User"),
                      let uid = UUID(uuidString: raw) else { throw Abort(.unauthorized) }
                return SyncChannel(id: id, userId: uid, databaseFileName: fileName)
            })
        try await app.startup()
        guard let assigned = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "no port")
        }
        port = assigned
    }

    func connect(_ client: ForensicClient, lastEventId: UUID? = nil) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-User", value: UUID().uuidString)
        var config = WebSocketClient.Configuration()
        config.maxFrameSize = 1 << 27
        var url = "ws://127.0.0.1:\(port)/sync"
        if let lastEventId { url += "?last-event-id=\(lastEventId.uuidString)" }
        let once = AtomicOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            WebSocket.connect(to: url, headers: headers, configuration: config,
                              on: app.eventLoopGroup) { ws in
                client.attach(ws)
                if once.tryFire() { cont.resume() }
            }.whenFailure { error in
                if once.tryFire() { cont.resume(throwing: error) }
            }
        }
    }

    func shutdown() async {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: storageURL)
    }

    /// Shuts the relay down but leaves the channel file for inspection.
    func shutdown_keepingStorage() async {
        try? await app.asyncShutdown()
    }
}

private func frame(_ entries: [AuditLog]) throws -> ByteBuffer {
    ByteBuffer(data: try JSONEncoder().encode(ServerSentEvent.auditLog(entries)))
}

private func poll(timeout: TimeInterval, _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate()
}

/// Seeds the channel file with `count` locally-authored rows (so their audit
/// entries are `isSynchronized = 0` — a catch-up ack against them performs a
/// real UPDATE, exactly like a production channel that has never been fully
/// acked). Returns the seeded audit entries, oldest first.
private func seedSummary(_ url: URL, count: Int) throws -> (count: Int, tail: UUID?) {
    let seed = try Lattice(for: [SimpleSyncObject.self], configuration: .init(fileURL: url))
    try seed.add(contentsOf: (0..<count).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
    let entries = Array(seed.eventsAfter(globalId: nil))
    return (entries.count, entries.last?.globalId)
}

/// One unmanaged INSERT's worth of audit entries, produced by a donor lattice
/// — exactly what a client uploads for a single new row.
private func makeUploadEntries(donorPath: String, value: Int) throws -> [AuditLog] {
    let donor = try Lattice(for: [SimpleSyncObject.self],
                            configuration: .init(fileURL: FileManager.default
                                .temporaryDirectory.appending(path: donorPath)))
    let before = Array(donor.eventsAfter(globalId: nil)).last?.globalId
    try donor.add(SimpleSyncObject(value: value, floatValue: Float(value)))
    return Array(donor.eventsAfter(globalId: before))
}

/// `count` INSERT entries from one donor — a multi-chunk upload frame
/// (apply_remote_changes commits in chunks of 50).
private func makeUploadEntries(donorPath: String, count: Int) throws -> [AuditLog] {
    let donor = try Lattice(for: [SimpleSyncObject.self],
                            configuration: .init(fileURL: FileManager.default
                                .temporaryDirectory.appending(path: donorPath)))
    try donor.add(contentsOf: (0..<count).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
    return Array(donor.eventsAfter(globalId: nil))
}

/// Wire-level frame builder: encodes `entries`, then appends a poison entry
/// naming a table the relay's schema does not have.
private func poisonedFrame(_ entries: [AuditLog], poisonTable: String) throws -> (bytes: [UInt8], poisonId: UUID) {
    let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(entries))
    var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var array = try #require(root["auditLog"] as? [[String: Any]])
    var poison = try #require(array.last)
    let poisonId = UUID()
    poison["tableName"] = poisonTable
    poison["globalId"] = poisonId.uuidString.lowercased()
    poison["globalRowId"] = UUID().uuidString.lowercased()
    array.append(poison)
    root["auditLog"] = array
    return (Array(try JSONSerialization.data(withJSONObject: root)), poisonId)
}

/// Holds a real SQLite write lock on the channel file from ANOTHER PROCESS,
/// so the relay's `BEGIN IMMEDIATE` genuinely gets SQLITE_BUSY (rather than
/// the same-connection transaction race an in-process holder would produce).
private final class ExternalWriteLock: @unchecked Sendable {
    private let proc = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let seen = LockedBox("")
    private let releasedOnce = AtomicOnce()

    init(path: String) throws {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [path]
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [seen] h in
            let d = h.availableData
            if !d.isEmpty { seen.withLock { $0 += String(decoding: d, as: UTF8.self) } }
        }
        try proc.run()
        stdinPipe.fileHandleForWriting.write(Data("BEGIN IMMEDIATE;\nSELECT 'LOCKHELD';\n".utf8))
    }

    func waitUntilHeld(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { [seen] in seen.withLock { $0.contains("LOCKHELD") } }
    }

    /// Idempotent: the tests release as soon as they have their answer and
    /// again in a deadline task, whichever comes first.
    func release() {
        guard releasedOnce.tryFire() else { return }
        stdinPipe.fileHandleForWriting.write(Data("COMMIT;\n.quit\n".utf8))
        try? stdinPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
    }
}

/// Rows present in the channel file, read with a throwaway handle after the
/// relay has been shut down.
private func rowCount(inChannelFile url: URL) throws -> (rows: Int, audit: Int) {
    let l = try Lattice(for: [SimpleSyncObject.self], configuration: .init(fileURL: url))
    return (l.objects(SimpleSyncObject.self).count, l.objects(AuditLog.self).count)
}

@Suite("BusySafeApplyForensics", .serialized, .timeLimit(.minutes(10)))
final class BusySafeApplyForensicsTests: BaseTest {

    // MARK: - (1) The bounded busy budget

    /// The relay must NOT open channel stores at the library default: 30s is
    /// the BEGIN-acquisition budget, so a contended apply parks half a minute
    /// (twice, with the core's contained chunk retry) on a live socket.
    ///
    /// Also pins the aliasing fact the old "ONE lattice per connection"
    /// comment obscured: every relay-shaped open of one file returns ONE
    /// cached instance, so leaked per-connection Lattices retain that shared
    /// instance rather than adding SQLite connections — and since the instance
    /// cache does not key on `busyTimeoutMs`, the FIRST open installs the
    /// budget for every later aliased handle (which is why the observer-push
    /// watcher open uses the same policy).
    @Test func relayOpensChannelStoresWithABoundedBusyBudget() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "alias-\(String.random(length: 12)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        // The library default is unchanged — the relay layers its own budget.
        #expect(Lattice.Configuration(fileURL: url).busyTimeoutMs == 30_000)
        #expect(Lattice.Configuration.defaultBusyTimeoutMs == 30_000)

        let relayConfig = SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil)
        print("FORENSIC relay busyTimeoutMs=\(relayConfig.busyTimeoutMs)")
        #expect(relayConfig.busyTimeoutMs == SyncRelayApplyPolicy.busyTimeoutMs)
        #expect(relayConfig.busyTimeoutMs == 2_000)

        // A mount that asked for a specific budget keeps it verbatim; a mount
        // that only supplied schema/migration gets the relay budget.
        let explicit = SyncRelayApplyPolicy.configuration(fileURL: url) { u in
            .init(fileURL: u, busyTimeoutMs: 9_000)
        }
        #expect(explicit.busyTimeoutMs == 9_000)
        let defaulted = SyncRelayApplyPolicy.configuration(fileURL: url) { u in .init(fileURL: u) }
        #expect(defaulted.busyTimeoutMs == 2_000)

        // Backoff ladder: 20 → 320, five attempts.
        #expect(SyncRelayApplyPolicy.maxAttempts == 5)
        #expect((1...5).map(SyncRelayApplyPolicy.retryDelayMs(afterAttempt:)) == [20, 40, 80, 160, 320])

        // Exactly the relay's open shape: all three alias ONE instance.
        let a = try Lattice(for: [SimpleSyncObject.self], configuration: relayConfig)
        let b = try Lattice(for: [SimpleSyncObject.self], configuration: relayConfig)
        let c = try Lattice(for: [SimpleSyncObject.self], configuration: relayConfig)
        print("FORENSIC alias: a=\(a.backend.identityHash) b=\(b.backend.identityHash) c=\(c.backend.identityHash)")
        #expect(a.backend.identityHash == b.backend.identityHash,
                "two relay-shaped opens of one channel file should alias one instance")
        #expect(b.backend.identityHash == c.backend.identityHash)
    }

    // MARK: - (2) The main repro, now a latency regression

    /// MAIN REGRESSION. Peer B performs a large catch-up and acks every page
    /// (the server-side write burst — every ack is a BEGIN + UPDATE burst
    /// through `mark_audit_entries_synced`). Mid-burst, client A uploads ONE
    /// insert on its own live socket. Measure upload → server-visible
    /// (= ack, which the relay sends only after a successful apply).
    ///
    /// Pre-fix this was the "invisible for 40s" shape. Post-fix A's upload
    /// takes at most ONE queued ack frame's worth of waiting, because both go
    /// through the channel file's FIFO apply slot instead of colliding inside
    /// `begin_transaction`.
    @Test func liveUploadStaysFastDuringPeerCatchUpAckBurst() async throws {
        let n = Int(ProcessInfo.processInfo.environment["FORENSIC_N"] ?? "") ?? 4_000
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self])
        defer { Task { [harness] in await harness.shutdown() } }

        // Seed the channel file BEFORE any socket opens, then release the
        // seeding handle so the relay opens the file itself.
        let seeded = try seedSummary(harness.channelFileURL, count: n)
        let seededCount = seeded.count
        let seededTail = try #require(seeded.tail)
        print("FORENSIC seeded \(seededCount) audit entries into \(harness.channelFileURL.lastPathComponent)")

        // Client A: joins already up to date (no catch-up of its own), so the
        // ONLY contention it faces is peer B's burst.
        let a = ForensicClient(label: "A", autoAck: true)
        try await harness.connect(a, lastEventId: seededTail)

        // Warm A's connection: prove its per-connection lattice is live and
        // its apply pipeline acks, before the burst starts.
        let warm = try makeUploadEntries(donorPath: "donor-warm-\(String.random(length: 8)).sqlite", value: -1)
        let warmId = try #require(warm.first?.globalId)
        try await a.socket!.send(Array(buffer: frame(warm)))
        try #require(await poll(timeout: 60) { a.ackTime(for: warmId) != nil },
                     "A's warmup upload was never acked; rejections=\(a.rejected) nacks=\(a.nacks)")

        // Client B: fresh store, full catch-up, acks every page.
        let b = ForensicClient(label: "B", autoAck: true)
        try await harness.connect(b)

        // Let the burst get going, then upload from A mid-burst.
        _ = await poll(timeout: 60) { b.pages >= 2 }
        let pagesAtUpload = b.pages
        let upload = try makeUploadEntries(donorPath: "donor-a-\(String.random(length: 8)).sqlite", value: 42)
        let uploadId = try #require(upload.first?.globalId)
        let payload = Array(buffer: try frame(upload))

        let t0 = DispatchTime.now()
        try await a.socket!.send(payload)

        let acked = await poll(timeout: 60) { a.ackTime(for: uploadId) != nil }
        let latencyMs = a.ackTime(for: uploadId).map {
            Double($0.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
        }

        // Drain the rest of the burst so the numbers below describe a
        // completed catch-up.
        _ = await poll(timeout: 120) { b.entries >= seededCount }

        print("""
        FORENSIC peer-burst: seeded=\(seededCount) \
        pages_at_upload=\(pagesAtUpload) b_pages=\(b.pages) b_entries=\(b.entries) \
        a_upload_visible_ms=\(latencyMs.map { String(format: "%.0f", $0) } ?? "NEVER") \
        acked=\(acked) nacks=\(a.nacks.count)
        """)

        #expect(acked, "A's live-socket upload was never applied server-side")
        #expect(latencyMs ?? .infinity < 1_000,
                Comment(rawValue: "A's upload took \(latencyMs.map { String(format: "%.0f", $0) } ?? "NEVER")ms to become "
                + "visible under B's catch-up ack burst (budget: 1000ms)"))
        #expect(a.nacks.isEmpty, "nothing should be nacked on the healthy path")
        #expect(a.rejected.isEmpty)
    }

    /// SECOND MECHANISM, kept as a guard. The incident's client A had itself
    /// just redialed, so it ran its OWN catch-up: every page it acks goes back
    /// through the SAME per-connection FIFO applier its upload must pass
    /// through. This also pins the B3.7 ack chunking (100 ids per commit) —
    /// without it a single 1000-id ack frame is one enormous transaction.
    @Test func liveUploadBehindOwnCatchUpAckBacklog() async throws {
        let n = Int(ProcessInfo.processInfo.environment["FORENSIC_N"] ?? "") ?? 4_000
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self])
        defer { Task { [harness] in await harness.shutdown() } }

        let seededCount = try seedSummary(harness.channelFileURL, count: n).count
        print("FORENSIC seeded \(seededCount) audit entries")

        // A redials with an empty store: full catch-up, acks every page.
        let a = ForensicClient(label: "A-redial", autoAck: true)
        try await harness.connect(a)

        // The user types the moment the page paints — well before catch-up drains.
        _ = await poll(timeout: 60) { a.pages >= 2 }
        let pagesAtUpload = a.pages
        let upload = try makeUploadEntries(donorPath: "donor-redial-\(String.random(length: 8)).sqlite", value: 7)
        let uploadId = try #require(upload.first?.globalId)
        let payload = Array(buffer: try frame(upload))

        let t0 = DispatchTime.now()
        try await a.socket!.send(payload)
        let acked = await poll(timeout: 120) { a.ackTime(for: uploadId) != nil }
        let latencyMs = a.ackTime(for: uploadId).map {
            Double($0.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
        }
        _ = await poll(timeout: 120) { a.entries >= seededCount }

        print("""
        FORENSIC own-backlog: seeded=\(seededCount) pages_at_upload=\(pagesAtUpload) \
        a_pages=\(a.pages) a_entries=\(a.entries) \
        a_upload_visible_ms=\(latencyMs.map { String(format: "%.0f", $0) } ?? "NEVER") \
        acked=\(acked) nacks=\(a.nacks.count)
        """)

        #expect(acked, "A's upload was never applied server-side")
        #expect(a.nacks.isEmpty, "an ack backlog is a queue, not a failure")
    }

    /// NEGATIVE RESULT (kept as a regression guard). An entry naming a table
    /// the relay's schema does not have is NOT a silent drop: the core
    /// recognises it as schema drift and acks it as an inapplicable no-op, and
    /// the rest of the frame applies and acks normally. Schema drift is
    /// therefore NOT the incident's mechanism — and because the core ACKS the
    /// drifted entry, the 1.7.1 shortfall diff sees no shortfall and nacks
    /// nothing.
    @Test func unknownTableEntryIsAckedAsNoOpNotDropped() async throws {
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self])

        // Peer observes the fan-out; it must not ack (we want raw arrivals).
        let peer = ForensicClient(label: "peer", autoAck: false)
        try await harness.connect(peer)

        let uploader = ForensicClient(label: "uploader", autoAck: false)
        try await harness.connect(uploader)

        // Warm the uploader so we know its pipeline acks a healthy frame.
        let warm = try makeUploadEntries(donorPath: "donor-pw-\(String.random(length: 8)).sqlite", value: -1)
        let warmId = try #require(warm.first?.globalId)
        try await uploader.socket!.send(Array(buffer: try frame(warm)))
        try #require(await poll(timeout: 60) { uploader.ackTime(for: warmId) != nil },
                     "warmup frame was not acked — harness is wrong, not the relay")

        let good = try makeUploadEntries(donorPath: "donor-poison-\(String.random(length: 8)).sqlite", count: 60)
        try #require(good.count == 60)
        let goodIds = good.compactMap(\.globalId)
        let built = try poisonedFrame(good, poisonTable: "GhostTable")
        let peerPagesBefore = peer.pages

        try await uploader.socket!.send(built.bytes)

        _ = await poll(timeout: 30) { uploader.ackFrames > 1 }
        let ackedAny = goodIds.contains { uploader.ackTime(for: $0) != nil }
        let fannedOut = await poll(timeout: 15) { peer.pages > peerPagesBefore }

        print("""
        FORENSIC poison-frame: good=\(good.count) \
        acked_any_good=\(ackedAny) ack_frames=\(uploader.ackFrames) \
        nacks=\(uploader.nacks.count) fanned_out_to_peer=\(fannedOut)
        """)

        #expect(ackedAny, "schema-drift entries must not poison the rest of the frame")
        #expect(uploader.rejected.isEmpty)
        #expect(uploader.nacks.isEmpty, "the core acks a drifted entry as a no-op — no shortfall to nack")
        #expect(fannedOut, "a fully-applied frame still fans out to peers")

        await harness.shutdown_keepingStorage()
        let counts = try rowCount(inChannelFile: harness.channelFileURL)
        print("FORENSIC poison-frame server state: rows=\(counts.rows) auditEntries=\(counts.audit)")
        #expect(counts.rows == 61, "1 warmup + 60 good rows applied; the drifted entry stores nothing")
        try? FileManager.default.removeItem(at: harness.storageURL)
    }

    // MARK: - (3) The real mechanism, now fail-fast + nack

    /// THE REAL MECHANISM, fixed. A genuinely contended write lock (held by
    /// ANOTHER PROCESS) used to park the relay's `BEGIN IMMEDIATE` for the
    /// full 30s budget, twice, and then return EMPTY without throwing: no ack,
    /// no nack, no log line.
    ///
    /// Post-1.7.1 the budget is 2s, so one apply resolves in ~4s (BEGIN +
    /// the core's contained chunk retry), the Swift-side retry ladder stops at
    /// its wall-clock budget, and the client gets an explicit nack naming the
    /// entry — WHILE THE LOCK IS STILL HELD. Nothing is fanned out, and
    /// nothing is silently applied later.
    @Test func contendedApplyNacksPromptlyInsteadOfParking() async throws {
        let holdSeconds = Double(ProcessInfo.processInfo.environment["FORENSIC_HOLD_S"] ?? "") ?? 12
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self])

        let peer = ForensicClient(label: "peer", autoAck: false)
        try await harness.connect(peer)
        let uploader = ForensicClient(label: "uploader", autoAck: false)
        try await harness.connect(uploader)

        // Prove the pipeline acks a healthy frame first.
        let warm = try makeUploadEntries(donorPath: "donor-lockwarm-\(String.random(length: 8)).sqlite", value: -1)
        let warmId = try #require(warm.first?.globalId)
        try await uploader.socket!.send(Array(buffer: try frame(warm)))
        try #require(await poll(timeout: 60) { uploader.ackTime(for: warmId) != nil },
                     "warmup frame was not acked — harness is wrong, not the relay")

        // Another process takes the write lock and holds it.
        let lock = try ExternalWriteLock(path: harness.channelFileURL.path)
        try #require(await lock.waitUntilHeld(timeout: 30), "external lock never engaged")
        // Deadline release, so a regression can't hang the suite.
        let deadlineRelease = Task { [lock] in
            try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1e9))
            lock.release()
        }

        let upload = try makeUploadEntries(donorPath: "donor-locked-\(String.random(length: 8)).sqlite", value: 99)
        let uploadId = try #require(upload.first?.globalId)
        let peerPagesBefore = peer.pages
        let t0 = DispatchTime.now()
        try await uploader.socket!.send(Array(buffer: try frame(upload)))

        // The headline: an answer arrives while the lock is STILL HELD.
        let nacked = await poll(timeout: holdSeconds) { uploader.nackTime(for: uploadId) != nil }
        let nackMs = uploader.nackTime(for: uploadId).map {
            Double($0.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
        }
        let ackedWhileLocked = uploader.ackTime(for: uploadId) != nil
        lock.release()
        deadlineRelease.cancel()

        // Nothing may be applied after the fact either: the relay dropped the
        // frame deliberately and told the client to resend it.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let ackedEventually = uploader.ackTime(for: uploadId) != nil
        let fannedOut = await poll(timeout: 3) { peer.pages > peerPagesBefore }

        print("""
        FORENSIC lock-contention: hold_s=\(holdSeconds) nacked=\(nacked) \
        nack_ms=\(nackMs.map { String(format: "%.0f", $0) } ?? "NEVER") \
        acked_while_locked=\(ackedWhileLocked) acked_eventually=\(ackedEventually) \
        nacks=\(uploader.nacks.count) fanned_out_to_peer=\(fannedOut) \
        reason=\(uploader.nacks.first ?? "-")
        """)

        #expect(nacked, "a contended apply must answer with a nack, not silence")
        #expect(nackMs ?? .infinity < 9_000,
                Comment(rawValue: "the nack took \(nackMs.map { String(format: "%.0f", $0) } ?? "NEVER")ms — "
                + "the relay is parking again instead of failing fast"))
        #expect(!ackedWhileLocked, "nothing can be acked while the write lock is held elsewhere")
        #expect(!ackedEventually, "a nacked frame is dropped, not applied behind the client's back")
        #expect(!fannedOut, "a frame the relay could not store must never reach a peer")
        #expect(uploader.nacks.first?.contains("SQLITE") == true
                || uploader.nacks.first?.contains("no-throw-shortfall") == true,
                "the nack must name the SQLite classification: \(uploader.nacks.first ?? "-")")

        await harness.shutdown_keepingStorage()
        let counts = try rowCount(inChannelFile: harness.channelFileURL)
        print("FORENSIC lock-contention server state: rows=\(counts.rows)")
        #expect(counts.rows == 1, "only the warmup row is durable; the nacked upload is not")
        try? FileManager.default.removeItem(at: harness.storageURL)
    }

    // MARK: - (4) Retry ladder — deterministic

    /// Transient failures are RETRIED, not dropped: the first two attempts
    /// fail, the third applies, and the client sees a plain ack with no nack.
    /// (Real contention needs a foreign process holding a lock for seconds;
    /// the fault box makes the ladder deterministic — same technique as
    /// `_catchUpFaultForTesting`.)
    @Test func transientApplyFailureIsRetriedAndAcked() async throws {
        let channelId = "forensics-retry-\(String.random(length: 8))"
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self],
                                                      channelId: channelId)
        defer { Task { [harness] in await harness.shutdown() } }
        let attempts = LockedBox(0)
        _applyFaultForTesting.withLockedValue { box in
            box = { channel, attempt in
                guard channel == channelId else { return }
                attempts.withLock { $0 = max($0, attempt) }
                if attempt <= 2 {
                    throw LatticeError.syncReceiveFailed(
                        "Failed to begin transaction: database is locked")
                }
            }
        }
        defer { _applyFaultForTesting.withLockedValue { $0 = nil } }

        let client = ForensicClient(label: "retry", autoAck: false)
        try await harness.connect(client)
        let upload = try makeUploadEntries(donorPath: "donor-retry-\(String.random(length: 8)).sqlite", value: 5)
        let uploadId = try #require(upload.first?.globalId)
        try await client.socket!.send(Array(buffer: try frame(upload)))

        let acked = await poll(timeout: 60) { client.ackTime(for: uploadId) != nil }
        print("FORENSIC retry-ladder: acked=\(acked) attempts=\(attempts.withLock { $0 }) nacks=\(client.nacks.count)")
        #expect(acked, "a transient failure must be retried, not dropped")
        #expect(attempts.withLock { $0 } == 3, "the third attempt should be the one that applies")
        #expect(client.nacks.isEmpty, "a recovered apply must not nack")
    }

    /// Retry EXHAUSTION: every attempt fails, so the relay stops after
    /// `maxAttempts`, nacks the exact globalIds it could not store, sends no
    /// ack, and fans nothing out.
    @Test func retryExhaustionNacksTheUnappliedIds() async throws {
        let channelId = "forensics-exhaust-\(String.random(length: 8))"
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self],
                                                      channelId: channelId)
        let attempts = LockedBox(0)
        _applyFaultForTesting.withLockedValue { box in
            box = { channel, attempt in
                guard channel == channelId else { return }
                attempts.withLock { $0 = max($0, attempt) }
                throw LatticeError.syncReceiveFailed("Failed to begin transaction: database is locked")
            }
        }
        defer { _applyFaultForTesting.withLockedValue { $0 = nil } }

        let peer = ForensicClient(label: "peer", autoAck: false)
        try await harness.connect(peer)
        let client = ForensicClient(label: "exhaust", autoAck: false)
        try await harness.connect(client)

        let upload = try makeUploadEntries(donorPath: "donor-exhaust-\(String.random(length: 8)).sqlite", count: 3)
        let ids = upload.compactMap(\.globalId)
        try #require(ids.count == 3)
        let peerPagesBefore = peer.pages
        let t0 = DispatchTime.now()
        try await client.socket!.send(Array(buffer: try frame(upload)))

        let nacked = await poll(timeout: 30) { ids.allSatisfy { client.nackTime(for: $0) != nil } }
        let nackMs = client.nackTime(for: ids[0]).map {
            Double($0.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
        }
        let fannedOut = await poll(timeout: 3) { peer.pages > peerPagesBefore }

        print("""
        FORENSIC exhaustion: nacked=\(nacked) attempts=\(attempts.withLock { $0 }) \
        nack_ms=\(nackMs.map { String(format: "%.0f", $0) } ?? "NEVER") \
        acked=\(ids.contains { client.ackTime(for: $0) != nil }) fanned_out=\(fannedOut) \
        reason=\(client.nacks.first ?? "-")
        """)

        #expect(nacked, "every unapplied globalId must be named in the nack")
        #expect(attempts.withLock { $0 } == SyncRelayApplyPolicy.maxAttempts,
                "the ladder must run exactly \(SyncRelayApplyPolicy.maxAttempts) attempts")
        // 20 + 40 + 80 + 160 = 300ms of backoff, plus four no-op applies.
        #expect(nackMs ?? .infinity < 5_000, "the exhausted ladder must answer promptly")
        #expect(!ids.contains { client.ackTime(for: $0) != nil }, "nothing applied, so nothing acked")
        #expect(!fannedOut, "a frame that never applied must not reach a peer")

        await harness.shutdown_keepingStorage()
        let counts = try rowCount(inChannelFile: harness.channelFileURL)
        #expect(counts.rows == 0, "no row may exist for an exhausted apply")
        try? FileManager.default.removeItem(at: harness.storageURL)
    }

    // MARK: - (5) The nack wire contract

    /// The nack frame must round-trip in Swift AND be inert on clients that
    /// predate it: the C++ `server_sent_event::from_json` dispatches on the
    /// presence of `auditLog` / `ack` / `replayRequest` and returns nullopt
    /// otherwise, so a nack must carry NEITHER of those keys — a nack that
    /// looked like an ack would tell an old client its entries are durable.
    @Test func nackFrameIsWireCompatibleAndRoundTrips() throws {
        let ids = [UUID(), UUID()]
        let encoded = try JSONEncoder().encode(ServerSentEvent.nack(ids: ids, reason: "SQLITE_BUSY"))
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(root["kind"] as? String == "nack")
        #expect((root["nack"] as? [String])?.count == 2)
        #expect(root["nackReason"] as? String == "SQLITE_BUSY")
        #expect(root["ack"] == nil, "a nack must never decode as an ack on a legacy client")
        #expect(root["auditLog"] == nil, "a nack must never decode as an audit-log page")
        #expect(root["replayRequest"] == nil)

        let decoded = try JSONDecoder().decode(ServerSentEvent.self, from: encoded)
        guard case .nack(let decodedIds, let reason) = decoded else {
            Issue.record("nack did not round-trip: \(decoded)")
            return
        }
        #expect(decodedIds == ids)
        #expect(reason == "SQLITE_BUSY")
    }

    // MARK: - (6) Per-file serialization

    /// The gate itself: one key admits one holder at a time (FIFO), and two
    /// keys make progress concurrently — the property that keeps a busy
    /// channel from stalling every other channel in the process.
    @Test func fileApplyGateSerializesPerKeyAndKeepsKeysIndependent() async throws {
        let key = "/tmp/forensics-gate-\(String.random(length: 8)).sqlite"
        let inside = LockedBox(0)
        let peak = LockedBox(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await withApplyLock(key) {
                        let now = inside.withLock { $0 += 1; return $0 }
                        peak.withLock { $0 = max($0, now) }
                        Thread.sleep(forTimeInterval: 0.005)
                        inside.withLock { $0 -= 1 }
                    }
                }
            }
        }
        #expect(peak.withLock { $0 } == 1, "one apply slot per channel file")
        #expect(inside.withLock { $0 } == 0)
        #expect(await FileApplyGate.shared.isHeld(key) == false, "the slot must be released")
        #expect(await FileApplyGate.shared.queueDepth(forKey: key) == 0)

        // Independence: A holds key1 and waits for B to enter key2. If
        // different files shared a queue, B could never signal.
        let otherKey = key + ".other"
        let bEntered = LockedBox(false)
        async let a: Void = withApplyLock(key) {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && !bEntered.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await withApplyLock(otherKey) { bEntered.withLock { $0 = true } }
        await a
        #expect(bEntered.withLock { $0 }, "two channel files must apply concurrently")
    }

    /// End to end: many connections uploading at once on ONE channel file all
    /// land. Pre-fix these collided inside `begin_transaction` on the single
    /// shared connection they alias; now they queue.
    @Test func concurrentConnectionsOnOneFileAllApply() async throws {
        let harness = try await ForensicsRelayHarness(schema: [SimpleSyncObject.self])
        let clientCount = 6

        var clients: [ForensicClient] = []
        for i in 0..<clientCount {
            let c = ForensicClient(label: "c\(i)", autoAck: false)
            try await harness.connect(c)
            clients.append(c)
        }
        var uploads: [(ForensicClient, UUID, [UInt8])] = []
        for (i, c) in clients.enumerated() {
            let entries = try makeUploadEntries(
                donorPath: "donor-conc-\(String.random(length: 8)).sqlite", value: 100 + i)
            let id = try #require(entries.first?.globalId)
            uploads.append((c, id, Array(buffer: try frame(entries))))
        }

        // Fire them all at once.
        await withTaskGroup(of: Void.self) { group in
            for (client, _, payload) in uploads {
                group.addTask { try? await client.socket!.send(payload) }
            }
        }

        var acked = 0
        for (client, id, _) in uploads {
            if await poll(timeout: 60, { client.ackTime(for: id) != nil }) { acked += 1 }
        }
        let nacks = clients.reduce(0) { $0 + $1.nacks.count }
        print("FORENSIC concurrency: clients=\(clientCount) acked=\(acked) nacks=\(nacks)")
        #expect(acked == clientCount, "every concurrent upload must apply")
        #expect(nacks == 0, "serialized applies must not contend")

        await harness.shutdown_keepingStorage()
        let counts = try rowCount(inChannelFile: harness.channelFileURL)
        #expect(counts.rows == clientCount)
        try? FileManager.default.removeItem(at: harness.storageURL)
    }
}
