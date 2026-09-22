import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

@Model class RecoveryAuthorizationHiddenRow {
    var value: Int = 0
    init(value: Int) { self.value = value }
}
private enum RecoveryAuthorizationFixtureError: Error { case timeout, rejected }
private final class RecoveryAuthorizationGate: Sendable {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    init() { let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1)); stream = pair.stream; continuation = pair.continuation }
    func release() { continuation.yield(true); continuation.finish() }
    func wait() async { for await _ in stream { return } }
}
private final class RegisteredRecoveryPeers: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case normal, wrongPeer, wrongSource, wrongScope, held }
    let user = UUID(), token = UUID().uuidString
    let first = SyncRecoveryPeerIdentity(replicaID: "registered-first", receiverIncarnation: UUID(), channelIncarnation: UUID())
    let second = SyncRecoveryPeerIdentity(replicaID: "registered-second", receiverIncarnation: UUID(), channelIncarnation: UUID())
    let sourceA = UUID(), sourceB = UUID(), epoch = UUID()
    let mode: Mode
    let gate = RecoveryAuthorizationGate()
    let calls = NIOLockedValueBox(0)
    let accepted = NIOLockedValueBox<[SyncRecoveryAuthorizationContext]>([])
    init(_ mode: Mode = .normal) { self.mode = mode }
    func channel(_ request: Request) throws -> SyncChannel {
        guard request.headers["X-Registered-Session"] == [token] else { throw Abort(.unauthorized) }
        let group = request.headers.first(name: "X-Registered-Group") ?? "group-a"
        guard group == "group-a" || group == "group-b" else { throw Abort(.forbidden) }
        return SyncChannel(id: group, userId: user)
    }
    func source(_ channel: SyncChannel) throws -> SyncRecoveryMountConfiguration {
        guard channel.userId == user else { throw Abort(.forbidden) }
        return try .init(authority: "registered-service", sourceID: channel.id == "group-a" ? sourceA : sourceB,
            epoch: epoch, localNamespace: "service-local", namespaces: [
                .init(namespaceID: "service-local", coverageID: "local-v1", revision: 1),
                .init(namespaceID: "application", coverageID: "registered-peers-v1", revision: 7)],
            receiptNamespace: "application", models: ["SimpleSyncObject"], durability: .walFull,
            maximumAuthorizationMilliseconds: 60_000)
    }
    func authorize(_ request: Request, _ context: SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization {
        // This is an actual trusted fixture registration lookup: a valid user
        // token does not authorize an unknown or retired store incarnation.
        let actual = try channel(request)
        guard actual.id == context.channel.id, actual.userId == context.channel.userId,
              context.declaredPeer == first || context.declaredPeer == second,
              context.source.sourceID == (actual.id == "group-a" ? sourceA : sourceB), context.source.epoch == epoch,
              context.source.receiptNamespace == "application", context.source.coverageRevision == 7,
              context.incomingScope.models.map(\.table) == ["SimpleSyncObject"],
              context.incomingScope.models[0].incomingOperations == [.insert, .update, .delete],
              context.source.schemaDigest == context.incomingScope.catalogDigest
        else { throw Abort(.forbidden) }
        calls.withLockedValue { $0 += 1 }
        if mode == .held { await gate.wait() }
        var peer = context.declaredPeer, source = context.source, scope = context.incomingScope
        if mode == .wrongPeer { peer = context.declaredPeer == first ? second : first }
        if mode == .wrongSource {
            source = .init(authority: source.authority, sourceID: UUID(), epoch: source.epoch, scopeDigest: source.scopeDigest,
                schemaDigest: source.schemaDigest, receiptNamespace: source.receiptNamespace, coverageID: source.coverageID,
                coverageRevision: source.coverageRevision, descriptorDigest: source.descriptorDigest)
        }
        if mode == .wrongScope { scope = .init(models: [], relations: [], scopedLinkTables: [], catalogDigest: scope.catalogDigest) }
        accepted.withLockedValue { $0.append(context) }
        return .init(authenticatedUserID: user, peer: peer, source: source, incomingScope: scope,
                     authorizationRevision: "registration-7", validForMilliseconds: 60_000)
    }
}
private final class RecoveryAuthorizationPeer: @unchecked Sendable {
    struct Facts { var kinds: [String] = []; var acks: [String] = []; var audits: [String] = []; var closed = false }
    let facts = NIOLockedValueBox(Facts())
    private let transport = NIOLockedValueBox<WebSocket?>(nil)
    var socket: WebSocket? { transport.withLockedValue { $0 } }
    func attach(_ socket: WebSocket) {
        transport.withLockedValue { $0 = socket }
        socket.onBinary { [weak self] _, bytes in
            guard let self, let root = (try? JSONSerialization.jsonObject(with: Data(buffer: bytes))) as? [String: Any] else { return }
            facts.withLockedValue { value in
                value.kinds.append(root["kind"] as? String ?? "?")
                value.acks += (root["ack"] as? [String] ?? []).map { $0.lowercased() }
                value.audits += (root["auditLog"] as? [[String: Any]] ?? []).compactMap { ($0["globalId"] as? String)?.lowercased() }
            }
        }
        socket.onClose.whenComplete { [weak self] _ in self?.facts.withLockedValue { $0.closed = true } }
    }
    func wait(_ predicate: @escaping @Sendable (Facts) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !Task.isCancelled {
            if facts.withLockedValue({ predicate($0) }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RecoveryAuthorizationFixtureError.timeout
    }
}
private final class RecoveryAuthorizationHarness: @unchecked Sendable {
    let app: Application
    let directory: URL
    let registrations: RegisteredRecoveryPeers
    let writer: SyncRelayHandle
    let observer: SyncRelayHandle
    let port: Int
    private let peers = NIOLockedValueBox<[RecoveryAuthorizationPeer]>([])
    init(_ registrations: RegisteredRecoveryPeers = .init(), seedHidden: Bool = false) async throws {
        self.registrations = registrations
        directory = FileManager.default.temporaryDirectory.appending(path: "relay-recovery-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if seedHidden {
            let seed = try Lattice(isolation: nil, for: [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self],
                                   configuration: .init(fileURL: directory.appending(path: "group-a.sqlite")))
            try seed.transaction {
                for index in 0..<101 { try seed.add(RecoveryAuthorizationHiddenRow(value: index)) }
                try seed.add(SimpleSyncObject(value: 42, floatValue: 1))
            }
            seed.close()
        }
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let created = try await Application.make(environment)
        app = created
        app.http.server.configuration.port = 0; app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        writer = Lattice.configureSyncRelay(on: app.routes, path: ["writer"],
            for: [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self], storageURL: directory,
            recoverySource: { try registrations.source($0) }, channelExtractor: { try registrations.channel($0) },
            recoveryAuthorization: { try await registrations.authorize($0, $1) })
        observer = Lattice.configureSyncRelay(on: app.routes, path: ["observer"],
            for: [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self], storageURL: directory,
            writePolicy: .init(allowedOperations: [:], unlistedTables: .deny),
            observerPush: .init(reconcileInterval: nil), recoverySource: { try registrations.source($0) },
            channelExtractor: { try registrations.channel($0) }, recoveryAuthorization: { try await registrations.authorize($0, $1) })
        do { try await created.startup(); port = try #require(created.http.server.shared.localAddress?.port) }
        catch { try? await created.asyncShutdown(); throw error }
    }
    func connect(_ peer: SyncRecoveryPeerIdentity? = nil, mount: String = "writer", group: String = "group-a", duplicateDeclaration: Bool = false) async throws -> RecoveryAuthorizationPeer {
        let declared = peer ?? registrations.first
        let query = "recovery-v=1&recovery-replica=\(declared.replicaID)&recovery-receiver=\(declared.receiverIncarnation)&recovery-channel=\(declared.channelIncarnation)"
            + (duplicateDeclaration ? "&recovery-v=1" : "")
        let client = RecoveryAuthorizationPeer(); peers.withLockedValue { $0.append(client) }
        var headers = HTTPHeaders(); headers.add(name: "X-Registered-Session", value: registrations.token)
        headers.add(name: "X-Registered-Group", value: group)
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 1 << 20
        try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/\(mount)?\(query)", headers: headers,
            configuration: configuration, on: app.eventLoopGroup) { client.attach($0) }.get()
        return client
    }
    func inspect(group: String = "group-a") async throws -> (Int, [Int], Int) {
        let url = directory.appending(path: "\(group).sqlite")
        return try await withCheckedThrowingContinuation { continuation in
            RelayExecutionPool.io.submitRequired(for: FileWatchManager.canonicalKey(for: url)) {
                do {
                    let actual = try Lattice(isolation: nil, for: [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self], configuration: .init(fileURL: url))
                    continuation.resume(returning: (actual.objects(SimpleSyncObject.self).count,
                        Array(actual.objects(SimpleSyncObject.self)).map(\.value), actual.objects(AuditLog.self).count))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func shutdown() async throws {
        registrations.gate.release()
        let clients = peers.withLockedValue { $0 }
        for peer in clients { peer.socket?.close(promise: nil) }
        await writer.retireRecoveryAuthorization(); await observer.retireRecoveryAuthorization()
        try await app.asyncShutdown()
        for peer in clients { try await peer.wait { $0.closed } }
        let deadline = Date().addingTimeInterval(10)
        while (writer.recoverySessionCount != 0 || observer.recoverySessionCount != 0), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(writer.recoverySessionCount == 0); #expect(observer.recoverySessionCount == 0)
        // The checkpoint governor can retain a source owner. Do not unlink a
        // live WAL/custody directory beneath it; this UUID fixture is retained.
    }
}
private func withRecoveryAuthorizationHarness(_ mode: RegisteredRecoveryPeers.Mode = .normal, seedHidden: Bool = false,
    _ body: @escaping (RecoveryAuthorizationHarness) async throws -> Void) async throws {
    let harness = try await RecoveryAuthorizationHarness(.init(mode), seedHidden: seedHidden)
    do { try await body(harness); try await harness.shutdown() }
    catch { let original = error; do { try await harness.shutdown() } catch { Issue.record("authorization cleanup: \(error)") }; throw original }
}
private func recoveryDonorFrame(_ value: Int) throws -> (Data, [String]) {
    let donor = try Lattice(isolation: nil, SimpleSyncObject.self, configuration: .init(storage: .memory()))
    defer { donor.close() }
    try donor.add(SimpleSyncObject(value: value, floatValue: 1))
    let entries = Array(donor.eventsAfter(globalId: nil))
    return (try JSONEncoder().encode(ServerSentEvent.auditLog(entries)), entries.compactMap { $0.globalId?.uuidString.lowercased() })
}
@Suite("Actual registered-peer relay authorization", .timeLimit(.minutes(2)))
private struct RelayRecoveryAuthorizationTests {
    @Test func registeredReplicasShareActualSourceAndLostAckReplayDeduplicates() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let a = try await h.connect(), b = try await h.connect(h.registrations.second)
            let (frame, ids) = try recoveryDonorFrame(42)
            try await a.socket!.send(Array(frame)); try await a.wait { Set(ids).isSubset(of: Set($0.acks)) }
            try await b.wait { Set(ids).isSubset(of: Set($0.audits)) }
            let before = try await h.inspect(); #expect(before.0 == 1); #expect(before.1 == [42])
            let ackCount = a.facts.withLockedValue { $0.acks.count }
            try await a.socket!.send(Array(frame)); try await a.wait { $0.acks.count == ackCount + ids.count }
            let after = try await h.inspect(); #expect(after.0 == before.0); #expect(after.2 == before.2)
            #expect(h.registrations.accepted.withLockedValue { Set($0.map(\.declaredPeer.replicaID)).count } == 2)
        }
    }
    @Test(arguments: [RegisteredRecoveryPeers.Mode.wrongPeer, .wrongSource, .wrongScope])
    func mismatchedApplicationOutcomesCannotDrainBufferedUploads(mode: RegisteredRecoveryPeers.Mode) async throws {
        try await withRecoveryAuthorizationHarness(mode) { h in
            let client = try await h.connect(); let (frame, _) = try recoveryDonorFrame(7)
            try? await client.socket!.send(Array(frame)); try await client.wait { $0.closed }
            #expect(client.facts.withLockedValue { $0.acks.isEmpty }); #expect(try await h.inspect().0 == 0)
        }
    }
    @Test func AuthenticatedUserCannotInventAnotherRegisteredReceiverIncarnation() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let forged = SyncRecoveryPeerIdentity(replicaID: h.registrations.first.replicaID,
                receiverIncarnation: UUID(), channelIncarnation: h.registrations.first.channelIncarnation)
            let client = try await h.connect(forged); try await client.wait { $0.closed }
            #expect(h.registrations.calls.withLockedValue { $0 } == 0)
            #expect(client.facts.withLockedValue { $0.acks.isEmpty })
        }
    }
    @Test func closeDuringActualAuthorizationRefusesLateResultAndReleasesCapacity() async throws {
        try await withRecoveryAuthorizationHarness(.held) { h in
            let client = try await h.connect(); let (frame, _) = try recoveryDonorFrame(9)
            try await client.socket!.send(Array(frame))
            let deadline = Date().addingTimeInterval(10)
            while h.registrations.calls.withLockedValue({ $0 }) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(h.registrations.calls.withLockedValue { $0 } == 1)
            try await client.socket!.close(); h.registrations.gate.release(); try await client.wait { $0.closed }
            #expect(client.facts.withLockedValue { $0.acks.isEmpty }); #expect(try await h.inspect().0 == 0)
        }
    }
    @Test func denyAllObserverStillReceivesItsAuthorizedScopeFromSharedMount() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let watcher = try await h.connect(h.registrations.second, mount: "observer"), writer = try await h.connect()
            let (frame, ids) = try recoveryDonorFrame(11)
            try await writer.socket!.send(Array(frame)); try await writer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            try await watcher.wait { Set(ids).isSubset(of: Set($0.audits)) }
            let (denied, _) = try recoveryDonorFrame(12); try await watcher.socket!.send(Array(denied))
            try await watcher.wait { $0.kinds.contains("rejected") }
            #expect(try await h.inspect().1 == [11])
        }
    }
    @Test func catchupSkipsWholeUnapprovedPageAndPreservesOrderedContinuation() async throws {
        try await withRecoveryAuthorizationHarness(seedHidden: true) { h in
            let watcher = try await h.connect(mount: "observer")
            try await watcher.wait { $0.audits.count == 1 }
            #expect(watcher.facts.withLockedValue { $0.audits.count } == 1)
            #expect(try await h.inspect().0 == 1)
        }
    }
    @Test func trustedPerChannelSourceProviderKeepsDifferentFilesDistinct() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let a = try await h.connect(), b = try await h.connect(h.registrations.second, group: "group-b")
            let (frame, ids) = try recoveryDonorFrame(71)
            try await a.socket!.send(Array(frame)); try await a.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let (other, otherIDs) = try recoveryDonorFrame(72)
            try await b.socket!.send(Array(other)); try await b.wait { Set(otherIDs).isSubset(of: Set($0.acks)) }
            #expect(try await h.inspect().1 == [71]); #expect(try await h.inspect(group: "group-b").1 == [72])
            #expect(h.registrations.accepted.withLockedValue { Set($0.map(\.source.sourceID)).count } == 2)
        }
    }
    @Test func actualMembershipKickStopsFurtherUploadWithoutReclassifyingPriorAcceptance() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let client = try await h.connect(); let (first, ids) = try recoveryDonorFrame(91)
            try await client.socket!.send(Array(first)); try await client.wait { Set(ids).isSubset(of: Set($0.acks)) }
            await h.writer.disconnect(channelId: "group-a", userId: h.registrations.user)
            let (late, lateIDs) = try recoveryDonorFrame(92); try? await client.socket!.send(Array(late))
            try await client.wait { $0.closed }
            #expect(client.facts.withLockedValue { Set(lateIDs).isDisjoint(with: Set($0.acks)) })
            #expect(try await h.inspect().1 == [91])
        }
    }
    @Test func duplicatePeerDeclarationIsRefusedBeforeApplicationAuthorization() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let peer = try await h.connect(duplicateDeclaration: true); try await peer.wait { $0.closed }
            #expect(h.registrations.calls.withLockedValue { $0 } == 0)
        }
    }
}
