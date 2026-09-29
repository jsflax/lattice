import Foundation
import CoreFoundation
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
private enum RecoveryAuthorizationFixtureError: Error { case timeout(String), rejected }
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
// Failure-only diagnostics. Retain no control/request/page payloads here.
// Strings and entry counts have separate bounds; these facts grant no authority.
private func readyDiagnosticText(_ text: String, limit: Int = 64) -> String {
    String(decoding: text.utf8.prefix(limit), as: UTF8.self)
}
private func readyDiagnosticReply(_ value: [String: Any]) -> String {
    func scalar(_ key: String, in object: [String: Any]) -> String {
        guard let field = object[key] else { return "missing" }
        if let text = field as? String { return "text:" + String(reflecting: readyDiagnosticText(text)) }
        if let number = field as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "bool:true" : "bool:false"
        }
        return "wrongType"
    }
    var fields = ["operation", "requestID", "leaseAvailable", "requiresFullRequest", "frameAvailable", "captureError", "error"]
        .map { "\($0)=\(scalar($0, in: value))" }
    for key in ["expiration", "preparation", "publication", "settlement"] {
        guard let part = value[key] as? [String: Any] else {
            fields.append("\(key)=\(value[key] == nil ? "missing" : "wrongType")"); continue
        }
        for member in ["state", "unexpectedCommitObserved", "primaryError", "cleanupError", "postcommitError", "notificationError"] {
            fields.append("\(key).\(member)=\(scalar(member, in: part))")
        }
    }
    return readyDiagnosticText(fields.joined(separator: " "), limit: 2_048)
}
// Scalar timing only. No timestamp decides a wait, native result, or deadline.
private struct ReadyWaitTiming: Sendable {
    var predicates: UInt64 = 0, sleeps: UInt64 = 0, resumes: UInt64 = 0
    var lastPredicateAt: UInt64?, lastSleepEnteredAt: UInt64?, lastSleepReturnedAt: UInt64?
    mutating func predicate(at now: UInt64) {
        if predicates < UInt64.max { predicates += 1 }; lastPredicateAt = now
    }
    mutating func sleepEntered(at now: UInt64) {
        if sleeps < UInt64.max { sleeps += 1 }; lastSleepEnteredAt = now
    }
    mutating func sleepReturned(at now: UInt64) {
        if resumes < UInt64.max { resumes += 1 }; lastSleepReturnedAt = now
    }
    var summary: String {
        "predicates=\(predicates) sleeps=\(sleeps) resumes=\(resumes) lastPredicateNs=\(String(reflecting: lastPredicateAt)) " +
        "sleepEnteredNs=\(String(reflecting: lastSleepEnteredAt)) sleepReturnedNs=\(String(reflecting: lastSleepReturnedAt))"
    }
}
private struct ReadyPeerObservation: Sendable {
    var operation: String = "unknown"
    var requestedDuration: Int64?
    var sendRequestedAt: UInt64?, sendCompletedAt: UInt64?
    var firstReceivedAt: UInt64?, lastReceivedAt: UInt64?
    var firstPublishedAt: UInt64?, lastPublishedAt: UInt64?
    var receivedCount: UInt64 = 0
    var reply = "unobserved"
    var waitStartedAt: UInt64?, nominalWaitDeadline: UInt64?, nominalWaitDeadlineUpper: UInt64?, waitReturnedAt: UInt64?
    var summary: String {
        "operation=\(String(reflecting: operation)) durationMs=\(String(reflecting: requestedDuration)) " +
        "sendRequestedNs=\(String(reflecting: sendRequestedAt)) sendCompletedNs=\(String(reflecting: sendCompletedAt)) " +
        "firstReceivedNs=\(String(reflecting: firstReceivedAt)) lastReceivedNs=\(String(reflecting: lastReceivedAt)) receivedCount=\(receivedCount) " +
        "firstPublishedNs=\(String(reflecting: firstPublishedAt)) lastPublishedNs=\(String(reflecting: lastPublishedAt)) " +
        "waitStartedNs=\(String(reflecting: waitStartedAt)) nominalWaitDeadlineLowerNs=\(String(reflecting: nominalWaitDeadline)) nominalWaitDeadlineUpperNs=\(String(reflecting: nominalWaitDeadlineUpper)) waitReturnedNs=\(String(reflecting: waitReturnedAt)) reply={\(reply)}"
    }
}
private final class RecoveryAuthorizationPeer: @unchecked Sendable {
    struct Facts { var kinds: [String] = []; var acks: [String] = []; var audits: [String] = []; var closed = false; var ready: [String: Data] = [:]; var canonical: [Data] = []; var firstRejection: String?
        var readyObservations: [String: ReadyPeerObservation] = [:]
        var observationsOmitted = false
        mutating func observe(_ id: String, _ update: (inout ReadyPeerObservation) -> Void) {
            guard id.utf8.prefix(65).count <= 64, readyObservations[id] != nil || readyObservations.count < 64 else {
                observationsOmitted = true; return
            }
            var record = readyObservations[id] ?? ReadyPeerObservation()
            update(&record); readyObservations[id] = record
        }
    }
    let facts = NIOLockedValueBox(Facts())
    private let transport = NIOLockedValueBox<WebSocket?>(nil)
    private weak var diagnosticSendGate: RecoveryReadySendGate?
    init(diagnosticSendGate: RecoveryReadySendGate? = nil) { self.diagnosticSendGate = diagnosticSendGate }
    func observeReadySend(_ command: ReadyTestControl, completed: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        facts.withLockedValue { value in value.observe(command.requestID) {
            $0.operation = readyDiagnosticText(command.operation, limit: 16); $0.requestedDuration = command.durationMilliseconds
            if completed { $0.sendCompletedAt = now } else { $0.sendRequestedAt = now }
        } }
    }
    func readyObservation(_ id: String) -> String {
        let snapshot = facts.withLockedValue { value in
            "requestID=\(String(reflecting: readyDiagnosticText(id))) presentNow=\(value.ready[id] != nil) omitted=\(value.observationsOmitted) " +
            (value.readyObservations[id]?.summary ?? "metadata=unobserved")
        }
        return snapshot + " sendDecision=\(String(reflecting: diagnosticSendGate?.decision(id)))"
    }
    var socket: WebSocket? { transport.withLockedValue { $0 } }
    func attach(_ socket: WebSocket) {
        transport.withLockedValue { $0 = socket }
        socket.onBinary { [weak self] _, bytes in
            guard let self, let root = (try? JSONSerialization.jsonObject(with: Data(buffer: bytes))) as? [String: Any] else { return }
            // Timestamp the parsed callback before taking the facts lock; this
            // is not a transport/kernel arrival timestamp.
            let readyReceivedAt = root["kind"] as? String == "recoveryReady" ? DispatchTime.now().uptimeNanoseconds : nil
            facts.withLockedValue { value in
                value.kinds.append(root["kind"] as? String ?? "?")
                if root["kind"] as? String == "rejected", value.firstRejection == nil,
                   let reason = root["rejected"] as? String {
                    value.firstRejection = String(decoding: reason.utf8.prefix(256), as: UTF8.self)
                }
                var publishedAt: UInt64?
                if root["kind"] as? String == "recoveryReady", let requestID = root["requestID"] as? String, value.ready.count < 64 {
                    value.ready[requestID] = Data(buffer: bytes)
                    // Sample only this callback's actual publication, including
                    // the original capacity guard; never reuse an older reply.
                    publishedAt = DispatchTime.now().uptimeNanoseconds
                }
                if root["latticeCanonicalRange"] != nil, value.canonical.count < 16 { value.canonical.append(Data(buffer: bytes)) }
                value.acks += (root["ack"] as? [String] ?? []).map { $0.lowercased() }
                value.audits += (root["auditLog"] as? [[String: Any]] ?? []).compactMap { ($0["globalId"] as? String)?.lowercased() }
                if let receivedAt = readyReceivedAt, let id = root["requestID"] as? String {
                    value.observe(id) {
                        if let publishedAt {
                            if $0.firstPublishedAt == nil { $0.firstPublishedAt = publishedAt }
                            $0.lastPublishedAt = publishedAt
                        }
                        if $0.firstReceivedAt == nil { $0.firstReceivedAt = receivedAt }
                        $0.lastReceivedAt = receivedAt
                        if $0.receivedCount < UInt64.max { $0.receivedCount += 1 }
                        $0.reply = readyDiagnosticReply(root)
                    }
                }
            }
        }
        socket.onClose.whenComplete { [weak self] _ in self?.facts.withLockedValue { $0.closed = true } }
    }
    func wait(_ phase: String = "peer state", diagnosticRequestID: String? = nil, _ predicate: @escaping @Sendable (Facts) -> Bool) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = Date().addingTimeInterval(10)
        // Bracket the unchanged Date deadline with monotonic samples. These
        // are nominal bounds, not a replacement for the actual wall clock.
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        let sum = startedAt.addingReportingOverflow(10_000_000_000)
        let nominalDeadline = sum.overflow ? UInt64.max : sum.partialValue
        let upperSum = capturedAt.addingReportingOverflow(10_000_000_000)
        let nominalDeadlineUpper = upperSum.overflow ? UInt64.max : upperSum.partialValue
        if let id = diagnosticRequestID { facts.withLockedValue { value in value.observe(id) {
            $0.waitStartedAt = startedAt; $0.nominalWaitDeadline = nominalDeadline; $0.nominalWaitDeadlineUpper = nominalDeadlineUpper
        } } }
        var lastPredicateAt: UInt64?
        var timing = ReadyWaitTiming()
        while Date() < deadline, !Task.isCancelled {
            lastPredicateAt = DispatchTime.now().uptimeNanoseconds
            if let lastPredicateAt { timing.predicate(at: lastPredicateAt) }
            if facts.withLockedValue({ predicate($0) }) {
                if let id = diagnosticRequestID { facts.withLockedValue { value in value.observe(id) {
                    $0.waitReturnedAt = DispatchTime.now().uptimeNanoseconds
                } } }
                return
            }
            timing.sleepEntered(at: DispatchTime.now().uptimeNanoseconds)
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch {
                timing.sleepReturned(at: DispatchTime.now().uptimeNanoseconds)
                print("READY_WAIT_SLEEP_FAILED phase=\(String(reflecting: readyDiagnosticText(phase, limit: 128))) \(timing.summary) cancelled=\(Task.isCancelled)")
                throw error
            }
            timing.sleepReturned(at: DispatchTime.now().uptimeNanoseconds)
        }
        let state = diagnosticState
        let finalAt = DispatchTime.now().uptimeNanoseconds
        let retained = facts.withLockedValue { value in
            "count=\(value.ready.count) first8=[" + value.ready.keys.prefix(8).map { String(reflecting: readyDiagnosticText($0)) }.joined(separator: ",") + "]"
        }
        let observed = diagnosticRequestID.map { readyObservation($0) } ?? "requestID=unspecified"
        print("READY_WAIT_TIMEOUT phase=\(String(reflecting: readyDiagnosticText(phase, limit: 128))) startNs=\(startedAt) nominalDeadlineLowerNs=\(nominalDeadline) nominalDeadlineUpperNs=\(nominalDeadlineUpper) wallDeadline=\(deadline.timeIntervalSince1970) lastPredicateAttemptNs=\(String(reflecting: lastPredicateAt)) finalNs=\(finalAt) wallFinal=\(Date().timeIntervalSince1970) retainedIDs=[\(retained)] \(timing.summary) \(observed)")
        throw RecoveryAuthorizationFixtureError.timeout("\(phase.prefix(128)); \(state); cancelled=\(Task.isCancelled)")
    }
    var diagnosticState: String {
        facts.withLockedValue {
            let rejectedCount = $0.kinds.filter { $0 == "rejected" }.count
            return "closed=\($0.closed) ackCount=\($0.acks.count) readyCount=\($0.ready.count) canonicalCount=\($0.canonical.count) auditCount=\($0.audits.count) rejectedCount=\(rejectedCount) firstRejection=\(String(reflecting: $0.firstRejection))"
        }
    }
}
private final class RecoveryAuthorizationHarness: @unchecked Sendable {
    let app: Application
    let directory: URL
    let registrations: RegisteredRecoveryPeers
    let writer: SyncRelayHandle
    let observer: SyncRelayHandle
    let lifecycle: SyncRelayHandle?
    let port: Int
    private let peers = NIOLockedValueBox<[RecoveryAuthorizationPeer]>([])
    init(_ registrations: RegisteredRecoveryPeers = .init(), seedHidden: Bool = false,
         administrativeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil,
         lifecycleTarget: NIOLockedValueBox<SyncRecoveryMountConfiguration?>? = nil) async throws {
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
        let hookDirectory = directory
        defer { if let hooks { RelayIngressTesting.remove(hooks, for: hookDirectory) } }
        let relaySchema: [any Lattice.Model.Type] = registrations.mode == .readyLarge
            ? [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self, RecoveryReadyPayloadRow.self]
            : [SimpleSyncObject.self, RecoveryAuthorizationHiddenRow.self]
        writer = Lattice.configureSyncRelay(on: app.routes, path: ["writer"],
            for: relaySchema, storageURL: directory, storeConfiguration: administrativeConfiguration,
            recoverySource: { try registrations.source($0) }, channelExtractor: { try registrations.channel($0) },
            recoveryAuthorization: { try await registrations.authorize($0, $1) })
        observer = Lattice.configureSyncRelay(on: app.routes, path: ["observer"],
            for: relaySchema, storageURL: directory,
            writePolicy: .init(allowedOperations: [:], unlistedTables: .deny),
            observerPush: .init(reconcileInterval: nil), recoverySource: { try registrations.source($0) },
            channelExtractor: { try registrations.channel($0) }, recoveryAuthorization: { try await registrations.authorize($0, $1) })
        // Register the successor route before server startup. Its explicit
        // value is supplied only after actual administration reports COMMIT.
        if let lifecycleTarget {
            lifecycle = Lattice.configureSyncRelay(on: app.routes, path: ["lifecycle"], for: relaySchema, storageURL: directory,
                recoverySource: { _ in
                    guard let next = lifecycleTarget.withLockedValue({ $0 }) else { throw SyncRecoveryConfigurationError.staleAuthorization }
                    return next
                }, channelExtractor: { try registrations.channel($0) },
                recoveryAuthorization: { try await registrations.authorize($0, $1) })
        } else { lifecycle = nil }
        do { try await created.startup(); port = try #require(created.http.server.shared.localAddress?.port) }
        catch { try? await created.asyncShutdown(); throw error }
    }
    func connect(_ peer: SyncRecoveryPeerIdentity? = nil, mount: String = "writer", group: String = "group-a", duplicateDeclaration: Bool = false) async throws -> RecoveryAuthorizationPeer {
        let declared = peer ?? registrations.first
        let query = "recovery-v=1&recovery-replica=\(declared.replicaID)&recovery-receiver=\(declared.receiverIncarnation)&recovery-channel=\(declared.channelIncarnation)"
            + (duplicateDeclaration ? "&recovery-v=1" : "")
        let client = RecoveryAuthorizationPeer(diagnosticSendGate: registrations.readySendGate); peers.withLockedValue { $0.append(client) }
        var headers = HTTPHeaders(); headers.add(name: "X-Registered-Session", value: registrations.token)
        headers.add(name: "X-Registered-Group", value: group)
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = registrations.mode == .readyLarge ? 8 << 20 : 1 << 20
        try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/\(mount)?\(query)", headers: headers,
            configuration: configuration, on: app.eventLoopGroup) { client.attach($0) }.get()
        try await readyWait("authorization peer socket attachment") { client.socket != nil }
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
        await lifecycle?.retireRecoveryAuthorization()
        try await app.asyncShutdown()
        for peer in clients { try await peer.wait { $0.closed } }
        let deadline = Date().addingTimeInterval(10)
        while (writer.recoverySessionCount != 0 || observer.recoverySessionCount != 0 || (lifecycle?.recoverySessionCount ?? 0) != 0), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(writer.recoverySessionCount == 0); #expect(observer.recoverySessionCount == 0)
        #expect((lifecycle?.recoverySessionCount ?? 0) == 0)
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
            try await writer.socket!.send(Array(frame)); try await writer.wait("shared mount writer upload ACK") { Set(ids).isSubset(of: Set($0.acks)) }
            try await watcher.wait("shared mount observer authorized audit") { Set(ids).isSubset(of: Set($0.audits)) }
            let (denied, _) = try recoveryDonorFrame(12); try await watcher.socket!.send(Array(denied))
            try await watcher.wait("shared mount observer denied upload refusal") { $0.kinds.contains("rejected") }
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
private func readyWait(_ phase: String = "READY fixture state", _ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var timing = ReadyWaitTiming()
    var completed = false
    defer {
        if !completed {
            print("READY_FIXTURE_WAIT_FAILED phase=\(String(reflecting: readyDiagnosticText(phase, limit: 128))) startNs=\(startedAt) finalNs=\(DispatchTime.now().uptimeNanoseconds) \(timing.summary) cancelled=\(Task.isCancelled)")
        }
    }
    while Date() < deadline, !Task.isCancelled {
        timing.predicate(at: DispatchTime.now().uptimeNanoseconds)
        if predicate() { completed = true; return }
        timing.sleepEntered(at: DispatchTime.now().uptimeNanoseconds)
        do { try await Task.sleep(nanoseconds: 10_000_000) }
        catch { timing.sleepReturned(at: DispatchTime.now().uptimeNanoseconds); throw error }
        timing.sleepReturned(at: DispatchTime.now().uptimeNanoseconds)
    }
    throw RecoveryAuthorizationFixtureError.timeout("\(phase.prefix(128)); cancelled=\(Task.isCancelled)")
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
        observeReadySend(command)
        try await actual.send(Array(data))
        observeReadySend(command, completed: true)
        try await wait("READY \(command.operation) reply", diagnosticRequestID: id) { $0.ready[id] != nil }
        return try #require(facts.withLockedValue { $0.ready.removeValue(forKey: id) })
    }
    func readyFrame(_ command: ReadyTestControl) async throws -> Data {
        let actual = try #require(socket)
        observeReadySend(command)
        try await actual.send(Array(try command.data()))
        observeReadySend(command, completed: true)
        try await wait("READY \(command.operation) frame index=\(command.index ?? "missing")", diagnosticRequestID: command.requestID) { !$0.canonical.isEmpty }
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
    let entries: [[String: Any]] = try originals.map { data in
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
private func readyRead(_ offer: Data, index: Int, diagnosticPeer: RecoveryAuthorizationPeer? = nil) throws -> ReadyTestControl {
    let d = try readyObject(offer); var c = ReadyTestControl(operation: "read")
    if d["leaseID"] as? String == nil {
        let observed = (d["requestID"] as? String).map { diagnosticPeer?.readyObservation($0) ?? "peerMetadata=unavailable" } ?? "requestID=missing"
        print("READY_MISSING_LEASE \(readyDiagnosticReply(d)) \(observed)")
    }
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
            let framesRaw = try #require(offered["frames"] as? String)
            let count = try #require(Int(framesRaw))
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
            peer.observeReadySend(describe)
            try await peer.socket!.send(Array(try describe.data()))
            peer.observeReadySend(describe, completed: true)
            try await readyWait("held describe authorization entry deny=\(deny)") { h.registrations.heldSecondEntered.withLockedValue { $0 } }
            #expect(peer.facts.withLockedValue { $0.ready.isEmpty && $0.canonical.isEmpty })
            h.registrations.gate.release()
            if deny { try await peer.wait { $0.closed }; #expect(peer.facts.withLockedValue { $0.ready.isEmpty && $0.canonical.isEmpty }) }
            else { let id = describe.requestID; try await peer.wait("held describe after authorization release", diagnosticRequestID: id) { $0.ready[id] != nil } }
        }
    }
    @Test func keeperReconnectResumesSameCapsuleWithFreshPhysicalGeneration() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let first = try await h.connect(), keeper = try await h.connect(h.registrations.second)
            let before = try await first.ready(.init(operation: "describe")); let q = try readyRequest(before)
            let offer = try await first.ready(readyOffer(q, descriptor: before)); let original = try await first.readyFrame(readyRead(offer, index: 0, diagnosticPeer: first))
            try await first.socket!.close(); try await first.wait { $0.closed }
            let next = try await h.connect(), after = try await next.ready(.init(operation: "describe"))
            var raw = try readyObject(Data(q.wire.utf8)), inner = try #require(raw["latticeCanonicalRange"] as? [String: Any])
            inner["route_generation"] = try readyObject(after)["routeGeneration"]; raw["latticeCanonicalRange"] = inner
            let replacement = ReadyTestRequest(wire: String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self), digest: q.digest, attempt: q.attempt, sequence: q.sequence)
            let renewed = try await next.ready(readyOffer(replacement, descriptor: after, op: "resume"))
            let current = try readyObject(await next.readyFrame(readyRead(renewed, index: 0, diagnosticPeer: next)))
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
            let command = try readyRead(offer, index: 0, diagnosticPeer: first), id = command.requestID
            first.observeReadySend(command)
            h.registrations.readySendGate.arm(id); try await first.socket!.send(Array(try command.data()))
            first.observeReadySend(command, completed: true)
            do {
                try await readyWait("parked send entry action=\(action)") { h.registrations.readySendGate.parked }
            } catch {
                // This observes an already failed wait; a refused read and a
                // missing native-to-socket handoff require different fixes.
                print("READY_PARK_TIMEOUT action=\(action) \(first.diagnosticState) decision=\(String(reflecting: h.registrations.readySendGate.decision(id)))")
                throw error
            }
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
                if action == "resume" { _ = try await other.readyFrame(readyRead(reply, index: 0, diagnosticPeer: other)) }
            }
            h.registrations.readySendGate.release(); try await readyWait("parked send decision action=\(action)") { h.registrations.readySendGate.decision(id) != nil }
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
                try await peer.socket!.send(Array(wire)); try await peer.wait("8000-row upload ACK begin=\(begin)") { expected.isSubset(of: Set($0.acks)) }
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


@Suite("Actual resolved-mount receipt migration", .timeLimit(.minutes(2)))
private struct RelayReceiptCoverageMigrationTests {
    @Test func actualResolvedMountMigrationRetiresPeersAndPreservesLegacyRows() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let peer = try await h.connect()
            let (frame, ids) = try recoveryDonorFrame(73)
            try await peer.socket!.send(Array(frame))
            try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let before = try await h.inspect()
            #expect(before.0 == 1); #expect(before.1 == [73])
            let cohort = try SyncRecoveryReceiptCohort(id: UUID(), revision: 1, namespaces: [
                .init(namespaceID: "application", coverageID: "registered-peers-v1", revision: 7)
            ])
            let channel = SyncChannel(id: "group-a", userId: h.registrations.user)
            let deadline = Date().addingTimeInterval(10)
            var migrated: SyncRecoveryMountConfiguration?
            while Date() < deadline, migrated == nil {
                switch try await h.writer.migrateRecoveryReceiptCoverage(channel: channel, cohort: cohort) {
                case .pendingQuiescence: try await Task.sleep(nanoseconds: 10_000_000)
                case .migrated(let configuration): migrated = configuration
                }
            }
            let actual = try #require(migrated)
            let policyBytes = try actual.policy(nil)
            let policy = try #require(JSONSerialization.jsonObject(with: policyBytes) as? [String: Any])
            #expect(policy["version"] as? Int == 2)
            #expect(policy["sourceID"] as? String == h.registrations.sourceA.uuidString.lowercased())
            #expect(policy["epoch"] as? String == h.registrations.epoch.uuidString.lowercased())
            let coverage = try #require(policy["receiptCoverage"] as? [String: Any])
            #expect(coverage["cohortID"] as? String == cohort.id.uuidString.lowercased())
            #expect(coverage["namespaces"] as? [String] == ["application"])
            try await peer.wait { $0.closed }
            #expect(h.writer.recoverySessionCount == 0)
            let after = try await h.inspect()
            #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            // The public administration call consumed this mount. A later
            // peer cannot obtain either old or new recovery authority here.
            let late = try await h.connect(h.registrations.second)
            try await late.wait { $0.closed }
            #expect(late.facts.withLockedValue { $0.acks.isEmpty && $0.audits.isEmpty })
        }
    }
}

@Suite("Recovery native retirement with retained sockets", .timeLimit(.minutes(2)))
private struct RelayRecoveryRetirementTests {
    @Test(arguments: [false, true])
    func heldAuthorizationKeepsMountCapacityAfterNativeRetirement(deny: Bool) async throws {
        let mode: RegisteredRecoveryPeers.Mode = deny ? .heldSecondDenied : .heldSecondApproved
        try await withRecoveryAuthorizationHarness(mode) { h in
            let peer = try await h.connect(h.registrations.second)
            let socket = try #require(peer.socket)
            try await readyWait { h.registrations.heldSecondEntered.withLockedValue { $0 } }
            try await socket.close()
            try await peer.wait { $0.closed }
            // Observe the real IO retirement, rather than assuming that a
            // socket close means its queued native release already ran.
            try await readyWait { h.writer.recoveryRetiredNativeSessionCount == 1 }
            #expect(h.writer.recoverySessionCount == 1)
            #expect(peer.facts.withLockedValue { $0.acks.isEmpty && $0.canonical.isEmpty })

            h.registrations.gate.release()
            try await readyWait { h.writer.recoverySessionCount == 0 }
            #expect(h.writer.recoveryRetiredNativeSessionCount == 0)
            #expect(h.registrations.calls.withLockedValue { $0 } == 1)
            withExtendedLifetime(socket) {}
        }
    }

    @Test func closedSocketDoesNotRetainRegistrationOrBlockReceiptMigration() async throws {
        try await withRecoveryAuthorizationHarness { h in
            let peer = try await h.connect()
            let socket = try #require(peer.socket)
            let (frame, ids) = try recoveryDonorFrame(81)
            try await socket.send(Array(frame))
            try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            #expect(h.writer.recoverySessionCount == 1)
            let before = try await h.inspect()
            #expect(before.0 == 1); #expect(before.1 == [81])

            await h.writer.retireRecoveryAuthorization()
            await h.writer.retireRecoveryAuthorization()
            try await peer.wait { $0.closed }
            let deadline = Date().addingTimeInterval(10)
            while h.writer.recoverySessionCount != 0, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(h.writer.recoverySessionCount == 0)

            let cohort = try SyncRecoveryReceiptCohort(id: UUID(), revision: 1, namespaces: [
                .init(namespaceID: "application", coverageID: "registered-peers-v1", revision: 7)
            ])
            let channel = SyncChannel(id: "group-a", userId: h.registrations.user)
            let migrationDeadline = Date().addingTimeInterval(10)
            var migrated = false
            while !migrated, Date() < migrationDeadline {
                switch try await h.writer.migrateRecoveryReceiptCoverage(channel: channel, cohort: cohort) {
                case .pendingQuiescence: try await Task.sleep(nanoseconds: 10_000_000)
                case .migrated: migrated = true
                }
            }
            #expect(migrated)
            let after = try await h.inspect()
            #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            #expect(socket.isClosed)
            // Keep the socket and its handler state alive through both gates.
            // Native retirement must not depend on this wrapper's destruction.
            withExtendedLifetime(socket) {}
        }
    }
}


@Suite("Receipt administration fixed intended file", .timeLimit(.minutes(2)))
private struct RelayReceiptAdministrativeFileTests {
    @Test func redirectedProviderRefusesBeforeOpeningAlternateFile() async throws {
        let redirect = NIOLockedValueBox(false)
        let calls = NIOLockedValueBox(0)
        let alternate = FileManager.default.temporaryDirectory.appending(path: "receipt-admin-never-create-\(UUID().uuidString).sqlite")
        let h = try await RecoveryAuthorizationHarness(administrativeConfiguration: { url in
            if redirect.withLockedValue({ $0 }) {
                calls.withLockedValue { $0 += 1 }
                return .init(fileURL: alternate)
            }
            return .init(fileURL: url)
        })
        do {
            let peer = try await h.connect()
            let (frame, ids) = try recoveryDonorFrame(173)
            try await peer.socket!.send(Array(frame))
            try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let before = try await h.inspect()
            redirect.withLockedValue { $0 = true }
            let cohort = try SyncRecoveryReceiptCohort(id: UUID(), revision: 1, namespaces: [
                .init(namespaceID: "application", coverageID: "registered-peers-v1", revision: 7)
            ])
            do {
                _ = try await h.writer.migrateRecoveryReceiptCoverage(channel: .init(id: "group-a", userId: h.registrations.user), cohort: cohort)
                Issue.record("redirected administration unexpectedly succeeded")
            } catch { #expect(error is SyncRecoveryConfigurationError) }
            #expect(calls.withLockedValue { $0 } == 1)
            #expect(!FileManager.default.fileExists(atPath: alternate.path))
            let after = try await h.inspect()
            #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            try await h.shutdown()
        } catch { let original = error; try? await h.shutdown(); throw original }
    }
}


@Suite("Receipt administration cannot run app schema migration", .timeLimit(.minutes(2)))
private struct RelayReceiptAdministrativeSchemaTests {
    @Test func declaredVersionMismatchRefusesWithoutExecutingMigrationBody() async throws {
        let changed = NIOLockedValueBox(false)
        let bodies = NIOLockedValueBox(0)
        let h = try await RecoveryAuthorizationHarness(administrativeConfiguration: { url in
            if changed.withLockedValue({ $0 }) {
                let forbidden = Migration().add(from: SimpleSyncObject.self, to: SimpleSyncObject.self) { _, _ in
                    bodies.withLockedValue { $0 += 1 }
                }
                return .init(fileURL: url, migration: [2: forbidden])
            }
            return .init(fileURL: url)
        })
        do {
            let peer = try await h.connect()
            let (frame, ids) = try recoveryDonorFrame(174)
            try await peer.socket!.send(Array(frame))
            try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let before = try await h.inspect()
            changed.withLockedValue { $0 = true }
            let cohort = try SyncRecoveryReceiptCohort(id: UUID(), revision: 1, namespaces: [
                .init(namespaceID: "application", coverageID: "registered-peers-v1", revision: 7)
            ])
            let deadline = Date().addingTimeInterval(10)
            var refused = false
            while Date() < deadline, !refused {
                do {
                    switch try await h.writer.migrateRecoveryReceiptCoverage(channel: .init(id: "group-a", userId: h.registrations.user), cohort: cohort) {
                    case .pendingQuiescence: try await Task.sleep(nanoseconds: 10_000_000)
                    case .migrated: Issue.record("administration silently changed the declared schema version"); refused = true
                    }
                } catch {
                    #expect(String(describing: error).contains("declared schema version differs")); refused = true
                }
            }
            #expect(refused); #expect(bodies.withLockedValue { $0 } == 0)
            let after = try await h.inspect()
            #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            try await h.shutdown()
        } catch { let original = error; try? await h.shutdown(); throw original }
    }
}


@Suite("Actual resolved-mount lifecycle adoption", .timeLimit(.minutes(3)))
private struct RelayLifecycleAdministrationTests {
    private func adopt(_ h: RecoveryAuthorizationHarness, grace: Int64 = 60_000) async throws -> SyncRecoveryLifecycleAdoptionResult {
        let channel = SyncChannel(id: "group-a", userId: h.registrations.user)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !Task.isCancelled {
            switch try await h.writer.adoptRecoveryOrphanLifecycle(channel: channel,
                orphanResumeGraceMilliseconds: grace, retainedTransfers: .preserveCompleted) {
            case .pendingQuiescence: try await Task.sleep(nanoseconds: 10_000_000)
            case .settled(let result): return result
            }
        }
        throw RecoveryAuthorizationFixtureError.timeout("explicit lifecycle administration quiescence")
    }
    private func committed(_ result: SyncRecoveryLifecycleAdoptionResult) throws -> SyncRecoveryLifecycleTransition {
        guard case .committed = result.settlement.phase else {
            Issue.record("lifecycle phase: \(result.settlement.phase); primary=\(result.settlement.primaryError ?? "none")")
            throw RecoveryAuthorizationFixtureError.rejected
        }
        #expect(!result.settlement.hasError); #expect(!result.settlement.unexpectedCommitObserved)
        return try #require(result.transition)
    }
    @Test func retainedActualSendBlocksAdoptionThenExactOldRequestResumesOnExplicitTarget() async throws {
        let target = NIOLockedValueBox<SyncRecoveryMountConfiguration?>(nil)
        let h = try await RecoveryAuthorizationHarness(.init(.readyParked), lifecycleTarget: target)
        do {
            let peer = try await h.connect(); let (upload, ids) = try recoveryDonorFrame(281)
            try await peer.socket!.send(Array(upload)); try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let before = try await h.inspect(), descriptor = try await peer.ready(.init(operation: "describe"))
            let q = try readyRequest(descriptor, originals: upload), offer = try await peer.ready(readyOffer(q, descriptor: descriptor))
            #expect(try readyObject(offer)["leaseAvailable"] as? Bool == true)
            let read = try readyRead(offer, index: 0)
            h.registrations.readySendGate.arm(read.requestID); try await peer.socket!.send(Array(try read.data()))
            try await readyWait("actual retained READY send before adoption") { h.registrations.readySendGate.parked }
            let initial = try await h.writer.adoptRecoveryOrphanLifecycle(channel: .init(id: "group-a", userId: h.registrations.user),
                orphanResumeGraceMilliseconds: 60_000, retainedTransfers: .preserveCompleted)
            guard case .pendingQuiescence = initial else { Issue.record("retained native result did not block adoption"); throw RecoveryAuthorizationFixtureError.rejected }
            try await peer.wait { $0.closed }; #expect(peer.facts.withLockedValue { $0.canonical.isEmpty })
            h.registrations.readySendGate.release()
            try await readyWait("retired retained READY send decision") { h.registrations.readySendGate.decision(read.requestID) != nil }
            #expect(h.registrations.readySendGate.decision(read.requestID) == false)
            let result = try await adopt(h), transition = try committed(result)
            guard case .applied = transition.disposition else { throw RecoveryAuthorizationFixtureError.rejected }
            #expect(transition.recordDigest.utf8.count == 64)
            let repeated = try committed(await adopt(h))
            guard case .verifiedExisting = repeated.disposition else { throw RecoveryAuthorizationFixtureError.rejected }
            #expect(repeated.id == transition.id); #expect(repeated.recordDigest == transition.recordDigest)
            #expect(try repeated.configuration.policy(nil) == transition.configuration.policy(nil))
            let changed = try await adopt(h, grace: 60_001)
            #expect(changed.transition == nil)
            if case .committed = changed.settlement.phase { Issue.record("changed grace reconfigured the stored predecessor") }
            let after = try await h.inspect(); #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            target.withLockedValue { $0 = transition.configuration }
            let successor = try await h.connect(mount: "lifecycle"), current = try await successor.ready(.init(operation: "describe"))
            let profile = try #require(readyObject(current)["profile"] as? [String: Any])
            #expect(profile["name"] as? String == "boundedV1OrphanV1")
            #expect(profile["transfers"] as? Int == 16); #expect(profile["orphanResumeGraceMilliseconds"] as? Int == 60_000)
            // The frozen old Q stays exact except its transport route wrapper.
            var raw = try readyObject(Data(q.wire.utf8)), inner = try #require(raw["latticeCanonicalRange"] as? [String: Any])
            inner["route_generation"] = try readyObject(current)["routeGeneration"]; raw["latticeCanonicalRange"] = inner
            let same = ReadyTestRequest(wire: String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), as: UTF8.self),
                digest: q.digest, attempt: q.attempt, sequence: q.sequence)
            let resumed = try await successor.ready(readyOffer(same, descriptor: current, op: "resume"))
            let value = try readyObject(resumed); #expect(value["leaseAvailable"] as? Bool == true)
            #expect(value["requestDigest"] as? String == q.digest); #expect(value["attemptID"] as? String == q.attempt)
            #expect(value["sequence"] as? String == q.sequence)
            let encodedCount = try #require(value["frames"] as? String)
            let count = try #require(Int(encodedCount))
            var kinds: [String] = [], positives: [String] = []
            for index in 0..<count {
                let frame = try readyObject(await successor.readyFrame(readyRead(resumed, index: index)))
                let body = try #require(frame["latticeCanonicalRange"] as? [String: Any]), kind = try #require(body["kind"] as? String)
                kinds.append(kind)
                if kind == "receipt_page" {
                    let page = try #require(body["body"] as? [String: Any])
                    for receipt in try #require(page["items"] as? [[String: Any]]) {
                        #expect(receipt["status"] as? String == "committed"); positives.append(try #require(receipt["original_id"] as? String))
                    }
                }
            }
            #expect(kinds.first == "manifest"); #expect(kinds.last == "end"); #expect(Set(positives) == Set(ids))
            let late = try await h.connect(h.registrations.second); try await late.wait { $0.closed }
            #expect(late.facts.withLockedValue { $0.acks.isEmpty && $0.canonical.isEmpty }); #expect(h.writer.recoverySessionCount == 0)
            let final = try await h.inspect(); #expect(final.0 == before.0); #expect(final.1 == before.1); #expect(final.2 == before.2)
            try await h.shutdown()
        } catch { let original = error; h.registrations.readySendGate.release(); try? await h.shutdown(); throw original }
    }
    @Test func redirectedProviderIsCalledOnceAndRefusedBeforeEitherFileIsOpened() async throws {
        let changed = NIOLockedValueBox(false), calls = NIOLockedValueBox(0)
        let alternate = FileManager.default.temporaryDirectory.appending(path: "lifecycle-admin-never-create-\(UUID().uuidString).sqlite")
        let h = try await RecoveryAuthorizationHarness(administrativeConfiguration: { url in
            if changed.withLockedValue({ $0 }) { calls.withLockedValue { $0 += 1 }; return .init(fileURL: alternate) }
            return .init(fileURL: url)
        })
        do {
            let peer = try await h.connect(); let (frame, ids) = try recoveryDonorFrame(282)
            try await peer.socket!.send(Array(frame)); try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let before = try await h.inspect(); changed.withLockedValue { $0 = true }
            do { _ = try await adopt(h); Issue.record("redirected lifecycle administration succeeded") }
            catch { #expect(error is SyncRecoveryConfigurationError) }
            #expect(calls.withLockedValue { $0 } == 1); #expect(!FileManager.default.fileExists(atPath: alternate.path))
            let after = try await h.inspect(); #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            try await h.shutdown()
        } catch { let original = error; try? await h.shutdown(); throw original }
    }
    @Test func declaredVersionMismatchReportsRefusedWithoutExecutingAppMigration() async throws {
        let changed = NIOLockedValueBox(false), bodies = NIOLockedValueBox(0)
        let h = try await RecoveryAuthorizationHarness(administrativeConfiguration: { url in
            guard changed.withLockedValue({ $0 }) else { return .init(fileURL: url) }
            let forbidden = Migration().add(from: SimpleSyncObject.self, to: SimpleSyncObject.self) { _, _ in bodies.withLockedValue { $0 += 1 } }
            return .init(fileURL: url, migration: [2: forbidden])
        })
        do {
            let peer = try await h.connect(); let (frame, ids) = try recoveryDonorFrame(283)
            try await peer.socket!.send(Array(frame)); try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            let before = try await h.inspect(); changed.withLockedValue { $0 = true }
            let result = try await adopt(h)
            guard case .refused = result.settlement.phase else { throw RecoveryAuthorizationFixtureError.rejected }
            #expect(result.settlement.hasError); #expect(result.transition == nil)
            #expect(result.settlement.primaryError?.contains("declared schema version differs") == true)
            #expect(bodies.withLockedValue { $0 } == 0)
            let after = try await h.inspect(); #expect(after.0 == before.0); #expect(after.1 == before.1); #expect(after.2 == before.2)
            try await h.shutdown()
        } catch { let original = error; try? await h.shutdown(); throw original }
    }
}

// Automatic setup admission fixtures use real route/IO/authorization paths.
// Their dedicated directory is retained; no live native file is unlinked.
private final class AutomaticSetupIOHold: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    let entered = NIOLockedValueBox(false)
    let timedOut = NIOLockedValueBox(false)
    func hold() {
        entered.withLockedValue { $0 = true }
        if gate.wait(timeout: .now() + 12) != .success { timedOut.withLockedValue { $0 = true } }
    }
    func release() { gate.signal() }
}
/// A finite publication/tail fence. Normal observation is bounded by readyWait.
/// Only failed cleanup may join actual custody without a timer: abandoning that
/// callback would permit native retirement while it still owns test work.
private final class AutomaticSetupBusyFence: Sendable {
    private struct State {
        var complete = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = NIOLockedValueBox(State())
    var complete: Bool { state.withLockedValue { $0.complete } }
    func finish() {
        let waiter = state.withLockedValue { value in
            value.complete = true
            let held = value.waiter; value.waiter = nil; return held
        }
        waiter?.resume()
    }
    func joinFailedCleanup() async {
        await withCheckedContinuation { continuation in
            let alreadyComplete = state.withLockedValue { value in
                if value.complete { return true }
                precondition(value.waiter == nil)
                value.waiter = continuation; return false
            }
            if alreadyComplete { continuation.resume() }
        }
    }
}
/// Armed for one actualBusy case only. It cannot supply an admission result.
/// Weak back-references avoid state -> probe -> mount -> state ownership cycles.
private final class AutomaticSetupBusyRendezvous: @unchecked Sendable {
    struct Boundary: Sendable {
        let holder: AutomaticSetupActualMutex.Facts?
        let configurationCalls, sourceCalls, authorizationCalls: Int
        let sessions: Int?
    }
    struct Result: Sendable {
        let trigger: RelaySetupAdmissionObservation
        let beforeSubmission, beforeRelease: Boundary
        let sameKeyAt, otherKeyAt, releaseAt: UInt64
        let sameKeyOnIO, otherKeyOnIO, disarmed: Bool
    }
    private struct State {
        var armed = true, waiting = 0, reserved = false, releaseClaimed = false, draining = false
        var trigger: RelaySetupAdmissionObservation?
        var beforeSubmission: Boundary?
        var sameKeyAt: UInt64?, otherKeyAt: UInt64?
        var sameKeyOnIO = false, otherKeyOnIO = false
        var result: Result?
    }
    private weak var harness: AutomaticSetupHarness?
    private weak var testCase: AutomaticSetupCase?
    private let key: String
    private let state = NIOLockedValueBox(State())
    private let published = AutomaticSetupBusyFence()
    init(_ harness: AutomaticSetupHarness) {
        self.harness = harness; testCase = harness.state; key = harness.state.key
    }
    var result: Result? { state.withLockedValue { $0.result } }
    private func boundary() -> (Boundary, AutomaticSetupActualMutex?) {
        // Every foreign read is outside the probe/case/pool locks.
        let owner = testCase
        let holder = owner?.actualMutex.withLockedValue { $0 }
        let counts = owner?.facts.withLockedValue { ($0.configurationCalls, $0.sourceCalls) }
        let calls = owner?.registrations.calls.withLockedValue { $0 }
        let sessions = harness?.writer.recoverySessionCount
        return (.init(holder: holder?.facts, configurationCalls: counts?.0 ?? -1,
                      sourceCalls: counts?.1 ?? -1, authorizationCalls: calls ?? -1,
                      sessions: sessions), holder)
    }
    func observe(_ event: RelaySetupAdmissionObservation) {
        guard event.stage == .waiting else { return }
        let submit = state.withLockedValue { value in
            guard value.armed, !value.reserved else { return false }
            value.waiting += 1
            guard value.waiting == 2 else { return false }
            value.reserved = true; value.trigger = event; return true
        }
        guard submit else { return }
        let before = boundary().0
        state.withLockedValue { value in
            precondition(value.reserved && value.beforeSubmission == nil)
            value.beforeSubmission = before
        }
        RelayExecutionPool.io.submitRequired(for: key) { [self] in sentinel(sameKey: true) }
        RelayExecutionPool.io.submitRequired(for: key + ".other") { [self] in sentinel(sameKey: false) }
        // Cleanup cannot enqueue tails before both submissions are published,
        // even if disarm raced after reservation but before either enqueue.
        published.finish()
    }
    private func sentinel(sameKey: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let onIO = RelayExecutionPool.io.isCurrentWorker
        let release = state.withLockedValue { value -> (RelaySetupAdmissionObservation, Boundary, UInt64, UInt64, Bool, Bool)? in
            if sameKey {
                precondition(value.sameKeyAt == nil)
                value.sameKeyAt = now; value.sameKeyOnIO = onIO
            } else {
                precondition(value.otherKeyAt == nil)
                value.otherKeyAt = now; value.otherKeyOnIO = onIO
            }
            guard value.armed, !value.releaseClaimed,
                  let same = value.sameKeyAt, let other = value.otherKeyAt,
                  let trigger = value.trigger, let before = value.beforeSubmission else { return nil }
            value.releaseClaimed = true
            return (trigger, before, same, other, value.sameKeyOnIO, value.otherKeyOnIO)
        }
        guard let release else { return }
        let (before, holder) = boundary()
        let releaseAt = DispatchTime.now().uptimeNanoseconds
        // Capture bad facts as-is; never wait for a favorable capacity/count.
        holder?.requestRelease()
        state.withLockedValue { value in
            precondition(value.result == nil)
            value.result = .init(trigger: release.0, beforeSubmission: release.1, beforeRelease: before,
                                 sameKeyAt: release.2, otherKeyAt: release.3, releaseAt: releaseAt,
                                 sameKeyOnIO: release.4, otherKeyOnIO: release.5, disarmed: !value.armed)
        }
    }
    func disarm() {
        let noSubmission = state.withLockedValue { value in value.armed = false; return !value.reserved }
        if noSubmission { published.finish() }
    }
    func drain() async throws {
        state.withLockedValue { precondition(!$0.draining); $0.draining = true }
        disarm()
        var first: (any Error)?
        func wait(_ fence: AutomaticSetupBusyFence, _ phase: String) async -> (any Error)? {
            do { try await readyWait(phase) { fence.complete }; return nil }
            catch {
                // Failure containment is never a successful rendezvous. Keep
                // custody until the actual callback, including cancellation.
                testCase?.releaseHolds()
                await fence.joinFailedCleanup()
                return error
            }
        }
        first = await wait(published, "automatic busy: sentinel submission publication")
        let sameTail = AutomaticSetupBusyFence(), otherTail = AutomaticSetupBusyFence()
        RelayExecutionPool.io.submitRequired(for: key) { sameTail.finish() }
        RelayExecutionPool.io.submitRequired(for: key + ".other") { otherTail.finish() }
        // Pool FIFO releases prior callback bodies/captures before each tail.
        // These tail closures own only fences, never the probe/harness/holder.
        if let error = await wait(sameTail, "automatic busy: same-key sentinel tail"), first == nil { first = error }
        if let error = await wait(otherTail, "automatic busy: other-key sentinel tail"), first == nil { first = error }
        if let first { throw first }
    }
}
private final class AutomaticSetupCase: @unchecked Sendable {
    struct Facts {
        var configurationCalls = 0, sourceCalls = 0, finished = 0
        var observationOverflow = false
        var failureDiagnosticPrinted = false
        var events: [RelaySetupAdmissionObservation] = []
    }
    let directory: URL
    let facts = NIOLockedValueBox(Facts())
    let registrations: RegisteredRecoveryPeers
    let hold = AutomaticSetupIOHold()
    let queuedHold: Bool
    let constructorHold: Bool
    let memory: Bool
    let holdAfterAdmission: Bool
    let holdBeforeCapture: Bool
    let holdActualMutex: Bool
    let holdWhenWaiting: Bool
    let actualMutex = NIOLockedValueBox<AutomaticSetupActualMutex?>(nil)
    let busyRendezvous = NIOLockedValueBox<AutomaticSetupBusyRendezvous?>(nil)
    let otherKeyProgress = NIOLockedValueBox(false)
    init(queuedHold: Bool = false, constructorHold: Bool = false, memory: Bool = false,
         mode: RegisteredRecoveryPeers.Mode = .normal, holdAfterAdmission: Bool = false,
         holdBeforeCapture: Bool = false, holdActualMutex: Bool = false, holdWhenWaiting: Bool = false) throws {
        self.queuedHold = queuedHold; self.constructorHold = constructorHold; self.memory = memory
        self.holdAfterAdmission = holdAfterAdmission; self.holdBeforeCapture = holdBeforeCapture
        self.holdActualMutex = holdActualMutex
        self.holdWhenWaiting = holdWhenWaiting
        registrations = .init(mode)
        let home = try #require(ProcessInfo.processInfo.environment["HOME"])
        directory = URL(fileURLWithPath: home).appending(path: "localdev/lattice-automatic-setup-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var key: String { FileWatchManager.canonicalKey(for: directory.appending(path: "group-a.sqlite")) }
    func ownerOpened(_ owner: Lattice) {
        if holdActualMutex, facts.withLockedValue({ $0.configurationCalls == 1 }) {
            let holder = AutomaticSetupActualMutex(owner: owner)
            actualMutex.withLockedValue { existing in
                precondition(existing == nil) // One selected physical connection.
                existing = holder
            }
        }
        if constructorHold { hold.hold() }
    }
    func releaseHolds() {
        hold.release()
        actualMutex.withLockedValue { $0 }?.requestRelease()
    }
    func retireHolder() async {
        guard let holder = actualMutex.withLockedValue({ $0 }) else { return }
        let retired = await holder.retire(on: key)
        if !retired { printFailureOnce(.holderRetirement) }
        #expect(retired)
        let facts = holder.facts
        if !facts.workerFinished || !facts.writerRetired || !facts.releaseRequested ||
            facts.acquisitionTimedOut || facts.safetyReleased || facts.status != 0 {
            printFailureOnce(.holderRetirement)
        }
        #expect(facts.workerFinished && facts.writerRetired && facts.releaseRequested)
        #expect(!facts.acquisitionTimedOut && !facts.safetyReleased && facts.status == 0)
        let released = actualMutex.withLockedValue { value in let held = value; value = nil; return held }
        withExtendedLifetime(released) {}
    }
    func observe(_ event: RelaySetupAdmissionObservation) {
        facts.withLockedValue { if $0.events.count < 256 { $0.events.append(event) } else { $0.observationOverflow = true } }
        busyRendezvous.withLockedValue { $0 }?.observe(event)
        if event.stage == .attemptEntered, holdBeforeCapture { hold.hold() }
        if event.stage == .admitted, holdAfterAdmission { hold.hold() }
        if event.stage == .waiting, holdWhenWaiting, facts.withLockedValue({ $0.configurationCalls == 1 }) { hold.hold() }
        if event.stage == .ownerOpened, queuedHold {
            RelayExecutionPool.io.submitRequired(for: key) { [hold] in hold.hold() }
        }
    }
    enum FailurePhase: String { case body, cleanup, holderRetirement }
    func printFailureOnce(_ phase: FailurePhase) {
        // Copy bounded scalars first; no formatting or other lock acquisition
        // while holding the case/holder/pool leaf. At most one line per case.
        let copied = facts.withLockedValue { value -> Facts? in
            guard !value.failureDiagnosticPrinted else { return nil }
            value.failureDiagnosticPrinted = true; return value
        }
        guard let copied else { return }
        let holder = actualMutex.withLockedValue { $0 }?.facts
        let control = RelayExecutionPool.control.snapshot, io = RelayExecutionPool.io.snapshot
        func pool(_ value: RelayExecutionSnapshot) -> String {
            "live=\(value.liveWorkers),started=\(value.startedWorkers),executors=\(value.executors),queued=\(value.queued),running=\(value.running),stopping=\(value.stopping)"
        }
        let chosen = copied.events.count <= 8 ? copied.events : Array(copied.events.prefix(2)) + Array(copied.events.suffix(6))
        let events = chosen.map { event in
            "stage=\(event.stage),ns=\(event.observedAt),io=\(event.onIO),attempts=\(String(reflecting: event.budget?.attempts)),start=\(String(reflecting: event.budget?.startedAt)),deadline=\(String(reflecting: event.budget?.deadline)),inflight=\(String(reflecting: event.budget?.inFlight)),cancelled=\(String(reflecting: event.budget?.cancelled)),completed=\(String(reflecting: event.budget?.completed))"
        }.joined(separator: ";")
        let held: String
        if let holder {
            held = "acquired=\(holder.acquired),workerFinished=\(holder.workerFinished),releaseRequested=\(holder.releaseRequested),acquisitionTimedOut=\(holder.acquisitionTimedOut),safetyReleased=\(holder.safetyReleased),writerRetired=\(holder.writerRetired),status=\(holder.status)"
        } else { held = "unobserved" }
        let line = "AUTOMATIC_SETUP_FAILURE phase=\(phase.rawValue) ns=\(DispatchTime.now().uptimeNanoseconds) configurationCalls=\(copied.configurationCalls) sourceCalls=\(copied.sourceCalls) finished=\(copied.finished) eventsCount=\(copied.events.count) eventsOmitted=\(copied.events.count - chosen.count) overflow=\(copied.observationOverflow) holder={\(held)} control={\(pool(control))} io={\(pool(io))} events=[\(events)]"
        print(readyDiagnosticText(line, limit: 4_096))
    }
    func events(_ stage: RelaySetupAdmissionObservation.Stage) -> [RelaySetupAdmissionObservation] {
        facts.withLockedValue { $0.events.filter { $0.stage == stage } }
    }
}
private final class AutomaticSetupHarness: @unchecked Sendable {
    let state: AutomaticSetupCase
    let app: Application
    let writer: SyncRelayHandle
    let port: Int
    private let peers = NIOLockedValueBox<[RecoveryAuthorizationPeer]>([])
    init(_ state: AutomaticSetupCase, didFinish: (@Sendable () -> Void)? = nil) async throws {
        self.state = state
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let created = try await Application.make(environment)
        app = created
        app.http.server.configuration.port = 0
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
            didFinishAsyncSetup: { didFinish?(); state.facts.withLockedValue { $0.finished += 1 } },
            didObserveRecoverySetup: { state.observe($0) },
            didOpenRecoverySetupOwnerForTesting: { state.ownerOpened($0) })
        RelayIngressTesting.install(hooks, for: state.directory)
        defer { RelayIngressTesting.remove(hooks, for: state.directory) }
        writer = Lattice.configureSyncRelay(on: app.routes, path: ["writer"], for: [SimpleSyncObject.self],
            storageURL: state.directory, storeConfiguration: { url in
                state.facts.withLockedValue { $0.configurationCalls += 1 }
                return state.memory ? .init(storage: .memory()) : .init(fileURL: url)
            }, recoverySource: { channel in
                state.facts.withLockedValue { $0.sourceCalls += 1 }
                return try state.registrations.source(channel)
            }, channelExtractor: { try state.registrations.channel($0) },
            recoveryAuthorization: { try await state.registrations.authorize($0, $1) })
        do { try await created.startup(); port = try #require(created.http.server.shared.localAddress?.port) }
        catch { try? await created.asyncShutdown(); throw error }
    }
    func connect() async throws -> RecoveryAuthorizationPeer {
        let p = state.registrations.first
        let query = "recovery-v=1&recovery-replica=\(p.replicaID)&recovery-receiver=\(p.receiverIncarnation)&recovery-channel=\(p.channelIncarnation)"
        let client = RecoveryAuthorizationPeer(); peers.withLockedValue { $0.append(client) }
        var headers = HTTPHeaders(); headers.add(name: "X-Registered-Session", value: state.registrations.token)
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 1 << 20
        try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/writer?\(query)", headers: headers,
            configuration: configuration, on: app.eventLoopGroup) { client.attach($0) }.get()
        try await readyWait("automatic setup peer socket attachment") { client.socket != nil }
        return client
    }
    func shutdown() async throws {
        var first: (any Error)?
        if let rendezvous = state.busyRendezvous.withLockedValue({ $0 }) {
            do { try await rendezvous.drain() } catch { first = error }
            state.busyRendezvous.withLockedValue { $0 = nil }
        }
        state.releaseHolds(); state.registrations.gate.release()
        let clients = peers.withLockedValue { $0 }
        for client in clients { client.socket?.close(promise: nil) }
        await writer.retireRecoveryAuthorization()
        do { try await app.asyncShutdown() } catch { if first == nil { first = error } }
        do { try await readyWait("automatic setup actual drain") { self.writer.recoverySessionCount == 0 } }
        catch { if first == nil { first = error } }
        await state.retireHolder()
        #expect(!state.hold.timedOut.withLockedValue { $0 })
        #expect(!state.facts.withLockedValue { $0.observationOverflow })
        if let first { throw first }
    }
}
private func withAutomaticSetupCase(_ state: AutomaticSetupCase,
    _ body: (AutomaticSetupHarness) async throws -> Void) async throws {
    let harness = try await AutomaticSetupHarness(state)
    var first: (any Error)?
    do {
        try await withTaskCancellationHandler {
            try await body(harness)
        } onCancel: {
            state.busyRendezvous.withLockedValue { $0 }?.disarm()
        }
    } catch { state.printFailureOnce(.body); first = error }
    state.busyRendezvous.withLockedValue { $0 }?.disarm()
    // Exactly one cleanup attempt, including when cleanup itself fails.
    do { try await harness.shutdown() }
    catch { state.printFailureOnce(.cleanup); if first == nil { first = error } else { Issue.record("automatic setup cleanup: \(error)") } }
    if let first { throw first }
}

@Suite("Actual automatic source setup admission", .serialized, .timeLimit(.minutes(2)))
private struct AutomaticSourceSetupTests {
    @Test func actualBusyYieldsKeyedIOAndReusesOneOwnerUntilSuccessfulRelease() async throws {
        let state = try AutomaticSetupCase(holdActualMutex: true)
        try await withAutomaticSetupConsumer { placement in
            // Runs after the original body, shutdown and holder retirement,
            // including a thrown primary error or failed harness construction.
            defer { placement.expectCurrent() }
            try await withAutomaticSetupCase(state) { h in
                placement.expectCurrent() // Actual harness construction returned.
                let rendezvous = AutomaticSetupBusyRendezvous(h)
                state.busyRendezvous.withLockedValue { precondition($0 == nil); $0 = rendezvous }
                try Task.checkCancellation()
                let peer = try await h.connect()
                placement.expectCurrent()
                try await readyWait("automatic busy: two actual waiting returns") { state.events(.waiting).count >= 2 }
                placement.expectCurrent()
                try await readyWait("automatic busy: both actual IO sentinels") { rendezvous.result != nil }
                placement.expectCurrent()
                let observed = try #require(rendezvous.result)
                #expect(!observed.disarmed)
                #expect(observed.trigger.connectionID == state.events(.waiting)[1].connectionID)
                #expect(observed.trigger.observedAt == state.events(.waiting)[1].observedAt)
                #expect(observed.trigger.budget?.attempts == 2)
                #expect(observed.sameKeyOnIO && observed.otherKeyOnIO)
                #expect(observed.sameKeyAt >= observed.trigger.observedAt && observed.otherKeyAt >= observed.trigger.observedAt)
                #expect(observed.releaseAt >= observed.sameKeyAt && observed.releaseAt >= observed.otherKeyAt)
                for boundary in [observed.beforeSubmission, observed.beforeRelease] {
                    let held = try #require(boundary.holder)
                    #expect(held.acquired && held.status == 0 && !held.workerFinished)
                    #expect(!held.releaseRequested && !held.acquisitionTimedOut && !held.safetyReleased)
                    #expect(boundary.authorizationCalls == 0)
                    #expect(boundary.configurationCalls == 1 && boundary.sourceCalls == 1)
                }
                // The original live count oracle belongs at this actual
                // pre-release boundary, even if the consumer resumes late.
                #expect(observed.beforeRelease.sessions == 1)
                try await readyWait("automatic busy: admitted and completion returned") { state.events(.admitted).count == 1 && state.facts.withLockedValue { $0.finished == 1 } }
                placement.expectCurrent()
                #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
                #expect(state.registrations.calls.withLockedValue { $0 } == 1)
                let attempts = state.events(.attemptEntered)
                #expect(attempts.count >= 3 && attempts.count <= 32)
                let attemptsOnIO = attempts.allSatisfy(\.onIO)
                #expect(attemptsOnIO)
                #expect(Set(attempts.compactMap(\.owner)).count == 1)
                #expect(Set(attempts.compactMap { $0.budget?.deadline }).count == 1)
                for (before, after) in zip(attempts, attempts.dropFirst()) {
                    #expect(after.observedAt >= before.observedAt + 100_000_000)
                }
                let (frame, ids) = try recoveryDonorFrame(611)
                try await peer.socket!.send(Array(frame))
                placement.expectCurrent()
                try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
                placement.expectCurrent()
                #expect(peer.facts.withLockedValue { Set($0.acks).count == ids.count })
            }
        }
    }

    @Test func actualBusyExhaustsOriginalBudgetWhileMutexIsStillHeld() async throws {
        let state = try AutomaticSetupCase(holdActualMutex: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            try await readyWait { !state.events(.waiting).isEmpty }
            let holder = try #require(state.actualMutex.withLockedValue { $0 })
            #expect(holder.facts.acquired && holder.facts.status == 0)
            try await readyWait { !state.events(.failed).isEmpty }
            let failed = try #require(state.events(.failed).first)
            let budget = try #require(failed.budget)
            #expect(budget.attempts > 0 && budget.attempts <= 32)
            #expect(budget.attempts == 32 || failed.observedAt >= budget.deadline)
            #expect(budget.deadline - budget.startedAt == 5_000_000_000)
            #expect(!holder.facts.workerFinished && !holder.facts.releaseRequested && !holder.facts.safetyReleased)
            #expect(state.events(.admitted).isEmpty)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
            // Never release the actual mutex to manufacture the refusal oracle.
            holder.requestRelease()
            try await peer.wait { $0.closed }
            try await readyWait { h.writer.recoverySessionCount == 0 }
        }
    }

    @Test func closedTimerCallbackKeepsCapacityUntilItActuallyDrainsAndCannotPoisonSuccessor() async throws {
        let state = try AutomaticSetupCase(holdActualMutex: true, holdWhenWaiting: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            let socket = try #require(peer.socket)
            try await readyWait { state.hold.entered.withLockedValue { $0 } }
            let waiting = try #require(state.events(.waiting).first)
            let holder = try #require(state.actualMutex.withLockedValue { $0 })
            #expect(holder.facts.acquired && holder.facts.status == 0)
            try await socket.close()
            try await peer.wait { $0.closed }
            // Native retirement can finish on IO while the real timer/control
            // callback remains pending. This must not recycle the mount slot.
            try await readyWait { h.writer.recoveryRetiredNativeSessionCount == 1 }
            #expect(h.writer.recoverySessionCount == 1)
            #expect(state.events(.timerDrained).isEmpty)
            #expect(state.events(.ownerReleased).isEmpty)
            holder.requestRelease(); state.hold.release()
            try await readyWait { h.writer.recoverySessionCount == 0 && state.events(.timerDrained).count == 1 }
            await state.retireHolder()
            let successor = try await h.connect()
            try await readyWait { state.events(.admitted).count == 1 && state.registrations.calls.withLockedValue { $0 } == 1 }
            let admitted = try #require(state.events(.admitted).first)
            #expect(admitted.connectionID != waiting.connectionID)
            #expect(!state.events(.admitted).contains { $0.connectionID == waiting.connectionID })
            let (frame, ids) = try recoveryDonorFrame(612)
            try await successor.socket!.send(Array(frame))
            try await successor.wait { Set(ids).isSubset(of: Set($0.acks)) }
            withExtendedLifetime(socket) {}
        }
    }

    @Test func oneOpenedOwnerAndAuthorizationRemainUsableBeyondAdmissionDeadline() async throws {
        let state = try AutomaticSetupCase()
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            try await readyWait { state.events(.admitted).count == 1 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
            #expect(state.registrations.calls.withLockedValue { $0 } == 1)
            let admitted = try #require(state.events(.admitted).first)
            let budget = try #require(admitted.budget)
            let now = DispatchTime.now().uptimeNanoseconds
            if now <= budget.deadline { try await Task.sleep(nanoseconds: budget.deadline - now + 100_000_000) }
            // The setup deadline must never become retained route liveness.
            let (frame, ids) = try recoveryDonorFrame(610)
            try await peer.socket!.send(Array(frame))
            try await peer.wait { Set(ids).isSubset(of: Set($0.acks)) }
            #expect(!peer.facts.withLockedValue { $0.closed })
            let owners = state.facts.withLockedValue { Set($0.events.compactMap(\.owner)) }
            #expect(owners.count == 1)
            #expect(state.events(.admitted).count == 1)
        }
    }

    @Test(arguments: [false, true])
    func closeKeepsSetupCapacityUntilActualQueuedOrOpeningIODrains(opening: Bool) async throws {
        let state = try AutomaticSetupCase(queuedHold: !opening, constructorHold: opening)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            let socket = try #require(peer.socket)
            try await readyWait { state.hold.entered.withLockedValue { $0 } }
            RelayExecutionPool.io.submitRequired(for: state.key + ".independent") {
                state.otherKeyProgress.withLockedValue { $0 = true }
            }
            try await readyWait { state.otherKeyProgress.withLockedValue { $0 } }
            try await socket.close()
            try await peer.wait { $0.closed }
            #expect(h.writer.recoverySessionCount == 1)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            #expect(state.events(.attemptEntered).isEmpty)
            #expect(state.events(.ownerReleased).isEmpty)
            state.hold.release()
            try await readyWait { h.writer.recoverySessionCount == 0 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(state.events(.ownerReleased).count == 1)
            #expect(state.events(.admitted).isEmpty)
            #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
            withExtendedLifetime(socket) {}
        }
    }

    @Test func firstCaptureQueuedBeyondOriginalDeadlineNeverEntersNativeAdmission() async throws {
        let state = try AutomaticSetupCase(queuedHold: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            try await readyWait { state.hold.entered.withLockedValue { $0 } && !state.events(.attemptQueued).isEmpty }
            let queued = try #require(state.events(.attemptQueued).first)
            let budget = try #require(queued.budget)
            #expect(budget.attempts == 0)
            let now = DispatchTime.now().uptimeNanoseconds
            if now <= budget.deadline { try await Task.sleep(nanoseconds: budget.deadline - now + 100_000_000) }
            #expect(h.writer.recoverySessionCount == 1)
            state.hold.release()
            try await peer.wait { $0.closed }
            try await readyWait { h.writer.recoverySessionCount == 0 && !state.events(.failed).isEmpty }
            #expect(state.events(.attemptEntered).isEmpty)
            #expect(state.events(.failed).first?.budget?.attempts == 0)
            #expect(state.events(.failed).first?.budget?.deadline == budget.deadline)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
        }
    }

    @Test func deadlineCrossedAfterAttemptEntryIsVetoedBeforeNativeEnrollment() async throws {
        let state = try AutomaticSetupCase(holdBeforeCapture: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            try await readyWait { state.hold.entered.withLockedValue { $0 } && state.events(.attemptEntered).count == 1 }
            let entered = try #require(state.events(.attemptEntered).first)
            let budget = try #require(entered.budget)
            #expect(budget.attempts == 1)
            let now = DispatchTime.now().uptimeNanoseconds
            if now <= budget.deadline { try await Task.sleep(nanoseconds: budget.deadline - now + 100_000_000) }
            state.hold.release()
            try await peer.wait { $0.closed }
            try await readyWait { h.writer.recoverySessionCount == 0 && !state.events(.failed).isEmpty }
            #expect(state.events(.attemptEntered).count == 1)
            #expect(state.events(.failed).first?.budget?.attempts == 1)
            #expect(state.events(.failed).first?.budget?.deadline == budget.deadline)
            #expect(state.events(.admitted).isEmpty && state.events(.busy).isEmpty)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
        }
    }

    @Test func retiringActualMountCancelsBusyEpisodeAndDrainsWithSocketRetained() async throws {
        let state = try AutomaticSetupCase(holdActualMutex: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            let socket = try #require(peer.socket)
            try await readyWait { state.events(.waiting).count >= 2 }
            let holder = try #require(state.actualMutex.withLockedValue { $0 })
            #expect(holder.facts.acquired && holder.facts.status == 0)
            await h.writer.retireRecoveryAuthorization()
            try await peer.wait { $0.closed }
            try await readyWait { h.writer.recoverySessionCount == 0 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(state.events(.admitted).isEmpty)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            #expect(state.events(.ownerReleased).count == 1)
            #expect(!holder.facts.workerFinished && !holder.facts.releaseRequested && !holder.facts.safetyReleased)
            holder.requestRelease()
            withExtendedLifetime(socket) {}
        }
    }

    @Test func unsupportedPhysicalStoreIsTerminalWithoutBusyRetry() async throws {
        let state = try AutomaticSetupCase(memory: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            try await peer.wait { $0.closed }
            try await readyWait { h.writer.recoverySessionCount == 0 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(state.events(.ownerOpened).count == 1)
            #expect(state.events(.attemptEntered).count == 1)
            #expect(state.events(.failed).count == 1)
            #expect(state.events(.busy).isEmpty)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
        }
    }

    @Test func closeAfterRealEnrollmentBeforeControlHandoffDisposesLateSetup() async throws {
        let state = try AutomaticSetupCase(holdAfterAdmission: true)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            let socket = try #require(peer.socket)
            try await readyWait { state.hold.entered.withLockedValue { $0 } && state.events(.admitted).count == 1 }
            try await socket.close()
            try await peer.wait { $0.closed }
            #expect(h.writer.recoverySessionCount == 1)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            state.hold.release()
            try await readyWait { h.writer.recoverySessionCount == 0 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(state.events(.admitted).count == 1)
            #expect(state.events(.ownerReleased).count == 1)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            withExtendedLifetime(socket) {}
        }
    }

    @Test func authorizationRefusalAfterEnrollmentNeverRestartsCapture() async throws {
        let state = try AutomaticSetupCase(mode: .wrongSource)
        try await withAutomaticSetupCase(state) { h in
            let peer = try await h.connect()
            try await peer.wait { $0.closed }
            try await readyWait { h.writer.recoverySessionCount == 0 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(state.events(.admitted).count == 1)
            #expect(state.registrations.calls.withLockedValue { $0 } == 1)
            #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
            #expect(peer.facts.withLockedValue { $0.acks.isEmpty && $0.audits.isEmpty })
        }
    }
    @Test(arguments: [false, true])
    func stalePreReadUnopenedKeyCannotRetireOnAnotherLane(retireBeforeReservation: Bool) async throws {
        let state = try AutomaticSetupCase(holdAfterAdmission: !retireBeforeReservation)
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.port = 0; app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        let mount = RecoveryRelayMount(source: { try state.registrations.source($0) }, upload: nil,
                                      authorize: { try await state.registrations.authorize($0, $1) })
        let sockets = SocketManager()
        let staleLaneDrained = NIOLockedValueBox(false)
        let oldKey = NIOLockedValueBox<String?>(nil)
        let failure = NIOLockedValueBox<String?>(nil)
        let peer = RecoveryAuthorizationPeer()
        app.webSocket("custody") { request, socket in
            do {
                let channel = try state.registrations.channel(request)
                let source = try mount.resolve(channel)
                let connectionState = ConnectionRelayState()
                let recovery = try RecoveryRelayConnection(mount: mount, request: request, socket: socket,
                                                            revocation: connectionState.revocation)
                connectionState.recovery = recovery
                // This is an actual pre-start read, not a fabricated apply key.
                let capturedBeforeStart = connectionState.nativeReleaseKey
                oldKey.withLockedValue { $0 = capturedBeforeStart }
                socket.onClose.whenComplete { _ in
                    // Deliberately deliver the genuine stale captured argument
                    // first. A fresh-key second call must not hide the race.
                    recovery.retire(for: capturedBeforeStart)
                    connectionState.sealIngress(.setupRefused, socket: socket)
                    RelayExecutionPool.io.submitRequired(for: capturedBeforeStart) {
                        staleLaneDrained.withLockedValue { $0 = true }
                    }
                    Task { @RelayControlActor in sockets.remove(socket: socket, channelId: channel.id) }
                }
                if retireBeforeReservation { recovery.retire(for: capturedBeforeStart) }
                let input = RelayConnectionSetupInput(schema: [SimpleSyncObject.self], storageURL: state.directory,
                    fileURL: state.directory.appending(path: "group-a.sqlite"), applyKey: state.key,
                    channel: channel, recoverySource: source, socket: socket, state: connectionState,
                    sockets: sockets, watchManager: nil, pushContext: nil,
                    storeConfiguration: { url in
                        state.facts.withLockedValue { $0.configurationCalls += 1 }; return .init(fileURL: url)
                    }, lastEventId: nil, processFrame: { _, _, _ in }, diagnostic: nil, sendCatchUp: nil,
                    didFinish: { state.facts.withLockedValue { $0.finished += 1 } },
                    didObserveRecoverySetup: { state.observe($0) }, didOpenRecoverySetupOwnerForTesting: nil)
                Task { @RelayControlActor in RelayConnectionSetup(input: input).start() }
            } catch {
                failure.withLockedValue { $0 = String(describing: error) }
                socket.close(promise: nil)
            }
        }
        var first: (any Error)?
        do {
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let p = state.registrations.first
            let query = "recovery-v=1&recovery-replica=\(p.replicaID)&recovery-receiver=\(p.receiverIncarnation)&recovery-channel=\(p.channelIncarnation)"
            var headers = HTTPHeaders(); headers.add(name: "X-Registered-Session", value: state.registrations.token)
            try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/custody?\(query)", headers: headers,
                                         on: app.eventLoopGroup) { peer.attach($0) }.get()
            try await readyWait("custody peer socket attachment") { peer.socket != nil }
            let socket = try #require(peer.socket)
            if !retireBeforeReservation {
                try await readyWait { state.hold.entered.withLockedValue { $0 } && state.events(.admitted).count == 1 }
                let captured = try #require(oldKey.withLockedValue { $0 })
                #expect(captured.hasPrefix("unopened:") && captured != state.key)
                try await socket.close()
                try await peer.wait { $0.closed }
                // Any wrongly submitted old-key native cleanup would precede
                // this real sentinel. Correct cleanup waits behind held new IO.
                try await readyWait { staleLaneDrained.withLockedValue { $0 } }
                #expect(mount.retiredNativeSessionCount == 0)
                #expect(mount.sessionCount == 1)
                #expect(state.events(.ownerReleased).isEmpty)
                state.hold.release()
            }
            try await peer.wait { $0.closed }
            try await readyWait { mount.sessionCount == 0 && state.facts.withLockedValue { $0.finished == 1 } }
            #expect(failure.withLockedValue { $0 } == nil)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            if retireBeforeReservation {
                #expect(state.events(.ownerOpened).isEmpty)
                #expect(state.events(.attemptEntered).isEmpty)
                #expect(state.facts.withLockedValue { $0.configurationCalls == 0 })
            } else {
                #expect(state.events(.ownerReleased).count == 1)
                #expect(state.events(.admitted).count == 1)
                #expect(state.facts.withLockedValue { $0.configurationCalls == 1 })
            }
            withExtendedLifetime(socket) {}
        } catch { first = error }
        state.releaseHolds(); peer.socket?.close(promise: nil); mount.retire()
        do { try await app.asyncShutdown() } catch { if first == nil { first = error } }
        do { try await readyWait { mount.sessionCount == 0 } } catch { if first == nil { first = error } }
        #expect(!state.hold.timedOut.withLockedValue { $0 })
        #expect(!state.facts.withLockedValue { $0.observationOverflow })
        if let first { throw first }
    }

    @Test func closedSetupKeepsCapacityThroughActualFinalCompletionCallbackReturn() async throws {
        let state = try AutomaticSetupCase(constructorHold: true)
        let completionHold = AutomaticSetupIOHold()
        let h = try await AutomaticSetupHarness(state, didFinish: { completionHold.hold() })
        var first: (any Error)?
        do {
            let peer = try await h.connect()
            let socket = try #require(peer.socket)
            try await readyWait { state.hold.entered.withLockedValue { $0 } }
            try await socket.close()
            try await peer.wait { $0.closed }
            await h.writer.retireRecoveryAuthorization()
            try await readyWait { state.events(.stopCallbackReturning).count == 1 }
            // The scalar event precedes the stop task's work defer. A later
            // actual turn proves that defer returned, so earlier stop custody
            // cannot mask a missing charge on the final completion callback.
            await Task { @RelayControlActor in () }.value
            #expect(state.events(.ownerReleased).isEmpty)
            #expect(h.writer.recoverySessionCount == 1)
            state.hold.release()
            try await readyWait { completionHold.entered.withLockedValue { $0 } }
            let finalizerReturned = NIOLockedValueBox(false)
            RelayExecutionPool.io.submitRequired(for: state.key) {
                finalizerReturned.withLockedValue { $0 = RelayExecutionPool.io.isCurrentWorker }
            }
            try await readyWait { finalizerReturned.withLockedValue { $0 } }
            #expect(!completionHold.timedOut.withLockedValue { $0 })
            #expect(state.events(.ownerReleased).count == 1)
            let ownerReleasesOnIO = state.events(.ownerReleased).allSatisfy(\.onIO)
            #expect(ownerReleasesOnIO)
            #expect(h.writer.recoveryRetiredNativeSessionCount == 1)
            #expect(h.writer.recoverySessionCount == 1)
            #expect(state.facts.withLockedValue { $0.finished == 0 })
            #expect(socket.isClosed)
            #expect(state.events(.attemptEntered).isEmpty && state.events(.admitted).isEmpty)
            #expect(state.registrations.calls.withLockedValue { $0 } == 0)
            #expect(state.facts.withLockedValue { $0.configurationCalls == 1 && $0.sourceCalls == 1 })
            completionHold.release()
            try await readyWait { state.facts.withLockedValue { $0.finished == 1 } && h.writer.recoverySessionCount == 0 }
            #expect(!completionHold.timedOut.withLockedValue { $0 })
            withExtendedLifetime(socket) {}
        } catch { first = error }
        // Release both real callbacks before shutdown even on the first failure.
        completionHold.release(); state.releaseHolds()
        do { try await h.shutdown() }
        catch { if first == nil { first = error } else { Issue.record("final setup callback cleanup: \(error)") } }
        #expect(!completionHold.timedOut.withLockedValue { $0 })
        if let first { throw first }
    }
}
