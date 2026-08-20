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
    /// SECOND push-enabled watch mount over the same channel files — the
    /// per-process manager must resolve both to ONE watch group per file.
    let watch2Handle: SyncRelayHandle

    init(push: SyncObserverPush = SyncObserverPush(reconcileInterval: nil)) async throws {
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "push-harness-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        // Awaited teardown (see `withPushHarness`) means we actually wait for
        // the graceful server stop — and these tests deliberately end with
        // observer sockets still open, which is exactly what the default 10s
        // shutdownTimeout waits out, once per test. Half a second is plenty
        // for a loopback close and keeps the awaited cleanup cheap.
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        writerHandle = Lattice.configureSyncRelay(
            on: app.routes, path: ["writer", "group", ":groupID"],
            for: [SimpleSyncObject.self], storageURL: storageURL,
            channelExtractor: pushGroupExtractor)
        watchHandle = Lattice.configureSyncRelay(
            on: app.routes, path: ["watch", "group", ":groupID"],
            for: [SimpleSyncObject.self], storageURL: storageURL,
            observerPush: push,
            channelExtractor: pushGroupExtractor)
        watch2Handle = Lattice.configureSyncRelay(
            on: app.routes, path: ["watch2", "group", ":groupID"],
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

/// Scoped harness: shutdown is AWAITED on every exit path, including a
/// thrown expectation.
///
/// The tests used to hold the harness with
/// `defer { Task { await harness.shutdown() } }` — fire-and-forget. The
/// process can (and under a full parallel `swift test` regularly does) tear
/// the test task down before that detached task ever runs its
/// `removeItem`, so every such test leaked its temp storage directory —
/// SQLite file, WAL and shm per channel — into the system temp dir, and
/// left the Vapor app's shutdown unordered against the next test's port
/// binding.
func withPushHarness(
    push: SyncObserverPush = SyncObserverPush(reconcileInterval: nil),
    _ body: (PushHarness) async throws -> Void
) async throws {
    let harness = try await PushHarness(push: push)
    do {
        try await body(harness)
    } catch {
        await harness.shutdown()
        throw error
    }
    await harness.shutdown()
}

/// Injected by `catchupFailureReleasesParkedSubscription` through the
/// relay's test-only catch-up fault hook.
private enum InjectedCatchUpFault: Error { case injected }

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
        try await withPushHarness { harness in
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
    }

    // MARK: (b) co-process writer (no socket) → watch socket

    /// The case the writer-frame tee is structurally incapable of serving —
    /// it pins the mechanism choice: a plain in-process Lattice (projector
    /// stand-in, no mount, no wire frame) commits directly to the channel
    /// file, and the watch socket receives the entries via push.
    @Test func coProcessWriterReachesWatchSocket() async throws {
        try await withPushHarness { harness in
            let watcher = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            let co = try harness.coWriter("g1")
            try co.add(SimpleSyncObject(value: 41, floatValue: 1))
            let expected = gids(Array(co.eventsAfter(globalId: nil)))
            #expect(expected.count == 1)

            #expect(await watcher.wait { $0.receivedGlobalIds.count >= 1 })
            #expect(watcher.receivedGlobalIds == expected)
        }
    }

    // MARK: (c) dead socket doesn't stall peers

    /// One observer's transport dies abruptly mid-stream (its event-loop
    /// group is torn down under it); the healthy observer keeps receiving
    /// every subsequent commit, ordered and exactly once — pumps are
    /// per-socket and awaited sends throttle only their own subscription.
    @Test func deadSocketDoesNotStallPeers() async throws {
        try await withPushHarness { harness in
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
    }

    // MARK: (d) revoked socket receives nothing after revocation

    /// Revocation authority is the shared flag, checked before every pushed
    /// page — same authority as the apply path. After the kick, commits
    /// deliver to the surviving observer and NEVER to the kicked one.
    @Test func revokedSocketReceivesNothingAfterRevocation() async throws {
        try await withPushHarness { harness in
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
    }

    // MARK: (e) cursor coherence: push + a subsequent catch-up dial compose

    /// Frames pushed on a live socket extend the client's applied cursor
    /// exactly like catch-up frames: a later redial with
    /// `last-event-id=<last pushed entry>` receives only the remainder —
    /// exactly-once and id-ordered across the push/catch-up boundary in
    /// both directions.
    @Test func pushAndCatchupComposeExactlyOnceAcrossRedial() async throws {
        try await withPushHarness { harness in
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
    }

    // MARK: catch-up ↔ push boundary under concurrent commits

    /// Pre-seeded log (multiple catch-up pages) + commits racing the
    /// catch-up: the parked subscription buffers nudges, activation's first
    /// pump reads strictly beyond the snapshot boundary — the union of
    /// catch-up and pushed frames is exactly-once and id-ordered.
    @Test func concurrentCommitsDuringCatchupDeliverExactlyOnce() async throws {
        try await withPushHarness { harness in
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
    }

    // MARK: push mount suppresses legacy same-channel fan-out

    /// On a push-enabled mount, a client frame (an observer's ack) is NOT
    /// echoed to same-channel peers — delivery is the pump's job, and the
    /// echo would be N² frames per commit under push.
    @Test func pushMountSuppressesLegacyAckFanOut() async throws {
        try await withPushHarness { harness in
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
    }

    // MARK: group teardown

    /// Last subscriber out tears the per-file watch group down (watcher
    /// Lattice released — no fd/instance accumulation across cycles); a
    /// later observer forms a fresh group over the same file and push still
    /// works. Observability is key-scoped (`hasGroup(forFile:)`) because
    /// the manager is process-wide and parallel suites hold their own
    /// groups.
    @Test func groupTeardownReleasesWatcherAndAllowsRejoin() async throws {
        try await withPushHarness { harness in
            let manager = try #require(harness.watchHandle.pushManager)
            let file = harness.channelFile("g1")

            let a = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            let b = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            #expect(await pollSubscriberCount(manager, file: file, equals: 2))

            try await a.socket!.close(code: .goingAway)
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(await manager.hasGroup(forFile: file))   // b still holds the group

            try await b.socket!.close(code: .goingAway)
            #expect(await pollHasGroup(manager, file: file, equals: false))

            // Rejoin: fresh group over the same file, push still flows.
            let c = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            #expect(await pollHasGroup(manager, file: file, equals: true))
            let co = try harness.coWriter("g1")
            try co.add(SimpleSyncObject(value: 7, floatValue: 7))
            #expect(await c.wait { $0.receivedGlobalIds.count >= 1 })
        }
    }

    // MARK: per-process manager: two push mounts, one file, ONE watcher

    /// The design invariant is one `FileWatchManager` per PROCESS, not per
    /// mount: two push-enabled mounts whose channels resolve to the same
    /// file must share one watch group — one watcher Lattice, one commit
    /// observer — proven here by both handles exposing the SAME manager
    /// instance and by both subscribers landing in the ONE group for the
    /// file (per-mount managers would each hold a 1-subscriber group).
    @Test func twoPushMountsOneFileShareOneWatcherGroup() async throws {
        try await withPushHarness { harness in
            let m1 = try #require(harness.watchHandle.pushManager)
            let m2 = try #require(harness.watch2Handle.pushManager)
            #expect(m1 === m2)   // process-wide, not per-mount

            let file = harness.channelFile("g1")
            let a = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            let b = try await harness.connect(pathSuffix: "watch2/group/g1", user: UUID())
            // Exactly one group holds BOTH mounts' subscribers.
            #expect(await pollSubscriberCount(m1, file: file, equals: 2))
            #expect(await m1.hasGroup(forFile: file))

            // One co-process commit reaches both mounts' sockets via that one
            // shared watcher.
            let co = try harness.coWriter("g1")
            try co.add(SimpleSyncObject(value: 11, floatValue: 11))
            let expected = gids(Array(co.eventsAfter(globalId: nil)))
            #expect(await a.wait { $0.receivedGlobalIds.count >= 1 })
            #expect(await b.wait { $0.receivedGlobalIds.count >= 1 })
            #expect(a.receivedGlobalIds == expected)
            #expect(b.receivedGlobalIds == expected)

            // Cross-mount teardown: the group survives either mount's socket
            // and dies with the last one.
            try await a.socket!.close(code: .goingAway)
            #expect(await pollSubscriberCount(m1, file: file, equals: 1))
            #expect(await m1.hasGroup(forFile: file))
            try await b.socket!.close(code: .goingAway)
            #expect(await pollHasGroup(m1, file: file, equals: false))
        }
    }

    // MARK: reconcile tick (safety net for missed cross-process wakeups)

    /// With the commit-notification path suppressed (test-only knob), the
    /// reconcile tick ALONE delivers within its interval — the recovery
    /// layer the design promises for the documented best-effort
    /// cross-process wakeup.
    ///
    /// Platform honesty: every writer in this suite is same-process (an
    /// in-process co-writer reaches the watcher through the core's instance
    /// registry, not the cross-process notifier), so the genuinely
    /// cross-process wakeup — Linux inotify on the sibling signal file,
    /// Darwin notify_post — is NOT exercised here, and the Linux CI leg
    /// runs this same in-process suite. What this test pins down is the
    /// recovery path that makes a missed wakeup an added-latency event
    /// rather than a lost-delivery event; the retained client redial is the
    /// outermost net (rollout §9).
    @Test func reconcileTickAloneDeliversWhenCommitObserverSuppressed() async throws {
        var push = SyncObserverPush(reconcileInterval: .milliseconds(250))
        push._suppressCommitObserverForTesting = true
        try await withPushHarness(push: push) { harness in
            let watcher = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            let co = try harness.coWriter("g1")

            // The first commit can race connect-time catch-up/activation (either
            // of which would deliver it without any nudge) — wait it out so the
            // NEXT commit is provably post-activation.
            try co.add(SimpleSyncObject(value: 1, floatValue: 1))
            #expect(await watcher.wait(timeout: 15) { $0.receivedGlobalIds.count >= 1 })

            // Post-activation commit: with the commit observer suppressed, the
            // ONLY thing that can deliver this is the reconcile tick.
            try co.add(SimpleSyncObject(value: 2, floatValue: 2))
            #expect(await watcher.wait(timeout: 15) { $0.receivedGlobalIds.count >= 2 })

            // Tick-driven delivery preserves the same ordering/exactly-once
            // guarantees (same pump, same cursor).
            let expected = gids(Array(co.eventsAfter(globalId: nil)))
            #expect(watcher.receivedGlobalIds == expected)
        }
    }

    // MARK: teardown/pump race stress (adversarial review, MAJOR)

    /// Subscribe/unsubscribe churn under a commit storm — the shape that
    /// makes last-subscriber teardown overlap in-flight pumps. Each wave
    /// joins `subscribersPerWave` observers, proves push is live on each,
    /// fires a 150-commit BURST, and — *while the burst is still
    /// committing* — mass-closes every socket, one of them by killing its
    /// transport out from under the server (so that wave's teardown is
    /// driven from INSIDE a pump's own send-failure path, not just from
    /// `onClose`). The last unsubscribe of every wave therefore tears the
    /// group down with pumps mid-pass, and the next wave rebuilds a fresh
    /// group over the same file.
    ///
    /// What this pins down: across 10 such teardown/rebuild cycles the
    /// relay never crashes, hangs, leaks a group, or loses/duplicates an
    /// entry — the post-churn subscriber receives the ENTIRE log, ordered
    /// and exactly once.
    ///
    /// Honest scope. This does NOT reproduce a nil-trap on the pre-fix
    /// (force-unwrapping) shape: it was run 3× against a locally restored
    /// pre-fix `maybePump`/`pump` and passed every time. The reason is that
    /// every reachable `unsubscribe` today follows a closed or revoked
    /// socket, and the pump re-checks `isClosed`/`isRevoked` immediately
    /// before each `watcher` read — so the cleared-box window is not
    /// reachable through the close path. The force-unwrap was a structural
    /// hazard (one future caller that unsubscribed a still-open socket, or
    /// one reordering of that guard, and it becomes a nil-trap /
    /// use-after-free), and the fix removes the hazard class rather than
    /// narrowing it: pumps take their own strong `WatcherRef` on the actor
    /// and there are ZERO force-unwraps left on the pump path. This test is
    /// the behavioral regression net around that churn, not a pre-fix
    /// reproducer.
    ///
    /// Deliberately BOUNDED (`waves × burstPerWave` commits, no unpaced
    /// writer loop): an unpaced loop mints hundreds of thousands of entries
    /// and hundreds of MB of temp DB, starving the rest of the suite
    /// without making the overlap any likelier — the overlap needs commits
    /// *concurrent with* teardown, not a high commit count.
    @Test(.timeLimit(.minutes(5))) func teardownRaceStressUnderCommitLoad() async throws {
        try await withPushHarness { harness in
            let manager = try #require(harness.watchHandle.pushManager)
            let file = harness.channelFile("g1")

            let waves = 10
            let subscribersPerWave = 4
            let burstPerWave = 150
            var minted = 0

            // Seed one entry so every wave's subscribers have something to
            // receive at connect time (an empty log delivers nothing, and the
            // waves would then prove nothing about the pump).
            let seed = try harness.coWriter("g1")
            try seed.add(SimpleSyncObject(value: -100, floatValue: 0))

            for _ in 0..<waves {
                // One socket per wave gets its own event-loop group so it can be
                // killed at the transport level mid-burst: that socket's pump
                // fails its awaited send and unsubscribes from INSIDE the pump,
                // which is the teardown path that overlaps pump execution most
                // tightly.
                let doomedGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                var wave: [PushFrameCollector] = []
                wave.append(try await harness.connect(
                    pathSuffix: "watch/group/g1", user: UUID(), on: doomedGroup))
                for _ in 1..<subscribersPerWave {
                    wave.append(try await harness.connect(pathSuffix: "watch/group/g1", user: UUID()))
                }
                // Prove every subscriber is activated (cursor installed, pump
                // path live) before the churn — a parked subscription would not
                // exercise the pump at all.
                for collector in wave {
                    #expect(await collector.wait(timeout: 30) { $0.receivedGlobalIds.count >= 1 })
                }

                // Commit storm on its own thread; do NOT await it before closing.
                let burst = Task.detached { [harness] () -> Int in
                    guard let co = try? harness.coWriter("g1") else { return 0 }
                    var n = 0
                    for i in 0..<burstPerWave {
                        if (try? co.add(SimpleSyncObject(value: i, floatValue: 0))) != nil { n += 1 }
                    }
                    return n
                }
                // Let the storm get going, then mass-close DURING it: the last
                // unsubscribe tears the group down while the other sockets'
                // pumps are still paging/sending against the watcher.
                try? await Task.sleep(nanoseconds: 5_000_000)
                try? await doomedGroup.shutdownGracefully()
                for collector in wave.dropFirst() {
                    try? await collector.socket?.close(code: .goingAway)
                }
                minted += await burst.value
                // Let the teardown fully land before the next wave rebuilds the
                // group over the same file.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            // The storm really ran. Not an equality: under full-suite parallel
            // load a burst `add` can lose a busy-timeout race, and a dropped
            // COMMIT is not what this test is about — delivery integrity of
            // whatever did commit is. The floor keeps a silently no-op storm
            // from passing.
            #expect(minted >= waves * burstPerWave * 9 / 10)

            // The system survived the churn: the group tore down cleanly and a
            // fresh subscriber still gets live push over the same file.
            #expect(await pollHasGroup(manager, file: file, equals: false))
            let after = try await harness.connect(pathSuffix: "watch/group/g1", user: UUID())
            let co = try harness.coWriter("g1")
            try co.add(SimpleSyncObject(value: -1, floatValue: -1))
            // Full-log integrity end to end: the post-churn subscriber receives
            // every entry the churn actually committed — ordered, exactly once.
            let expected = gids(Array(co.eventsAfter(globalId: nil)))
            #expect(expected.count >= minted + 1)
            #expect(await after.wait(timeout: 60) { $0.receivedGlobalIds.count >= expected.count })
            #expect(after.receivedGlobalIds == expected)
        }
    }

    // MARK: connect-time catch-up failure releases the subscription (NIT)

    /// A throw during connect-time catch-up must not strand the parked push
    /// subscription.
    ///
    /// Pre-fix, the catch block only logged: the subscription stayed in the
    /// group with no cursor (so it could never be pumped) and was never
    /// unsubscribed, and the socket was left OPEN — so `onClose` never ran
    /// either, and the client, seeing a healthy connection, never redialed.
    /// One such connection therefore pinned the file's watch group, and its
    /// watcher `Lattice`, for the process lifetime.
    ///
    /// The fault is injected through the relay's test-only hook because the
    /// path is otherwise unreachable from a test: the only throwing calls in
    /// catch-up are the JSON encode and the query read, neither of which a
    /// client can make fail on demand. It is scoped to THIS test's channel
    /// (the hook is process-global and suites run in parallel) and installed
    /// only after the healthy subscriber is past the fault site, which sits
    /// before the first frame this socket is sent.
    @Test func catchupFailureReleasesParkedSubscription() async throws {
        try await withPushHarness { harness in
            let manager = try #require(harness.watchHandle.pushManager)
            let file = harness.channelFile("gfail")
            let co = try harness.coWriter("gfail")
            try co.add(SimpleSyncObject(value: 1, floatValue: 1))

            // A healthy subscriber owns the group first, so the assertions
            // below are about the FAILED connection's subscription, not
            // about whether a group ever existed.
            let healthy = try await harness.connect(pathSuffix: "watch/group/gfail", user: UUID())
            #expect(await healthy.wait { $0.receivedGlobalIds.count >= 1 })
            #expect(await pollSubscriberCount(manager, file: file, equals: 1))

            _catchUpFaultForTesting.withLockedValue { $0 = { channelId in
                if channelId == "group-gfail" { throw InjectedCatchUpFault.injected }
            } }
            defer { _catchUpFaultForTesting.withLockedValue { $0 = nil } }

            // The failed connection is closed by the error path (the relay
            // unsubscribes BEFORE closing, so observing the close means the
            // release already happened) — and the client can redial, which
            // it never could while the socket stayed open.
            let doomed = try await harness.connect(pathSuffix: "watch/group/gfail", user: UUID())
            #expect(await doomed.wait { $0.isClosed })
            #expect(doomed.receivedGlobalIds.isEmpty)
            #expect(await pollSubscriberCount(manager, file: file, equals: 1))

            // The decisive one: with the failed connection's subscription
            // released, the LAST healthy socket leaving tears the group
            // down. Pre-fix the stranded parked subscription kept
            // `subscribers` non-empty, so the group — and the watcher
            // Lattice it holds — outlived every real observer.
            try await healthy.socket!.close(code: .goingAway)
            #expect(await pollHasGroup(manager, file: file, equals: false))
        }
    }

    // MARK: concurrent first subscribers share ONE watcher open (MINOR)

    /// The watcher open runs OFF the manager actor, which introduces a
    /// suspension point between "no group for this key" and "group
    /// installed". Concurrent first subscribers must dedupe onto that one
    /// in-flight open instead of each starting their own: the design's
    /// one-watcher-Lattice-plus-one-commit-observer-per-file invariant is
    /// what keeps two push mounts over a file from doubling fds, observers
    /// and pumped work.
    ///
    /// Six sockets are dialed concurrently across BOTH push mounts, so
    /// several land in the empty-group window together. The assertions hold
    /// however the scheduler interleaves them (a fully serialized run simply
    /// takes the `groups[key]` fast path), so this is a dedupe pin, not a
    /// timing gamble.
    @Test func concurrentFirstSubscribersShareOneWatcherOpen() async throws {
        try await withPushHarness { harness in
            let manager = try #require(harness.watchHandle.pushManager)
            let file = harness.channelFile("gopen")

            let collectors = try await withThrowingTaskGroup(
                of: PushFrameCollector.self
            ) { group -> [PushFrameCollector] in
                for i in 0..<6 {
                    let mount = i % 2 == 0 ? "watch" : "watch2"
                    group.addTask {
                        try await harness.connect(pathSuffix: "\(mount)/group/gopen", user: UUID())
                    }
                }
                var all: [PushFrameCollector] = []
                for try await collector in group { all.append(collector) }
                return all
            }
            #expect(collectors.count == 6)
            #expect(await pollSubscriberCount(manager, file: file, equals: 6))
            // ONE open for the six racing subscribers — the dedupe.
            #expect(await manager.watcherOpenCount(forFile: file) == 1)

            // And the one shared watcher serves all six: a single
            // co-process commit reaches every socket.
            let co = try harness.coWriter("gopen")
            try co.add(SimpleSyncObject(value: 3, floatValue: 3))
            let expected = gids(Array(co.eventsAfter(globalId: nil)))
            for collector in collectors {
                #expect(await collector.wait(timeout: 20) { $0.receivedGlobalIds.count >= 1 })
                #expect(collector.receivedGlobalIds == expected)
            }
        }
    }

    // MARK: polling helpers (key-scoped: the manager is process-wide)

    private func pollHasGroup(_ manager: FileWatchManager, file: URL, equals target: Bool,
                              timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.hasGroup(forFile: file) == target { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await manager.hasGroup(forFile: file) == target
    }

    private func pollSubscriberCount(_ manager: FileWatchManager, file: URL, equals target: Int,
                                     timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.subscriberCount(forFile: file) == target { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await manager.subscriberCount(forFile: file) == target
    }
}
