import Foundation
import Testing
import Vapor
import NIOCore
import NIOPosix
import NIOWebSocket
import Lattice
@testable import LatticeServerKit

// ============================================================================
// Observer push (1.7): live fan-out of committed changes to watch sockets via
// commit-notification → per-socket incremental catch-up ("nudge + pump").
//
// The harness mirrors the rooms topology: ONE Vapor app with TWO mounts over
// the SAME storage directory — a legacy writer mount (no observerPush,
// verbatim fan-out untouched) and a push-enabled watch mount — so channels
// with equal ids resolve to one shared database file. Clients are RAW
// WebSockets (deterministic control over the wire; no client engine timing).
//
// Reconcile ticks are DISABLED in every test: deliveries prove the push path
// (observer nudge → pump), not the safety-net poll.
// ============================================================================

/// Records everything a raw push client receives: frame kinds, the ordered
/// globalId sequence across every auditLog frame, per-globalId arrival
/// timestamps (for the latency bench), texts, and close state.
final class PushFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var binaryKinds: [String] = []
    private var entryGlobalIds: [String] = []
    private var arrival: [String: DispatchTime] = [:]
    private var texts: [String] = []
    private(set) var socket: WebSocket?

    var isClosed: Bool { socket?.isClosed ?? true }

    func attach(_ ws: WebSocket) {
        socket = ws
        ws.onBinary { [weak self] _, bb in
            guard let self else { return }
            let now = DispatchTime.now()
            let data = Data(buffer: bb)
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let kind = root?["kind"] as? String ?? "?"
            self.lock.lock()
            self.binaryKinds.append(kind)
            if kind == "auditLog", let entries = root?["auditLog"] as? [[String: Any]] {
                for entry in entries {
                    if let gid = entry["globalId"] as? String {
                        self.entryGlobalIds.append(gid.lowercased())
                        if self.arrival[gid.lowercased()] == nil {
                            self.arrival[gid.lowercased()] = now
                        }
                    }
                }
            }
            self.lock.unlock()
        }
        ws.onText { [weak self] _, text in
            guard let self else { return }
            self.lock.lock()
            self.texts.append(text)
            self.lock.unlock()
        }
    }

    var kinds: [String] { lock.withLock { binaryKinds } }
    /// Every auditLog entry received, in arrival order, as lowercase
    /// globalId strings — the ordering/exactly-once assertion surface.
    var receivedGlobalIds: [String] { lock.withLock { entryGlobalIds } }
    var receivedTexts: [String] { lock.withLock { texts } }
    func count(of kind: String) -> Int { kinds.filter { $0 == kind }.count }
    func arrivalTime(of globalId: String) -> DispatchTime? {
        lock.withLock { arrival[globalId.lowercased()] }
    }

    /// Awaits until `predicate` over this collector holds, or timeout.
    func wait(timeout: TimeInterval = 10, until predicate: @escaping @Sendable (PushFrameCollector) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(self) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate(self)
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock(); defer { unlock() }
        return body()
    }
}

@Sendable private func pushGroupExtractor(_ req: Request) async throws -> SyncChannel {
    guard let gid = req.parameters.get("groupID"),
          let raw = req.headers.first(name: "X-Test-User"),
          let uid = UUID(uuidString: raw) else { throw Abort(.unauthorized) }
    return SyncChannel(id: "group-\(gid)", userId: uid)
}

/// One app, two mounts, one storage dir — the rooms topology in miniature.
final class PushHarness: @unchecked Sendable {
    let app: Application
    let storageURL: URL
    let port: Int
    /// Legacy mount: verbatim same-channel fan-out, no push.
    let writerHandle: SyncRelayHandle
    /// Push-enabled watch mount over the same channel files.
    let watchHandle: SyncRelayHandle

    init(push: SyncObserverPush = SyncObserverPush(reconcileInterval: nil)) async throws {
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "push-harness-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        writerHandle = Lattice.configureSyncRelay(
            on: app.routes, path: ["writer", "group", ":groupID"],
            for: [SimpleSyncObject.self], storageURL: storageURL,
            channelExtractor: pushGroupExtractor)
        watchHandle = Lattice.configureSyncRelay(
            on: app.routes, path: ["watch", "group", ":groupID"],
            for: [SimpleSyncObject.self], storageURL: storageURL,
            observerPush: push,
            channelExtractor: pushGroupExtractor)
        try await app.startup()
        guard let assigned = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "no port")
        }
        port = assigned
    }

    func connect(pathSuffix: String, user: UUID,
                 on group: EventLoopGroup? = nil) async throws -> PushFrameCollector {
        let collector = PushFrameCollector()
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-User", value: user.uuidString)
        // A 1000-entry catch-up page blows past WebSocketKit's 16KB default
        // client maxFrameSize — raise it (same as BenchRelayHarness).
        var config = WebSocketClient.Configuration()
        config.maxFrameSize = 1 << 27
        let once = AtomicOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            WebSocket.connect(
                to: "ws://127.0.0.1:\(port)/\(pathSuffix)",
                headers: headers,
                configuration: config,
                on: group ?? app.eventLoopGroup
            ) { ws in
                collector.attach(ws)
                if once.tryFire() { cont.resume() }
            }.whenFailure { error in
                if once.tryFire() { cont.resume(throwing: error) }
            }
        }
        return collector
    }

    /// The channel database file both mounts resolve for `group-<gid>`.
    func channelFile(_ gid: String) -> URL {
        storageURL.appending(path: "group-\(gid).sqlite")
    }

    /// Opens a plain in-process co-writer Lattice directly on the channel
    /// file — the projector stand-in: NO socket, NO mount, no wire frame to
    /// tee. Creates the storage dir when the relay hasn't yet.
    func coWriter(_ gid: String) throws -> Lattice {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        return try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: channelFile(gid)))
    }

    func shutdown() async {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: storageURL)
    }
}

/// Wire-true upload frame (what a syncing client sends on a writer socket).
private func makePushFrame(entries: [AuditLog]) throws -> [UInt8] {
    Array(try JSONEncoder().encode(ServerSentEvent.auditLog(entries)))
}

@Suite("Observer Push", .timeLimit(.minutes(5)))
final class ObserverPushTests: BaseTest {

    private func donorEntries(_ body: (Lattice) throws -> Void) throws -> [AuditLog] {
        let donor = try testLattice(SimpleSyncObject.self)
        try body(donor)
        return Array(donor.eventsAfter(globalId: nil))
    }

    private func gids(_ entries: [AuditLog]) -> [String] {
        entries.compactMap { $0.globalId?.uuidString.lowercased() }
    }

    // MARK: (a) writer-socket frame → watch socket, live, no redial

    /// Two mounts, one file: a frame uploaded on the WRITER mount reaches a
    /// watch-mount observer as a pushed `ServerSentEvent.auditLog` frame on
    /// its ORIGINAL connection — ordered, exactly once, no redial.
    @Test func writerFrameReachesWatchSocketLive() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        let watcher = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        let writer = try await harness.connect(pathSuffix: "writer/group/g1", user: UUID())

        let entries = try donorEntries { donor in
            try donor.add(SimpleSyncObject(value: 1, floatValue: 1))
            try donor.add(SimpleSyncObject(value: 2, floatValue: 2))
            try donor.add(SimpleSyncObject(value: 3, floatValue: 3))
        }
        let expected = gids(entries)
        #expect(!expected.isEmpty)
        try await writer.socket!.send(try makePushFrame(entries: entries))

        #expect(await watcher.wait { $0.receivedGlobalIds.count >= expected.count })
        #expect(watcher.receivedGlobalIds == expected)
        #expect(!watcher.isClosed)   // same connection — push, not redial
    }

    // MARK: (b) co-process writer (no socket) → watch socket

    /// The case the writer-frame tee is structurally incapable of serving —
    /// it pins the mechanism choice: a plain in-process Lattice (projector
    /// stand-in, no mount, no wire frame) commits directly to the channel
    /// file, and the watch socket receives the entries via push.
    @Test func coProcessWriterReachesWatchSocket() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        let watcher = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        let co = try harness.coWriter("g1")
        try co.add(SimpleSyncObject(value: 41, floatValue: 1))
        let expected = gids(Array(co.eventsAfter(globalId: nil)))
        #expect(expected.count == 1)

        #expect(await watcher.wait { $0.receivedGlobalIds.count >= 1 })
        #expect(watcher.receivedGlobalIds == expected)
    }

    // MARK: (c) dead socket doesn't stall peers

    /// One observer's transport dies abruptly mid-stream (its event-loop
    /// group is torn down under it); the healthy observer keeps receiving
    /// every subsequent commit, ordered and exactly once — pumps are
    /// per-socket and awaited sends throttle only their own subscription.
    @Test func deadSocketDoesNotStallPeers() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        let doomedGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let doomed = try await harness.connect(
            pathSuffix: "watch/group/g1", user: UUID(), on: doomedGroup)
        let healthy = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())

        let co = try harness.coWriter("g1")
        try co.add(SimpleSyncObject(value: 0, floatValue: 0))
        #expect(await doomed.wait { $0.receivedGlobalIds.count >= 1 })
        #expect(await healthy.wait { $0.receivedGlobalIds.count >= 1 })

        // Kill the doomed client's transport out from under the server.
        try await doomedGroup.shutdownGracefully()

        // A burst of individual commits after the death.
        for i in 1...50 {
            try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }
        let expected = gids(Array(co.eventsAfter(globalId: nil)))
        #expect(expected.count == 51)

        #expect(await healthy.wait(timeout: 20) { $0.receivedGlobalIds.count >= expected.count })
        #expect(healthy.receivedGlobalIds == expected)   // ordered, no dupes, no gaps
    }

    // MARK: (d) revoked socket receives nothing after revocation

    /// Revocation authority is the shared flag, checked before every pushed
    /// page — same authority as the apply path. After the kick, commits
    /// deliver to the surviving observer and NEVER to the kicked one.
    @Test func revokedSocketReceivesNothingAfterRevocation() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        let kickedUser = UUID()
        let kicked = try await harness.connect(pathSuffix: "watch/group/g1", user: kickedUser)
        let survivor = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())

        let co = try harness.coWriter("g1")
        try co.add(SimpleSyncObject(value: 1, floatValue: 1))
        #expect(await kicked.wait { $0.receivedGlobalIds.count >= 1 })
        #expect(await survivor.wait { $0.receivedGlobalIds.count >= 1 })
        let kickedCountAtRevocation = kicked.receivedGlobalIds.count

        await harness.watchHandle.disconnect(channelId: "group-g1", userId: kickedUser)

        for i in 2...10 {
            try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }
        let expected = gids(Array(co.eventsAfter(globalId: nil)))
        #expect(await survivor.wait(timeout: 20) { $0.receivedGlobalIds.count >= expected.count })
        #expect(survivor.receivedGlobalIds == expected)

        // The kicked observer saw NOTHING minted after its revocation.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(kicked.receivedGlobalIds.count == kickedCountAtRevocation)
    }

    // MARK: (e) cursor coherence: push + a subsequent catch-up dial compose

    /// Frames pushed on a live socket extend the client's applied cursor
    /// exactly like catch-up frames: a later redial with
    /// `last-event-id=<last pushed entry>` receives only the remainder —
    /// exactly-once and id-ordered across the push/catch-up boundary in
    /// both directions.
    @Test func pushAndCatchupComposeExactlyOnceAcrossRedial() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        // Session 1: live pushes.
        let first = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        let co = try harness.coWriter("g1")
        for i in 1...5 {
            try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }
        let firstBatch = gids(Array(co.eventsAfter(globalId: nil)))
        #expect(firstBatch.count == 5)
        #expect(await first.wait { $0.receivedGlobalIds.count >= 5 })
        #expect(first.receivedGlobalIds == firstBatch)
        let lastPushed = try #require(first.receivedGlobalIds.last)
        try await first.socket!.close(code: .goingAway)

        // Offline commits, then a redial from the pushed cursor.
        for i in 6...8 {
            try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }
        let all = gids(Array(co.eventsAfter(globalId: nil)))
        let remainder = Array(all.dropFirst(5))
        #expect(remainder.count == 3)

        let second = try await harness.connect(
            pathSuffix: "watch/group/g1?last-event-id=\(lastPushed)", user: UUID())
        #expect(await second.wait { $0.receivedGlobalIds.count >= remainder.count })
        // Catch-up delivered ONLY the remainder — nothing already pushed.
        #expect(second.receivedGlobalIds == remainder)

        // And the redialed socket is live: the next commit is pushed too.
        try co.add(SimpleSyncObject(value: 9, floatValue: 9))
        let final = gids(Array(co.eventsAfter(globalId: nil)))
        #expect(await second.wait { $0.receivedGlobalIds.count >= remainder.count + 1 })
        #expect(second.receivedGlobalIds == Array(final.dropFirst(5)))
        // Union across both sessions: every entry exactly once, in id order.
        #expect(first.receivedGlobalIds + second.receivedGlobalIds == final)
    }

    // MARK: catch-up ↔ push boundary under concurrent commits

    /// Pre-seeded log (multiple catch-up pages) + commits racing the
    /// catch-up: the parked subscription buffers nudges, activation's first
    /// pump reads strictly beyond the snapshot boundary — the union of
    /// catch-up and pushed frames is exactly-once and id-ordered.
    @Test func concurrentCommitsDuringCatchupDeliverExactlyOnce() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        let co = try harness.coWriter("g1")
        try co.transaction {
            for i in 0..<2500 {
                try co.add(SimpleSyncObject(value: i, floatValue: Float(i)))
            }
        }

        let watcher = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        // Race the catch-up (2500 entries = 3 pages) with live commits.
        for i in 0..<5 {
            try co.add(SimpleSyncObject(value: 10_000 + i, floatValue: 0))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let expected = gids(Array(co.eventsAfter(globalId: nil)))
        #expect(expected.count == 2505)
        #expect(await watcher.wait(timeout: 30) { $0.receivedGlobalIds.count >= expected.count })
        let received = watcher.receivedGlobalIds
        #expect(received.count == expected.count)          // no dupes, no gaps
        #expect(received == expected)                      // id-ordered
        #expect(Set(received).count == received.count)     // exactly-once
    }

    // MARK: push mount suppresses legacy same-channel fan-out

    /// On a push-enabled mount, a client frame (an observer's ack) is NOT
    /// echoed to same-channel peers — delivery is the pump's job, and the
    /// echo would be N² frames per commit under push.
    @Test func pushMountSuppressesLegacyAckFanOut() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }

        let a = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        let b = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())

        // Deliver one pushed frame to both so the pipeline is proven live.
        let co = try harness.coWriter("g1")
        try co.add(SimpleSyncObject(value: 1, floatValue: 1))
        #expect(await a.wait { $0.receivedGlobalIds.count >= 1 })
        #expect(await b.wait { $0.receivedGlobalIds.count >= 1 })
        let bKindsBefore = b.kinds.count

        // A acks (the only frame a deny-all observer ever uploads).
        let ack = try JSONEncoder().encode(ServerSentEvent.ack([UUID()]))
        try await a.socket!.send(raw: ack, opcode: .binary)

        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(b.kinds.count == bKindsBefore)   // no echo to the peer observer
        #expect(!a.isClosed)
    }

    // MARK: group teardown

    /// Last subscriber out tears the per-file watch group down (watcher
    /// Lattice released — no fd/instance accumulation across cycles); a
    /// later observer forms a fresh group over the same file and push still
    /// works.
    @Test func groupTeardownReleasesWatcherAndAllowsRejoin() async throws {
        let harness = try await PushHarness()
        defer { Task { [harness] in await harness.shutdown() } }
        let manager = try #require(harness.watchHandle.pushManager)

        let a = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        let b = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        #expect(await pollGroupCount(manager, equals: 1))

        try await a.socket!.close(code: .goingAway)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await manager.groupCount == 1)   // b still holds the group

        try await b.socket!.close(code: .goingAway)
        #expect(await pollGroupCount(manager, equals: 0))

        // Rejoin: fresh group over the same file, push still flows.
        let c = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
        #expect(await pollGroupCount(manager, equals: 1))
        let co = try harness.coWriter("g1")
        try co.add(SimpleSyncObject(value: 7, floatValue: 7))
        #expect(await c.wait { $0.receivedGlobalIds.count >= 1 })
    }

    private func pollGroupCount(_ manager: FileWatchManager, equals target: Int,
                                timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.groupCount == target { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await manager.groupCount == target
    }
}
