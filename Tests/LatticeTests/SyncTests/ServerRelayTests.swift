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
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil,
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
            storeConfiguration: storeConfiguration,
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

    /// Server-side registration completes AFTER the client's upgrade
    /// resolves (the extractor awaits in between), so connection counts are
    /// eventually-consistent from the client's point of view — poll.
    func awaitConnectionCount(_ target: Int, channelId: String, timeout: TimeInterval = 5) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = await handle.connectionCount(channelId: channelId)
        while seen != target && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            seen = await handle.connectionCount(channelId: channelId)
        }
        return seen
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
        #expect(await harness.awaitConnectionCount(2, channelId: "group-g1") == 2)
        #expect(await harness.awaitConnectionCount(1, channelId: "group-g2") == 1)

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
        #expect(await harness.awaitConnectionCount(2, channelId: "group-g1") == 2)

        await harness.handle.disconnect(channelId: "group-g1", userId: kicked)
        #expect(await a.wait { $0.isClosed })
        #expect(!b.isClosed)
        #expect(await harness.awaitConnectionCount(1, channelId: "group-g1") == 1)

        // Survivor still relays: an upload is acked post-kick.
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 7, floatValue: 1)) }
        try await b.socket!.send(try makeFrame(entries: entries))
        #expect(await b.wait { !$0.acks.isEmpty })

        await harness.handle.disconnectAll(channelId: "group-g1")
        #expect(await b.wait { $0.isClosed })
        #expect(await harness.awaitConnectionCount(0, channelId: "group-g1") == 0)
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

    /// `.exact` mode refuses BOTH older and newer clients, with distinct
    /// legible reasons, via either declaration channel — the `?schema=`
    /// query parameter (checked first: browser WebSockets cannot set
    /// headers) or the header. Replaces the consumer-side pre-upgrade
    /// query-lift middleware + app-level newer-schema check.
    @Test func exactMatchRefusesAboveAndBelowViaQueryAndHeader() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            handshake: SyncSchemaHandshake(exactVersion: 3),
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        // Both reasons are asserted UNCONDITIONALLY: the refusal text is
        // sent on the connection BEFORE the close frame, so it is ordered
        // ahead of the close on the same channel — waiting for the text is
        // the assertion, and a refusal that closed silently (or with the
        // wrong reason) fails here instead of being skipped by an
        // `if !receivedTexts.isEmpty` guard, which is exactly how a
        // regression in the distinct-reasons behavior would hide.

        // Below, via header → refused: upgrade required.
        let low = try await harness.connect(
            pathSuffix: "sync/group/g1", user: UUID(), headers: ["X-Lattice-Schema": "2"])
        #expect(await low.wait { collector in
            collector.receivedTexts.contains { $0.contains("upgrade required") }
        })
        #expect(await low.wait { $0.isClosed })
        #expect(low.closeCode == nil || low.closeCode == WebSocketErrorCode.policyViolation)
        // ...and NOT the newer-client reason.
        #expect(!low.receivedTexts.contains { $0.contains("server behind client") })

        // Above, via query → refused: server behind client (a distinct
        // reason — this client must NOT be told to upgrade).
        let high = try await harness.connect(
            pathSuffix: "sync/group/g1?schema=4", user: UUID())
        #expect(await high.wait { collector in
            collector.receivedTexts.contains { $0.contains("server behind client") }
        })
        #expect(await high.wait { $0.isClosed })
        #expect(high.closeCode == nil || high.closeCode == WebSocketErrorCode.policyViolation)
        #expect(!high.receivedTexts.contains { $0.contains("upgrade required") })

        // Missing declaration entirely → refused (requireDeclaration).
        let missing = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        #expect(await missing.wait { $0.isClosed })

        // Exact via query → admitted and functional; the query is checked
        // FIRST, so it wins over a (stale) low header.
        let ok = try await harness.connect(
            pathSuffix: "sync/group/g1?schema=3", user: UUID(),
            headers: ["X-Lattice-Schema": "1"])
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 6, floatValue: 1)) }
        try await ok.socket!.send(try makeFrame(entries: entries))
        #expect(await ok.wait { !$0.acks.isEmpty })
        #expect(!ok.isClosed)

        // Exact via header alone → admitted too.
        let okHeader = try await harness.connect(
            pathSuffix: "sync/group/g2", user: UUID(), headers: ["X-Lattice-Schema": "3"])
        let more = try donorEntries { try $0.add(SimpleSyncObject(value: 7, floatValue: 1)) }
        try await okHeader.socket!.send(try makeFrame(entries: more))
        #expect(await okHeader.wait { !$0.acks.isEmpty })
    }

    /// Query-param admission is OPT-IN: a legacy `minimumVersion` mount is
    /// header-only, exactly as pre-1.7 — upgrading the package must not
    /// silently widen its admission surface to `?schema=`.
    @Test func legacyMinimumMountIgnoresQueryParameter() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            handshake: SyncSchemaHandshake(headerName: "X-Engram-Schema", minimumVersion: 3),
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        // A valid version via query ONLY is a missing declaration on a
        // legacy mount (would be admitted if the query were honored).
        let queryOnly = try await harness.connect(
            pathSuffix: "sync/group/g1?schema=3", user: UUID())
        #expect(await queryOnly.wait { $0.isClosed })
        #expect(queryOnly.closeCode == nil || queryOnly.closeCode == WebSocketErrorCode.policyViolation)

        // A BELOW-minimum query value cannot override a valid header either
        // (the query wins when honored, so admission here proves it was
        // ignored, not merely outranked).
        let headerWins = try await harness.connect(
            pathSuffix: "sync/group/g1?schema=2", user: UUID(),
            headers: ["X-Engram-Schema": "3"])
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 8, floatValue: 1)) }
        try await headerWins.socket!.send(try makeFrame(entries: entries))
        #expect(await headerWins.wait { !$0.acks.isEmpty })
        #expect(!headerWins.isClosed)
    }

    /// The other half of opt-in: a minimum-mode mount that EXPLICITLY sets
    /// `queryParameterName` does honor the query channel (checked before
    /// the header), same as the exact-mode default.
    @Test func minimumMountWithExplicitQueryParameterHonorsQuery() async throws {
        var handshake = SyncSchemaHandshake(headerName: "X-Engram-Schema", minimumVersion: 3)
        handshake.queryParameterName = "schema"
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            handshake: handshake,
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        // Query alone admits...
        let ok = try await harness.connect(pathSuffix: "sync/group/g1?schema=3", user: UUID())
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 9, floatValue: 1)) }
        try await ok.socket!.send(try makeFrame(entries: entries))
        #expect(await ok.wait { !$0.acks.isEmpty })
        #expect(!ok.isClosed)

        // ...and a low query refuses, even past a valid header (query is
        // checked FIRST once opted in).
        let low = try await harness.connect(
            pathSuffix: "sync/group/g1?schema=2", user: UUID(),
            headers: ["X-Engram-Schema": "3"])
        #expect(await low.wait { $0.isClosed })
        #expect(low.closeCode == nil || low.closeCode == WebSocketErrorCode.policyViolation)
        if !low.receivedTexts.isEmpty {
            #expect(low.receivedTexts.contains { $0.contains("upgrade required") })
        }
    }

    // MARK: Policy fail-closed (adversarial review)

    /// The inspector (Foundation) and the applier (nlohmann) are different
    /// parsers. Anything the inspector cannot fully vet must be REFUSED, not
    /// waved through: the original fail-open version was defeated by
    /// prefixing the entry array with a single `0`.
    @Test func policyFailsClosedOnParserDifferentials() async throws {
        let policy = SyncWritePolicy(
            allowedOperations: ["SimpleSyncObject": [.insert, .update]],
            unlistedTables: .deny)
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            writePolicy: policy,
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        // Build a REAL delete entry, then smuggle it behind junk.
        let donor = try testLattice(SimpleSyncObject.self)
        let obj = SimpleSyncObject(value: 55, floatValue: 1)
        try donor.add(obj)
        let inserts = Array(donor.eventsAfter(globalId: nil))
        donor.delete(obj)
        let insertedIds = Set(inserts.compactMap(\.globalId))
        let deleteEntry = Array(donor.eventsAfter(globalId: nil))
            .first { entry in
                entry.operation == .delete
                    && !(entry.globalId.map { insertedIds.contains($0) } ?? false)
            }
        #expect(deleteEntry != nil)

        // Seed the channel with the row through the legitimate path.
        try await a.socket!.send(try makeFrame(entries: inserts))
        #expect(await a.wait { !$0.acks.isEmpty })
        let ackCountAfterInsert = a.acks.count
        let peerFramesAfterInsert = peer.count(of: "auditLog")

        func rawFrame(_ object: [String: Any]) throws -> [UInt8] {
            Array(try JSONSerialization.data(withJSONObject: object))
        }
        let deleteJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(deleteEntry!)) as! [String: Any]

        // (1) Junk-prefixed array — the exact bypass.
        var rejects = 0
        try await a.socket!.send(try rawFrame(["kind": "auditLog", "auditLog": [0, deleteJSON]]))
        let afterJunk = rejects
        #expect(await a.wait { $0.count(of: "rejected") > afterJunk })
        rejects = a.count(of: "rejected")

        // (2) Case-flipped table name — SQLite identifiers are
        // case-insensitive, so an exact-match allowlist would miss it.
        var lowered = deleteJSON
        lowered["tableName"] = "simplesyncobject"
        try await a.socket!.send(try rawFrame(["kind": "auditLog", "auditLog": [lowered]]))
        let afterCase = rejects
        #expect(await a.wait { $0.count(of: "rejected") > afterCase })
        rejects = a.count(of: "rejected")

        // (3) Forged AuditLog write — the relay serves that table verbatim
        // to catching-up peers, so it launders forbidden ops.
        var forgedAudit = deleteJSON
        forgedAudit["tableName"] = "AuditLog"
        forgedAudit["operation"] = "INSERT"
        try await a.socket!.send(try rawFrame(["kind": "auditLog", "auditLog": [forgedAudit]]))
        let afterForged = rejects
        #expect(await a.wait { $0.count(of: "rejected") > afterForged })
        rejects = a.count(of: "rejected")

        // (4) Unknown table under .deny.
        var unknown = deleteJSON
        unknown["tableName"] = "SomeOtherTable"
        unknown["operation"] = "INSERT"
        try await a.socket!.send(try rawFrame(["kind": "auditLog", "auditLog": [unknown]]))
        let afterUnknown = rejects
        #expect(await a.wait { $0.count(of: "rejected") > afterUnknown })

        // Nothing was applied, nothing acked, nothing fanned out.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(a.acks.count == ackCountAfterInsert)
        #expect(peer.count(of: "auditLog") == peerFramesAfterInsert)
        let channelDB = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
        #expect(channelDB.objects(SimpleSyncObject.self).contains { $0.value == 55 })
    }

    // MARK: Authoritative revocation

    /// `close(code:)` only SENDS a close frame; a peer that never answers
    /// keeps `isClosed == false`. Revocation must therefore be enforced
    /// server-side, not by transport cooperation.
    @Test func revokedConnectionCannotWriteEvenIfItIgnoresTheClose() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let kicked = UUID()
        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: kicked)
        let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        // Establish the connection works pre-kick.
        let warmup = try donorEntries { try $0.add(SimpleSyncObject(value: 11, floatValue: 1)) }
        try await a.socket!.send(try makeFrame(entries: warmup))
        #expect(await a.wait { !$0.acks.isEmpty })
        let acksBeforeKick = a.acks.count
        let peerFramesBeforeKick = peer.count(of: "auditLog")

        await harness.handle.disconnect(channelId: "group-g1", userId: kicked)

        // Simulate a hostile client: keep writing on the same socket
        // regardless of the close frame. Sends may fail once the transport
        // actually dies — that's fine, the assertion is about EFFECT.
        let postKick = try donorEntries { try $0.add(SimpleSyncObject(value: 99, floatValue: 1)) }
        for _ in 0..<3 {
            try? await a.socket?.send(try makeFrame(entries: postKick))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        // No ack, no fan-out, and — decisively — nothing in the channel DB.
        #expect(a.acks.count == acksBeforeKick)
        #expect(peer.count(of: "auditLog") == peerFramesBeforeKick)
        let channelDB = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
        #expect(!channelDB.objects(SimpleSyncObject.self).contains { $0.value == 99 })
        // The surviving member is unaffected.
        let survivorEntries = try donorEntries { try $0.add(SimpleSyncObject(value: 12, floatValue: 1)) }
        try await peer.socket!.send(try makeFrame(entries: survivorEntries))
        #expect(await peer.wait { !$0.acks.isEmpty })
    }

    /// A refused connection must not buffer frames: handlers now register
    /// before authorization, so an unauthorized peer that ignores the close
    /// could otherwise pin memory until OOM.
    @Test func refusedConnectionDiscardsFramesInsteadOfBuffering() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            channelExtractor: { _ in throw Abort(.forbidden) })
        defer { Task { [harness] in await harness.shutdown() } }

        let refused = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 8, floatValue: 1)) }
        for _ in 0..<5 {
            try? await refused.socket?.send(try makeFrame(entries: entries))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Never acked, never registered, no database created for a channel
        // that was never authorized.
        #expect(refused.acks.isEmpty)
        #expect(await harness.awaitConnectionCount(0, channelId: "group-g1") == 0)
        #expect(!FileManager.default.fileExists(
            atPath: harness.storageURL.appending(path: "group-g1.sqlite").path))
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

    // MARK: Store configuration

    /// A mount can serve channel files it did NOT create: a projector that
    /// opens with `migration:` leaves the file at `user_version == max key`,
    /// and the relay's default open (target version 1) refuses it — every
    /// observer's socket closed at connect, forever. `storeConfiguration`
    /// hands the mount the projector's own migration dictionary so the open
    /// succeeds; a mount left at the default keeps today's behavior for its
    /// own relay-created (version-1) files.
    @Test func storeConfigurationOpensProjectorMigratedChannelFiles() async throws {
        let migrations: [Int: Migration] = [2: Migration(), 3: Migration()]
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            storeConfiguration: { url in .init(fileURL: url, migration: migrations) },
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        // Projector-shaped creation: the channel file exists BEFORE any
        // connection, migrated to user_version 3, with a projected row.
        try FileManager.default.createDirectory(at: harness.storageURL,
                                                withIntermediateDirectories: true)
        let fileURL = harness.storageURL.appending(path: "group-g1.sqlite")
        do {
            let projector = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: fileURL, migration: migrations))
            try projector.add(SimpleSyncObject(value: 33, floatValue: 1))
        }

        // The configured mount opens the v3 file: connection survives and
        // the catch-up delivers the projected row.
        let observer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        #expect(await observer.wait { $0.count(of: "auditLog") > 0 })
        #expect(!observer.isClosed)

        // Uploads still work through the configured open.
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 34, floatValue: 1)) }
        try await observer.socket!.send(try makeFrame(entries: entries))
        #expect(await observer.wait { !$0.acks.isEmpty })
    }

    /// The bug this parameter fixes, pinned as a regression shape: a DEFAULT
    /// mount pointed at a projector-migrated (v3) file refuses the open and
    /// closes the socket — while the same default mount on its own fresh
    /// file keeps working exactly as before.
    @Test func defaultMountRefusesMigratedFileButStillServesOwnFiles() async throws {
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        try FileManager.default.createDirectory(at: harness.storageURL,
                                                withIntermediateDirectories: true)
        do {
            let projector = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: harness.storageURL.appending(path: "group-g1.sqlite"),
                migration: [2: Migration(), 3: Migration()]))
            try projector.add(SimpleSyncObject(value: 33, floatValue: 1))
        }

        // Version-skewed file → open fails → connect-then-close.
        let refused = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        #expect(await refused.wait { $0.isClosed })

        // Cookie-1 path unchanged: a fresh relay-created channel file works.
        let ok = try await harness.connect(pathSuffix: "sync/group/g2", user: UUID())
        let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 21, floatValue: 1)) }
        try await ok.socket!.send(try makeFrame(entries: entries))
        #expect(await ok.wait { !$0.acks.isEmpty })
    }
}
