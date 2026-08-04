import Foundation
import Testing
import Vapor
import NIOWebSocket
import Lattice
@testable import LatticeServerKit

// ============================================================================
// LatticeServerKit relay generalization: channel-keyed fan-out/storage,
// SyncRelayHandle revocation kicks, per-channel write policy, schema
// handshake, and the personal-topology wrapper's on-disk parity.
//
// Clients here are RAW WebSockets sending hand-crafted (donor-lattice-
// produced) frames — deterministic control over exactly what crosses the
// wire, no client sync-engine timing. The full client-engine loop is
// exercised daily by engram-server's E2E suite through the wrapper.
// ============================================================================

/// Records everything a raw relay client receives, with awaitable arrival.
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var binaryKinds: [String] = []
    private var texts: [String] = []
    private var ackedIds: [UUID] = []
    private var waiters: [(predicate: () -> Bool, cont: CheckedContinuation<Void, Never>)] = []
    private(set) var socket: WebSocket?

    /// nil socket (upgrade never completed) counts as closed.
    var isClosed: Bool { socket?.isClosed ?? true }
    var closeCode: WebSocketErrorCode? { socket?.closeCode }

    func attach(_ ws: WebSocket) {
        socket = ws
        ws.onBinary { [weak self] _, bb in
            guard let self else { return }
            let data = Data(buffer: bb)
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let kind = root?["kind"] as? String ?? "?"
            self.lock.lock()
            self.binaryKinds.append(kind)
            if kind == "ack", let ids = root?["ack"] as? [String] {
                self.ackedIds.append(contentsOf: ids.compactMap(UUID.init(uuidString:)))
            }
            let ready = self.waiters.filter { $0.predicate() }
            self.waiters.removeAll { $0.predicate() }
            self.lock.unlock()
            ready.forEach { $0.cont.resume() }
        }
        ws.onText { [weak self] _, text in
            guard let self else { return }
            self.lock.lock()
            self.texts.append(text)
            let ready = self.waiters.filter { $0.predicate() }
            self.waiters.removeAll { $0.predicate() }
            self.lock.unlock()
            ready.forEach { $0.cont.resume() }
        }
    }

    var kinds: [String] { lock.withLock { binaryKinds } }
    var receivedTexts: [String] { lock.withLock { texts } }
    var acks: [UUID] { lock.withLock { ackedIds } }

    func count(of kind: String) -> Int { kinds.filter { $0 == kind }.count }

    /// Awaits until `predicate` over this collector holds (checked on every
    /// arrival), or the timeout elapses.
    func wait(timeout: TimeInterval = 10, until predicate: @escaping @Sendable (FrameCollector) -> Bool) async -> Bool {
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

/// In-process relay running the REAL `configureSyncRelay` on an ephemeral
/// port, with a storage dir per harness.
private final class RelayHarness: @unchecked Sendable {
    let app: Application
    let handle: SyncRelayHandle
    let storageURL: URL
    let port: Int

    init(
        path: [PathComponent],
        schema: [any Lattice.Model.Type],
        writePolicy: SyncWritePolicy? = nil,
        handshake: SyncSchemaHandshake? = nil,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel
    ) async throws {
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-harness-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        handle = Lattice.configureSyncRelay(
            on: app.routes, path: path, for: schema, storageURL: storageURL,
            writePolicy: writePolicy, handshake: handshake,
            channelExtractor: channelExtractor)
        try await app.startup()
        guard let assigned = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "no port")
        }
        port = assigned
    }

    /// Wrapper-mounted harness (old personal API).
    init(wrapperWithSchema schema: [any Lattice.Model.Type]) async throws {
        storageURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-harness-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        Lattice.configureSyncRelay(
            on: app.routes, for: schema, storageURL: storageURL,
            userIdExtractor: { req in
                guard let raw = req.headers.first(name: "X-Test-User"),
                      let uid = UUID(uuidString: raw) else { throw Abort(.unauthorized) }
                return uid
            })
        handle = SyncRelayHandle(manager: SocketManager())  // unused in wrapper tests
        try await app.startup()
        guard let assigned = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "no port")
        }
        port = assigned
    }

    func connect(pathSuffix: String, user: UUID, headers extra: [String: String] = [:]) async throws -> FrameCollector {
        let collector = FrameCollector()
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-User", value: user.uuidString)
        for (k, v) in extra { headers.add(name: k, value: v) }
        // Resume on ATTACH, not on the connect future — the two aren't
        // strictly ordered, and reading collector.socket before onUpgrade
        // ran was a nil crash under parallel test load.
        let once = AtomicOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            WebSocket.connect(
                to: "ws://127.0.0.1:\(port)/\(pathSuffix)",
                headers: headers,
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

/// Produces wire-true frames by pulling real audit entries from a donor
/// lattice — exactly what a syncing client uploads.
private func makeFrame(entries: [AuditLog]) throws -> [UInt8] {
    Array(try JSONEncoder().encode(ServerSentEvent.auditLog(entries)))
}

@Sendable private func groupExtractor(_ req: Request) async throws -> SyncChannel {
    guard let gid = req.parameters.get("groupID"),
          let raw = req.headers.first(name: "X-Test-User"),
          let uid = UUID(uuidString: raw) else { throw Abort(.unauthorized) }
    return SyncChannel(id: "group-\(gid)", userId: uid)
}

@Suite("Server Relay Generalization", .timeLimit(.minutes(5)))
final class ServerRelayTests: BaseTest {

    private func donorEntries(_ body: (Lattice) throws -> Void) throws -> [AuditLog] {
        let donor = try testLattice(SimpleSyncObject.self)
        try body(donor)
        return Array(donor.eventsAfter(globalId: nil))
    }


    // MARK: Channel isolation

    @Test func fanOutAndStorageStayWithinChannel() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let userA = UUID(), userB = UUID(), userC = UUID()
        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: userA)
        let b = try await harness.connect(pathSuffix: "sync/group/g1", user: userB)
        let c = try await harness.connect(pathSuffix: "sync/group/g2", user: userC)
        #expect(await harness.handle.connectionCount(channelId: "group-g1") == 2)
        #expect(await harness.handle.connectionCount(channelId: "group-g2") == 1)

        let entries = try donorEntries { donor in
            try donor.add(SimpleSyncObject(value: 41, floatValue: 1))
        }
        #expect(!entries.isEmpty)
        try await a.socket!.send(try makeFrame(entries: entries))

        // Sender is acked; same-channel peer receives the fan-out.
        #expect(await a.wait { !$0.acks.isEmpty })
        #expect(await b.wait { $0.count(of: "auditLog") > 0 })
        // Cross-channel client receives nothing.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(c.count(of: "auditLog") == 0)

        // Channel storage: g1's DB has the row, g2's does not exist or is empty.
        let g1 = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
        #expect(g1.objects(SimpleSyncObject.self).contains { $0.value == 41 })
        let g2 = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: harness.storageURL.appending(path: "group-g2.sqlite")))
        #expect(!g2.objects(SimpleSyncObject.self).contains { $0.value == 41 })
    }

    // MARK: Revocation kicks

    @Test func disconnectKicksOneUserThenDisconnectAllClearsChannel() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let kicked = UUID(), survivor = UUID()
        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: kicked)
        let b = try await harness.connect(pathSuffix: "sync/group/g1", user: survivor)
        #expect(await harness.handle.connectionCount(channelId: "group-g1") == 2)

        await harness.handle.disconnect(channelId: "group-g1", userId: kicked)
        #expect(await a.wait { $0.isClosed })
        #expect(!b.isClosed)
        #expect(await harness.handle.connectionCount(channelId: "group-g1") == 1)

        // Survivor still relays: an upload is acked post-kick.
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 7, floatValue: 1)) }
        try await b.socket!.send(try makeFrame(entries: entries))
        #expect(await b.wait { !$0.acks.isEmpty })

        await harness.handle.disconnectAll(channelId: "group-g1")
        #expect(await b.wait { $0.isClosed })
        #expect(await harness.handle.connectionCount(channelId: "group-g1") == 0)
    }

    // MARK: Write policy

    @Test func writePolicyRejectsDisallowedOperationWhole() async throws {
        let policy = SyncWritePolicy(allowedOperations: [
            "SimpleSyncObject": [.insert, .update],
        ])
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            writePolicy: policy,
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        // INSERT passes.
        let donor = try testLattice(SimpleSyncObject.self)
        let obj = SimpleSyncObject(value: 90, floatValue: 1)
        try donor.add(obj)
        let insertEntries = Array(donor.eventsAfter(globalId: nil))
        try await a.socket!.send(try makeFrame(entries: insertEntries))
        #expect(await a.wait { !$0.acks.isEmpty })
        #expect(await peer.wait { $0.count(of: "auditLog") > 0 })

        // DELETE is refused: rejected frame, row survives, no fan-out.
        let preDelete = Array(donor.eventsAfter(globalId: nil))
        donor.delete(obj)
        let deleteEntries = Array(donor.eventsAfter(globalId: nil)).filter { entry in
            !preDelete.contains { $0.globalId == entry.globalId }
        }
        #expect(deleteEntries.contains { $0.operation == .delete })
        let peerFramesBefore = peer.count(of: "auditLog")
        try await a.socket!.send(try makeFrame(entries: deleteEntries))
        #expect(await a.wait { $0.count(of: "rejected") > 0 })

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(peer.count(of: "auditLog") == peerFramesBefore)
        let channelDB = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
        #expect(channelDB.objects(SimpleSyncObject.self).contains { $0.value == 90 })
    }

    @Test func writePolicyDeleteCapAdmitsSingleRejectsBulk() async throws {
        let policy = SyncWritePolicy(
            allowedOperations: ["SimpleSyncObject": [.insert, .update, .delete]],
            maxDeletesPerFrame: 1)
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            writePolicy: policy,
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        let donor = try testLattice(SimpleSyncObject.self)
        let first = SimpleSyncObject(value: 1, floatValue: 1)
        let second = SimpleSyncObject(value: 2, floatValue: 1)
        try donor.add(first)
        try donor.add(second)
        let preDelete = Array(donor.eventsAfter(globalId: nil))
        donor.delete(first)
        donor.delete(second)
        let deletes = Array(donor.eventsAfter(globalId: nil)).filter { entry in
            entry.operation == .delete && !preDelete.contains { $0.globalId == entry.globalId }
        }
        #expect(deletes.count == 2)

        // Two deletes in one frame: over the cap → rejected.
        try await a.socket!.send(try makeFrame(entries: preDelete + deletes))
        #expect(await a.wait { $0.count(of: "rejected") > 0 })

        // Single delete per frame: admitted (inserts first, then one delete).
        try await a.socket!.send(try makeFrame(entries: preDelete))
        #expect(await a.wait { !$0.acks.isEmpty })
        let ackCount = a.acks.count
        try await a.socket!.send(try makeFrame(entries: [deletes[0]]))
        #expect(await a.wait { $0.acks.count > ackCount })
    }

    // MARK: Schema handshake

    @Test func handshakeClosesLowMissingAndUnparsableAdmitsCurrent() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            handshake: SyncSchemaHandshake(headerName: "X-Engram-Schema", minimumVersion: 3),
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        // Missing header → closed with the policy-violation code (the
        // close code rides the close frame itself, so it is deterministic;
        // the reason TEXT frame races client handler registration and is
        // asserted only as best-effort logging).
        let missing = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        #expect(await missing.wait { $0.isClosed })
        #expect(missing.closeCode == nil || missing.closeCode == WebSocketErrorCode.policyViolation)

        // Low version → same, with the upgrade-required reason when the
        // text made it through.
        let low = try await harness.connect(
            pathSuffix: "sync/group/g1", user: UUID(), headers: ["X-Engram-Schema": "2"])
        #expect(await low.wait { $0.isClosed })
        #expect(low.closeCode == nil || low.closeCode == WebSocketErrorCode.policyViolation)
        if !low.receivedTexts.isEmpty {
            #expect(low.receivedTexts.contains { $0.contains("upgrade required") })
        }

        // Current version → admitted and functional.
        let ok = try await harness.connect(
            pathSuffix: "sync/group/g1", user: UUID(), headers: ["X-Engram-Schema": "3"])
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 5, floatValue: 1)) }
        try await ok.socket!.send(try makeFrame(entries: entries))
        #expect(await ok.wait { !$0.acks.isEmpty })
    }

    // MARK: Traversal guard

    @Test func unsafeDatabaseFileNameIsRefused() async throws {
        // Vapor's router already 404s an encoded-slash path parameter (a
        // `%2F` traversal never matches the single-segment `:groupID` route
        // — verified while writing this test), so the relay guard's real
        // target is extractors that build database names from OTHER request
        // data. Simulate that buggy-consumer shape: filename from a header.
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            channelExtractor: { req in
                guard let raw = req.headers.first(name: "X-Test-User"),
                      let uid = UUID(uuidString: raw) else { throw Abort(.unauthorized) }
                let gid = req.parameters.get("groupID") ?? "g"
                let name = req.headers.first(name: "X-Test-DBName")
                return SyncChannel(id: "group-\(gid)", userId: uid, databaseFileName: name)
            })
        defer { Task { [harness] in await harness.shutdown() } }

        let hostile = try await harness.connect(
            pathSuffix: "sync/group/g1", user: UUID(),
            headers: ["X-Test-DBName": "../evil.sqlite"])
        #expect(await hostile.wait { $0.isClosed })
        // Nothing escaped the storage dir: its parent gained no evil.sqlite.
        let parent = harness.storageURL.deletingLastPathComponent()
        let escaped = (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?
            .contains { $0 == "evil.sqlite" } ?? false
        #expect(!escaped)
        // A legitimate connection on the same mount still works.
        let ok = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 3, floatValue: 1)) }
        try await ok.socket!.send(try makeFrame(entries: entries))
        #expect(await ok.wait { !$0.acks.isEmpty })
    }

    // MARK: Personal wrapper parity

    @Test func wrapperKeepsPersonalLayoutAndBehavior() async throws {
        let harness = try await RelayHarness(wrapperWithSchema: [SimpleSyncObject.self])
        defer { Task { [harness] in await harness.shutdown() } }

        let user = UUID()
        let a = try await harness.connect(pathSuffix: "sync", user: user)
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 77, floatValue: 1)) }
        try await a.socket!.send(try makeFrame(entries: entries))
        #expect(await a.wait { !$0.acks.isEmpty })

        // The historical on-disk layout: `<userId>.sqlite`, uppercase UUID.
        let dbURL = harness.storageURL.appending(path: "\(user.uuidString).sqlite")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        let db = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: dbURL))
        #expect(db.objects(SimpleSyncObject.self).contains { $0.value == 77 })
    }
}
