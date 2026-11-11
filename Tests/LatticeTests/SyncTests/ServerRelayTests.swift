import Foundation
import Testing
import Vapor
import NIOCore
import NIOHTTP1
import NIOPosix
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

/// Test-only, opt-in attribution for this legacy relay harness. The process
/// admits at most 32 recorders (no replenishment), each with eight connections,
/// 256 head records and sixteen latest scalar facts. A harness emits at most
/// one <=64 KiB ACK snapshot. IDs identify this diagnostic run/connection;
/// neither paths, wire payloads nor audit IDs are recorded.
private final class RelayHarnessDiagnostics: Sendable {
    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var admitted = 0
        private var omissionReported = false

        func take() -> (accepted: Bool, reportOmission: Bool) {
            lock.lock(); defer { lock.unlock() }
            if admitted < 32 {
                admitted += 1
                return (true, false)
            }
            let report = !omissionReported
            omissionReported = true
            return (false, report)
        }
    }

    private static let admission = Admission()
    let recorder = ACKPathRecorder(testRunID: UUID(), connectionLimit: 8, retainLatestStages: true)

    static func make() -> RelayHarnessDiagnostics? {
        guard ProcessInfo.processInfo.environment["LATTICE_ACK_PATH_DIAGNOSTICS"] == "1" else { return nil }
        let result = admission.take()
        if result.reportOmission {
            print("DIAGNOSTIC RelayHarnessAdmission: omitted=true limit=32 later_harness_stages=unknown")
        }
        return result.accepted ? RelayHarnessDiagnostics() : nil
    }

    func firstFailure(site: UInt, connection: UUID? = nil) {
        // The recorder closes admission before formatting or teardown; only
        // the first failed wait/connect for this harness can select a snapshot.
        guard let snapshot = recorder.closeSnapshot(partial: true) else { return }
        print("DIAGNOSTIC RelayHarnessFailure: test=\(recorder.testRunID) connection=\(connection?.uuidString ?? "none") site=\(site) cutoff_ns=\(snapshot.cutoffUptime) first_failure=true later_cascade=unclassified")
        ACKPathRecorder.emitSnapshot(snapshot)
    }

    func finish() { _ = recorder.closeSnapshot(partial: false) }
}

/// Records everything a raw relay client receives, with awaitable arrival.
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var binaryKinds: [String] = []
    private var texts: [String] = []
    private var ackedIds: [UUID] = []
    private var auditIds: [UUID] = []
    private var auditPageSizes: [Int] = []
    private var auditPageBytes: [Int] = []
    private var waiters: [(predicate: () -> Bool, cont: CheckedContinuation<Void, Never>)] = []
    private(set) var socket: WebSocket?
    private let diagnostic: ACKPathConnection?
    private let failureDiagnostic: (@Sendable (UInt) -> Void)?

    init(diagnostic: ACKPathConnection? = nil,
         failureDiagnostic: (@Sendable (UInt) -> Void)? = nil) {
        self.diagnostic = diagnostic
        self.failureDiagnostic = failureDiagnostic
    }

    /// nil socket (upgrade never completed) counts as closed.
    var isClosed: Bool { socket?.isClosed ?? true }
    var closeCode: WebSocketErrorCode? { socket?.closeCode }

    func attach(_ ws: WebSocket) {
        socket = ws
        diagnostic?.record(.clientHandlersAttached)
        let diagnostic = self.diagnostic
        ws.onClose.whenComplete { _ in diagnostic?.record(.connectionClosed) }
        ws.onBinary { [weak self] _, bb in
            guard let self else { return }
            self.diagnostic?.record(.clientBinaryEntered, bytes: bb.readableBytes)
            let data = Data(buffer: bb)
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let kind = root?["kind"] as? String ?? "?"
            self.lock.lock()
            self.binaryKinds.append(kind)
            if kind == "ack", let ids = root?["ack"] as? [String] {
                self.ackedIds.append(contentsOf: ids.compactMap(UUID.init(uuidString:)))
            }
            if kind == "auditLog", let entries = root?["auditLog"] as? [[String: Any]] {
                self.auditPageSizes.append(entries.count)
                self.auditPageBytes.append(data.count)
                self.auditIds.append(contentsOf: entries.compactMap {
                    ($0["globalId"] as? String).flatMap(UUID.init(uuidString:))
                })
            }
            let ready = self.waiters.filter { $0.predicate() }
            self.waiters.removeAll { $0.predicate() }
            self.lock.unlock()
            if root == nil {
                self.diagnostic?.record(.clientDecodeError, bytes: data.count)
            } else {
                let stage: ACKPathStage
                switch kind {
                case "ack": stage = .clientDecodedAck
                case "nack": stage = .clientDecodedNack
                case "auditLog": stage = .clientDecodedAudit
                case "rejected": stage = .clientDecodedRejected
                default: stage = .clientDecodedOther
                }
                self.diagnostic?.record(stage, bytes: data.count)
            }
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
    var receivedAuditIds: [UUID] { lock.withLock { auditIds } }
    var receivedAuditPageSizes: [Int] { lock.withLock { auditPageSizes } }
    var receivedAuditPageBytes: [Int] { lock.withLock { auditPageBytes } }

    func count(of kind: String) -> Int { kinds.filter { $0 == kind }.count }

    /// Awaits until `predicate` over this collector holds (checked on every
    /// arrival), or the timeout elapses.
    func wait(timeout: TimeInterval = 10, site: UInt = #line, until predicate: @escaping @Sendable (FrameCollector) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(self) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = predicate(self)
        if !result { failureDiagnostic?(site) }
        return result
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
    private let diagnostics: RelayHarnessDiagnostics?

    init(
        path: [PathComponent],
        schema: [any Lattice.Model.Type],
        writePolicy: SyncWritePolicy? = nil,
        handshake: SyncSchemaHandshake? = nil,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil,
        onSetupFinished: (@Sendable () -> Void)? = nil,
        maxBufferedFrameBytes: Int? = nil,
        initialCatchUpPageSize: Int = 1000,
        downloadExcludedTables: Set<String> = [],
        reauthorizeChannel: (@Sendable (Request, SyncChannel) async throws -> Void)? = nil,
        revalidateAfterRegistration: Bool = false,
        transactionAuthorization: (@Sendable (SyncChannel, Data, Lattice) -> Bool)? = nil,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel
    ) async throws {
        let diagnostics = RelayHarnessDiagnostics.make()
        self.diagnostics = diagnostics
        storageURL = testTemporaryDirectory
            .appending(path: "relay-harness-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        let diagnosticMount = storageURL
        var initialized = false
        if let diagnostics { ACKPathDiagnostics.install(diagnostics.recorder, for: diagnosticMount) }
        defer {
            if !initialized, let diagnostics {
                diagnostics.firstFailure(site: #line)
                ACKPathDiagnostics.remove(diagnostics.recorder, for: diagnosticMount)
            }
        }
        // Captured by this mount during configure; remove the temporary lookup
        // after initialization. Other harnesses use distinct storage URLs.
        let hookStorageURL = storageURL
        let ingressHooks: RelayIngressTestHooks?
        if onSetupFinished != nil || maxBufferedFrameBytes != nil {
            ingressHooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
                                                 didFinishAsyncSetup: { onSetupFinished?() },
                                                 maxBufferedFrameBytes: maxBufferedFrameBytes)
        } else {
            ingressHooks = nil
        }
        if let ingressHooks { RelayIngressTesting.install(ingressHooks, for: hookStorageURL) }
        defer { if let ingressHooks { RelayIngressTesting.remove(ingressHooks, for: hookStorageURL) } }
        handle = Lattice.configureSyncRelay(
            on: app.routes, path: path, for: schema, storageURL: storageURL,
            writePolicy: writePolicy, handshake: handshake,
            storeConfiguration: storeConfiguration,
            initialCatchUpPageSize: initialCatchUpPageSize,
            reauthorizeChannel: reauthorizeChannel,
            revalidateAfterRegistration: revalidateAfterRegistration,
            transactionAuthorization: transactionAuthorization,
            downloadExcludedTables: downloadExcludedTables,
            channelExtractor: channelExtractor)
        try await app.startup()
        guard let assigned = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "no port")
        }
        port = assigned
        initialized = true
    }

    /// Wrapper-mounted harness (old personal API).
    init(wrapperWithSchema schema: [any Lattice.Model.Type]) async throws {
        let diagnostics = RelayHarnessDiagnostics.make()
        self.diagnostics = diagnostics
        storageURL = testTemporaryDirectory
            .appending(path: "relay-harness-\(String.random(length: 12))")
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        app = try await Application.make(env)
        app.http.server.configuration.port = 0
        let diagnosticMount = storageURL
        var initialized = false
        if let diagnostics { ACKPathDiagnostics.install(diagnostics.recorder, for: diagnosticMount) }
        defer {
            if !initialized, let diagnostics {
                diagnostics.firstFailure(site: #line)
                ACKPathDiagnostics.remove(diagnostics.recorder, for: diagnosticMount)
            }
        }
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
        initialized = true
    }

    func connect(pathSuffix: String, user: UUID, headers extra: [String: String] = [:],
                 maxFrameSize: Int = 1 << 14) async throws -> FrameCollector {
        // All raw clients can upload; this role does not assert a frame was sent.
        let diagnostic = diagnostics?.recorder.registerConnection(id: UUID(), role: .uploader)
        let failureDiagnostic: (@Sendable (UInt) -> Void)?
        if let diagnostics {
            failureDiagnostic = { site in diagnostics.firstFailure(site: site, connection: diagnostic?.id) }
        } else {
            failureDiagnostic = nil
        }
        let collector = FrameCollector(diagnostic: diagnostic, failureDiagnostic: failureDiagnostic)
        diagnostic?.record(.connectBegin)
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-User", value: user.uuidString)
        for (k, v) in extra { headers.add(name: k, value: v) }
        if let diagnostic {
            headers.replaceOrAdd(name: "X-Lattice-Diagnostic-Connection", value: diagnostic.id.uuidString)
        }
        // Resume on ATTACH, not on the connect future — the two aren't
        // strictly ordered, and reading collector.socket before onUpgrade
        // ran was a nil crash under parallel test load.
        let once = AtomicOnce()
        let configuration = WebSocketClient.Configuration(maxFrameSize: maxFrameSize)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            WebSocket.connect(
                to: "ws://127.0.0.1:\(port)/\(pathSuffix)",
                headers: headers,
                configuration: configuration,
                on: app.eventLoopGroup
            ) { ws in
                collector.attach(ws)
                diagnostic?.record(.connectEnd)
                if once.tryFire() { cont.resume() }
            }.whenFailure { error in
                diagnostic?.record(.connectError)
                failureDiagnostic?(#line)
                if once.tryFire() { cont.resume(throwing: error) }
            }
        }
        return collector
    }

    /// Server-side registration completes AFTER the client's upgrade
    /// resolves (the extractor awaits in between), so connection counts are
    /// eventually-consistent from the client's point of view — poll.
    func awaitConnectionCount(_ target: Int, channelId: String, timeout: TimeInterval = 5,
                              site: UInt = #line) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = await handle.connectionCount(channelId: channelId)
        while seen != target && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            seen = await handle.connectionCount(channelId: channelId)
        }
        if seen != target { diagnostics?.firstFailure(site: site) }
        return seen
    }

    func shutdown() async {
        // Passing harnesses close silently; failures froze before teardown.
        diagnostics?.finish()
        if let diagnostics { ACKPathDiagnostics.remove(diagnostics.recorder, for: storageURL) }
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

/// Raw WebSocket frames deliberately leave the close handshake unanswered.
/// One small overflow frame exercises admission without a large stress buffer.
private final class CloseIgnoringRelayPeer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let lock = NSLock()
    private var closeFrames = 0
    private var binaryFrames = 0
    var observedClose: Bool { lock.withLock { closeFrames > 0 } }
    var receivedBinaryFrames: Int { lock.withLock { binaryFrames } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.opcode == .ping {
            // Keep the transport alive while deliberately ignoring Close. Otherwise
            // the server's dead-peer timer can expire before reauthorization resumes.
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        }
        lock.withLock {
            if frame.opcode == .connectionClose { closeFrames += 1 }
            if frame.opcode == .binary { binaryFrames += 1 }
        }
    }

    func connect(to harness: RelayHarness, user: UUID) async throws -> any Channel {
        let upgraded = harness.app.eventLoopGroup.next().makePromise(of: Void.self)
        let completion = AtomicOnce()
        let channel = try await ClientBootstrap(group: harness.app.eventLoopGroup)
            .channelInitializer { channel in
                let upgrader = NIOWebSocketClientUpgrader(
                    maxFrameSize: 4096, automaticErrorHandling: true,
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(self).map {
                            if completion.tryFire() { upgraded.succeed(()) }
                        }
                    })
                return channel.pipeline.addHTTPClientHandlers(
                    withClientUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            }.connect(host: "127.0.0.1", port: harness.port).get()
        do {
            try Task.checkCancellation()
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "127.0.0.1:\(harness.port)")
            headers.add(name: "X-Test-User", value: user.uuidString)
            let request = HTTPRequestHead(version: .http1_1, method: .GET,
                                          uri: "/sync/group/g1", headers: headers)
            channel.write(HTTPClientRequestPart.head(request), promise: nil)
            // Start the five-second upgrade response budget at request flush completion
            // on the channel's event loop, independent of bootstrap and task resumption.
            let timeout = try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).map {
                channel.eventLoop.scheduleTask(in: .seconds(5)) {
                    if completion.tryFire() { upgraded.fail(Abort(.requestTimeout)) }
                }
            }.get()
            defer { timeout.cancel() }
            try Task.checkCancellation()
            try await upgraded.futureResult.get()
            try Task.checkCancellation()
            return channel
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

private final class RelayAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private var released = false
    private var allowed = true
    private var continuation: CheckedContinuation<Void, Never>?
    var entered: Bool { lock.withLock { didEnter } }
    var isAllowed: Bool { lock.withLock { allowed } }
    func revoke() { lock.withLock { allowed = false } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                didEnter = true
                if released { return true }
                precondition(self.continuation == nil)
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let continuation = lock.withLock {
            released = true
            let result = self.continuation; self.continuation = nil
            return result
        }
        continuation?.resume()
    }
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

    @Test func postRegistrationRefusalDoesNotOpenStoreOrPublish() async throws {
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() },
            reauthorizeChannel: { _, _ in throw Abort(.forbidden) }, channelExtractor: groupExtractor)
        do {
            let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            try #require(await peer.wait { $0.isClosed })
            try #require(await peer.wait { _ in setups.count == 1 })
            #expect(peer.receivedAuditIds.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.storageURL.appending(path: "group-g1.sqlite").path))
            #expect(await harness.awaitConnectionCount(0, channelId: "group-g1") == 0)
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test(arguments: ["channel", "user", "file", "currentness"])
    func legacyRevalidationRefusesChangedOriginalBeforeOpeningStore(kind: String) async throws {
        let extractions = RelaySetupCompletions()
        let reauthorizations = RelaySetupCompletions()
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() },
            reauthorizeChannel: { _, _ in reauthorizations.noteFinished() },
            revalidateAfterRegistration: true,
            channelExtractor: { request in
                let original = try await groupExtractor(request)
                extractions.noteFinished()
                guard extractions.count > 1 else { return original }
                return SyncChannel(
                    id: kind == "channel" ? "another-channel" : original.id,
                    userId: kind == "user" ? UUID() : original.userId,
                    databaseFileName: kind == "file" ? "another-file.sqlite" : original.databaseFileName,
                    isCurrent: { kind != "currentness" })
            })
        do {
            let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            try #require(await peer.wait { $0.isClosed })
            try #require(await peer.wait { _ in setups.count == 1 })
            #expect(extractions.count == 2)
            #expect(reauthorizations.count == 0)
            #expect(peer.receivedAuditIds.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.storageURL.appending(path: "group-g1.sqlite").path))
            #expect(!FileManager.default.fileExists(atPath: harness.storageURL.appending(path: "another-file.sqlite").path))
            #expect(await harness.awaitConnectionCount(0, channelId: "group-g1") == 0)
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test func revocationBeforeRegistrationIsCaughtBySecondAuthorization() async throws {
        let gate = RelayAdmissionGate()
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() },
            reauthorizeChannel: { _, _ in guard gate.isAllowed else { throw Abort(.forbidden) } },
            channelExtractor: { request in
                let initiallyAuthorized = try await groupExtractor(request)
                await gate.wait() // The grant can be revoked after this first check.
                return initiallyAuthorized
            })
        do {
            let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            try #require(await peer.wait { _ in gate.entered })
            #expect(await harness.handle.connectionCount(channelId: "group-g1") == 0)
            gate.revoke()
            await harness.handle.disconnectAll(channelId: "group-g1") // No entry yet: this kick alone misses it.
            gate.release()
            try #require(await peer.wait { $0.isClosed })
            try #require(await peer.wait { _ in setups.count == 1 })
            #expect(peer.receivedAuditIds.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.storageURL.appending(path: "group-g1.sqlite").path))
        } catch { gate.release(); await harness.shutdown(); throw error }
        gate.release(); await harness.shutdown()
    }

    @Test func successfulReauthorizationCannotResurrectAnAlreadyKickedSocket() async throws {
        let gate = RelayAdmissionGate()
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() },
            reauthorizeChannel: { _, _ in await gate.wait() }, channelExtractor: groupExtractor)
        do {
            let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            try #require(await peer.wait { _ in gate.entered })
            #expect(await harness.handle.connectionCount(channelId: "group-g1") == 1)
            await harness.handle.disconnectAll(channelId: "group-g1")
            gate.release() // Callback succeeds, but the registered revocation flag is permanent.
            try #require(await peer.wait { $0.isClosed })
            try #require(await peer.wait { _ in setups.count == 1 })
            #expect(peer.receivedAuditIds.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.storageURL.appending(path: "group-g1.sqlite").path))
        } catch { gate.release(); await harness.shutdown(); throw error }
        gate.release(); await harness.shutdown()
    }

    @Test func pendingOverflowCannotBeAdmittedAfterSuccessfulReauthorization() async throws {
        let gate = RelayAdmissionGate()
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() }, maxBufferedFrameBytes: 1024,
            reauthorizeChannel: { _, _ in await gate.wait() }, channelExtractor: groupExtractor)
        let hostile = CloseIgnoringRelayPeer()
        var channel: (any Channel)?
        do {
            let connected = try await hostile.connect(to: harness, user: UUID())
            channel = connected
            let wait = FrameCollector()
            try #require(await wait.wait { _ in gate.entered })
            var bytes = connected.allocator.buffer(capacity: 1025)
            bytes.writeRepeatingByte(0, count: 1025)
            let overflow = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: bytes)
            try await connected.writeAndFlush(overflow).get()
            try #require(await wait.wait { _ in hostile.observedClose })
            // A normal WebSocket client would answer close and hide this race.
            try #require(connected.isActive)
            gate.release()
            try #require(await wait.wait { _ in setups.count == 1 })
            #expect(hostile.receivedBinaryFrames == 0)
            #expect(!FileManager.default.fileExists(atPath: harness.storageURL.appending(path: "group-g1.sqlite").path))
            #expect(await harness.handle.connectionCount(channelId: "group-g1") == 0)
        } catch {
            gate.release()
            if let channel { try? await channel.close().get() }
            await harness.shutdown()
            throw error
        }
        gate.release()
        if let channel { try? await channel.close().get() }
        await harness.shutdown()
    }

    @Test func pendingReauthorizationIsExcludedFromPeerFanout() async throws {
        let gate = RelayAdmissionGate()
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() },
            reauthorizeChannel: { request, _ in
                if request.headers.first(name: "X-Test-Pending") == "yes" {
                    await gate.wait(); throw Abort(.forbidden)
                }
            }, channelExtractor: groupExtractor)
        do {
            let writer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            let pending = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID(), headers: ["X-Test-Pending": "yes"])
            try #require(await pending.wait { _ in gate.entered })
            let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 81, floatValue: 1)) }
            try await writer.socket!.send(try makeFrame(entries: entries))
            try #require(await writer.wait { !$0.acks.isEmpty })
            gate.release()
            try #require(await pending.wait { $0.isClosed })
            try #require(await pending.wait { _ in setups.count == 2 })
            #expect(pending.receivedAuditIds.isEmpty)
            await harness.handle.disconnectAll(channelId: "group-g1")
            try #require(await writer.wait { $0.isClosed })
        } catch { gate.release(); await harness.shutdown(); throw error }
        gate.release(); await harness.shutdown()
    }

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
        let setupCompletions = RelaySetupCompletions()
        let policy = SyncWritePolicy(allowedOperations: [
            "SimpleSyncObject": [.insert, .update],
        ])
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            writePolicy: policy,
            onSetupFinished: { setupCompletions.noteFinished() },
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        // Client upgrade precedes server setup and initial catch-up. Finish
        // both empty catch-ups before seeding the no-fanout baseline.
        let setupsReady = await a.wait { _ in setupCompletions.count == 2 }
        try #require(setupsReady)

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

    @Test func legacyUploadAboveOutboundLimitIsStoredAndOutboundStaysBounded() async throws {
        let donor = try testLattice(SyncChild.self)
        defer { donor.close() }
        let payload = String(repeating: "x", count: 600 * 1024)
        try donor.withTransaction {
            for _ in 0..<8 { try donor.add(SyncChild(name: payload)) }
        }
        let entries = Array(donor.eventsAfter(globalId: nil))
        let expected = try entries.map { try #require($0.globalId) }
        let legacyFrame = try makeFrame(entries: entries)
        try #require(expected.count == 8)
        try #require(legacyFrame.count > Lattice.maximumEncodedSyncMessageBytes)
        try #require(legacyFrame.count < 64 * 1024 * 1024)

        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"],
            schema: [SyncChild.self], channelExtractor: groupExtractor)
        do {
            let writer = try await harness.connect(
                pathSuffix: "sync/group/legacy?lattice-catch-up-complete=1", user: UUID())
            let ready = await writer.wait { $0.count(of: "catchUpComplete") == 1 }
            try #require(ready)
            let live = try await harness.connect(
                pathSuffix: "sync/group/legacy?lattice-catch-up-complete=1", user: UUID(),
                maxFrameSize: Lattice.maximumEncodedSyncMessageBytes)
            let liveReady = await live.wait { $0.count(of: "catchUpComplete") == 1 }
            try #require(liveReady)
            let socket = try #require(writer.socket)
            try await socket.send(legacyFrame)
            let acknowledged = await writer.wait { $0.acks.count == expected.count }
            try #require(acknowledged)
            #expect(writer.acks == expected)
            #expect(writer.count(of: "nack") == 0)
            #expect(writer.count(of: "rejected") == 0)
            #expect(!writer.isClosed)
            let deliveredLive = await live.wait { $0.receivedAuditIds.count == expected.count }
            try #require(deliveredLive)
            #expect(live.receivedAuditIds == expected)
            #expect(live.receivedAuditPageBytes.count > 1)
            #expect(live.receivedAuditPageBytes.allSatisfy { $0 <= Lattice.maximumEncodedSyncMessageBytes })
            #expect(!live.isClosed)

            let reader = try await harness.connect(
                pathSuffix: "sync/group/legacy?lattice-catch-up-complete=1", user: UUID(),
                maxFrameSize: Lattice.maximumEncodedSyncMessageBytes)
            let caughtUp = await reader.wait { $0.count(of: "catchUpComplete") == 1 }
            try #require(caughtUp)
            #expect(reader.receivedAuditIds == expected)
            #expect(reader.receivedAuditPageBytes.count > 1)
            #expect(reader.receivedAuditPageBytes.allSatisfy { $0 <= Lattice.maximumEncodedSyncMessageBytes })
            #expect(!reader.isClosed)

            let persisted = try Lattice(SyncChild.self, configuration: .init(
                fileURL: harness.storageURL.appending(path: "group-legacy.sqlite")))
            defer { persisted.close() }
            #expect(persisted.objects(SyncChild.self).count == expected.count)
            #expect(persisted.objects(SyncChild.self).allSatisfy { $0.name == payload })
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test("Initial catch-up retains ordered history and resumed suffix", arguments: [1, 2, 1000])
    func initialCatchUpPageSizePreservesHistoryAndResume(pageSize: Int) async throws {
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self], initialCatchUpPageSize: pageSize,
            channelExtractor: groupExtractor)
        do {
            try FileManager.default.createDirectory(at: harness.storageURL, withIntermediateDirectories: true)
            let expected: [UUID] = try {
                let store = try Lattice(SimpleSyncObject.self, configuration: .init(
                    fileURL: harness.storageURL.appending(path: "group-pages.sqlite")))
                defer { store.close() }
                try store.withTransaction {
                    for value in 0..<9 { try store.add(SimpleSyncObject(value: value, floatValue: 0)) }
                }
                return try Array(store.eventsAfter(globalId: nil)).map { try #require($0.globalId) }
            }()
            try #require(expected.count == 9)
            let full = try await harness.connect(
                pathSuffix: "sync/group/pages?lattice-catch-up-complete=1", user: UUID())
            try #require(await full.wait { $0.count(of: "catchUpComplete") == 1 })
            #expect(full.receivedAuditIds == expected)
            #expect(full.receivedAuditPageSizes.allSatisfy { $0 > 0 && $0 <= pageSize })
            #expect(full.receivedAuditPageSizes.count == (expected.count + pageSize - 1) / pageSize)
            #expect(full.receivedAuditPageBytes.allSatisfy { $0 <= Lattice.maximumEncodedSyncMessageBytes })
            await harness.handle.disconnectAll(channelId: "group-pages")
            try #require(await harness.awaitConnectionCount(0, channelId: "group-pages") == 0)
            let middle = expected.count / 2
            let resumed = try await harness.connect(pathSuffix: "sync/group/pages?last-event-id=" +
                expected[middle].uuidString.lowercased() + "&lattice-catch-up-complete=1", user: UUID())
            try #require(await resumed.wait { $0.count(of: "catchUpComplete") == 1 })
            #expect(resumed.receivedAuditIds == Array(expected.dropFirst(middle + 1)))
            #expect(resumed.receivedAuditPageSizes.allSatisfy { $0 > 0 && $0 <= pageSize })
            #expect(resumed.count(of: "floorReset") == 0)
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test func readOnlySourceExcludesPrivatePagesAndConsumesOnlyPureAcknowledgements() async throws {
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self, SyncChild.self],
            writePolicy: .init(allowedOperations: [:], unlistedTables: .deny),
            storeConfiguration: { url in
                var config = Lattice.Configuration(fileURL: url)
                config.isReadOnly = true
                config.uploadsEnabled = false
                return config
            }, initialCatchUpPageSize: 1, downloadExcludedTables: ["sYnCcHiLd"],
            channelExtractor: groupExtractor)
        do {
            try FileManager.default.createDirectory(at: harness.storageURL, withIntermediateDirectories: true)
            let url = harness.storageURL.appending(path: "group-readonly.sqlite")
            let expected: [UUID] = try {
                let store = try Lattice(SimpleSyncObject.self, SyncChild.self, configuration: .init(fileURL: url))
                defer { store.close() }
                try store.withTransaction {
                    for value in 0..<3 { try store.add(SyncChild(name: "private-\(value)")) }
                    for value in 0..<2 { try store.add(SimpleSyncObject(value: value, floatValue: 0)) }
                }
                return try Array(store.eventsAfter(globalId: nil))
                    .filter { $0.tableName == "SimpleSyncObject" }.map { try #require($0.globalId) }
            }()
            try #require(expected.count == 2)
            let reader = try await harness.connect(
                pathSuffix: "sync/group/readonly?lattice-catch-up-complete=1", user: UUID())
            try #require(await reader.wait { $0.count(of: "catchUpComplete") == 1 })
            #expect(reader.receivedAuditIds == expected)
            #expect(reader.receivedAuditPageSizes == [1, 1])
            let validACK = try JSONEncoder().encode(ServerSentEvent.ack(expected))
            try await reader.socket!.send(Array(validACK))
            // Ordered malformed ACK is a positive processing barrier after the
            // valid ACK; no sleeping or inferred successful write is needed.
            let malformed = try JSONSerialization.data(withJSONObject: ["kind": "ack", "ack": ["invalid"]])
            try await reader.socket!.send(Array(malformed))
            try #require(await reader.wait { $0.count(of: "rejected") == 1 })
            let denied = try donorEntries { try $0.add(SimpleSyncObject(value: 999, floatValue: 0)) }
            try await reader.socket!.send(try makeFrame(entries: denied))
            try #require(await reader.wait { $0.count(of: "rejected") == 2 })
            #expect(reader.acks.isEmpty && reader.count(of: "nack") == 0)
            let store = try Lattice(SimpleSyncObject.self, SyncChild.self, configuration: .init(fileURL: url))
            defer { store.close() }
            #expect(store.objects(SimpleSyncObject.self).count == 2)
            #expect(store.objects(SyncChild.self).count == 3)
            #expect(store.eventsAfter(globalId: nil).allSatisfy { !$0.isSynchronized })
            #expect(RelayFrame(validACK).isPureAcknowledgement)
            #expect(!RelayFrame(malformed).isPureAcknowledgement)
            let mixed = try JSONSerialization.data(withJSONObject: ["kind": "ack", "ack": [], "auditLog": []])
            #expect(!RelayFrame(mixed).isPureAcknowledgement)
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test func defaultRelayPreservesOrdinarySchemaSkewAcknowledgement() async throws {
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self], channelExtractor: groupExtractor)
        do {
            let writer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 73, floatValue: 1)) }
            let ids = Set(entries.compactMap(\.globalId))
            try #require(!ids.isEmpty)
            var frame = try #require(JSONSerialization.jsonObject(
                with: Data(try makeFrame(entries: entries))) as? [String: Any])
            var rows = try #require(frame["auditLog"] as? [[String: Any]])
            var newerTable = try #require(rows.first)
            let unknownID = UUID()
            newerTable["globalId"] = unknownID.uuidString.lowercased()
            newerTable["tableName"] = "NewerPeerOnly"
            rows.append(newerTable)
            frame["auditLog"] = rows
            try await writer.socket!.send(Array(try JSONSerialization.data(withJSONObject: frame)))
            // The default receiver stores its known model and ACKs an unknown
            // newer table without promoting it. Strict policy is not implicit.
            try #require(await writer.wait { ids.union([unknownID]).isSubset(of: Set($0.acks)) })
            #expect(writer.count(of: "rejected") == 0)
            #expect(writer.count(of: "nack") == 0)
            let store = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
            defer { store.close() }
            #expect(store.objects(SimpleSyncObject.self).count == 1)
            #expect(store.objects(SimpleSyncObject.self).first?.value == 73)
            #expect(!store.eventsAfter(globalId: nil).contains { $0.globalId == unknownID })
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test func immutableTablePolicyRejectsConflictWithoutAckOrFanout() async throws {
        #expect(!RelayApplyErrorClass.classify("immutable sync violation: BusyCommand identity changed").isContention)
        #expect(!RelayApplyErrorClass.classify("sync authorization denied: busy principal revoked").isContention)
        let setups = RelaySetupCompletions()
        let reauthorizations = RelaySetupCompletions()
        let policy = SyncWritePolicy(allowedOperations: ["SimpleSyncObject": [.insert]],
            unlistedTables: .deny, immutableTables: ["SimpleSyncObject"])
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            writePolicy: policy, onSetupFinished: { setups.noteFinished() },
            reauthorizeChannel: { _, _ in reauthorizations.noteFinished() },
            revalidateAfterRegistration: true, channelExtractor: groupExtractor)
        do {
            let writer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            try #require(await writer.wait { _ in setups.count == 2 })
            #expect(reauthorizations.count == 2)
            let entries = try donorEntries { try $0.add(SimpleSyncObject(value: 91, floatValue: 1)) }
            let ids = Set(entries.compactMap(\.globalId))
            try #require(!ids.isEmpty)
            let bytes = try makeFrame(entries: entries)
            try await writer.socket!.send(bytes)
            try #require(await writer.wait { ids.isSubset(of: Set($0.acks)) })
            try #require(await peer.wait { ids.isSubset(of: Set($0.receivedAuditIds)) })

            // Replaying the original complete snapshot settles the same identity.
            let ackCount = writer.acks.count
            try await writer.socket!.send(bytes)
            try #require(await writer.wait { $0.acks.count >= ackCount + ids.count })

            var frame = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            var rows = try #require(frame["auditLog"] as? [[String: Any]])
            let index = try #require(rows.firstIndex { ($0["tableName"] as? String) == "SimpleSyncObject" })
            let conflictingID = UUID()
            rows[index]["globalId"] = conflictingID.uuidString.lowercased()
            var fields = try #require(rows[index]["changedFields"] as? [String: Any])
            var value = try #require(fields["value"] as? [String: Any])
            value["value"] = 999
            fields["value"] = value
            rows[index]["changedFields"] = fields
            frame["auditLog"] = rows
            try await writer.socket!.send(Array(try JSONSerialization.data(withJSONObject: frame)))
            try #require(await writer.wait { $0.count(of: "rejected") == 1 })

            // A subsequent accepted frame is the positive ordering barrier for
            // the conflict's no-fanout assertion; no elapsed-time guess is used.
            let later = try donorEntries { try $0.add(SimpleSyncObject(value: 92, floatValue: 1)) }
            let laterIDs = Set(later.compactMap(\.globalId))
            try #require(!laterIDs.isEmpty)
            try await writer.socket!.send(try makeFrame(entries: later))
            try #require(await peer.wait { laterIDs.isSubset(of: Set($0.receivedAuditIds)) })
            #expect(!writer.acks.contains(conflictingID))
            #expect(!peer.receivedAuditIds.contains(conflictingID))
            let store = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
            defer { store.close() }
            #expect(store.objects(SimpleSyncObject.self).contains { $0.value == 91 })
            #expect(store.objects(SimpleSyncObject.self).contains { $0.value == 92 })
            #expect(!store.objects(SimpleSyncObject.self).contains { $0.value == 999 })
            #expect(!store.eventsAfter(globalId: nil).contains { $0.globalId == conflictingID })
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
    }

    @Test(arguments: [false, true])
    func transactionAuthorizationRefusesDeniedOrReentrantlyRevokedFrame(revokeInsideCallback: Bool) async throws {
        let writerID = UUID()
        let current = RelayAdmissionGate()
        let authorizations = RelaySetupCompletions()
        let setups = RelaySetupCompletions()
        let harness = try await RelayHarness(path: ["sync", "group", ":groupID"], schema: [SimpleSyncObject.self],
            onSetupFinished: { setups.noteFinished() },
            transactionAuthorization: { channel, _, _ in
                guard channel.userId == writerID else { return true }
                authorizations.noteFinished()
                if revokeInsideCallback { current.revoke(); return true }
                return false
            },
            channelExtractor: { request in
                let channel = try await groupExtractor(request)
                return SyncChannel(id: channel.id, userId: channel.userId,
                    databaseFileName: channel.databaseFileName,
                    isCurrent: { channel.userId != writerID || current.isAllowed })
            })
        do {
            let writer = try await harness.connect(pathSuffix: "sync/group/g1", user: writerID)
            let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
            try #require(await writer.wait { _ in setups.count == 2 })
            let refused = try donorEntries { try $0.add(SimpleSyncObject(value: 41, floatValue: 1)) }
            let refusedIDs = Set(refused.compactMap(\.globalId))
            try #require(!refusedIDs.isEmpty)
            try await writer.socket!.send(try makeFrame(entries: refused))
            try #require(await writer.wait { _ in authorizations.count > 0 })
            if !revokeInsideCallback {
                try #require(await writer.wait { $0.count(of: "rejected") == 1 })
            }
            let accepted = try donorEntries { try $0.add(SimpleSyncObject(value: 42, floatValue: 1)) }
            let acceptedIDs = Set(accepted.compactMap(\.globalId))
            try #require(!acceptedIDs.isEmpty)
            try await peer.socket!.send(try makeFrame(entries: accepted))
            try #require(await peer.wait { acceptedIDs.isSubset(of: Set($0.acks)) })
            #expect(refusedIDs.isDisjoint(with: Set(writer.acks)))
            #expect(refusedIDs.isDisjoint(with: Set(peer.receivedAuditIds)))
            let store = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: harness.storageURL.appending(path: "group-g1.sqlite")))
            defer { store.close() }
            #expect(store.objects(SimpleSyncObject.self).contains { $0.value == 42 })
            #expect(!store.objects(SimpleSyncObject.self).contains { $0.value == 41 })
            #expect(store.eventsAfter(globalId: nil).allSatisfy { entry in
                entry.globalId.map { !refusedIDs.contains($0) } ?? true
            })
        } catch { await harness.shutdown(); throw error }
        await harness.shutdown()
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
        let setupCompletions = RelaySetupCompletions()
        let policy = SyncWritePolicy(
            allowedOperations: ["SimpleSyncObject": [.insert, .update]],
            unlistedTables: .deny)
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            writePolicy: policy,
            onSetupFinished: { setupCompletions.noteFinished() },
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())
        let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        // Client upgrade is earlier than server setup/catch-up completion.
        // Finish both empty-channel catch-ups before creating the seed, so a
        // delayed legitimate replay cannot contaminate the no-fanout baseline.
        let setupsReady = await a.wait { _ in setupCompletions.count == 2 }
        try #require(setupsReady)

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
        try #require(!insertedIds.isEmpty)
        let seedWasAcked = insertedIds.isSubset(of: Set(a.acks))
        try #require(seedWasAcked)
        // The writer ACK is sent before legacy fan-out is awaited. Identify
        // every exact seed audit event at the peer before freezing its count.
        let seedReachedPeer = await peer.wait {
            insertedIds.isSubset(of: Set($0.receivedAuditIds))
        }
        try #require(seedReachedPeer)
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
        let setupCompletions = RelaySetupCompletions()
        let harness = try await RelayHarness(
            path: ["sync", "group", ":groupID"],
            schema: [SimpleSyncObject.self],
            onSetupFinished: { setupCompletions.noteFinished() },
            channelExtractor: groupExtractor)
        defer { Task { [harness] in await harness.shutdown() } }

        let kicked = UUID()
        let a = try await harness.connect(pathSuffix: "sync/group/g1", user: kicked)
        let peer = try await harness.connect(pathSuffix: "sync/group/g1", user: UUID())

        // Finish both empty-channel catch-ups before creating the warmup.
        // Client upgrade alone does not establish server setup completion.
        let setupsReady = await a.wait { _ in setupCompletions.count == 2 }
        try #require(setupsReady)

        // Establish the connection works pre-kick.
        let warmup = try donorEntries { try $0.add(SimpleSyncObject(value: 11, floatValue: 1)) }
        try await a.socket!.send(try makeFrame(entries: warmup))
        #expect(await a.wait { !$0.acks.isEmpty })
        let warmupIds = Set(warmup.compactMap(\.globalId))
        try #require(!warmupIds.isEmpty)
        let warmupWasAcked = warmupIds.isSubset(of: Set(a.acks))
        try #require(warmupWasAcked)
        // ACK precedes awaited legacy fan-out. Freeze the no-fanout baseline
        // only after this peer has received every exact warmup audit event.
        let warmupReachedPeer = await peer.wait {
            warmupIds.isSubset(of: Set($0.receivedAuditIds))
        }
        try #require(warmupReachedPeer)
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

/// Test-local setup completion count. It carries no socket, database or payload.
private final class RelaySetupCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = 0
    func noteFinished() { lock.withLock { finished += 1 } }
    var count: Int { lock.withLock { finished } }
}
