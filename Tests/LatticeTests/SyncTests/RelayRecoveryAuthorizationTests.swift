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
    enum Mode: Sendable, Equatable { case normal, wrongPeer, wrongSource, wrongScope, held, heldSecondApproved, heldSecondDenied, readyLarge, readyParked }
    let user = UUID(), token = UUID().uuidString
    let first = SyncRecoveryPeerIdentity(replicaID: "registered-first", receiverIncarnation: UUID(), channelIncarnation: UUID())
    let second = SyncRecoveryPeerIdentity(replicaID: "registered-second", receiverIncarnation: UUID(), channelIncarnation: UUID())
    let sourceA = UUID(), sourceB = UUID(), epoch = UUID()
    let mode: Mode
    let gate = RecoveryAuthorizationGate()
    let readySendGate = RecoveryReadySendGate()
    let calls = NIOLockedValueBox(0)
    let accepted = NIOLockedValueBox<[SyncRecoveryAuthorizationContext]>([])
    let heldSecondEntered = NIOLockedValueBox(false)
    let fanoutDecisions = NIOLockedValueBox<[Bool]>([])
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
            receiptNamespace: "application", models: mode == .readyLarge ? ["RecoveryReadyPayloadRow"] : ["SimpleSyncObject"], durability: .walFull,
            maximumAuthorizationMilliseconds: mode == .readyLarge ? 600_000 : 60_000,
            readyProfile: mode == .readyLarge ? .bounded48MiBV1 : .boundedV1)
    }
    func authorize(_ request: Request, _ context: SyncRecoveryAuthorizationContext) async throws -> SyncRecoveryAuthorization {
        // This is an actual trusted fixture registration lookup: a valid user
        // token does not authorize an unknown or retired store incarnation.
        let actual = try channel(request)
        guard actual.id == context.channel.id, actual.userId == context.channel.userId,
              context.declaredPeer == first || context.declaredPeer == second,
              context.source.sourceID == (actual.id == "group-a" ? sourceA : sourceB), context.source.epoch == epoch,
              context.source.receiptNamespace == "application", context.source.coverageRevision == 7,
              context.incomingScope.models.map(\.table) == (mode == .readyLarge ? ["RecoveryReadyPayloadRow"] : ["SimpleSyncObject"]),
              context.incomingScope.models[0].incomingOperations == [.insert, .update, .delete],
              context.source.schemaDigest == context.incomingScope.catalogDigest
        else { throw Abort(.forbidden) }
        calls.withLockedValue { $0 += 1 }
        if mode == .held { await gate.wait() }
        if context.declaredPeer == second, mode == .heldSecondApproved || mode == .heldSecondDenied {
            heldSecondEntered.withLockedValue { $0 = true }
            await gate.wait()
            if mode == .heldSecondDenied { throw Abort(.forbidden) }
        }
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
                     authorizationRevision: "registration-7", validForMilliseconds: mode == .readyLarge ? 600_000 : 60_000)
    }
}
private final class RecoveryAuthorizationPeer: @unchecked Sendable {
    struct Facts { var kinds: [String] = []; var acks: [String] = []; var audits: [String] = []; var closed = false; var ready: [String: Data] = [:]; var canonical: [Data] = [] }
    let facts = NIOLockedValueBox(Facts())
    private let transport = NIOLockedValueBox<WebSocket?>(nil)
    var socket: WebSocket? { transport.withLockedValue { $0 } }
    func attach(_ socket: WebSocket) {
        transport.withLockedValue { $0 = socket }
        socket.onBinary { [weak self] _, bytes in
            guard let self, let root = (try? JSONSerialization.jsonObject(with: Data(buffer: bytes))) as? [String: Any] else { return }
            facts.withLockedValue { value in
                value.kinds.append(root["kind"] as? String ?? "?")
                if root["kind"] as? String == "recoveryReady", let requestID = root["requestID"] as? String, value.ready.count < 64 {
                    value.ready[requestID] = Data(buffer: bytes)
                }
                if root["latticeCanonicalRange"] != nil, value.canonical.count < 16 { value.canonical.append(Data(buffer: bytes)) }
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
        let hooks: RelayIngressTestHooks?
        if registrations.mode == .heldSecondApproved || registrations.mode == .heldSecondDenied || registrations.mode == .readyParked {
            hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: {},
                didRecoveryFanoutDecision: { allowed in
                    registrations.fanoutDecisions.withLockedValue { if $0.count < 16 { $0.append(allowed) } }
                }, parkRecoveryReadySend: { id, send in registrations.readySendGate.park(id, send) },
                didRecoveryReadyDecision: { id, allowed in registrations.readySendGate.decision(id, allowed) })
            RelayIngressTesting.install(hooks!, for: directory)
        } else { hooks = nil }
        defer { if let hooks { RelayIngressTesting.remove(hooks, for: directory) } }
        let relaySchema: [any Lattice.Model.Type] = registrations.mode == .readyLarge
            ? [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self, RecoveryReadyPayloadRow.self]
            : [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self]
        writer = Lattice.configureSyncRelay(on: app.routes, path: ["writer"],
            for: relaySchema, storageURL: directory,
            recoverySource: { try registrations.source($0) }, channelExtractor: { try registrations.channel($0) },
            recoveryAuthorization: { try await registrations.authorize($0, $1) })
        observer = Lattice.configureSyncRelay(on: app.routes, path: ["observer"],
            for: relaySchema, storageURL: directory,
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
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = registrations.mode == .readyLarge ? 8 << 20 : 1 << 20
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
        registrations.readySendGate.release()
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

    @Test(arguments: [RegisteredRecoveryPeers.Mode.heldSecondApproved, .heldSecondDenied])
    func pendingRecipientReceivesNothingBeforeActualAuthorizationDecision(mode: RegisteredRecoveryPeers.Mode) async throws {
        try await withRecoveryAuthorizationHarness(mode) { h in
            let a = try await h.connect(), b = try await h.connect(h.registrations.second)
            func waitFor(_ predicate: @escaping @Sendable () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(10)
                while !predicate(), Date() < deadline, !Task.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
                try #require(predicate())
            }
            try await waitFor { h.registrations.heldSecondEntered.withLockedValue { $0 } }
            let (first, firstIDs) = try recoveryDonorFrame(121)
            try await a.socket!.send(Array(first)); try await a.wait { Set(firstIDs).isSubset(of: Set($0.acks)) }
            // The exact real recipient loop has rejected this publication.
            // Waiting for A's ACK alone would not prove fan-out had run yet.
            try await waitFor { h.registrations.fanoutDecisions.withLockedValue { !$0.isEmpty } }
            #expect(h.registrations.fanoutDecisions.withLockedValue { $0 } == [false])
            #expect(b.facts.withLockedValue { $0.audits.isEmpty && $0.acks.isEmpty })
            #expect(h.writer.recoverySessionCount == 2)
            h.registrations.gate.release()
            if mode == .heldSecondDenied {
                try await b.wait { $0.closed }
                #expect(b.facts.withLockedValue { $0.audits.isEmpty && $0.acks.isEmpty })
            } else {
                // Once approved, catch-up must include the withheld original.
                try await b.wait { Set(firstIDs).isSubset(of: Set($0.audits)) }
            }
            let (second, secondIDs) = try recoveryDonorFrame(122)
            try await a.socket!.send(Array(second)); try await a.wait { Set(secondIDs).isSubset(of: Set($0.acks)) }
            if mode == .heldSecondApproved {
                try await b.wait { Set(secondIDs).isSubset(of: Set($0.audits)) }
                try await waitFor { h.registrations.fanoutDecisions.withLockedValue { $0.contains(true) } }
                #expect(h.registrations.accepted.withLockedValue { Set($0.map(\.declaredPeer.replicaID)).count } == 2)
            } else {
                #expect(b.facts.withLockedValue { $0.closed && $0.audits.isEmpty && $0.acks.isEmpty })
                #expect(h.registrations.accepted.withLockedValue { $0.map(\.declaredPeer.replicaID) } == [h.registrations.first.replicaID])
            }
            let rows = try await h.inspect(); #expect(rows.0 == 2); #expect(Set(rows.1) == Set([121, 122]))
        }
    }
}


@Model class RecoveryReadyPayloadRow {
    var sequence: Int = 0
    var content: String = ""
    init(sequence: Int, content: String) { self.sequence = sequence; self.content = content }
}
private final class RecoveryReadySendGate: Sendable {
    private struct State {
        var id: String?; var send: (@Sendable () -> Void)?; var parked = false
        var decisions: [String: Bool] = [:]
    }
    private let state = NIOLockedValueBox(State())
    func arm(_ id: String) { state.withLockedValue { precondition($0.send == nil); $0.id = id; $0.parked = false } }
    func park(_ id: String, _ send: @escaping @Sendable () -> Void) -> Bool {
        state.withLockedValue { s in
            guard s.id == id, s.send == nil else { return false }
            s.send = send; s.parked = true; return true
        }
    }
    var parked: Bool { state.withLockedValue { $0.parked } }
    func release() {
        let send = state.withLockedValue { s in let held = s.send; s.send = nil; s.id = nil; return held }
        send?()
    }
    func decision(_ id: String, _ allowed: Bool) { state.withLockedValue { if $0.decisions.count < 64 { $0.decisions[id] = allowed } } }
    func decision(_ id: String) -> Bool? { state.withLockedValue { $0.decisions[id] } }
}
private func readyObject(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
private func readyWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !Task.isCancelled {
        if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw RecoveryAuthorizationFixtureError.timeout
}
private struct ReadyTestControl: Encodable {
    let kind = "recoveryReady", version = 1
    var operation: String
    var requestID = UUID().uuidString.lowercased()
    var routeGeneration: String?, request: String?, durationMilliseconds: Int64?
    var leaseID: String?, requestDigest: String?, attemptID: String?, sequence: String?, index: String?
    func data() throws -> Data { try JSONEncoder().encode(self) }
}
private extension RecoveryAuthorizationPeer {
    func ready(_ command: ReadyTestControl) async throws -> Data {
        let id = command.requestID, data = try command.data()
        let actual = try #require(socket)
        try await actual.send(Array(data))
        try await wait { $0.ready[id] != nil }
        return try #require(facts.withLockedValue { $0.ready.removeValue(forKey: id) })
    }
    func readyFrame(_ command: ReadyTestControl) async throws -> Data {
        let actual = try #require(socket)
        try await actual.send(Array(try command.data()))
        try await wait { !$0.canonical.isEmpty }
        return facts.withLockedValue { $0.canonical.removeFirst() }
    }
}
private struct ReadyRequestHash {
    private var hash = SHA256()
    mutating func byte(_ value: UInt8) { hash.update(data: Data([value])) }
    mutating func number(_ value: UInt64) {
        var big = value.bigEndian; withUnsafeBytes(of: &big) { hash.update(data: Data($0)) }
    }
    mutating func string(_ value: String) { number(UInt64(value.utf8.count)); hash.update(data: Data(value.utf8)) }
    mutating func digest(_ value: String) throws {
        let chars = Array(value); guard chars.count == 64 else { throw RecoveryAuthorizationFixtureError.rejected }
        var bytes: [UInt8] = []; bytes.reserveCapacity(32)
        for i in stride(from: 0, to: 64, by: 2) {
            bytes.append(try #require(UInt8(String(chars[i...(i+1)]), radix: 16)))
        }
        hash.update(data: Data(bytes))
    }
    mutating func source(_ value: [String: String]) throws {
        for key in ["authority", "source_id", "epoch"] { string(try #require(value[key])) }
        for key in ["scope_digest", "schema_digest"] { try digest(#require(value[key])) }
    }
    mutating func finish() -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
}
private struct ReadyTestRequest {
    let wire: String, digest: String, attempt: String, sequence: String
}
private func readyRequest(_ descriptor: Data, sequence: Int = 1, originals: Data? = nil,
                          peerOverride: UUID? = nil) throws -> ReadyTestRequest {
    let d = try readyObject(descriptor)
    let source = try #require(d["source"] as? [String: Any]), peer = try #require(d["peer"] as? [String: Any])
    let profile = try #require(d["profile"] as? [String: Any]), budget = try #require(profile["wire"] as? [String: String])
    let channel = try #require(d["channel"] as? String), route = try #require(d["routeGeneration"] as? String)
    var binding: [String: String] = [:]
    for (key, wire) in [("authority", "authority"), ("sourceID", "source_id"), ("epoch", "epoch"), ("scopeDigest", "scope_digest"), ("schemaDigest", "schema_digest")] {
        binding[wire] = try #require(source[key] as? String)
    }
    let receiver: String
    if let peerOverride { receiver = peerOverride.uuidString.lowercased() }
    else { receiver = try #require(peer["receiverIncarnation"] as? String) }
    let incarnation = try #require(peer["channelIncarnation"] as? String), attempt = UUID().uuidString.lowercased()
    let logical: [String: String] = ["receiver_incarnation": receiver, "channel_incarnation": incarnation,
        "channel": channel, "sequence": String(sequence), "attempt_id": attempt]
    let entries = try originals.map { data in
        let object = try readyObject(data); return try #require(object["auditLog"] as? [[String: Any]])
    } ?? []
    var receipts: [[String: Any]] = []
    for entry in entries {
        let original = try #require(entry["globalId"] as? String).lowercased()
        let target = try #require(entry["globalRowId"] as? String).lowercased()
        receipts.append(["original_id": original, "provenance": ["kind": "negotiated", "namespace_id": try #require(source["receiptNamespace"] as? String)],
                         "targets": [["table": try #require(entry["tableName"] as? String), "id": target]]])
    }
    receipts.sort { ($0["original_id"] as! String) < ($1["original_id"] as! String) }
    var h = ReadyRequestHash(); h.string("lattice.canonical-range.v2/request")
    h.string(receiver); h.string(incarnation); h.string(channel); h.number(UInt64(sequence)); h.string(attempt)
    try h.source(binding); h.string("full"); h.byte(0); h.number(0); h.byte(1); try h.source(binding); h.string("uninitialized")
    for key in ["frame_bytes", "payload_bytes", "items_per_page", "content_pages", "content_identities", "content_bytes", "receipt_pages", "receipts", "receipt_bytes"] {
        let spelling = try #require(budget[key]); h.number(try #require(UInt64(spelling)))
    }
    h.number(UInt64(receipts.count))
    for receipt in receipts {
        h.string(receipt["original_id"] as! String); h.string("negotiated"); h.string(try #require(source["receiptNamespace"] as? String)); h.number(1)
        let target = (receipt["targets"] as! [[String: String]])[0]; h.string(target["table"]!); h.string(target["id"]!)
    }
    let digest = h.finish()
    let body: [String: Any] = ["source": binding, "mode": "full", "base": NSNull(),
        "expected_install": ["revision": "0", "binding": binding, "frontier": ["kind": "uninitialized"]],
        "limits": budget, "receipt_requests": receipts, "request_digest": digest]
    let encoded = try JSONSerialization.data(withJSONObject: ["latticeCanonicalRange": ["version": 2, "attempt": logical,
        "route_generation": route, "kind": "request", "body": body]], options: [.sortedKeys])
    return .init(wire: String(decoding: encoded, as: UTF8.self), digest: digest, attempt: attempt, sequence: String(sequence))
}
private func readyOffer(_ request: ReadyTestRequest, descriptor: Data, op: String = "prepare", duration: Int64 = 10_000) throws -> ReadyTestControl {
    var c = ReadyTestControl(operation: op); c.routeGeneration = try #require(readyObject(descriptor)["routeGeneration"] as? String)
    c.request = request.wire; if op != "discard" { c.durationMilliseconds = duration }; return c
}
private func readyRead(_ offer: Data, index: Int) throws -> ReadyTestControl {
    let d = try readyObject(offer); var c = ReadyTestControl(operation: "read")
    c.routeGeneration = try #require(d["routeGeneration"] as? String); c.leaseID = try #require(d["leaseID"] as? String)
    c.requestDigest = try #require(d["requestDigest"] as? String); c.attemptID = try #require(d["attemptID"] as? String)
    c.sequence = try #require(d["sequence"] as? String); c.index = String(index); return c
}
@Suite("Actual mounted authenticated READY controls", .timeLimit(.minutes(3)))
private struct RelayAuthenticatedReadyTests {
    @Test func ordinaryUploadAboveOneMiBStillRefusesOnRecoveryMount() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let peer = try await h.connect(); _ = try await peer.ready(.init(operation: "describe"))
            let prefix = "{\"auditLog\":[],\"padding\":\"", suffix = "\"}"
            let oversized = Data((prefix + String(repeating: "x", count: 1_048_577 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
            #expect(oversized.count == 1_048_577)
            try await peer.socket!.send(Array(oversized)); try await peer.wait { $0.kinds.contains("rejected") }
            #expect(peer.facts.withLockedValue { $0.acks.isEmpty && $0.canonical.isEmpty }); #expect(try await h.inspect().0 == 0)
        }
    }

    @Test func realMountDescribesPreparesAndSendsEveryFrameWithoutLegacyBroadcast() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let a = try await h.connect(), b = try await h.connect(h.registrations.second)
            let (upload, ids) = try recoveryDonorFrame(711)
            try await a.socket!.send(Array(upload)); try await a.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let description = try await a.ready(.init(operation: "describe"))
            let q = try readyRequest(description, originals: upload)
            let offer = try await a.ready(readyOffer(q, descriptor: description))
            let offered = try readyObject(offer); #expect(offered["leaseAvailable"] as? Bool == true)
            let count = try #require(Int(#require(offered["frames"] as? String)))
            var kinds: [String] = [], found: [String] = []
            for index in 0..<count {
                let frame = try readyObject(await a.readyFrame(readyRead(offer, index: index)))
                let inner = try #require(frame["latticeCanonicalRange"] as? [String: Any])
                kinds.append(try #require(inner["kind"] as? String))
                if inner["kind"] as? String == "receipt_page" {
                    let body = try #require(inner["body"] as? [String: Any])
                    for item in try #require(body["items"] as? [[String: Any]]) {
                        #expect(item["status"] as? String == "committed"); found.append(try #require(item["original_id"] as? String))
                    }
                }
            }
            #expect(kinds.first == "manifest"); #expect(kinds.last == "end"); #expect(Set(found) == Set(ids))
            #expect(b.facts.withLockedValue { $0.ready.isEmpty && $0.canonical.isEmpty })
            #expect(try await h.inspect().0 == 1)
        }
    }
    @Test func denyAllObserverCanReadCanonicalSourceButCannotUpload() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let a = try await h.connect(), observer = try await h.connect(h.registrations.second, mount: "observer")
            let (upload, ids) = try recoveryDonorFrame(712); try await a.socket!.send(Array(upload)); try await a.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let description = try await observer.ready(.init(operation: "describe")), q = try readyRequest(description)
            let offer = try await observer.ready(readyOffer(q, descriptor: description))
            #expect(try readyObject(await observer.readyFrame(readyRead(offer, index: 0)))["latticeCanonicalRange"] != nil)
            try await observer.socket!.send(Array(upload)); try await observer.wait { $0.kinds.contains("rejected") }
            #expect(try await h.inspect().0 == 1)
        }
    }
    @Test func changedRegisteredReceiverAndMixedControlRefuseBeforeEffects() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let peer = try await h.connect(), description = try await peer.ready(.init(operation: "describe"))
            let q = try readyRequest(description, peerOverride: UUID())
            try await peer.socket!.send(Array(try readyOffer(q, descriptor: description).data()))
            try await peer.wait { $0.kinds.contains("rejected") }; #expect(try await h.inspect().0 == 0)
            let before = peer.facts.withLockedValue { $0.kinds.filter { $0 == "rejected" }.count }
            var mixed = try readyObject(ReadyTestControl(operation: "describe").data()); mixed["auditLog"] = []
            try await peer.socket!.send(Array(try JSONSerialization.data(withJSONObject: mixed)))
            try await peer.wait { $0.kinds.filter { $0 == "rejected" }.count > before }
            #expect(peer.facts.withLockedValue { $0.acks.isEmpty && $0.canonical.isEmpty }); #expect(try await h.inspect().0 == 0)
        }
    }
    @Test(arguments: [false, true]) func heldRealAuthorizationNeverPublishesDescribeBeforeDecision(deny: Bool) async throws {
        let mode: RegisteredRecoveryPeers.Mode = deny ? .heldSecondDenied : .heldSecondApproved
        try await withRecoveryAuthorizationHarness(mode) { h in
            let peer = try await h.connect(h.registrations.second); let describe = ReadyTestControl(operation: "describe")
            try await peer.socket!.send(Array(try describe.data()))
            try await readyWait { h.registrations.heldSecondEntered.withLockedValue { $0 } }
            #expect(peer.facts.withLockedValue { $0.ready.isEmpty && $0.canonical.isEmpty })
            h.registrations.gate.release()
            if deny { try await peer.wait { $0.closed }; #expect(peer.facts.withLockedValue { $0.ready.isEmpty && $0.canonical.isEmpty }) }
            else { let id = describe.requestID; try await peer.wait { $0.ready[id] != nil } }
        }
    }
    @Test func keeperReconnectResumesSameCapsuleWithFreshPhysicalGeneration() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let first = try await h.connect(), keeper = try await h.connect(h.registrations.second)
            let before = try await first.ready(.init(operation: "describe")); let q = try readyRequest(before)
            let offer = try await first.ready(readyOffer(q, descriptor: before)); let original = try await first.readyFrame(readyRead(offer, index: 0))
            try await first.socket!.close(); try await first.wait { $0.closed }
            let next = try await h.connect(), after = try await next.ready(.init(operation: "describe"))
            var raw = try readyObject(Data(q.wire.utf8)), inner = try #require(raw["latticeCanonicalRange"] as? [String: Any])
            inner["route_generation"] = try readyObject(after)["routeGeneration"]; raw["latticeCanonicalRange"] = inner
            let replacement = ReadyTestRequest(wire: String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self), digest: q.digest, attempt: q.attempt, sequence: q.sequence)
            let renewed = try await next.ready(readyOffer(replacement, descriptor: after, op: "resume"))
            let current = try readyObject(await next.readyFrame(readyRead(renewed, index: 0)))
            var old = try readyObject(original), oldInner = try #require(old["latticeCanonicalRange"] as? [String: Any])
            oldInner["route_generation"] = try readyObject(after)["routeGeneration"]; old["latticeCanonicalRange"] = oldInner
            #expect(NSDictionary(dictionary: old).isEqual(to: current)); #expect(!keeper.facts.withLockedValue { $0.closed })
        }
    }
    @Test(arguments: ["close", "kick", "resume", "discard", "expiry"])
    func parkedActualSendRechecksItsExactLeaseOnSocketLoop(action: String) async throws {
        try await withRecoveryAuthorizationHarness(.readyParked) { h in
            let first = try await h.connect(), other = try await h.connect()
            let d = try await first.ready(.init(operation: "describe")), q = try readyRequest(d)
            let offer = try await first.ready(readyOffer(q, descriptor: d, duration: action == "expiry" ? 1_000 : 10_000))
            let command = try readyRead(offer, index: 0), id = command.requestID
            h.registrations.readySendGate.arm(id); try await first.socket!.send(Array(try command.data()))
            try await readyWait { h.registrations.readySendGate.parked }
            #expect(first.facts.withLockedValue { $0.canonical.isEmpty })
            if action == "close" { try await first.socket!.close(); try await first.wait { $0.closed } }
            else if action == "kick" { await h.writer.disconnect(channelId: "group-a", userId: h.registrations.user); try await first.wait { $0.closed } }
            else if action == "expiry" { try await Task.sleep(nanoseconds: 1_100_000_000) }
            else {
                let next = try await other.ready(.init(operation: "describe"))
                var raw = try readyObject(Data(q.wire.utf8)), inner = try #require(raw["latticeCanonicalRange"] as? [String: Any])
                inner["route_generation"] = try readyObject(next)["routeGeneration"]; raw["latticeCanonicalRange"] = inner
                let same = ReadyTestRequest(wire: String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self), digest: q.digest, attempt: q.attempt, sequence: q.sequence)
                let reply = try await other.ready(readyOffer(same, descriptor: next, op: action))
                if action == "resume" { _ = try await other.readyFrame(readyRead(reply, index: 0)) }
            }
            h.registrations.readySendGate.release(); try await readyWait { h.registrations.readySendGate.decision(id) != nil }
            #expect(h.registrations.readySendGate.decision(id) == false); #expect(first.facts.withLockedValue { $0.canonical.isEmpty })
        }
    }
}

// A separate budgeted fixture for the frozen 8,000 × 2,048-byte workload. No
// existing suite deadline or upload admission limit is weakened.
@Suite("Actual large authenticated READY workload", .timeLimit(.minutes(10)))
private struct RelayAuthenticatedReadyLargeTests {
    @Test func eightThousandActualRowsAndReceiptsCrossTheMountedControlRoute() async throws {
        try await withRecoveryAuthorizationHarness(.readyLarge) { h in
            let peer = try await h.connect()
            let description = try await peer.ready(.init(operation: "describe")), descriptor = try readyObject(description)
            let profile = try #require(descriptor["profile"] as? [String: Any])
            #expect(profile["name"] as? String == "bounded48MiBV1")
            let uploadLimits = try #require(descriptor["upload"] as? [String: Int])
            #expect(uploadLimits == ["maximumEntries": 256, "maximumWireBytes": 1_048_576,
                "maximumScalarBytes": 65_536, "parserNodes": 32_768, "parserDepth": 16, "maximumDeletes": 256])
            let donor = try Lattice(isolation: nil, RecoveryReadyPayloadRow.self, configuration: .init(storage: .memory()))
            defer { donor.close() }
            let payload = String(repeating: "x", count: 2_048)
            try donor.transaction { for index in 0..<8_000 { try donor.add(RecoveryReadyPayloadRow(sequence: index, content: payload)) } }
            let entries = Array(donor.eventsAfter(globalId: nil)); #expect(entries.count == 8_000)
            let ids = Set(entries.compactMap { $0.globalId?.uuidString.lowercased() })
            let rowIDs = Set(entries.compactMap { $0.globalRowId?.uuidString.lowercased() })
            #expect(ids.count == 8_000); #expect(rowIDs.count == 8_000)
            for begin in stride(from: 0, to: entries.count, by: 256) {
                let batch = Array(entries[begin..<min(entries.count, begin + 256)])
                let wire = try JSONEncoder().encode(ServerSentEvent.auditLog(batch))
                #expect(wire.count <= 1_048_576)
                let expected = Set(batch.compactMap { $0.globalId?.uuidString.lowercased() })
                try await peer.socket!.send(Array(wire)); try await peer.wait { expected.isSubset(of: Set($0.acks)) }
            }
            let originals = try JSONEncoder().encode(ServerSentEvent.auditLog(entries))
            let request = try readyRequest(description, originals: originals)
            #expect(request.wire.utf8.count > 1_048_576); #expect(request.wire.utf8.count <= 4_194_304)
            let offer = try await peer.ready(readyOffer(request, descriptor: description, duration: 300_000))
            let offered = try readyObject(offer); #expect(offered["leaseAvailable"] as? Bool == true)
            let framesRaw = try #require(offered["frames"] as? String), count = try #require(Int(framesRaw))
            var rows = Set<String>(), originalsSeen = Set<String>(), sequences = Set<Int>()
            var totalWire = 0, manifest: [String: Any] = [:], contentHash = ReadyRequestHash(), receiptHash = ReadyRequestHash()
            var contentPages = 0, receiptPages = 0
            for index in 0..<count {
                let wire = try await peer.readyFrame(readyRead(offer, index: index)); totalWire += wire.count
                let root = try readyObject(wire), frame = try #require(root["latticeCanonicalRange"] as? [String: Any])
                let kind = try #require(frame["kind"] as? String), body = try #require(frame["body"] as? [String: Any])
                #expect(frame["route_generation"] as? String == descriptor["routeGeneration"] as? String)
                if index == 0 {
                    #expect(kind == "manifest"); manifest = body
                    var anchor = ReadyRequestHash(); anchor.string("lattice.canonical-range.v2/anchor")
                    try anchor.digest(request.digest); try anchor.source(#require(body["source"] as? [String: String]))
                    anchor.string("full"); anchor.byte(0)
                    let head = try #require(body["head"] as? String); anchor.number(try #require(UInt64(head)))
                    let protection = try #require(body["lease"] as? [String: String])
                    anchor.string(try #require(protection["id"])); let duration = try #require(protection["duration_ms"])
                    anchor.number(try #require(UInt64(duration))); let hash = anchor.finish()
                    contentHash.string("lattice.canonical-range.v2/content"); try contentHash.digest(hash); contentHash.number(8_000)
                    receiptHash.string("lattice.canonical-range.v2/receipts"); try receiptHash.digest(hash); receiptHash.number(8_000)
                } else if index == count - 1 {
                    #expect(kind == "end"); #expect(body["manifest_digest"] as? String == manifest["manifest_digest"] as? String)
                } else {
                    #expect(kind == "content_page" || kind == "receipt_page")
                    #expect(body["manifest_digest"] as? String == manifest["manifest_digest"] as? String)
                    let pageIndex = try #require(body["index"] as? String), items = try #require(body["items"] as? [[String: Any]])
                    #expect(items.count <= 64)
                    if kind == "content_page" {
                        #expect(receiptPages == 0); #expect(pageIndex == String(contentPages)); contentPages += 1
                        for item in items {
                            let id = try #require(item["id"] as? String), table = try #require(item["table"] as? String)
                            let payloadWire = try #require(item["payload"] as? String)
                            #expect(item["tag"] as? String == "present"); #expect(table == "RecoveryReadyPayloadRow"); #expect(rows.insert(id).inserted)
                            let values = try readyObject(Data(payloadWire.utf8)), content = try #require(values["content"] as? [String: Any])
                            let sequence = try #require(values["sequence"] as? [String: Any])
                            #expect(content["kind"] as? Int == 2); #expect(content["value"] as? String == payload)
                            #expect(sequence["kind"] as? Int == 1); #expect(sequences.insert(try #require(sequence["value"] as? Int)).inserted)
                            contentHash.byte(1); contentHash.string(table); contentHash.string(id); contentHash.string(payloadWire)
                        }
                    } else {
                        #expect(pageIndex == String(receiptPages)); receiptPages += 1
                        for item in items {
                            let id = try #require(item["original_id"] as? String); #expect(originalsSeen.insert(id).inserted)
                            #expect(item["status"] as? String == "committed"); #expect(item["decision"] as? String == "applied")
                            receiptHash.string(id); receiptHash.string("committed")
                            receiptHash.string(try #require(item["namespace_id"] as? String)); receiptHash.string(try #require(item["coverage_id"] as? String))
                            receiptHash.string("applied"); let position = try #require(item["position"] as? String)
                            receiptHash.number(try #require(UInt64(position))); receiptHash.byte(1)
                            let target = try #require(item["accepted_target"] as? [String: String])
                            receiptHash.string(try #require(target["table"])); receiptHash.string(try #require(target["id"]))
                        }
                    }
                }
            }
            #expect(rows == rowIDs); #expect(originalsSeen == ids); #expect(sequences == Set(0..<8_000))
            #expect(contentHash.finish() == manifest["content_digest"] as? String)
            #expect(receiptHash.finish() == manifest["receipt_digest"] as? String)
            #expect(totalWire <= 41_943_040); #expect(count <= 770)
            let counts = try #require(manifest["totals"] as? [String: String])
            #expect(counts["identities"] == "8000"); #expect(counts["receipts"] == "8000")
            #expect(counts["content_pages"] == String(contentPages)); #expect(counts["receipt_pages"] == String(receiptPages))
        }
    }
}
