import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Vapor

/// Regression tests for the WSS URL-change handover scenario.
///
/// Background: each `lattice_db` opened with a `wssEndpoint` competes for an
/// `flock` on `<path>.sync.lock`. Pre-fix, when two in-process Lattices on the
/// same path opened with *different* URLs, the second one silently lost the
/// flock and ran with no synchronizer — for the lifetime of the first Lattice.
/// When the first Lattice closed, its sibling-handoff block iterated for an
/// instance with the SAME URL and (if it found a dormant ghost on the old URL)
/// resurrected sync against the now-stale URL.
///
/// Post-fix, `setup_sync_if_configured` recognizes a same-process sibling on a
/// different URL as a URL-change scenario and kicks the sibling out instead.
/// `teardown_sync(fire_handoff: false)` is called from the kick path so the
/// kicked sibling doesn't immediately resurrect another same-URL ghost.
///
/// All synchronization waits use observer-based primitives (`onSyncStateChange`,
/// `changeStream`) — no polls, no sleeps, per project convention.
@Suite("URLChange Sync Tests")
actor URLChangeSyncTests {
    let appA: Application
    let appB: Application
    let sharedPath = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let serverPathA = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let serverPathB = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var portA: Int = 0
    var portB: Int = 0
    private let socketsA = SocketStore(label: "URLChangeA")
    private let socketsB = SocketStore(label: "URLChangeB")
    private let serverConfigA: Lattice.Configuration
    private let serverConfigB: Lattice.Configuration

    enum URLChangeError: Error { case noPort }

    deinit {
        appA.shutdown()
        appB.shutdown()
        try? FileManager.default.removeItem(at: sharedPath)
        try? FileManager.default.removeItem(at: serverPathA)
        try? FileManager.default.removeItem(at: serverPathB)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.appA = try await Application.make(env)
        self.appB = try await Application.make(env)
        appA.http.server.configuration.port = 0
        appB.http.server.configuration.port = 0

        self.serverConfigA = .init(fileURL: serverPathA)
        self.serverConfigB = .init(fileURL: serverPathB)

        // Pre-create server-side lattices so the WS handlers can reopen them
        // off-EventLoop without races.
        _ = try Lattice(for: [SimpleSyncObject.self], configuration: serverConfigA)
        _ = try Lattice(for: [SimpleSyncObject.self], configuration: serverConfigB)

        try await Self.installRelay(on: appA, configuration: serverConfigA, sockets: socketsA)
        try await Self.installRelay(on: appB, configuration: serverConfigB, sockets: socketsB)
        try await appA.startup()
        try await appB.startup()

        guard let pA = appA.http.server.shared.localAddress?.port else { throw URLChangeError.noPort }
        guard let pB = appB.http.server.shared.localAddress?.port else { throw URLChangeError.noPort }
        self.portA = pA
        self.portB = pB
    }

    private static func installRelay(
        on app: Application,
        configuration: Lattice.Configuration,
        sockets: SocketStore
    ) async throws {
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else { return }
                if kind == "auditLog" {
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    for socket in sockets.others(excluding: ws) { socket.send(bb) }
                }
                Task.detached {
                    let lattice = try Lattice(configuration: configuration)
                    _ = try? lattice.receive(data)
                }
            }
            let lattice = try! Lattice(configuration: configuration)
            let events = lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let count = events.count
            for i in stride(from: 0, to: count, by: 1000) {
                let page = events[i..<min(count, i + 1000)]
                let encoded = try! JSONEncoder().encode(ServerSentEvent.auditLog(Array(page)))
                ws.send(ByteBuffer(data: encoded))
            }
        }
    }

    /// Wait for `lattice` to fire `onSyncStateChange(connected)` matching the
    /// requested boolean. Resolves immediately if `lattice.isSyncConnected`
    /// already matches the target — otherwise observes the next state change.
    private func waitForSyncState(_ lattice: Lattice, connected target: Bool) async {
        if lattice.isSyncConnected == target { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = AtomicOnce()
            lattice.onSyncStateChange { state in
                guard state == target else { return }
                if once.tryFire() { cont.resume() }
            }
        }
    }

    /// Open Lattice A on path P with URL_A. Open Lattice B on path P with
    /// URL_B. The kick path makes B take over: A's sync transitions to
    /// disconnected, B's transitions to connected. A write through B then
    /// reaches server B (the new URL); writes that pre-dated the open of B
    /// reach server A (the old URL) — confirming the kick happened only AT
    /// the moment of B's open.
    @Test(.timeLimit(.minutes(5)))
    func laterOpenWithDifferentURLTakesOverSync() async throws {
        let urlA = URL(string: "http://localhost:\(portA)/test")!
        let urlB = URL(string: "http://localhost:\(portB)/test")!

        let configA = Lattice.Configuration(
            fileURL: sharedPath,
            authorizationToken: "tokenA",
            wssEndpoint: urlA)
        let configB = Lattice.Configuration(
            fileURL: sharedPath,
            authorizationToken: "tokenB",
            wssEndpoint: urlB)

        // Open A; wait for connect.
        let latticeA = try Lattice(SimpleSyncObject.self, configuration: configA)
        await waitForSyncState(latticeA, connected: true)
        #expect(latticeA.isSyncConnected, "A should be connected after open")

        // Pre-kick write: lands on server A.
        let preKickValue = 100
        let preKickArrived: Task<Void, any Error> = Task.detached {
            let serverLattice = try Lattice(for: [SimpleSyncObject.self],
                                            configuration: self.serverConfigA)
            for await changes in serverLattice.changeStream {
                let resolved = changes.compactMap { $0.resolve(isolation: nil, on: serverLattice) }
                let touched = resolved.contains { $0.tableName == "SimpleSyncObject" }
                if touched, serverLattice.objects(SimpleSyncObject.self)
                    .first(where: { $0.value == preKickValue }) != nil { break }
            }
        }
        latticeA.add(SimpleSyncObject(value: preKickValue, floatValue: 1.0))
        try await preKickArrived.value

        // Open B with a different URL on the same path. The fix kicks A
        // synchronously inside B's `setup_sync_if_configured` —
        // `victim->teardown_sync(false)` resets A's `synchronizer_` unique_ptr
        // before B's constructor returns. We wait only for B's connect; A's
        // state-change callback won't fire (the C++ handler is destroyed
        // along with the synchronizer), but `isSyncConnected` reads false
        // because `synchronizer_ == nullptr`.
        let latticeB = try Lattice(SimpleSyncObject.self, configuration: configB)
        await waitForSyncState(latticeB, connected: true)

        #expect(!latticeA.isSyncConnected, "A should be disconnected after kick")
        #expect(latticeB.isSyncConnected, "B should be connected after take-over")

        // Post-kick write: lands on server B (B's URL).
        let postKickValue = 7
        let postKickArrived: Task<Void, any Error> = Task.detached {
            let serverLattice = try Lattice(for: [SimpleSyncObject.self],
                                            configuration: self.serverConfigB)
            for await changes in serverLattice.changeStream {
                let resolved = changes.compactMap { $0.resolve(isolation: nil, on: serverLattice) }
                let touched = resolved.contains { $0.tableName == "SimpleSyncObject" }
                if touched, serverLattice.objects(SimpleSyncObject.self)
                    .first(where: { $0.value == postKickValue }) != nil { break }
            }
        }
        latticeB.add(SimpleSyncObject(value: postKickValue, floatValue: 7.0))
        try await postKickArrived.value

        // Server A should NOT have received the post-kick write.
        let serverA = try Lattice(for: [SimpleSyncObject.self], configuration: serverConfigA)
        #expect(serverA.objects(SimpleSyncObject.self)
            .first(where: { $0.value == postKickValue }) == nil,
                "Server A must not have received B's post-kick write")

        latticeA.close()
        latticeB.close()
    }

    /// Same-URL legitimate dormant-duplicate case: opening two Lattices on the
    /// same path with the SAME URL must NOT kick either of them. The first to
    /// acquire the flock owns sync; the second runs as a dormant duplicate.
    /// Behavior unchanged from pre-fix.
    @Test(.timeLimit(.minutes(5)))
    func sameURLDoesNotKick() async throws {
        let urlA = URL(string: "http://localhost:\(portA)/test")!
        let configA = Lattice.Configuration(
            fileURL: sharedPath,
            authorizationToken: "tokenA",
            wssEndpoint: urlA)

        let latticeA1 = try Lattice(SimpleSyncObject.self, configuration: configA)
        await waitForSyncState(latticeA1, connected: true)

        // Open a second Lattice with the same URL. A1 must keep sync; the
        // second opens as a dormant duplicate. To detect that A1 is NOT
        // kicked, race a "did A1 disconnect within a write round-trip" probe
        // against an actual successful write through A1.
        let latticeA2 = try Lattice(SimpleSyncObject.self, configuration: configA)
        let writeArrived: Task<Void, any Error> = Task.detached {
            let serverLattice = try Lattice(for: [SimpleSyncObject.self],
                                            configuration: self.serverConfigA)
            for await changes in serverLattice.changeStream {
                let resolved = changes.compactMap { $0.resolve(isolation: nil, on: serverLattice) }
                let touched = resolved.contains { $0.tableName == "SimpleSyncObject" }
                if touched, serverLattice.objects(SimpleSyncObject.self)
                    .first(where: { $0.value == 42 }) != nil { break }
            }
        }
        latticeA1.add(SimpleSyncObject(value: 42, floatValue: 4.2))
        try await writeArrived.value

        #expect(latticeA1.isSyncConnected, "A1 must NOT be kicked by same-URL A2")
        _ = latticeA2  // suppress unused warning — keep alive through the test

        latticeA1.close()
        latticeA2.close()
    }
}
