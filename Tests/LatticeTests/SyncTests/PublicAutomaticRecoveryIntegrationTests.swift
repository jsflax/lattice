import Foundation
import Testing
import Vapor
import NIOConcurrencyHelpers
import CxxStdlib
import LatticeServerExportTestSupport
@testable import Lattice
@testable import LatticeServerKit

// Dedicated hosted gate only. Ordinary full suites do not create trust or run
// servers from this fixture. The wrapper must require all three actual passes.
@Model private final class ConnectedRecoverySharedRow {
    var label: String = ""
    var value: Int = 0
    init(label: String, value: Int) { self.label = label; self.value = value }
}
@Model private final class ConnectedRecoveryLocalRow {
    var value: String = ""
    init(value: String) { self.value = value }
}

#if os(Linux)
private typealias ConnectedStockClient = NIOWebsocketClient
#else
private typealias ConnectedStockClient = Lattice.WebsocketClient
#endif
private enum ConnectedRecoveryFailure: Error { case environment, deadline(String), metadata, receipt, unexpectedOriginal }

private struct ConnectedTLSEnvironment: Sendable {
    let root, certificate, key, wrongCertificate, wrongKey: URL
    init(observation: ConnectedFailureObservation? = nil) throws {
        observation?.phase(.environmentMarkers)
        let env = ProcessInfo.processInfo.environment
        guard env["LATTICE_CONNECTED_RECOVERY_GATE"] == "1",
              env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              let raw = env["LATTICE_CONNECTED_RECOVERY_RUN_DIR"] else { throw ConnectedRecoveryFailure.environment }
        observation?.phase(.environmentRoot)
        guard let runRoot = ConnectedHostedRootLayout.runRoot(raw, home: env["HOME"]) else { throw ConnectedRecoveryFailure.environment }
        root = runRoot
        guard runRoot.resolvingSymlinksInPath().path == runRoot.path else { throw ConnectedRecoveryFailure.environment }
        func privateFile(_ name: String) throws -> URL {
            guard let value = env[name], value.hasPrefix("/") else { throw ConnectedRecoveryFailure.environment }
            let url = URL(fileURLWithPath: value).standardizedFileURL
            guard url.path.hasPrefix(runRoot.path + "/private/"), url.resolvingSymlinksInPath().path == url.path,
                  FileManager.default.fileExists(atPath: url.path) else { throw ConnectedRecoveryFailure.environment }
            return url
        }
        observation?.phase(.environmentPrivateFiles)
        certificate = try privateFile("LATTICE_CONNECTED_RECOVERY_TLS_CERT")
        key = try privateFile("LATTICE_CONNECTED_RECOVERY_TLS_KEY")
        wrongCertificate = try privateFile("LATTICE_CONNECTED_RECOVERY_WRONG_HOST_CERT")
        wrongKey = try privateFile("LATTICE_CONNECTED_RECOVERY_WRONG_HOST_KEY")
        observation?.phase(.environmentReceiptPath)
        guard let receiptPath = env["LATTICE_CONNECTED_RECOVERY_TLS_RECEIPT"],
              URL(fileURLWithPath: receiptPath).standardizedFileURL.path == root.appendingPathComponent("receipts/tls-material.json").path
        else { throw ConnectedRecoveryFailure.environment }
        observation?.phase(.environmentReceiptRead)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        observation?.phase(.environmentReceiptDecode)
        guard bytes.count <= 16_384,
              let receipt = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              receipt["version"] as? Int == 1,
              receipt["matchingSANs"] as? [String] == ["DNS:localhost", "IP:127.0.0.1"],
              receipt["wrongHostSANs"] as? [String] == ["DNS:lattice-wrong-host.invalid"],
              receipt["minimumTLS"] as? String == "1.2",
              ["bothChainsVerified", "matchingIPVerified", "wrongHostIPRejected", "keyMatches", "validNow"].allSatisfy({ receipt[$0] as? Bool == true })
        else { throw ConnectedRecoveryFailure.receipt }
        observation?.phase(.environmentReceiptFields)
        for field in ["caSHA256", "matchingSHA256", "wrongHostSHA256"] {
            guard let hash = receipt[field] as? String, hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ConnectedRecoveryFailure.receipt }
        }
        guard (receipt["matchingSHA256"] as? String) != (receipt["wrongHostSHA256"] as? String) else { throw ConnectedRecoveryFailure.receipt }
    }
}

@MainActor
private func connectedWait(_ phase: String, until deadline: ContinuousClock.Instant,
                           _ predicate: () throws -> Bool) async throws {
    while true {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { throw ConnectedRecoveryFailure.deadline(phase) }
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func connectedApplication(_ certificate: URL, _ key: URL, observation: ConnectedFailureObservation? = nil) async throws -> Application {
    observation?.phase(.applicationEnvironment)
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    observation?.phase(.applicationCreate)
    // The bootstrap client uses this same group. Own it so failed pre-upgrade
    // channels are closed and its threads joined by fixture cleanup.
    let app = try await Application.make(environment, .createNew)
    observation?.phase(.applicationTLS)
    var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.file(certificate.path)], privateKey: .file(key.path))
    tls.minimumTLSVersion = .tlsv12
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 0
    app.http.server.configuration.supportVersions = [.one]
    app.http.server.configuration.tlsConfiguration = tls
    app.http.server.configuration.shutdownTimeout = .seconds(1)
    return app
}

@MainActor
private func connectedShutdown(_ app: Application) async throws {
    guard case .createNew = app.eventLoopGroupProvider else { throw ConnectedRecoveryFailure.metadata }
    var firstError: (any Error)?
    if !app.didShutdown {
        do { try await app.asyncShutdown() } catch { firstError = error }
    }
    // Vapor logs and suppresses group-shutdown errors. Pinned NIO explicitly
    // permits this second call: it returns the retained result after all
    // registered channels close and all owned event-loop threads are joined.
    do { try await app.eventLoopGroup.shutdownGracefully() }
    catch { if firstError == nil { firstError = error } }
    if let firstError { throw firstError }
}

/// Only copied scalar test facts leave the owning actor. No records, native
/// handles, source grants, bearer strings or file locations enter this receipt.
@MainActor
private func connectedReceipt(_ environment: ConnectedTLSEnvironment, name: String, facts: [String: Any]) throws {
    let path = environment.root.appendingPathComponent("receipts/connected-recovery-cases.json")
    let names: Set<String> = ["stockTLSAcceptsMatchingHostedCertificate", "stockTLSRejectsReachableWrongHostCertificate",
                             "twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels"]
    guard names.contains(name) else { throw ConnectedRecoveryFailure.receipt }
    var cases: [[String: Any]] = []
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        guard data.count <= 16_384, let prior = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              prior["version"] as? Int == 1, let priorCases = prior["cases"] as? [[String: Any]], priorCases.count < 3,
              !priorCases.contains(where: { $0["name"] as? String == name }) else { throw ConnectedRecoveryFailure.receipt }
        cases = priorCases
    }
    cases.append(["name": name, "passed": true, "scalarFacts": facts])
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "cases": cases], options: [.sortedKeys])
    guard data.count <= 16_384 else { throw ConnectedRecoveryFailure.receipt }
    try data.write(to: path, options: .atomic)
}

private final class ConnectedReadyGate: Sendable {
    private struct State {
        var observations: [RelayReadyControlObservation] = []
        var bytes = 0, overflow = false
        var target: (replica: String, channel: String)?
        var selected: RelayReadyControlObservation?
        var send: (@Sendable () -> Void)?
        var held = false
        var allowed: Bool?
    }
    private let state = NIOLockedValueBox(State())
    func observe(_ observation: RelayReadyControlObservation) {
        state.withLockedValue { value in
            let strings = [observation.channel, observation.requestID, observation.operation, observation.peer.replicaID,
                observation.routeGeneration ?? "", observation.requestDigest ?? "", observation.attemptID ?? "",
                observation.sequence ?? "", observation.index ?? "", observation.canonicalKind ?? ""]
            let bytes = strings.reduce(128) { $0 + $1.utf8.count }
            if value.observations.count >= 256 || bytes > 65_536 - value.bytes { value.overflow = true; return }
            value.bytes += bytes; value.observations.append(observation)
            guard value.selected == nil, let target = value.target,
                  observation.peer.replicaID == target.replica, observation.channel == target.channel,
                  observation.operation == "read", observation.index == "0", observation.canonicalKind == "manifest",
                  observation.routeGeneration != nil, observation.requestDigest != nil,
                  observation.attemptID != nil, observation.sequence != nil else { return }
            value.selected = observation
        }
    }
    func arm(replica: String, channel: String) {
        state.withLockedValue { value in
            precondition(value.target == nil && value.selected == nil && value.send == nil)
            value.target = (replica, channel)
        }
    }
    func park(_ id: String, _ send: @escaping @Sendable () -> Void) -> Bool {
        state.withLockedValue { value in
            guard value.selected?.requestID == id, value.send == nil, !value.held else { return false }
            value.send = send; value.held = true; return true
        }
    }
    func decision(_ id: String, _ allowed: Bool) {
        state.withLockedValue { if $0.selected?.requestID == id { $0.allowed = allowed } }
    }
    func release() {
        let send = state.withLockedValue { value in let send = value.send; value.send = nil; value.target = nil; return send }
        send?()
    }
    var held: Bool { state.withLockedValue { $0.held && $0.send != nil } }
    var selected: RelayReadyControlObservation? { state.withLockedValue { $0.selected } }
    var allowed: Bool? { state.withLockedValue { $0.allowed } }
    var overflow: Bool { state.withLockedValue { $0.overflow } }
    func canonicalRoutes(replicas: Set<String>) -> Set<String> {
        state.withLockedValue { value in Set(value.observations.compactMap {
            replicas.contains($0.peer.replicaID) && $0.operation == "read" && $0.canonicalKind != nil
                ? $0.peer.replicaID + "|" + $0.channel : nil
        }) }
    }
    func hasCanonicalReads(replica: String, channels: [String]) -> Bool {
        let observed = canonicalRoutes(replicas: [replica])
        return channels.allSatisfy { observed.contains(replica + "|" + $0) }
    }
}

private struct ConnectedRegistration: Sendable {
    let token: String
    let replica: String
    let receiver: UUID
    let channels: [UUID]
    let producer: SyncRecoveryProducerRegistration
    init(_ name: String) {
        token = UUID().uuidString; replica = "connected-" + name; receiver = UUID(); channels = [UUID(), UUID()]
        producer = .init(registrationID: "producer-" + name, incarnation: UUID())
    }
    func peer(_ index: Int) -> SyncRecoveryPeerIdentity {
        .init(replicaID: replica, receiverIncarnation: receiver, channelIncarnation: channels[index])
    }
}

private final class ConnectedRegistrations: Sendable {
    let user = UUID(), sourceID = UUID(), epoch = UUID(), cohortID = UUID()
    let bootstrap = ConnectedRegistration("bootstrap"), a = ConnectedRegistration("a"), b = ConnectedRegistration("b")
    let contexts = NIOLockedValueBox<[Int: SyncRecoveryAuthorizationContext]>([:])
    let endpoints = NIOLockedValueBox<[String]>([])
    let gate = ConnectedReadyGate()
    private var namespaces: [SyncRecoveryNamespace] {
        [.init(namespaceID: "local", coverageID: "local-v1", revision: 1),
         .init(namespaceID: "a", coverageID: "shared-v1", revision: 1),
         .init(namespaceID: "b", coverageID: "shared-v1", revision: 1)]
    }
    func channel(_ request: Request, index: Int) throws -> SyncChannel {
        _ = try registration(request)
        let endpoints = endpoints.withLockedValue { $0 }
        guard endpoints.count == 2 else { throw Abort(.serviceUnavailable) }
        return .init(id: "wss:" + endpoints[index], userId: user, databaseFileName: "source.sqlite")
    }
    private func registration(_ request: Request) throws -> ConnectedRegistration {
        guard let header = request.headers.first(name: "Authorization"),
              request.headers["Authorization"].count == 1,
              let found = [bootstrap, a, b].first(where: { header == "Bearer " + $0.token }) else { throw Abort(.unauthorized) }
        return found
    }
    func policy(_ index: Int) throws -> SyncRecoveryMountConfiguration {
        let cohort = try SyncRecoveryReceiptCohort(id: cohortID, revision: 1, namespaces: Array(namespaces.dropFirst()))
        return try .init(authority: "connected-service", sourceID: sourceID, epoch: epoch, localNamespace: "local",
            namespaces: namespaces, receiptNamespace: index == 0 ? "a" : "b", models: ["ConnectedRecoverySharedRow"],
            durability: .walFull, maximumAuthorizationMilliseconds: 600_000,
            readyProfile: .bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: 10_000), receiptCoverage: .registeredProducerV3(cohort))
    }
    func authorize(_ request: Request, _ context: SyncRecoveryAuthorizationContext, index: Int) throws -> SyncRecoveryAuthorization {
        let registered = try registration(request), expectedChannel = try channel(request, index: index)
        guard context.channel.id == expectedChannel.id, context.channel.userId == user,
              context.declaredPeer == registered.peer(index), context.source.authority == "connected-service",
              context.source.sourceID == sourceID, context.source.epoch == epoch,
              context.source.receiptNamespace == (index == 0 ? "a" : "b"), context.source.coverageID == "shared-v1",
              context.source.coverageRevision == 1, context.source.receiptCoverage?.cohortID == cohortID.uuidString.lowercased(),
              context.source.receiptCoverage?.cohortRevision == 1, context.source.receiptCoverage?.namespaces == ["a", "b"],
              context.incomingScope.models.count == 1, context.incomingScope.models[0].table == "ConnectedRecoverySharedRow",
              context.incomingScope.models[0].incomingOperations == [.insert, .update, .delete],
              context.incomingScope.relations.isEmpty, context.incomingScope.scopedLinkTables.isEmpty,
              context.incomingScope.catalogDigest == context.source.schemaDigest else { throw Abort(.forbidden) }
        if registered.replica == bootstrap.replica { contexts.withLockedValue { $0[index] = context } }
        return .init(authenticatedUserID: user, peer: registered.peer(index), source: context.source,
            incomingScope: context.incomingScope, authorizationRevision: "connected-registration-v1", validForMilliseconds: 600_000,
            receiptCoverage: .registeredProducer(registered.producer, cohortID: cohortID, cohortRevision: 1))
    }
}

/// Receives real ordinary catch-up only. It never emits READY/audit/ACK frames
/// and never serves as a receiver or an installation authority.
private final class ConnectedBootstrapPeer: Sendable {
    private struct State { var socket: WebSocket?; var ids = Set<String>(); var lifecycle = ConnectedBootstrapLifecycle(); var invalid = false }
    private let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        let closeAfterAttach = state.withLockedValue { value in
            value.socket = socket
            return value.lifecycle.didAttach()
        }
        socket.onBinary { [weak self] _, bytes in
            guard let self else { return }
            guard bytes.readableBytes <= 1_048_576,
                  let object = (try? JSONSerialization.jsonObject(with: Data(buffer: bytes))) as? [String: Any]
            else { self.state.withLockedValue { $0.invalid = true }; return }
            guard let audits = object["auditLog"] as? [[String: Any]] else { return }
            self.state.withLockedValue { value in
                for audit in audits {
                    guard value.ids.count < 64, audit["tableName"] as? String == "ConnectedRecoverySharedRow",
                          let id = audit["globalId"] as? String, UUID(uuidString: id) != nil else { value.invalid = true; return }
                    value.ids.insert(id.lowercased())
                }
            }
        }
        socket.onClose.whenComplete { [weak self] _ in self?.state.withLockedValue { $0.lifecycle.didClose(); $0.socket = nil } }
        if closeAfterAttach { socket.close(promise: nil) }
    }
    var ids: Set<String> { state.withLockedValue { $0.ids } }
    var invalid: Bool { state.withLockedValue { $0.invalid } }
    var closed: Bool { state.withLockedValue { $0.lifecycle.closed } }
    func connectFailed() { state.withLockedValue { $0.lifecycle.connectFailed() } }
    func cleanupRetired(ownedGroupJoined: Bool) -> Bool {
        state.withLockedValue { $0.lifecycle.cleanupRetired(ownedGroupJoined: ownedGroupJoined) }
    }
    func close() {
        let socket = state.withLockedValue { value in value.lifecycle.requestClose(); return value.socket }
        socket?.close(promise: nil)
    }
}

private struct ConnectedRow: Equatable, Sendable { let id: UUID; let label: String; let value: Int }
private struct ConnectedOriginal: Equatable, Sendable {
    let id, target: UUID
    let table, operation: String
    let fields: Data // Canonical Codable AnyProperty retains each actual type tag.
    let names: [String?]?
}

@MainActor
private final class ConnectedReceiver {
    let file: URL
    let registration: ConnectedRegistration
    let policy: ContinuousProducerPolicy
    let expectations: [Lattice.RecoverySourceExpectation]
    private var owners: [Lattice] = []
    init(root: URL, registration: ConnectedRegistration, contexts: [SyncRecoveryAuthorizationContext], endpoints: [String]) throws {
        self.registration = registration
        file = root.appendingPathComponent(registration.replica + ".lattice-continuous/store.sqlite")
        guard contexts.count == 2, endpoints.count == 2, contexts[0].incomingScope == contexts[1].incomingScope else { throw ConnectedRecoveryFailure.metadata }
        // Encode once and reuse byte-exact for the same canonical domain.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let claim = try encoder.encode(contexts[0].incomingScope)
        expectations = try contexts.enumerated().map { index, context in
            let s = context.source, scope = context.incomingScope, peer = registration.peer(index)
            return try .init(endpoint: URL(string: endpoints[index])!, source: .init(authority: s.authority, sourceID: s.sourceID,
                epoch: s.epoch, scopeDigest: s.scopeDigest, schemaDigest: s.schemaDigest, receiptNamespace: s.receiptNamespace,
                coverageID: s.coverageID, coverageRevision: s.coverageRevision, descriptorDigest: s.descriptorDigest, receiptCoverage: s.receiptCoverage),
                peer: .init(replicaID: peer.replicaID, receiverIncarnation: peer.receiverIncarnation, channelIncarnation: peer.channelIncarnation),
                incomingScope: .init(models: scope.models.map { .init(table: $0.table, incomingOperations: $0.incomingOperations.map { .init(rawValue: $0.rawValue)! }) },
                    relations: [], scopedLinkTables: [], catalogDigest: scope.catalogDigest), channel: "wss:" + endpoints[index], validForMilliseconds: 600_000)
        }
        policy = .init(contributions: contexts.enumerated().map { index, context in
            let source = context.source
            return .init(channel: "wss:" + endpoints[index], authority: source.authority, source: source.sourceID.uuidString.lowercased(),
                epoch: source.epoch.uuidString.lowercased(), scope: source.scopeDigest, schema: source.schemaDigest,
                profileDigest: "connected-public-v1", receiptNamespace: source.receiptNamespace,
                models: ["ConnectedRecoverySharedRow"], incomingGrantClaim: claim)
        }, routes: endpoints.map { .init(syncID: "wss:" + $0, endpoint: $0) },
            limits: .init(scopes: 4, records: 128, fieldBytes: 128, journalBytes: 2 * 1024 * 1024,
                channels: 4, bindingFieldBytes: 128, bindingBytes: 8192, profiles: 4, stamps: 128, producerFieldBytes: 128,
                manifestBytes: 1_048_576, producerBytes: 8 * 1024 * 1024, owners: 8, physicalRoutes: 8, operations: 8,
                frozenEntries: 128, frozenBytes: 2 * 1024 * 1024), recovery: .automatic)
    }
    func open(connected: Bool) throws {
        precondition(owners.isEmpty)
        do {
            for index in 0..<(connected ? 2 : 1) {
                var config = Lattice.Configuration(fileURL: file, busyTimeoutMs: 100)
                config.resultsTuning.crossProcessBeltIntervalMs = nil
                // The immutable whole-model contributions select protected
                // exports. Configured continuous routes correctly reject an
                // additional mutable syncFilter; local-only rows have no claim.
                if connected {
                    config.wssEndpoint = expectations[index].endpoint; config.authorizationToken = registration.token
                    config.recoverySourceExpectation = expectations[index]
                }
                owners.append(try Lattice(for: [ConnectedRecoverySharedRow.self, ConnectedRecoveryLocalRow.self], configuration: config, continuousProducer: policy))
            }
        } catch { close(); throw error }
    }
    func close() { for owner in owners.reversed() { owner.close() }; owners.removeAll() }
    private var owner: Lattice { precondition(!owners.isEmpty); return owners[0] }
    func rows() throws -> [ConnectedRow] {
        let result = owner.objects(ConnectedRecoverySharedRow.self)
        guard result.count <= 16 else { throw ConnectedRecoveryFailure.metadata }
        let copied = try Array(result).map {
            let id = try #require($0.globalId)
            return ConnectedRow(id: id, label: $0.label, value: $0.value)
        }
        guard copied.count <= 16, Set(copied.map(\.id)).count == copied.count, Set(copied.map(\.label)).count == copied.count else { throw ConnectedRecoveryFailure.metadata }
        return copied.sorted { $0.label < $1.label }
    }
    func originals() throws -> [ConnectedOriginal] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = owner.eventsAfter(globalId: nil)
        guard result.count <= 256 else { throw ConnectedRecoveryFailure.metadata }
        let events = Array(result)
        guard events.count <= 256 else { throw ConnectedRecoveryFailure.metadata }
        return try events.map { event in
            let id = try #require(event.globalId), target = try #require(event.globalRowId)
            return .init(id: id, target: target, table: event.tableName, operation: event.operation.rawValue,
                fields: try encoder.encode(event.changedFields), names: event.changedFieldsNames)
        }
    }
    func openGate() throws -> Bool {
        let result = try owner.inspectContinuousProducer()
        return result.settlement.phase == .committed && !result.settlement.hasError && !result.settlement.unexpectedCommitObserved && result.barrier == nil
    }
    func closedGate() throws -> Bool {
        let result = try owner.inspectContinuousProducer()
        return result.settlement.phase == .committed && !result.settlement.hasError && !result.settlement.unexpectedCommitObserved && result.barrier != nil
    }
    func offlineEdit(update: String, delete: String, insert: String, value: Int) throws -> [ConnectedOriginal] {
        let before = Set(try originals().map(\.id))
        let all = Array(owner.objects(ConnectedRecoverySharedRow.self))
        let changed = try #require(all.first { $0.label == update }), removed = try #require(all.first { $0.label == delete })
        let changedID = try #require(changed.globalId), removedID = try #require(removed.globalId)
        let inserted = ConnectedRecoverySharedRow(label: insert, value: value)
        try owner.withTransaction {
            changed.value = value
            guard owner.delete(removed) else { throw ConnectedRecoveryFailure.unexpectedOriginal }
            try owner.add(inserted)
            try owner.add(ConnectedRecoveryLocalRow(value: registration.replica + "-local"))
        }
        let insertedID = try #require(inserted.globalId)
        let own = try originals().filter { !before.contains($0.id) && $0.table == "ConnectedRecoverySharedRow" }
        try #require(own.count == 3 && Set(own.map(\.id)).count == 3)
        try #require(own.filter { $0.operation == "UPDATE" && $0.target == changedID }.count == 1)
        try #require(own.filter { $0.operation == "DELETE" && $0.target == removedID }.count == 1)
        try #require(own.filter { $0.operation == "INSERT" && $0.target == insertedID }.count == 1)
        for event in own {
            let fields = try JSONDecoder().decode([String: AnyProperty].self, from: event.fields)
            if event.operation == "UPDATE" || event.operation == "INSERT" {
                let actual = try #require(fields["value"])
                switch actual {
                case .int(let number): try #require(number == value)
                case .int64(let number): try #require(number == Int64(value))
                default: throw ConnectedRecoveryFailure.unexpectedOriginal
                }
                try #require(event.names?.contains("value") == true)
            }
            if event.operation == "INSERT" {
                let actual = try #require(fields["label"])
                guard case .string(let label) = actual, label == insert else { throw ConnectedRecoveryFailure.unexpectedOriginal }
            }
        }
        return own
    }
    func preserves(_ originals: [ConnectedOriginal]) throws -> Bool {
        let after = try self.originals()
        return originals.allSatisfy { expected in after.filter { $0.id == expected.id } == [expected] }
    }
    func localValue() -> [String] { Array(owner.objects(ConnectedRecoveryLocalRow.self)).map(\.value) }
    func postRecoveryWrite() throws {
        try owner.withTransaction { try owner.add(ConnectedRecoverySharedRow(label: "post", value: 99)) }
    }
}

private func connectedFailureFact(_ error: any Error) -> ConnectedFailureObservation.ErrorFact {
    if let value = error as? ConnectedRecoveryFailure {
        switch value {
        case .environment: return .init(.environment)
        case .deadline: return .init(.deadline)
        case .metadata: return .init(.metadata)
        case .receipt: return .init(.receipt)
        case .unexpectedOriginal: return .init(.unexpectedOriginal)
        }
    }
    return .init(error)
}

@MainActor
private func connectedObserved(_ name: ConnectedFailureObservation.Case,
                               _ body: (ConnectedFailureObservation) async throws -> Void) async throws {
    let observation = ConnectedFailureObservation(name)
    defer { observation.emit() }
    do { try await body(observation); observation.completed() }
    catch { observation.failed(connectedFailureFact(error)); throw error }
}

@Suite("Public connected automatic recovery", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LATTICE_CONNECTED_RECOVERY_GATE"] == "1"))
@MainActor
struct PublicConnectedAutomaticRecoveryTests {
    @Test func stockTLSAcceptsMatchingHostedCertificate() async throws {
        try await connectedObserved(.stockTLSAcceptsMatchingHostedCertificate) { try await stockTLS(wrongHost: false, observation: $0) }
    }
    @Test func stockTLSRejectsReachableWrongHostCertificate() async throws {
        try await connectedObserved(.stockTLSRejectsReachableWrongHostCertificate) { try await stockTLS(wrongHost: true, observation: $0) }
    }
    private func stockTLS(wrongHost: Bool, observation: ConnectedFailureObservation) async throws {
        let env = try ConnectedTLSEnvironment(observation: observation)
        let app = try await connectedApplication(wrongHost ? env.wrongCertificate : env.certificate, wrongHost ? env.wrongKey : env.key, observation: observation)
        app.webSocket("tls") { _, _ in }
        let identityFailure = NIOLockedValueBox(false)
        let client = ConnectedStockClient(onIdentityVerificationFailure: {
            identityFailure.withLockedValue { $0 = true }
        }, onFailureObservation: { observation.callback($0) })
        observation.phase(.tlsDriver)
        var driver = lattice.platform_tls_test_driver(try #require(client.createCxxClient()))
        func captureTLS() {
            observation.tlsFacts(opens: Int(driver.opens()), errors: Int(driver.errors()), systemTLS: driver.system_tls(),
                identityFailure: identityFailure.withLockedValue { $0 }, listenerPublished: app.http.server.shared.localAddress?.port != nil)
        }
        do {
            observation.phase(.serverStartup)
            try await app.startup()
            observation.phase(.serverAddress)
            let port = try #require(app.http.server.shared.localAddress?.port)
            observation.phase(.tlsConnect)
            driver.connect(std.string("wss://127.0.0.1:\(port)/tls"))
            observation.phase(.tlsTerminal)
            try await connectedWait("stock TLS terminal result", until: ContinuousClock.now.advanced(by: .seconds(10))) { driver.opens() > 0 || driver.errors() > 0 }
            // A timeout, failed startup or absent result fails this case. The
            // wrapper proves the valid same-CA chain differs by hostname SAN.
            try #require(app.http.server.shared.localAddress?.port == port)
            captureTLS()
            if wrongHost {
                observation.phase(.tlsWrongHostOracle)
                try #require(driver.errors() > 0); try #require(driver.opens() == 0); try #require(!driver.system_tls())
                try #require(identityFailure.withLockedValue { $0 })
            } else {
                observation.phase(.tlsMatchingOracle)
                try #require(driver.errors() == 0); try #require(driver.opens() == 1); try #require(driver.system_tls())
                try #require(!identityFailure.withLockedValue { $0 })
            }
            let opens = Int(driver.opens()), errors = Int(driver.errors()), systemTLS = driver.system_tls()
            observation.phase(.tlsClose)
            driver.close(); try #require(!driver.system_tls())
            observation.phase(.applicationShutdown)
            try await connectedShutdown(app)
            observation.phase(.successReceipt)
            try connectedReceipt(env, name: wrongHost ? "stockTLSRejectsReachableWrongHostCertificate" : "stockTLSAcceptsMatchingHostedCertificate",
                facts: ["stockOpens": opens, "stockErrors": errors, "stockTLS": systemTLS, "serverListening": true,
                        "identityFailureObserved": identityFailure.withLockedValue { $0 }])
        } catch {
            observation.failed(connectedFailureFact(error)); captureTLS()
            driver.close()
            observation.cleanup(.shutdownApplication)
            do { try await connectedShutdown(app); observation.cleanup(.completed) }
            catch { observation.cleanupFailed(connectedFailureFact(error)) }
            throw error
        }
    }

    @Test func twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels() async throws {
        try await connectedObserved(.twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels) { try await recover(observation: $0) }
    }
    private func recover(observation: ConnectedFailureObservation) async throws {
        let env = try ConnectedTLSEnvironment(observation: observation), deadline = ContinuousClock.now.advanced(by: .seconds(120))
        let directory = env.root.appendingPathComponent("private/connected-" + UUID().uuidString)
        observation.phase(.directoryCreate)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storage = directory.appendingPathComponent("source")
        observation.phase(.sourceDirectoryCreate)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func seedSource() throws -> ([ConnectedRow], Set<String>) {
            let seed = try Lattice(for: [ConnectedRecoverySharedRow.self, ConnectedRecoveryLocalRow.self], configuration: .init(fileURL: storage.appendingPathComponent("source.sqlite")))
            defer { seed.close() }
            try seed.withTransaction {
                for number in 1...6 { try seed.add(ConnectedRecoverySharedRow(label: "r\(number)", value: number)) }
            }
            let initial = try Array(seed.objects(ConnectedRecoverySharedRow.self)).map {
                let id = try #require($0.globalId); return ConnectedRow(id: id, label: $0.label, value: $0.value)
            }.sorted { $0.label < $1.label }
            let seededOriginals = Set(Array(seed.eventsAfter(globalId: nil)).compactMap { $0.globalId?.uuidString.lowercased() })
            try #require(initial.count == 6 && seededOriginals.count == 6)
            return (initial, seededOriginals)
        }
        observation.phase(.sourceSeed)
        let (initial, seededOriginals) = try seedSource()
        observation.phase(.registrations)
        let registrations = ConnectedRegistrations(), app = try await connectedApplication(env.certificate, env.key, observation: observation)
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: {},
            parkRecoveryReadySend: { registrations.gate.park($0, $1) },
            didRecoveryReadyDecision: { registrations.gate.decision($0, $1) },
            didRecoveryReadyControl: { registrations.gate.observe($0) })
        RelayIngressTesting.install(hooks, for: storage)
        var mounts: [SyncRelayHandle] = [], bootstrap: [ConnectedBootstrapPeer] = [], receivers: [ConnectedReceiver] = []
        var cleanupResult: Result<Void, any Error>?
        func cleanup() async throws {
            if let cleanupResult { return try cleanupResult.get() }
            var firstError: (any Error)?
            func failed(_ error: any Error) {
                if firstError == nil { firstError = error }
                observation.cleanupFailed(connectedFailureFact(error))
            }
            observation.cleanup(.releaseHeldSend)
            registrations.gate.release()
            observation.cleanup(.closeReceivers)
            for receiver in receivers { receiver.close() }
            observation.cleanup(.closeBootstrap)
            for peer in bootstrap { peer.close() }
            observation.cleanup(.retireAuthorization)
            for mount in mounts { await mount.retireRecoveryAuthorization() }
            observation.cleanup(.shutdownApplication)
            var ownedGroupJoined = false
            do { try await connectedShutdown(app); ownedGroupJoined = true }
            catch { failed(error) }
            observation.cleanup(.waitRetirement)
            do {
                try await connectedWait("all real authorization and held-result retirement", until: ContinuousClock.now.advanced(by: .seconds(10))) {
                    mounts.allSatisfy { $0.recoverySessionCount == 0 }
                        && bootstrap.allSatisfy { $0.cleanupRetired(ownedGroupJoined: ownedGroupJoined) }
                }
            } catch { failed(error) }
            observation.cleanup(.removeHooks)
            RelayIngressTesting.remove(hooks, for: storage)
            if let firstError { cleanupResult = .failure(firstError); throw firstError }
            cleanupResult = .success(())
            observation.cleanup(.completed)
            // The source checkpoint governor may retain an ordinary owner.
            // The wrapper removes this private UUID directory only after the
            // actual test process is reaped; never unlink live WAL/custody.
        }
        do {
            observation.phase(.relayConfigure)
            for index in 0..<2 {
                let namespace = index == 0 ? "a" : "b"
                mounts.append(try Lattice.configureSyncRelay(on: app.routes, path: [.constant(namespace)],
                    for: [ConnectedRecoverySharedRow.self, ConnectedRecoveryLocalRow.self], storageURL: storage,
                    writePolicy: .init(allowedOperations: ["ConnectedRecoverySharedRow": [.insert, .update, .delete]], unlistedTables: .deny),
                    recovery: registrations.policy(index), channelExtractor: { try registrations.channel($0, index: index) },
                    recoveryAuthorization: { try registrations.authorize($0, $1, index: index) }))
            }
            observation.phase(.serverStartup)
            try await app.startup()
            observation.phase(.serverAddress)
            let port = try #require(app.http.server.shared.localAddress?.port)
            let endpoints = ["wss://127.0.0.1:\(port)/a", "wss://127.0.0.1:\(port)/b"]
            let channels = endpoints.map { "wss:" + $0 }; try #require(channels.allSatisfy { $0.utf8.count <= 64 })
            registrations.endpoints.withLockedValue { $0 = endpoints }
            for index in 0..<2 {
                let declared = registrations.bootstrap.peer(index), peer = ConnectedBootstrapPeer(); bootstrap.append(peer)
                let query = "?recovery-v=1&recovery-replica=\(declared.replicaID)&recovery-receiver=\(declared.receiverIncarnation)&recovery-channel=\(declared.channelIncarnation)"
                var headers = HTTPHeaders(); headers.add(name: "Authorization", value: "Bearer " + registrations.bootstrap.token)
                // This real default-verifying socket sends no protocol frame.
                observation.phase(.bootstrapConnect)
                do {
                    try await WebSocket.connect(to: endpoints[index] + query, headers: headers, on: app.eventLoopGroup) { peer.attach($0) }.get()
                } catch {
                    peer.connectFailed()
                    throw error
                }
                observation.phase(.bootstrapCatchup)
                try await connectedWait("real enrolled source metadata and authorized seeded catch-up", until: deadline) {
                    !peer.invalid && peer.ids == seededOriginals && registrations.contexts.withLockedValue { $0[index] != nil }
                }
            }
            observation.phase(.bootstrapContext)
            let captured = registrations.contexts.withLockedValue { $0 }
            let contextA = try #require(captured[0]), contextB = try #require(captured[1])
            observation.phase(.bootstrapRetire)
            for peer in bootstrap { peer.close() }
            try await connectedWait("bootstrap native registration retirement", until: deadline) {
                bootstrap.allSatisfy(\.closed) && mounts.allSatisfy { $0.recoverySessionCount == 0 }
            }
            observation.phase(.receiverCreate)
            let a = try ConnectedReceiver(root: directory, registration: registrations.a, contexts: [contextA, contextB], endpoints: endpoints)
            let b = try ConnectedReceiver(root: directory, registration: registrations.b, contexts: [contextA, contextB], endpoints: endpoints)
            receivers = [a, b]
            try #require(a.file != b.file && registrations.a.producer != registrations.b.producer)
            observation.phase(.receiverOpen)
            try a.open(connected: true); try b.open(connected: true)
            observation.phase(.initialRecovery)
            try await connectedWait("both fresh public receivers installed through both actual channels", until: deadline) {
                try a.rows() == initial && b.rows() == initial && a.openGate() && b.openGate()
                    && registrations.gate.hasCanonicalReads(replica: registrations.a.replica, channels: channels)
                    && registrations.gate.hasCanonicalReads(replica: registrations.b.replica, channels: channels)
            }
            observation.phase(.receiverRetire)
            a.close(); b.close()
            try await connectedWait("all configured facades retired before offline edits", until: deadline) { mounts.allSatisfy { $0.recoverySessionCount == 0 } }
            observation.phase(.offlineEdit)
            try a.open(connected: false); try b.open(connected: false)
            let ownA = try a.offlineEdit(update: "r1", delete: "r2", insert: "a", value: 11)
            let ownB = try b.offlineEdit(update: "r3", delete: "r4", insert: "b", value: 33)
            let preimageA = try a.rows(), preimageB = try b.rows()
            let insertedA = try #require(preimageA.first { $0.label == "a" }), insertedB = try #require(preimageB.first { $0.label == "b" })
            let expected = (initial.filter { !["r2", "r4"].contains($0.label) }.map {
                ConnectedRow(id: $0.id, label: $0.label, value: $0.label == "r1" ? 11 : ($0.label == "r3" ? 33 : $0.value))
            } + [insertedA, insertedB]).sorted { $0.label < $1.label }
            try #require(expected.count == 6)
            a.close(); b.close()
            observation.phase(.recoveryReopen)
            registrations.gate.arm(replica: registrations.a.replica, channel: channels[0])
            try a.open(connected: true); try b.open(connected: true)
            observation.phase(.heldCanonicalRead)
            try await connectedWait("selected actual positive canonical manifest retained", until: deadline) { registrations.gate.held }
            observation.phase(.heldBarrierOracle)
            let held = try #require(registrations.gate.selected)
            try #require(held.peer == registrations.a.peer(0) && held.channel == channels[0])
            try #require(held.operation == "read" && held.index == "0" && held.canonicalKind == "manifest")
            try #require(held.routeGeneration != nil && held.requestDigest != nil && held.attemptID != nil && held.sequence != nil)
            try #require(try a.closedGate()); try #require(try a.rows() == preimageA)
            try #require(try a.preserves(ownA)); try #require(a.localValue() == [registrations.a.replica + "-local"])
            // Only A is held. B is allowed to progress independently.
            registrations.gate.release()
            try await connectedWait("actual retained read publication", until: deadline) { registrations.gate.allowed != nil }
            try #require(registrations.gate.allowed == true)
            observation.phase(.combinedRecovery)
            try await connectedWait("whole cohorts converge with original identities and local-only values", until: deadline) {
                try a.rows() == expected && b.rows() == expected && a.openGate() && b.openGate()
                    && a.preserves(ownA) && b.preserves(ownB)
                    && a.localValue() == [registrations.a.replica + "-local"] && b.localValue() == [registrations.b.replica + "-local"]
            }
            try #require(!registrations.gate.overflow)
            let routes = registrations.gate.canonicalRoutes(replicas: [registrations.a.replica, registrations.b.replica])
            try #require(routes.count == 4)
            observation.phase(.postRecoveryWrite)
            try a.postRecoveryWrite()
            try await connectedWait("new public write works after recovery and reaches the other receiver", until: deadline) {
                let ar = try a.rows(), br = try b.rows()
                return try ar.count == 7 && ar == br && ar.contains { $0.label == "post" && $0.value == 99 }
                    && ar.filter { $0.label != "post" } == expected
                    && a.openGate() && b.openGate() && a.preserves(ownA) && b.preserves(ownB)
                    && a.localValue() == [registrations.a.replica + "-local"] && b.localValue() == [registrations.b.replica + "-local"]
            }
            try #require(!registrations.gate.overflow)
            observation.phase(.cleanup)
            try await cleanup()
            observation.phase(.successReceipt)
            try connectedReceipt(env, name: "twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels", facts: [
                "receiverCount": 2, "channelsPerReceiver": 2, "initialRowsPerReceiver": 6, "finalSharedRowsPerReceiver": 6,
                "preservedSharedOriginals": ownA.count + ownB.count, "heldCanonicalReads": 1, "heldBarrierObserved": true,
                "canonicalRoutesObserved": routes.count, "postRecoveryWriteObserved": true])
        } catch {
            let original = error
            observation.failed(connectedFailureFact(original))
            observation.topology(mounts: mounts.count, bootstrapPeers: bootstrap.count, receivers: receivers.count)
            do { try await cleanup() } catch {
                observation.cleanupFailed(connectedFailureFact(error))
                Issue.record("connected fixture cleanup failed")
            }
            RelayIngressTesting.remove(hooks, for: storage)
            throw original
        }
    }
}

// B is a distinct opt-in experiment. Everything above, including A/TLS bodies,
// their receipt allowlist and their budgets, remains byte-exact.
private final class QuietACKOneShot<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, QuietACKFailure>?
        var continuation: CheckedContinuation<Value, any Error>?
    }
    private let state = NIOLockedValueBox(State())
    func resolve(_ result: Result<Value, QuietACKFailure>) {
        let continuation = state.withLockedValue { state -> CheckedContinuation<Value, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result; let continuation = state.continuation; state.continuation = nil; return continuation
        }
        if let continuation { continuation.resume(with: result.mapError { $0 as any Error }) }
    }
    private func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLockedValue { state -> Result<Value, QuietACKFailure>? in
                    if let result = state.result { return result }
                    guard state.continuation == nil else { return .failure(.metadata) }
                    state.continuation = continuation; return nil
                }
                if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
            }
        } onCancel: { self.resolve(.failure(.deadline)) }
    }
    func wait(until deadline: ContinuousClock.Instant) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await self.value() }
            group.addTask { try await ContinuousClock().sleep(until: deadline); throw QuietACKFailure.deadline }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw QuietACKFailure.deadline }
            return first
        }
    }
}

private final class QuietACKProbe: Sendable {
    private struct State {
        var connections: [UUID: RelayRecoveryConnectionObservation] = [:]
        var canonicalRoutes: Set<String> = []
        var setup = 0, authorized = 0, closed = 0, syncErrors = 0, disconnected = 0
        var baseline: [Int] = [], events = 0, overflow = false, failure = false
        var armed = false, selectedConnection: UUID?, selectedPeer: SyncRecoveryPeerIdentity?
        var selectedChannel = "", target: UUID?, selected: RelayAcknowledgedEntryObservation?
        var drops = 0
    }
    private let state = NIOLockedValueBox(State())
    let dropped = QuietACKOneShot<RelayAcknowledgedEntryObservation>()
    private func update(_ body: (inout State) -> Void) {
        state.withLockedValue { state in
            if state.armed {
                guard state.events < 256 else { state.overflow = true; return }
                state.events += 1
            }
            body(&state)
        }
    }
    func setup() { update { if $0.setup < 256 { $0.setup += 1 } else { $0.overflow = true } } }
    func authorized() { update { if $0.authorized < 256 { $0.authorized += 1 } else { $0.overflow = true } } }
    func closed() { update { if $0.closed < 256 { $0.closed += 1 } else { $0.overflow = true } } }
    func syncError() { update { if $0.syncErrors < 256 { $0.syncErrors += 1 } else { $0.overflow = true } } }
    func syncState(_ connected: Bool) { if !connected { update { if $0.disconnected < 256 { $0.disconnected += 1 } else { $0.overflow = true } } } }
    func observe(_ handle: RelayRecoveryConnectionObservation) {
        update { state in
            if let old = state.connections[handle.connectionID] {
                if old.peer != handle.peer || old.channel != handle.channel { state.failure = true }
            } else if state.connections.count < 4 { state.connections[handle.connectionID] = handle }
            else { state.overflow = true }
        }
    }
    func ready(_ observation: RelayReadyControlObservation) {
        update { state in
            guard observation.operation == "read", observation.canonicalKind == "manifest" else { return }
            guard observation.channel.utf8.count <= 64, observation.peer.replicaID.utf8.count <= 256,
                  let handle = state.connections[observation.connectionID], handle.peer == observation.peer,
                  handle.channel == observation.channel else { state.failure = true; return }
            let key = observation.peer.replicaID + "\n" + observation.channel
            if state.canonicalRoutes.contains(key) { return }
            guard state.canonicalRoutes.count < 4 else { state.overflow = true; return }
            state.canonicalRoutes.insert(key)
        }
    }
    func hasCanonicalReads(replica: String, channels: [String]) -> Bool {
        state.withLockedValue { state in channels.allSatisfy { state.canonicalRoutes.contains(replica + "\n" + $0) } }
    }
    func resetRetiredConnections() throws {
        try state.withLockedValue { state in
            guard !state.armed else { throw QuietACKFailure.metadata }; state.connections.removeAll(); state.canonicalRoutes.removeAll()
        }
    }
    func handles() throws -> [RelayRecoveryConnectionObservation] {
        try state.withLockedValue { state in
            guard state.connections.count == 4, !state.overflow, !state.failure else { throw QuietACKFailure.connections }
            return Array(state.connections.values)
        }
    }
    func arm(connection: RelayRecoveryConnectionObservation, target: UUID) throws {
        try state.withLockedValue { state in
            guard !state.armed, !state.overflow, !state.failure, state.connections.count == 4 else { throw QuietACKFailure.connections }
            state.baseline = [state.setup, state.authorized, state.closed, state.syncErrors, state.disconnected]
            state.selectedConnection = connection.connectionID; state.selectedPeer = connection.peer
            state.selectedChannel = connection.channel; state.target = target; state.armed = true
        }
    }
    func shouldDrop(_ observation: RelayRecoveryACKObservation) -> Bool {
        var signal: Result<RelayAcknowledgedEntryObservation, QuietACKFailure>?
        let drop = state.withLockedValue { state -> Bool in
            guard state.armed, !state.failure, !state.overflow else { return false }
            guard state.events < 256 else { state.overflow = true; signal = .failure(.metadata); return false }
            state.events += 1
            guard observation.connectionID == state.selectedConnection, observation.peer == state.selectedPeer,
                  observation.channel == state.selectedChannel else { return false }
            guard observation.metadataFailure == nil, let entry = observation.entry else {
                state.failure = true; signal = .failure(.metadata); return false
            }
            guard entry.targetID == state.target else { return false }
            guard entry.table == "ConnectedRecoverySharedRow", entry.operation == "UPDATE", entry.fieldName == "value",
                  (entry.integerKind == 0 || entry.integerKind == 1), entry.integerValue == 55, entry.originalIdentityVersion == 1,
                  entry.originalIdentityDigest.utf8.count == 64,
                  entry.originalIdentityDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                state.failure = true; signal = .failure(.metadata); return false
            }
            if let selected = state.selected {
                if selected != entry { state.failure = true }
                return false // A retransmission keeps its real ACK; never drop twice.
            }
            state.selected = entry; state.drops = 1; signal = .success(entry); return true
        }
        if let signal { dropped.resolve(signal) } // No continuation under leaf lock.
        return drop
    }
    func checkQuiet() throws {
        try state.withLockedValue { state in
            guard state.armed, state.drops == 1, state.selected != nil, !state.overflow, !state.failure,
                  state.baseline == [state.setup, state.authorized, state.closed, state.syncErrors, state.disconnected],
                  state.connections.count == 4 else { throw QuietACKFailure.connections }
        }
    }
    func dropCount() -> Int { state.withLockedValue { $0.drops } }
    func disarm() {
        state.withLockedValue { $0.armed = false; $0.connections.removeAll() }
        dropped.resolve(.failure(.deadline))
    }
}

@MainActor
private func quietACKSample(_ handles: [RelayRecoveryConnectionObservation], until deadline: ContinuousClock.Instant) async throws {
    guard handles.count == 4, Set(handles.map(\.connectionID)).count == 4 else { throw QuietACKFailure.connections }
    for handle in handles {
        let result = QuietACKOneShot<RelayRecoveryConnectionSample>()
        handle.sample { result.resolve(.success($0)) }
        let sample = try await result.wait(until: min(deadline, ContinuousClock.now.advanced(by: .seconds(2))))
        try quietACKRequire(sample.available && sample.socketOpen && sample.lifetimeLive, .connections)
    }
}

@MainActor
private final class QuietACKMutation {
    private var action: (@MainActor () throws -> Void)?
    init(_ action: @escaping @MainActor () throws -> Void) { self.action = action }
    func perform() throws {
        guard let action else { throw QuietACKFailure.metadata }
        self.action = nil
        // Release the captured model/owner at this call's return; no retained
        // Results or managed-object reads can be introduced during quiet.
        try action()
    }
}

@MainActor
private extension ConnectedReceiver {
    func quietObserve(_ probe: QuietACKProbe) {
        for owner in owners {
            owner.onSyncError { _ in probe.syncError() }
            owner.onSyncStateChange { probe.syncState($0) }
        }
    }
    func quietUpdate() throws -> (UUID, QuietACKMutation) {
        let row = try #require(Array(owner.objects(ConnectedRecoverySharedRow.self)).first { $0.label == "r5" })
        let id = try #require(row.globalId)
        try quietACKRequire(row.value != 55, .metadata)
        return (id, QuietACKMutation { try self.owner.withTransaction { row.value = 55 } })
    }
}

private typealias Q = QuietACKReadOnlySnapshot
private func quietKey(_ value: String) -> Data { Data(value.utf8) }
private func quietUUID(_ id: UUID) -> Data { quietKey(id.uuidString.lowercased()) }
private func quietModel(_ snapshot: QuietACKSnapshot) throws -> [ConnectedRow] {
    let values = try snapshot.rows(Q.shared).map { row -> ConnectedRow in
        guard let id = UUID(uuidString: try row.text("globalId")), let value = Int(exactly: try row.integer("value")) else { throw QuietACKFailure.sqliteType }
        return ConnectedRow(id: id, label: try row.text("label"), value: value)
    }
    guard values.count == 6, Set(values.map(\.id)).count == 6, Set(values.map(\.label)).count == 6 else { throw QuietACKFailure.receiverImage }
    return values.sorted { $0.label < $1.label }
}
private func quietFind(_ rows: [QuietACKRow], key: String, value: QuietACKCell, phase: QuietACKFailure) throws -> QuietACKRow {
    let found = rows.filter { $0.cells[key] == value }
    guard found.count == 1 else { throw phase }; return found[0]
}
private func quietAudit(_ snapshot: QuietACKSnapshot, id: UUID) throws -> QuietACKRow {
    let matches = try snapshot.rows("AuditLog").filter { UUID(uuidString: try $0.text("globalId")) == id }
    guard matches.count == 1 else { throw QuietACKFailure.originals }; return matches[0]
}
private func quietPreserves(_ before: QuietACKSnapshot, _ after: QuietACKSnapshot, originals: [ConnectedOriginal]) throws {
    for original in originals {
        try quietACKRequire(try quietAudit(before, id: original.id) == quietAudit(after, id: original.id), .originals)
    }
    // Local-only originals must also retain their exact tuple, independently of
    // mutable isSynchronized bookkeeping that is intentionally not projected.
    for row in try before.rows("AuditLog") where try row.text("tableName") == Q.local {
        let id = try row.text("globalId")
        let found = try quietFind(after.rows("AuditLog"), key: "globalId", value: .text(id), phase: .originals)
        try quietACKRequire(row == found, .originals)
    }
}
private func quietCanonicalBaseline(_ source: QuietACKSnapshot, originals: [ConnectedOriginal]) throws {
    let profile = try source.one(Q.coverageProfile)
    try quietACKRequire(try profile.integer("version") == 3 && profile.integer("codec") == 1, .sourceCoverage)
    try quietACKRequire(try profile.integer("cells") == profile.integer("mutation"), .sourceCoverage)
    let members = try source.rows("_lattice_canonical_receipt_member").map { try $0.blob("namespace_id") }
    try quietACKRequire(Set(members) == Set([quietKey("a"), quietKey("b")]), .sourceCoverage)
    for original in originals {
        _ = try quietFind(source.rows(Q.receipt), key: "original_id", value: .blob(quietUUID(original.id)), phase: .sourceCoverage)
        _ = try quietFind(source.rows(Q.origin), key: "original_id", value: .blob(quietUUID(original.id)), phase: .sourceCoverage)
        let cells = try source.rows(Q.coverage).filter { $0.cells["original_id"] == .blob(quietUUID(original.id)) }
        try quietACKRequire(cells.count == 2 && Set(try cells.map { try $0.blob("namespace_id") }) == Set([quietKey("a"), quietKey("b")]), .sourceCoverage)
    }
}
private func quietReceiverOpen(_ snapshot: QuietACKSnapshot, channels: [String], contexts: [SyncRecoveryAuthorizationContext], head: Int64) throws {
    let continuity = try snapshot.one(Q.continuity), store = try snapshot.one("_lattice_install_store")
    try quietACKRequire(try continuity.integer("id") == 1 && continuity.integer("phase") == 0, .receiverSettlement)
    try quietACKRequire(try store.integer("id") == 1 && store.integer("version") == 2 && store.integer("channels") == 2, .receiverSettlement)
    try quietACKRequire(try snapshot.rows(Q.scopes).count == 2 && snapshot.rows(Q.installs).count == 2, .receiverSettlement)
    for (index, channel) in channels.enumerated() {
        let scope = try quietFind(snapshot.rows(Q.scopes), key: "channel", value: .blob(quietKey(channel)), phase: .receiverSettlement)
        let installed = try quietFind(snapshot.rows(Q.installs), key: "channel", value: .blob(quietKey(channel)), phase: .receiverSettlement)
        let source = contexts[index].source
        let binding = ["authority": source.authority, "source": source.sourceID.uuidString.lowercased(), "epoch": source.epoch.uuidString.lowercased(), "scope": source.scopeDigest, "schema_digest": source.schemaDigest]
        for (key, value) in binding {
            try quietACKRequire(try scope.blob(key) == quietKey(value) && installed.blob(key) == quietKey(value), .receiverSettlement)
        }
        try quietACKRequire(try scope.blob("receipt_namespace") == quietKey(source.receiptNamespace), .receiverSettlement)
        try quietACKRequire(try scope.integer("mode") == 0 && scope.integer("installed_head") == head, .receiverSettlement)
        try quietACKRequire(try installed.integer("frontier_kind") == 2 && installed.integer("frontier") == head && installed.cell("active") == .null, .receiverSettlement)
        let sequence = try scope.integer("installed_sequence")
        try quietACKRequire(try sequence > 0 && sequence == continuity.integer("attempt") && sequence == installed.integer("last_sequence"), .receiverSettlement)
        try quietACKRequire(try scope.integer("installed_revision") == installed.integer("revision") && installed.integer("revision") > 0, .receiverSettlement)
        try quietACKRequire(try !scope.blob("installed_manifest").isEmpty && !installed.blob("last_install").isEmpty, .receiverSettlement)
        try quietACKValidateInstalledIdentity(channel: installed, scope: scope, store: store)
    }
}
private func quietSettled(_ snapshot: QuietACKSnapshot, channels: [String], id: UUID, target: UUID, position: Int64? = nil) throws {
    let audit = try quietAudit(snapshot, id: id)
    let entries = try snapshot.rows(Q.entries).filter { $0.cells["original"] == .blob(quietUUID(id)) }
    try quietACKRequire(entries.count == 2, .receiverSettlement)
    for channel in channels {
        let entry = try quietFind(entries, key: "channel", value: .blob(quietKey(channel)), phase: .receiverSettlement)
        let scope = try quietFind(snapshot.rows(Q.scopes), key: "channel", value: .blob(quietKey(channel)), phase: .receiverSettlement)
        try quietACKRequire(try entry.integer("stage") == 2 && entry.integer("origin") == 0 && entry.integer("first_export") > 0, .receiverSettlement)
        try quietACKRequire(try entry.integer("settled_sequence") > 0 && entry.integer("settled_sequence") <= scope.integer("installed_sequence"), .receiverSettlement)
        try quietACKRequire(try entry.integer("audit_id") == audit.integer("id") && entry.blob("actual_original") == quietKey(audit.text("globalId")), .originals)
        try quietACKRequire(try entry.blob("target") == quietUUID(target) && entry.blob("actual_target") == quietKey(audit.text("globalRowId")) && entry.blob("table_name") == quietKey(Q.shared), .originals)
        if let position { try quietACKRequire(try entry.integer("ack_position") == position && entry.integer("ack_outcome") == 0, .receiverSettlement) }
    }
}
private func quietDelta(_ before: QuietACKRow, _ after: QuietACKRow, _ key: String, _ expected: Int64, phase: QuietACKFailure) throws {
    let old = try before.integer(key), new = try after.integer(key)
    let difference = new.subtractingReportingOverflow(old)
    try quietACKRequire(!difference.overflow && difference.partialValue == expected, phase)
}
private func quietPreserveRows(_ before: [QuietACKRow], _ after: [QuietACKRow], key: String) throws {
    for row in before {
        let found = try quietFind(after, key: key, value: row.cell(key), phase: .originals)
        try quietACKRequire(found == row, .originals)
    }
}
private func quietSourceFinal(_ before: QuietACKSnapshot, _ after: QuietACKSnapshot, entry: RelayAcknowledgedEntryObservation,
                              producer: SyncRecoveryProducerRegistration) throws -> Int64 {
    try quietACKRequire(before.schemas == after.schemas, .sqliteSchema)
    let old = try before.one(Q.canonical), current = try after.one(Q.canonical)
    let oldProfile = try before.one(Q.coverageProfile), profile = try after.one(Q.coverageProfile)
    let added = try old.integer("head").addingReportingOverflow(2)
    guard !added.overflow else { throw QuietACKFailure.sourceCounters }; let head = added.partialValue
    try quietDelta(old, current, "head", 2, phase: .sourceCounters)
    try quietDelta(old, current, "receipts", 1, phase: .sourceCounters)
    try quietDelta(oldProfile, profile, "origins", 1, phase: .sourceCoverage)
    try quietDelta(oldProfile, profile, "cells", 2, phase: .sourceCoverage)
    try quietDelta(oldProfile, profile, "mutation", 2, phase: .sourceCoverage)
    let selected = quietUUID(entry.originalID), target = quietUUID(entry.targetID)
    let receipts = try after.rows(Q.receipt), origins = try after.rows(Q.origin), cells = try after.rows(Q.coverage)
    let receipt = try quietFind(receipts, key: "original_id", value: .blob(selected), phase: .sourceCounters)
    let origin = try quietFind(origins, key: "original_id", value: .blob(selected), phase: .sourceCoverage)
    try quietACKRequire(try receipt.integer("position") == head && receipt.integer("outcome") == 1
        && receipt.blob("relation") == quietKey(Q.shared) && receipt.blob("identity") == target, .sourceCounters)
    try quietACKRequire(try [quietKey("a"), quietKey("b")].contains(receipt.blob("namespace_id")), .sourceCoverage)
    try quietACKRequire(try origin.blob("producer") == quietKey(producer.registrationID)
        && origin.blob("incarnation") == quietUUID(producer.incarnation)
        && origin.blob("digest") == quietKey(entry.originalIdentityDigest) && origin.blob("operation") == quietKey("UPDATE"), .sourceCoverage)
    let selectedCells = cells.filter { $0.cells["original_id"] == .blob(selected) }
    try quietACKRequire(selectedCells.count == 2 && Set(try selectedCells.map { try $0.blob("namespace_id") }) == Set([quietKey("a"), quietKey("b")]), .sourceCoverage)
    let mutation = try oldProfile.integer("mutation"), next = mutation.addingReportingOverflow(2)
    guard !next.overflow else { throw QuietACKFailure.sourceCoverage }
    try quietACKRequire(Set(try selectedCells.map { try $0.integer("revision") }) == Set([mutation + 1, next.partialValue]), .sourceCoverage)
    for (table, extra) in [(Q.receipt, 1), (Q.origin, 1), (Q.coverage, 2)] {
        let prior = try before.rows(table), actual = try after.rows(table)
        try quietACKRequire(actual.count == prior.count + extra, .sourceCoverage)
        if table == Q.coverage {
            for row in prior { try quietACKRequire(actual.filter { $0 == row }.count == 1, .sourceCoverage) }
        } else { try quietPreserveRows(prior, actual, key: "original_id") }
        try quietACKRequire(!prior.contains { $0.cells["original_id"] == .blob(selected) }, .originals)
    }
    try quietDelta(old, current, "receipt_bytes", receipt.integer("charge"), phase: .sourceCounters)
    try quietDelta(oldProfile, profile, "origin_bytes", origin.integer("charge"), phase: .sourceCoverage)
    let cellCharges = try selectedCells.map { try $0.integer("charge") }
    let charge = cellCharges[0].addingReportingOverflow(cellCharges[1])
    guard !charge.overflow else { throw QuietACKFailure.sourceCoverage }
    try quietDelta(oldProfile, profile, "cell_bytes", charge.partialValue, phase: .sourceCoverage)
    let oldTouches = try before.rows(Q.touch), newTouches = try after.rows(Q.touch)
    let isTarget: (QuietACKRow) -> Bool = { $0.cells["relation"] == .blob(quietKey(Q.shared)) && $0.cells["identity"] == .blob(target) }
    let was = oldTouches.filter(isTarget), now = newTouches.filter(isTarget)
    try quietACKRequire(was.count <= 1 && now.count == 1, .sourceCounters)
    try quietACKRequire(try now[0].integer("position") == head - 1, .sourceCounters)
    if let previous = was.first { try quietACKRequire(try previous.integer("charge") == now[0].integer("charge"), .sourceCounters) }
    let fresh: Int64 = was.isEmpty ? 1 : 0
    try quietACKRequire(newTouches.count == oldTouches.count + Int(fresh), .sourceCounters)
    for row in oldTouches where !isTarget(row) { try quietACKRequire(newTouches.filter { $0 == row }.count == 1, .sourceCounters) }
    try quietDelta(old, current, "markers", fresh, phase: .sourceCounters)
    try quietDelta(old, current, "marker_bytes", fresh == 1 ? now[0].integer("charge") : 0, phase: .sourceCounters)
    let immutable = old.cells.keys.filter { !["head", "receipts", "receipt_bytes", "markers", "marker_bytes"].contains($0) }
    try quietACKRequire(try old.selecting(immutable) == current.selecting(immutable), .sourceCounters)
    let immutableProfile = oldProfile.cells.keys.filter { !["mutation", "origins", "origin_bytes", "cells", "cell_bytes"].contains($0) }
    try quietACKRequire(try oldProfile.selecting(immutableProfile) == profile.selecting(immutableProfile), .sourceCoverage)
    for table in ["_lattice_canonical_namespace", "_lattice_canonical_receipt_member"] {
        let prior = try before.rows(table), actual = try after.rows(table)
        try quietACKRequire(prior.count == actual.count && prior.allSatisfy { row in actual.filter { $0 == row }.count == 1 }, .sourceCoverage)
    }
    let oldAudit = try before.rows("AuditLog"), newAudit = try after.rows("AuditLog")
    try quietACKRequire(newAudit.count == oldAudit.count + 1, .originals)
    try quietPreserveRows(oldAudit, newAudit, key: "globalId")
    let selectedAudit = try quietAudit(after, id: entry.originalID)
    try quietACKRequire(try selectedAudit.text("operation") == "UPDATE" && selectedAudit.text("tableName") == Q.shared
        && UUID(uuidString: selectedAudit.text("globalRowId")) == entry.targetID, .originals)
    return head
}
private func quietReceiverFinal(_ before: QuietACKSnapshot, _ after: QuietACKSnapshot, originals: [ConnectedOriginal]) throws {
    try quietACKRequire(before.schemas == after.schemas, .sqliteSchema)
    let old = try before.one(Q.continuity), current = try after.one(Q.continuity)
    let immutable = old.cells.keys.filter { !["phase", "barrier", "attempt"].contains($0) }
    try quietACKRequire(try old.selecting(immutable) == current.selecting(immutable), .receiverSettlement)
    try quietPreserves(before, after, originals: originals)
    let beforeLocal = try before.rows(Q.local), afterLocal = try after.rows(Q.local)
    try quietACKRequire(beforeLocal.count == 1 && beforeLocal == afterLocal, .receiverImage)
}
private func quietOriginalValue(_ snapshot: QuietACKSnapshot, entry: RelayAcknowledgedEntryObservation) throws {
    let audit = try quietAudit(snapshot, id: entry.originalID)
    try quietACKRequire(try audit.text("tableName") == Q.shared && audit.text("operation") == "UPDATE"
        && UUID(uuidString: audit.text("globalRowId")) == entry.targetID, .originals)
    // The actual generated AuditLog stores flat values and NULL placeholders
    // for unchanged columns/names. Restricted export later types those values;
    // do not invent a persisted Int-vs-Int64 tag or erase the original tuple.
    guard let fields = try JSONSerialization.jsonObject(with: Data(audit.text("changedFields").utf8)) as? [String: Any],
          let names = try JSONSerialization.jsonObject(with: Data(audit.text("changedFieldsNames").utf8)) as? [Any]
    else { throw QuietACKFailure.originals }
    try quietACKRequire(Set(fields.keys) == Set(["label", "value"]) && fields["label"] is NSNull, .originals)
    try quietACKRequire(try quietACKJSONInteger(fields["value"]) == 55, .originals)
    try quietACKRequire(names.count == 2 && names.compactMap { $0 as? String } == ["value"]
        && names.filter { $0 is NSNull }.count == 1, .originals)
}

@MainActor
private func quietACKReceipt(_ environment: ConnectedTLSEnvironment, passed: Bool, phase: String, facts: [String: Any]) throws {
    let allowed: Set<String> = ["receiverCount", "channelsPerReceiver", "sharedRowsPerReceiver", "preservedSharedOriginals",
        "localOnlyRowsPreserved", "appWriteCount", "ackDropCount", "quietMilliseconds", "physicalConnections",
        "sameConnectionsLive", "noReconnectObserved", "noSyncErrorsObserved", "sourceHeadDelta", "sourceReceiptDelta",
        "sourceOriginDelta", "sourceCoverageDelta", "receiverSettledClaims", "installedChannels", "cohortsOpen", "rawSnapshotsBeforePublicInspection"]
    guard Set(facts.keys).isSubset(of: allowed), !passed || Set(facts.keys) == allowed else { throw QuietACKFailure.receipt }
    let path = environment.root.appendingPathComponent("receipts/quiet-ack-recovery-case.json")
    let record: [String: Any] = ["version": 1, "cases": [["name": "oneDroppedACKRecoversOnLiveConnectionWithoutAppActivity",
        "passed": passed, "phase": phase, "scalarFacts": facts]]]
    let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    guard bytes.count <= 16_384 else { throw QuietACKFailure.receipt }
    try bytes.write(to: path, options: .atomic)
}

@Suite("Public quiet ACK-loss recovery", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LATTICE_QUIET_ACK_RECOVERY_GATE"] == "1"))
@MainActor
struct PublicQuietACKLossRecoveryTests {
    @Test func oneDroppedACKRecoversOnLiveConnectionWithoutAppActivity() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        let env = try ConnectedTLSEnvironment()
        try quietACKRequire(ProcessInfo.processInfo.environment["LATTICE_QUIET_ACK_RECOVERY_GATE"] == "1", .environment)
        let directory = env.root.appendingPathComponent("private/connected-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storage = directory.appendingPathComponent("source"), sourceFile = storage.appendingPathComponent("source.sqlite")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let initial: [ConnectedRow], seededOriginals: Set<String>
        do {
            let seed = try Lattice(for: [ConnectedRecoverySharedRow.self, ConnectedRecoveryLocalRow.self], configuration: .init(fileURL: sourceFile))
            defer { seed.close() }
            try seed.withTransaction { for number in 1...6 { try seed.add(ConnectedRecoverySharedRow(label: "r\(number)", value: number)) } }
            initial = try Array(seed.objects(ConnectedRecoverySharedRow.self)).map {
                let id = try #require($0.globalId); return ConnectedRow(id: id, label: $0.label, value: $0.value)
            }.sorted { $0.label < $1.label }
            seededOriginals = Set(Array(seed.eventsAfter(globalId: nil)).compactMap { $0.globalId?.uuidString.lowercased() })
            try quietACKRequire(initial.count == 6 && seededOriginals.count == 6, .metadata)
        }
        let registrations = ConnectedRegistrations(), probe = QuietACKProbe()
        let app = try await connectedApplication(env.certificate, env.key)
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: { probe.setup() }, didBufferFrame: { _ in }, didFinishAsyncSetup: {},
            didCloseConnection: { probe.closed() }, didRecoveryReadyControl: { probe.ready($0) },
            shouldDropRecoveryACK: { probe.shouldDrop($0) }, didObserveRecoveryConnection: { probe.observe($0) })
        RelayIngressTesting.install(hooks, for: storage)
        var mounts: [SyncRelayHandle] = [], bootstrap: [ConnectedBootstrapPeer] = [], receivers: [ConnectedReceiver] = []
        var facts: [String: Any] = [:], phase = QuietACKFailure.metadata, cleanupAttempted = false
        func cleanup() async throws {
            cleanupAttempted = true; probe.disarm()
            for receiver in receivers { receiver.close() }
            for peer in bootstrap { peer.close() }
            for mount in mounts { await mount.retireRecoveryAuthorization() }
            try await app.asyncShutdown()
            try await connectedWait("quiet ACK actual authorization retirement", until: ContinuousClock.now.advanced(by: .seconds(10))) {
                mounts.allSatisfy { $0.recoverySessionCount == 0 } && bootstrap.allSatisfy(\.closed)
            }
            RelayIngressTesting.remove(hooks, for: storage)
            // No live-file deletion: the existing wrapper owns exact UUID
            // directory cleanup only after the actual test process is reaped.
        }
        do {
            for index in 0..<2 {
                let namespace = index == 0 ? "a" : "b"
                mounts.append(try Lattice.configureSyncRelay(on: app.routes, path: [.constant(namespace)],
                    for: [ConnectedRecoverySharedRow.self, ConnectedRecoveryLocalRow.self], storageURL: storage,
                    writePolicy: .init(allowedOperations: ["ConnectedRecoverySharedRow": [.insert, .update, .delete]], unlistedTables: .deny),
                    recovery: registrations.policy(index), channelExtractor: { try registrations.channel($0, index: index) },
                    recoveryAuthorization: { request, context in
                        let authorization = try registrations.authorize(request, context, index: index)
                        probe.authorized(); return authorization
                    }))
            }
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let endpoints = ["wss://127.0.0.1:\(port)/a", "wss://127.0.0.1:\(port)/b"], channels = endpoints.map { "wss:" + $0 }
            try quietACKRequire(channels.allSatisfy { $0.utf8.count <= 64 }, .metadata)
            registrations.endpoints.withLockedValue { $0 = endpoints }
            for index in 0..<2 {
                let declared = registrations.bootstrap.peer(index), peer = ConnectedBootstrapPeer(); bootstrap.append(peer)
                let query = "?recovery-v=1&recovery-replica=\(declared.replicaID)&recovery-receiver=\(declared.receiverIncarnation)&recovery-channel=\(declared.channelIncarnation)"
                var headers = HTTPHeaders(); headers.add(name: "Authorization", value: "Bearer " + registrations.bootstrap.token)
                try await WebSocket.connect(to: endpoints[index] + query, headers: headers, on: app.eventLoopGroup) { peer.attach($0) }.get()
                try await connectedWait("quiet ACK real bootstrap metadata", until: deadline) {
                    !peer.invalid && peer.ids == seededOriginals && registrations.contexts.withLockedValue { $0[index] != nil }
                }
            }
            let captured = registrations.contexts.withLockedValue { $0 }
            let contextA = try #require(captured[0]), contextB = try #require(captured[1]), contexts = [contextA, contextB]
            for peer in bootstrap { peer.close() }
            try await connectedWait("quiet ACK bootstrap retired", until: deadline) {
                bootstrap.allSatisfy(\.closed) && mounts.allSatisfy { $0.recoverySessionCount == 0 }
            }
            let a = try ConnectedReceiver(root: directory, registration: registrations.a, contexts: contexts, endpoints: endpoints)
            let b = try ConnectedReceiver(root: directory, registration: registrations.b, contexts: contexts, endpoints: endpoints)
            receivers = [a, b]
            try quietACKRequire(a.file != b.file && registrations.a.producer != registrations.b.producer, .metadata)
            try a.open(connected: true); try b.open(connected: true)
            try await connectedWait("quiet ACK initial two public cohorts", until: deadline) {
                try a.rows() == initial && b.rows() == initial && a.openGate() && b.openGate()
                    && probe.hasCanonicalReads(replica: registrations.a.replica, channels: channels)
                    && probe.hasCanonicalReads(replica: registrations.b.replica, channels: channels)
            }
            a.close(); b.close()
            try await connectedWait("quiet ACK before offline edits retirement", until: deadline) { mounts.allSatisfy { $0.recoverySessionCount == 0 } }
            try a.open(connected: false); try b.open(connected: false)
            let ownA = try a.offlineEdit(update: "r1", delete: "r2", insert: "a", value: 11)
            let ownB = try b.offlineEdit(update: "r3", delete: "r4", insert: "b", value: 33)
            let insertedA = try #require(a.rows().first { $0.label == "a" }), insertedB = try #require(b.rows().first { $0.label == "b" })
            let expected = (initial.filter { !["r2", "r4"].contains($0.label) }.map {
                ConnectedRow(id: $0.id, label: $0.label, value: $0.label == "r1" ? 11 : ($0.label == "r3" ? 33 : $0.value))
            } + [insertedA, insertedB]).sorted { $0.label < $1.label }
            a.close(); b.close(); try probe.resetRetiredConnections()
            try a.open(connected: true); try b.open(connected: true)
            a.quietObserve(probe); b.quietObserve(probe)
            try await connectedWait("quiet ACK settled six-original baseline", until: deadline) {
                try a.rows() == expected && b.rows() == expected && a.openGate() && b.openGate()
                    && a.preserves(ownA) && b.preserves(ownB)
                    && a.localValue() == [registrations.a.replica + "-local"] && b.localValue() == [registrations.b.replica + "-local"]
            }
            try quietACKRequire(probe.hasCanonicalReads(replica: registrations.a.replica, channels: channels)
                && probe.hasCanonicalReads(replica: registrations.b.replica, channels: channels), .connections)
            let handles = try probe.handles()
            for registration in [registrations.a, registrations.b] {
                for index in 0..<2 {
                    try quietACKRequire(handles.filter { $0.peer == registration.peer(index) && $0.channel == channels[index] }.count == 1, .connections)
                }
            }
            try await quietACKSample(handles, until: deadline)
            let selected = try #require(handles.first { $0.peer == registrations.a.peer(0) && $0.channel == channels[0] })
            let (target, update) = try a.quietUpdate()
            let finalExpected = expected.map { $0.id == target ? ConnectedRow(id: $0.id, label: $0.label, value: 55) : $0 }
            try quietACKRequire(expected.filter { $0.id == target }.count == 1, .metadata)
            phase = .sqliteOpen
            let sourceBefore = try Q.capture(file: sourceFile, root: directory, source: true, deadline: deadline)
            let aBefore = try Q.capture(file: a.file, root: directory, source: false, deadline: deadline)
            let bBefore = try Q.capture(file: b.file, root: directory, source: false, deadline: deadline)
            try quietACKRequire(try quietModel(sourceBefore) == expected && quietModel(aBefore) == expected && quietModel(bBefore) == expected, .receiverImage)
            try quietACKRequire(try sourceBefore.rows(Q.local).isEmpty, .sourceImage)
            try quietCanonicalBaseline(sourceBefore, originals: ownA + ownB)
            let head = try sourceBefore.one(Q.canonical).integer("head")
            try quietACKRequire(head >= 0 && head <= Int64.max - 2, .sourceCounters)
            try quietReceiverOpen(aBefore, channels: channels, contexts: contexts, head: head)
            try quietReceiverOpen(bBefore, channels: channels, contexts: contexts, head: head)
            for original in ownA { try quietSettled(aBefore, channels: channels, id: original.id, target: original.target) }
            for original in ownB { try quietSettled(bBefore, channels: channels, id: original.id, target: original.target) }
            facts["receiverCount"] = 2; facts["channelsPerReceiver"] = 2; facts["physicalConnections"] = 4
            try quietACKRequire(ContinuousClock.now.advanced(by: .seconds(53)) < deadline, .deadline)
            try probe.arm(connection: selected, target: target)
            phase = .drop
            try update.perform()
            facts["appWriteCount"] = 1
            // From this actual write return until all three final raw snapshots:
            // no public query/result access/inspection, sync/drain, write,
            // reopen, socket sample or extra network stimulus. Only this one
            // passive actual-drop continuation and one absolute clock sleep.
            let entry = try await probe.dropped.wait(until: deadline)
            facts["ackDropCount"] = probe.dropCount()
            let quietStart = ContinuousClock.now, quietEnd = quietStart.advanced(by: .seconds(45))
            try quietACKRequire(quietEnd.advanced(by: .seconds(8)) < deadline, .deadline)
            phase = .deadline
            try await ContinuousClock().sleep(until: quietEnd)
            let components = quietStart.duration(to: ContinuousClock.now).components
            try quietACKRequire(components.seconds >= 0 && components.seconds < 120 && components.attoseconds >= 0, .deadline)
            let elapsed = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
            try quietACKRequire(elapsed >= 45_000 && elapsed < 120_000, .deadline)
            facts["quietMilliseconds"] = Int(elapsed)
            try probe.checkQuiet()
            phase = .sqliteOpen
            let sourceAfter = try Q.capture(file: sourceFile, root: directory, source: true, deadline: deadline)
            let aAfter = try Q.capture(file: a.file, root: directory, source: false, deadline: deadline)
            let bAfter = try Q.capture(file: b.file, root: directory, source: false, deadline: deadline)
            facts["rawSnapshotsBeforePublicInspection"] = true
            // Snapshot verdicts cannot be rescued by any later public query.
            phase = .sourceImage
            try quietACKRequire(try quietModel(sourceAfter) == finalExpected && sourceAfter.rows(Q.local).isEmpty, .sourceImage)
            let finalHead = try quietSourceFinal(sourceBefore, sourceAfter, entry: entry, producer: registrations.a.producer)
            facts["sourceHeadDelta"] = 2; facts["sourceReceiptDelta"] = 1
            facts["sourceOriginDelta"] = 1; facts["sourceCoverageDelta"] = 2
            phase = .receiverImage
            try quietACKRequire(try quietModel(aAfter) == finalExpected && quietModel(bAfter) == finalExpected, .receiverImage)
            try quietReceiverFinal(aBefore, aAfter, originals: ownA); try quietReceiverFinal(bBefore, bAfter, originals: ownB)
            // Canonical installation suppresses AuditLog creation (actual Core
            // install checks _SyncControl); no replacement original is minted.
            try quietACKRequire(try aAfter.rows("AuditLog").count == aBefore.rows("AuditLog").count + 1
                && bAfter.rows("AuditLog").count == bBefore.rows("AuditLog").count, .originals)
            try quietPreserveRows(aBefore.rows("AuditLog"), aAfter.rows("AuditLog"), key: "globalId")
            try quietPreserveRows(bBefore.rows("AuditLog"), bAfter.rows("AuditLog"), key: "globalId")
            try quietACKRequire(!ownA.contains { $0.id == entry.originalID } && !ownB.contains { $0.id == entry.originalID }, .originals)
            try quietACKRequire(try !aBefore.rows("AuditLog").contains { UUID(uuidString: try $0.text("globalId")) == entry.originalID }, .originals)
            try quietOriginalValue(aAfter, entry: entry)
            facts["sharedRowsPerReceiver"] = 6; facts["preservedSharedOriginals"] = 6; facts["localOnlyRowsPreserved"] = 2
            phase = .receiverSettlement
            try quietReceiverOpen(aAfter, channels: channels, contexts: contexts, head: finalHead)
            try quietReceiverOpen(bAfter, channels: channels, contexts: contexts, head: finalHead)
            try quietSettled(aAfter, channels: channels, id: entry.originalID, target: target, position: finalHead)
            facts["receiverSettledClaims"] = 2; facts["installedChannels"] = 4; facts["cohortsOpen"] = 2
            phase = .connections
            // The only final liveness samples occur after frozen raw evidence.
            let finalHandles = try probe.handles()
            try quietACKRequire(Set(finalHandles.map(\.connectionID)) == Set(handles.map(\.connectionID)), .connections)
            try await quietACKSample(finalHandles, until: deadline)
            try probe.checkQuiet(); try quietACKRequire(ContinuousClock.now < deadline, .deadline)
            facts["sameConnectionsLive"] = true; facts["noReconnectObserved"] = true; facts["noSyncErrorsObserved"] = true
            phase = .fixtureCleanup
            try await cleanup()
            try quietACKRequire(ContinuousClock.now < deadline, .deadline)
            phase = .receipt
            try quietACKReceipt(env, passed: true, phase: "completed", facts: facts)
        } catch {
            let failure: QuietACKFailure
            if phase == .fixtureCleanup { failure = .fixtureCleanup }
            else if let fixed = error as? QuietACKFailure { failure = fixed }
            else if error is CancellationError { failure = .deadline }
            else if let existing = error as? ConnectedRecoveryFailure {
                switch existing {
                case .deadline: failure = .deadline
                case .environment: failure = .environment
                case .receipt: failure = .receipt
                case .metadata, .unexpectedOriginal: failure = .metadata
                }
            } else { failure = phase }
            // Preserve first failure before teardown. Unknown facts are omitted;
            // cleanup cannot transform it into success or publish a late pass.
            try? quietACKReceipt(env, passed: false, phase: failure.rawValue, facts: facts)
            if !cleanupAttempted {
                do { try await cleanup() } catch { Issue.record("quiet ACK fixtureCleanup") }
            }
            probe.disarm(); RelayIngressTesting.remove(hooks, for: storage)
            throw failure
        }
    }
}

// C uses a dedicated executable and two real process incarnations. A/B above
// remain byte-exact; no test-binary respawn or receiver installation seam.
import RecoveryProcessSupport

private final class KillRecoveryRegistrations: Sendable {
    let user = UUID(), sourceID = UUID(), epoch = UUID(), cohortID = UUID()
    let bootstrap = ConnectedRegistration("kill-bootstrap"), a = ConnectedRegistration("kill-a"), b = ConnectedRegistration("kill-b")
    let contexts = NIOLockedValueBox<[Int: SyncRecoveryAuthorizationContext]>([:])
    let endpoints = NIOLockedValueBox<[String]>([])
    let gate = KillRecoveryGate()
    private var namespaces: [SyncRecoveryNamespace] {
        [.init(namespaceID: "local", coverageID: "local-v1", revision: 1),
         .init(namespaceID: "a", coverageID: "shared-v1", revision: 1),
         .init(namespaceID: "b", coverageID: "shared-v1", revision: 1)]
    }
    func channel(_ request: Request, index: Int) throws -> SyncChannel {
        _ = try registration(request)
        let endpoints = endpoints.withLockedValue { $0 }
        guard endpoints.count == 2 else { throw Abort(.serviceUnavailable) }
        return .init(id: "wss:" + endpoints[index], userId: user, databaseFileName: "source.sqlite")
    }
    private func registration(_ request: Request) throws -> ConnectedRegistration {
        guard let header = request.headers.first(name: "Authorization"),
              request.headers["Authorization"].count == 1,
              let found = [bootstrap, a, b].first(where: { header == "Bearer " + $0.token }) else { throw Abort(.unauthorized) }
        return found
    }
    func policy(_ index: Int) throws -> SyncRecoveryMountConfiguration {
        let cohort = try SyncRecoveryReceiptCohort(id: cohortID, revision: 1, namespaces: Array(namespaces.dropFirst()))
        return try .init(authority: "receiver-kill-service", sourceID: sourceID, epoch: epoch, localNamespace: "local",
            namespaces: namespaces, receiptNamespace: index == 0 ? "a" : "b", models: ["RecoveryProcessSharedRow"],
            durability: .walFull, maximumAuthorizationMilliseconds: 600_000,
            readyProfile: .bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: 10_000), receiptCoverage: .registeredProducerV3(cohort))
    }
    func authorize(_ request: Request, _ context: SyncRecoveryAuthorizationContext, index: Int) throws -> SyncRecoveryAuthorization {
        let registered = try registration(request), expectedChannel = try channel(request, index: index)
        guard context.channel.id == expectedChannel.id, context.channel.userId == user,
              context.declaredPeer == registered.peer(index), context.source.authority == "receiver-kill-service",
              context.source.sourceID == sourceID, context.source.epoch == epoch,
              context.source.receiptNamespace == (index == 0 ? "a" : "b"), context.source.coverageID == "shared-v1",
              context.source.coverageRevision == 1, context.source.receiptCoverage?.cohortID == cohortID.uuidString.lowercased(),
              context.source.receiptCoverage?.cohortRevision == 1, context.source.receiptCoverage?.namespaces == ["a", "b"],
              context.incomingScope.models.count == 1, context.incomingScope.models[0].table == "RecoveryProcessSharedRow",
              context.incomingScope.models[0].incomingOperations == [.insert, .update, .delete],
              context.incomingScope.relations.isEmpty, context.incomingScope.scopedLinkTables.isEmpty,
              context.incomingScope.catalogDigest == context.source.schemaDigest else { throw Abort(.forbidden) }
        if registered.replica == bootstrap.replica { contexts.withLockedValue { $0[index] = context } }
        return .init(authenticatedUserID: user, peer: registered.peer(index), source: context.source,
            incomingScope: context.incomingScope, authorizationRevision: "receiver-kill-registration-v1", validForMilliseconds: 600_000,
            receiptCoverage: .registeredProducer(registered.producer, cohortID: cohortID, cohortRevision: 1))
    }
}

/// Receives real ordinary catch-up only. It never emits READY/audit/ACK frames
/// and never serves as a receiver or an installation authority.
private final class KillRecoveryBootstrapPeer: Sendable {
    private struct State { var socket: WebSocket?; var ids = Set<String>(); var lifecycle = ConnectedBootstrapLifecycle(); var invalid = false }
    private let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        let closeAfterAttach = state.withLockedValue { value in
            value.socket = socket
            return value.lifecycle.didAttach()
        }
        socket.onBinary { [weak self] _, bytes in
            guard let self else { return }
            guard bytes.readableBytes <= 1_048_576,
                  let object = (try? JSONSerialization.jsonObject(with: Data(buffer: bytes))) as? [String: Any]
            else { self.state.withLockedValue { $0.invalid = true }; return }
            guard let audits = object["auditLog"] as? [[String: Any]] else { return }
            self.state.withLockedValue { value in
                for audit in audits {
                    guard value.ids.count < 64, audit["tableName"] as? String == "RecoveryProcessSharedRow",
                          let id = audit["globalId"] as? String, UUID(uuidString: id) != nil else { value.invalid = true; return }
                    value.ids.insert(id.lowercased())
                }
            }
        }
        socket.onClose.whenComplete { [weak self] _ in self?.state.withLockedValue { $0.lifecycle.didClose(); $0.socket = nil } }
        if closeAfterAttach { socket.close(promise: nil) }
    }
    var ids: Set<String> { state.withLockedValue { $0.ids } }
    var invalid: Bool { state.withLockedValue { $0.invalid } }
    var closed: Bool { state.withLockedValue { $0.lifecycle.closed } }
    func connectFailed() { state.withLockedValue { $0.lifecycle.connectFailed() } }
    func cleanupRetired(ownedGroupJoined: Bool) -> Bool {
        state.withLockedValue { $0.lifecycle.cleanupRetired(ownedGroupJoined: ownedGroupJoined) }
    }
    func close() {
        let socket = state.withLockedValue { value in value.lifecycle.requestClose(); return value.socket }
        socket?.close(promise: nil)
    }
}

private enum KillRecoveryPhase: String, Codable { case environment, bootstrap, initial, offline, cut, kill, snapshot, retirement, reopen, recovery, postWrite, finalSnapshot, cleanup, complete }
private enum KillRecoveryFailure: Error { case environment, metadata, bounds, state, deadline, cleanup }
private enum KillRecoveryCut: String, Sendable, Equatable, Codable { case request, partial }

private final class KillRecoveryGate: Sendable {
    private struct State {
        var observations: [RelayReadyControlObservation] = []
        var connections: [UUID: RelayRecoveryConnectionObservation] = [:]
        var decisions: [String: Bool] = [:]
        var bytes = 0, overflow = false, invalid = false, armed = false, held = false
        var peer: SyncRecoveryPeerIdentity?, channel = "", cut: KillRecoveryCut = .request
        var excludedConnections = Set<UUID>()
        var prepare: RelayReadyControlObservation?, manifest: RelayReadyControlObservation?, firstPage: RelayReadyControlObservation?
        var selected: RelayReadyControlObservation?, send: (@Sendable () -> Void)?
    }
    private let state = NIOLockedValueBox(State())
    func connection(_ observation: RelayRecoveryConnectionObservation) {
        state.withLockedValue { s in
            guard s.connections.count < 16 || s.connections[observation.connectionID] != nil else { s.overflow = true; return }
            s.connections[observation.connectionID] = observation
        }
    }
    private static func same(_ actual: RelayReadyControlObservation, _ prepare: RelayReadyControlObservation) -> Bool {
        guard let a = actual.cutpoint, let p = prepare.cutpoint else { return false }
        return actual.connectionID == prepare.connectionID && actual.peer == prepare.peer && actual.channel == prepare.channel &&
            a.frame.canonicalVersion == p.frame.canonicalVersion && a.requestDigest == p.requestDigest &&
            a.frame.attemptID == p.frame.attemptID && a.frame.sequence == p.frame.sequence &&
            a.frame.receiverIncarnation == p.frame.receiverIncarnation && a.frame.channelIncarnation == p.frame.channelIncarnation &&
            a.frame.routeGeneration == p.frame.routeGeneration
    }
    func observe(_ observation: RelayReadyControlObservation) {
        state.withLockedValue { s in
            let frame = observation.cutpoint?.frame
            let strings = [observation.channel, observation.requestID, observation.operation, observation.peer.replicaID,
                observation.routeGeneration ?? "", observation.requestDigest ?? "", observation.attemptID ?? "", observation.sequence ?? "",
                observation.index ?? "", observation.canonicalKind ?? "", observation.cutpoint?.requestDigest ?? "",
                observation.cutpoint?.requestFrameSHA256 ?? "", frame?.receiverIncarnation ?? "", frame?.channelIncarnation ?? "",
                frame?.channel ?? "", frame?.attemptID ?? "", frame?.sequence ?? "", frame?.routeGeneration ?? "", frame?.requestDigest ?? "",
                frame?.manifestDigest ?? "", frame?.pageIndex ?? "", frame?.itemCount ?? "", frame?.payloadBytes ?? "",
                frame?.nativePageDigest ?? "", frame?.normalizedFrameSHA256 ?? ""]
            let bytes = strings.reduce(256) { $0 + $1.utf8.count }
            guard s.observations.count < 256, bytes <= 131_072 - s.bytes else { s.overflow = true; return }
            s.bytes += bytes; s.observations.append(observation)
            guard s.armed, s.selected == nil, !s.excludedConnections.contains(observation.connectionID),
                  observation.peer == s.peer, observation.channel == s.channel,
                  let cutpoint = observation.cutpoint else { return }
            if s.prepare == nil {
                guard observation.operation == "prepare", cutpoint.kind == .positivePrepareLease else { return }
                s.prepare = observation
                if s.cut == .request { s.selected = observation }
                return
            }
            guard let prepare = s.prepare, Self.same(observation, prepare), observation.operation == "read" else { return }
            switch observation.index {
            case "0":
                guard cutpoint.kind == .manifest, s.manifest == nil, s.decisions[prepare.requestID] == true else { s.invalid = true; return }
                s.manifest = observation
            case "1":
                guard let manifest = s.manifest, s.decisions[manifest.requestID] == true,
                      s.firstPage == nil, cutpoint.kind == .contentPage || cutpoint.kind == .receiptPage else { s.invalid = true; return }
                s.firstPage = observation
            case "2":
                guard let first = s.firstPage, s.decisions[first.requestID] == true,
                      cutpoint.kind == .contentPage || cutpoint.kind == .receiptPage || cutpoint.kind == .end else { s.invalid = true; return }
                s.selected = observation
            default: break
            }
        }
    }
    func arm(peer: SyncRecoveryPeerIdentity, channel: String, cut: KillRecoveryCut) throws {
        try state.withLockedValue { s in
            guard !s.armed, s.prepare == nil, s.send == nil, !s.overflow, !s.invalid else { throw KillRecoveryFailure.state }
            s.excludedConnections = Set(s.connections.values.filter { $0.peer == peer && $0.channel == channel }.map(\.connectionID))
            guard !s.excludedConnections.isEmpty else { throw KillRecoveryFailure.state }
            s.armed = true; s.peer = peer; s.channel = channel; s.cut = cut
        }
    }
    func park(_ id: String, _ send: @escaping @Sendable () -> Void) -> Bool {
        state.withLockedValue { s in
            guard s.selected?.requestID == id, !s.held, s.send == nil else { return false }
            s.send = send; s.held = true; return true
        }
    }
    func decision(_ id: String, _ allowed: Bool) {
        state.withLockedValue { s in
            guard s.observations.contains(where: { $0.requestID == id }) else { return }
            guard s.decisions.count < 256 || s.decisions[id] != nil else { s.overflow = true; return }
            if let prior = s.decisions[id], prior != allowed { s.invalid = true }
            s.decisions[id] = allowed
        }
    }
    func release() {
        let send = state.withLockedValue { s in let send = s.send; s.send = nil; s.armed = false; return send }
        send?() // The real send closure rechecks socket/lifetime/result itself.
    }
    var healthy: Bool { state.withLockedValue { !$0.overflow && !$0.invalid } }
    var held: Bool { state.withLockedValue { $0.held && $0.send != nil } }
    var staleDecision: Bool? { state.withLockedValue { s in s.selected.flatMap { s.decisions[$0.requestID] } } }
    var count: Int { state.withLockedValue { $0.observations.count } }
    func evidence() throws -> ReceiverReapCutEvidence {
        try state.withLockedValue { s in
            guard s.held, s.send != nil, let prepare = s.prepare, let selected = s.selected, !s.overflow, !s.invalid else { throw KillRecoveryFailure.state }
            if s.cut == .request {
                guard selected.requestID == prepare.requestID, s.manifest == nil, s.firstPage == nil else { throw KillRecoveryFailure.metadata }
                return .init(prepare: prepare, manifest: nil, firstPage: nil, heldSecondRead: nil)
            }
            guard let manifest = s.manifest, let first = s.firstPage,
                  s.decisions[prepare.requestID] == true, s.decisions[manifest.requestID] == true,
                  s.decisions[first.requestID] == true, selected.index == "2" else { throw KillRecoveryFailure.metadata }
            return .init(prepare: prepare, manifest: manifest, firstPage: first, heldSecondRead: selected)
        }
    }
    func handle(_ id: UUID) -> RelayRecoveryConnectionObservation? { state.withLockedValue { $0.connections[id] } }
    func connectionIDs(replica: String) -> Set<UUID> {
        state.withLockedValue { s in Set(s.connections.values.filter { $0.peer.replicaID == replica }.map(\.connectionID)) }
    }
    func handles(peer: ConnectedRegistration, channels: [String], after: Int = 0, excluding: Set<UUID> = []) throws -> [RelayRecoveryConnectionObservation] {
        try state.withLockedValue { s in
            guard after >= 0, after <= s.observations.count, !s.overflow, !s.invalid else { throw KillRecoveryFailure.bounds }
            return try channels.enumerated().map { index, channel in
                let ids = Set(s.observations.dropFirst(after).filter {
                    !excluding.contains($0.connectionID) && $0.peer == peer.peer(index) && $0.channel == channel &&
                        $0.operation == "read" && $0.cutpoint != nil && s.decisions[$0.requestID] == true
                }.map(\.connectionID))
                guard ids.count == 1, let id = ids.first, let handle = s.connections[id] else { throw KillRecoveryFailure.state }
                return handle
            }
        }
    }
    func completedRounds(peer: ConnectedRegistration, channels: [String], after: Int) -> Bool {
        state.withLockedValue { s in
            guard after >= 0, after <= s.observations.count, !s.overflow, !s.invalid else { return false }
            let observed = Array(s.observations.dropFirst(after))
            return channels.enumerated().allSatisfy { index, channel in
                observed.contains { prepare in
                    guard prepare.peer == peer.peer(index), prepare.channel == channel,
                          prepare.operation == "prepare", prepare.cutpoint?.kind == .positivePrepareLease,
                          s.decisions[prepare.requestID] == true else { return false }
                    return observed.contains { end in
                        Self.same(end, prepare) && end.operation == "read" && end.cutpoint?.kind == .end && s.decisions[end.requestID] == true
                    }
                }
            }
        }
    }
    // Same-Q actual read proves the newly authorized connection obtained a
    // usable lease. A fresh positive higher-Q prepare/read proves refreeze.
    // Neither copied result is supplied to the controller as authority.
    func recoveryBranch(after: Int, old: ReceiverReapCutEvidence) throws -> Bool? {
        try state.withLockedValue { s in
            guard after >= 0, after <= s.observations.count, let oldQ = old.prepare.cutpoint,
                  let sequence = Int64(oldQ.frame.sequence), !s.overflow, !s.invalid else { throw KillRecoveryFailure.metadata }
            let observed = Array(s.observations.dropFirst(after))
            for read in observed where read.connectionID != old.prepare.connectionID && read.peer == old.prepare.peer &&
                read.channel == old.prepare.channel && read.operation == "read" && s.decisions[read.requestID] == true {
                guard let r = read.cutpoint else { continue }
                if r.requestDigest == oldQ.requestDigest && r.frame.attemptID == oldQ.frame.attemptID && r.frame.sequence == oldQ.frame.sequence {
                    return false // exact retained Q, fresh actual connection/lease
                }
                guard let next = Int64(r.frame.sequence), next > sequence else { continue }
                if observed.contains(where: { candidate in
                    guard let q = candidate.cutpoint else { return false }
                    return candidate.connectionID == read.connectionID && candidate.peer == read.peer && candidate.channel == read.channel &&
                        candidate.operation == "prepare" && q.kind == .positivePrepareLease && s.decisions[candidate.requestID] == true &&
                        q.requestDigest == r.requestDigest && q.frame.attemptID == r.frame.attemptID && q.frame.sequence == r.frame.sequence
                }) { return true }
            }
            return nil
        }
    }
}

@MainActor
private func killRecoveryApplication(_ certificate: URL, _ key: URL) async throws -> Application {
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    // C owns the group used by both its server and bootstrap clients. Final
    // cleanup observes the checked join, including failed pre-upgrade channels.
    let app = try await Application.make(environment, .createNew)
    var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.file(certificate.path)], privateKey: .file(key.path))
    tls.minimumTLSVersion = .tlsv12
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 0
    app.http.server.configuration.supportVersions = [.one]
    app.http.server.configuration.tlsConfiguration = tls
    app.http.server.configuration.shutdownTimeout = .seconds(1)
    return app
}

@MainActor
private func killRecoveryShutdown(_ app: Application) async throws {
    guard case .createNew = app.eventLoopGroupProvider else { throw ConnectedRecoveryFailure.metadata }
    var firstError: (any Error)?
    if !app.didShutdown {
        do { try await app.asyncShutdown() } catch { firstError = error }
    }
    // Vapor logs and suppresses group-shutdown errors. Pinned NIO explicitly
    // permits this second call: it returns the retained result after all
    // registered channels close and all owned event-loop threads are joined.
    do { try await app.eventLoopGroup.shutdownGracefully() }
    catch { if firstError == nil { firstError = error } }
    if let firstError { throw firstError }
}

@MainActor
private func killRecoveryConfiguration(registration: ConnectedRegistration, contexts: [SyncRecoveryAuthorizationContext],
                                       endpoints: [String], store: String, deadline: UInt64) throws -> RecoveryProcessConfiguration {
    guard contexts.count == 2, endpoints.count == 2, contexts[0].incomingScope == contexts[1].incomingScope else { throw KillRecoveryFailure.metadata }
    let claim = try RecoveryProcessCodec.encode(contexts[0].incomingScope)
    let channels = try contexts.enumerated().map { index, context in
        let source = context.source, scope = context.incomingScope, peer = registration.peer(index)
        guard let endpoint = URL(string: endpoints[index]) else { throw KillRecoveryFailure.metadata }
        let expectation = try Lattice.RecoverySourceExpectation(endpoint: endpoint,
            source: .init(authority: source.authority, sourceID: source.sourceID, epoch: source.epoch,
                scopeDigest: source.scopeDigest, schemaDigest: source.schemaDigest, receiptNamespace: source.receiptNamespace,
                coverageID: source.coverageID, coverageRevision: source.coverageRevision, descriptorDigest: source.descriptorDigest,
                receiptCoverage: source.receiptCoverage),
            peer: .init(replicaID: peer.replicaID, receiverIncarnation: peer.receiverIncarnation, channelIncarnation: peer.channelIncarnation),
            incomingScope: .init(models: scope.models.map { .init(table: $0.table, incomingOperations: $0.incomingOperations.map { .init(rawValue: $0.rawValue)! }) },
                relations: [], scopedLinkTables: [], catalogDigest: scope.catalogDigest),
            channel: "wss:" + endpoints[index], validForMilliseconds: 600_000)
        return try RecoveryProcessChannelConfiguration(expectation: expectation, incomingGrantClaim: claim)
    }
    return try .init(nonce: UUID(), deadlineNanoseconds: deadline, storeDirectory: store,
                     authorizationToken: registration.token, channels: channels)
}

@MainActor
private func killRecoverySample(_ handle: RelayRecoveryConnectionObservation, until deadline: ContinuousClock.Instant) async throws -> RelayRecoveryConnectionSample {
    let pending = QuietACKOneShot<RelayRecoveryConnectionSample>()
    handle.sample { pending.resolve(.success($0)) }
    return try await pending.wait(until: deadline)
}
@MainActor
private func killRecoverySample(_ handle: RelayRecoveryRetirementObservation, until deadline: ContinuousClock.Instant) async throws -> RelayRecoveryRetirementSample {
    let pending = QuietACKOneShot<RelayRecoveryRetirementSample>()
    handle.sample { pending.resolve(.success($0)) }
    return try await pending.wait(until: deadline)
}
@MainActor
private func killRecoveryLive(_ handles: [RelayRecoveryConnectionObservation], until deadline: ContinuousClock.Instant) async throws {
    guard handles.count == 2, Set(handles.map(\.connectionID)).count == 2 else { throw KillRecoveryFailure.metadata }
    for handle in handles {
        let sample = try await killRecoverySample(handle, until: deadline)
        try #require(sample.available && sample.socketOpen && sample.lifetimeLive)
    }
}
@MainActor
private func killRecoveryRetired(_ handle: RelayRecoveryRetirementObservation, drained: Bool,
                                 until deadline: ContinuousClock.Instant) async throws {
    while true {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { throw KillRecoveryFailure.deadline }
        let value = try await killRecoverySample(handle, until: deadline)
        if drained ? value.operationsDrained : (value.connectionRetired && value.nativeAvailable && !value.nativeDrained) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func killRecoverySourceIdentity(_ file: URL) throws -> [UInt64] {
    guard file.isFileURL, file.standardizedFileURL == file, file.resolvingSymlinksInPath() == file else { throw KillRecoveryFailure.state }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
          let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw KillRecoveryFailure.state }
    return [device.uint64Value, inode.uint64Value]
}

private enum KillRecoveryCaseName: String, Codable, CaseIterable, Hashable {
    case killedReceiverReopensFromDurableQ, killedReceiverReopensFromCommittedPartialRange
}
private struct KillRecoveryFacts: Codable {
    var receiverCount: Int?, channelsPerReceiver: Int?, childSpawnCount: Int?, preservedSharedOriginals: Int?
    var sharedRowsBeforePostWrite: Int?, sharedRowsAfterPostWrite: Int?
    var killedByOwnedSIGKILL: Bool?, exactReapBeforeSnapshot: Bool?, durableCutValidated: Bool?
    var sameSavedConfiguration: Bool?, freshPhysicalIncarnation: Bool?, oldConnectionRetired: Bool?
    var staleSendRefused: Bool?, heldResultDrained: Bool?, sourceAndBStayedLive: Bool?
    var actualResumeObserved: Bool?, actualRefreezeObserved: Bool?, finalInstallLinksValidated: Bool?, postRecoveryWriteObserved: Bool?
    var matchedQ: Bool?, matchedManifest: Bool?, matchedPage: Bool?, distinctChildInstances: Bool?
    var exactRowsPreserved: Bool?, localOnlyPreserved: Bool?, finalCommittedOpen: Bool?
    var allChildrenReaped: Bool?, descriptorsClosed: Bool?, sourceAuthorizationRetired: Bool?, heldCallbacksReleased: Bool?
    var cut: KillRecoveryCut?, observedCanonicalKind: String?, observedReadIndex: Int?
    var configurationSHA256: String?, executableSHA256: String?
}
private struct KillRecoveryCaseReceipt: Codable {
    let name: KillRecoveryCaseName
    let passed: Bool
    let phase: KillRecoveryPhase
    let scalarFacts: KillRecoveryFacts
}
private struct KillRecoveryReceipt: Codable { let version: Int; var cases: [KillRecoveryCaseReceipt] }
@MainActor
private func killRecoveryReceipt(_ environment: ConnectedTLSEnvironment, name: KillRecoveryCaseName,
                                 passed: Bool, phase: KillRecoveryPhase, facts: KillRecoveryFacts) throws {
    let file = environment.root.appendingPathComponent("receipts/receiver-kill-recovery-cases.json")
    var receipt = KillRecoveryReceipt(version: 1, cases: [])
    if FileManager.default.fileExists(atPath: file.path) {
        let data = try Data(contentsOf: file)
        guard data.count <= 16_384 else { throw KillRecoveryFailure.bounds }
        receipt = try JSONDecoder().decode(KillRecoveryReceipt.self, from: data)
        guard receipt.version == 1, receipt.cases.count < 2, Set(receipt.cases.map(\.name)).count == receipt.cases.count,
              !receipt.cases.contains(where: { $0.name == name }) else { throw KillRecoveryFailure.state }
    }
    receipt.cases.append(.init(name: name, passed: passed, phase: phase, scalarFacts: facts))
    let bytes = try RecoveryProcessCodec.encode(receipt)
    guard bytes.count <= 16_384 else { throw KillRecoveryFailure.bounds }
    try bytes.write(to: file, options: .atomic)
}

@Suite("Public receiver kill recovery", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LATTICE_RECEIVER_KILL_RECOVERY_GATE"] == "1"))
@MainActor
struct PublicReceiverKillRecoveryTests {
    @Test func killedReceiverReopensFromDurableQ() async throws { try await run(.request) }
    @Test func killedReceiverReopensFromCommittedPartialRange() async throws { try await run(.partial) }

    private func run(_ cut: KillRecoveryCut) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now <= UInt64(Int64.max) - 120_000_000_000 else { throw KillRecoveryFailure.deadline }
        let nativeDeadline = now + 120_000_000_000
        let name: KillRecoveryCaseName = cut == .request ? .killedReceiverReopensFromDurableQ : .killedReceiverReopensFromCommittedPartialRange
        var phase = KillRecoveryPhase.environment, facts = KillRecoveryFacts()
        facts.cut = cut
        let environment = try ConnectedTLSEnvironment()
        let directory = environment.root.appendingPathComponent("private/connected-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storage = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sourceFile = storage.appendingPathComponent("source.sqlite")
        let registrations = KillRecoveryRegistrations()
        let app = try await killRecoveryApplication(environment.certificate, environment.key)
        let gate = registrations.gate
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: {},
            parkRecoveryReadySend: { gate.park($0, $1) }, didRecoveryReadyDecision: { gate.decision($0, $1) },
            didRecoveryReadyControl: { gate.observe($0) }, didObserveRecoveryConnection: { gate.connection($0) })
        RelayIngressTesting.install(hooks, for: storage)
        var mounts: [SyncRelayHandle] = [], bootstrap: [KillRecoveryBootstrapPeer] = []
        var parentB: RecoveryProcessReceiver?, process: RecoveryProcessOwner?
        var retirementObservation: RelayRecoveryRetirementObservation?
        var cleanupResult: Result<Void, any Error>?
        func cleanup() async throws {
            if let cleanupResult { return try cleanupResult.get() }
            var firstError: (any Error)?
            func failed(_ error: any Error) { if firstError == nil { firstError = error } }
            gate.release()
            retirementObservation = nil // Release the payload-free budget/fence reference too.
            if let process {
                let result = await process.cleanup()
                if !result.allSpawnedReaped || !result.descriptorsClosed { failed(KillRecoveryFailure.cleanup) }
            }
            do { try parentB?.close() } catch { failed(error) }
            for peer in bootstrap { peer.close() }
            for mount in mounts { await mount.retireRecoveryAuthorization() }
            var ownedGroupJoined = false
            do { try await killRecoveryShutdown(app); ownedGroupJoined = true } catch { failed(error) }
            do {
                try await connectedWait("C source authorization retirement", until: min(deadline, ContinuousClock.now.advanced(by: .seconds(10)))) {
                    mounts.allSatisfy { $0.recoverySessionCount == 0 }
                        && bootstrap.allSatisfy { $0.cleanupRetired(ownedGroupJoined: ownedGroupJoined) }
                }
            } catch { failed(error) }
            RelayIngressTesting.remove(hooks, for: storage)
            if let firstError { cleanupResult = .failure(firstError); throw firstError }
            cleanupResult = .success(())
            // Source governor ownership can outlive setup. No store/WAL is
            // unlinked here; the wrapper removes files only after group reap.
        }
        do {
            phase = .bootstrap
            func seed() throws -> (RecoveryProcessImage, Set<String>) {
                let owner = try Lattice(for: [RecoveryProcessSharedRow.self, RecoveryProcessLocalRow.self], configuration: .init(fileURL: sourceFile))
                func copied() throws -> (RecoveryProcessImage, Set<String>) {
                    try owner.withTransaction { for i in 1...6 { try owner.add(RecoveryProcessSharedRow(label: "r\(i)", value: i)) } }
                    let rows = try Array(owner.objects(RecoveryProcessSharedRow.self)).map {
                        RecoveryProcessRow(id: try #require($0.globalId), label: $0.label, value: $0.value)
                    }.sorted { $0.label < $1.label }
                    let ids = Set(Array(owner.eventsAfter(globalId: nil)).compactMap { $0.globalId?.uuidString.lowercased() })
                    try #require(rows.count == 6 && ids.count == 6)
                    return (.init(rows: rows, localValues: [], originals: []), ids)
                }
                do {
                    let image = try copied(), closed = owner.closeChecked()
                    try #require(closed.cleanupComplete && !closed.failed && !closed.cleanupFailed && closed.errorMessage == nil && !closed.errorMessageUnavailable)
                    return image
                } catch { owner.close(); throw error }
            }
            let (initial, seededIDs) = try seed()
            for index in 0..<2 {
                mounts.append(try Lattice.configureSyncRelay(on: app.routes, path: [.constant(index == 0 ? "a" : "b")],
                    for: [RecoveryProcessSharedRow.self, RecoveryProcessLocalRow.self], storageURL: storage,
                    writePolicy: .init(allowedOperations: ["RecoveryProcessSharedRow": [.insert, .update, .delete]], unlistedTables: .deny),
                    recovery: registrations.policy(index), channelExtractor: { try registrations.channel($0, index: index) },
                    recoveryAuthorization: { try registrations.authorize($0, $1, index: index) }))
            }
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let endpoints = ["wss://127.0.0.1:\(port)/a", "wss://127.0.0.1:\(port)/b"], channels = endpoints.map { "wss:" + $0 }
            try #require(channels.allSatisfy { $0.utf8.count <= 64 })
            registrations.endpoints.withLockedValue { $0 = endpoints }
            for index in 0..<2 {
                let peer = KillRecoveryBootstrapPeer(), declared = registrations.bootstrap.peer(index); bootstrap.append(peer)
                let query = "?recovery-v=1&recovery-replica=\(declared.replicaID)&recovery-receiver=\(declared.receiverIncarnation)&recovery-channel=\(declared.channelIncarnation)"
                var headers = HTTPHeaders(); headers.add(name: "Authorization", value: "Bearer " + registrations.bootstrap.token)
                do {
                    try await WebSocket.connect(to: endpoints[index] + query, headers: headers, on: app.eventLoopGroup) { peer.attach($0) }.get()
                } catch {
                    peer.connectFailed()
                    throw error
                }
                try await connectedWait("C actual source metadata and authorized seeded catch-up", until: deadline) {
                    !peer.invalid && peer.ids == seededIDs && registrations.contexts.withLockedValue { $0[index] != nil }
                }
            }
            let context = registrations.contexts.withLockedValue { $0 }
            let contexts = [try #require(context[0]), try #require(context[1])]
            for peer in bootstrap { peer.close() }
            try await connectedWait("C bootstrap registration retirement", until: deadline) {
                bootstrap.allSatisfy(\.closed) && mounts.allSatisfy { $0.recoverySessionCount == 0 }
            }
            let sourceIdentity = try killRecoverySourceIdentity(sourceFile)
            let configA = try killRecoveryConfiguration(registration: registrations.a, contexts: contexts, endpoints: endpoints,
                store: "receiver-a.lattice-continuous", deadline: nativeDeadline)
            let configB = try killRecoveryConfiguration(registration: registrations.b, contexts: contexts, endpoints: endpoints,
                store: "receiver-b.lattice-continuous", deadline: nativeDeadline)
            let b = try RecoveryProcessReceiver(configuration: configB, caseDirectory: directory); parentB = b
            let child = try RecoveryProcessOwner(configuration: configA, caseDirectory: directory, executable: RecoveryProcessOwner.executableURL()); process = child
            try #require(configA.channels.map(\.channel) == configB.channels.map(\.channel))
            try #require(registrations.a.producer != registrations.b.producer && b.file != directory.appendingPathComponent(configA.storeDirectory + "/store.sqlite"))
            facts.configurationSHA256 = child.configurationSHA256; facts.executableSHA256 = child.executableSHA256
            phase = .initial
            try b.open(connected: true)
            let firstHello = try await child.spawn()
            _ = try await child.command(.start)
            let initialA = try await child.command(.settle, expected: initial)
            try #require(initialA.committedOpen == true && initialA.image != nil)
            let initialB = try await b.settle(expected: initial)
            let liveB = try gate.handles(peer: registrations.b, channels: channels)
            let initialHandlesA = try gate.handles(peer: registrations.a, channels: channels)
            try await killRecoveryLive(initialHandlesA, until: deadline)
            try await killRecoveryLive(liveB, until: deadline)
            facts.receiverCount = 2; facts.channelsPerReceiver = 2
            phase = .offline
            let edit = try await child.command(.offlineEdit)
            let preimage = try #require(edit.image), pending = try #require(edit.createdShared)
            try #require(pending.count == 3 && preimage.rows.count == 6 && preimage.localValues == ["receiver-a-local"])
            try gate.arm(peer: registrations.a.peer(0), channel: channels[0], cut: cut)
            _ = try await child.command(.reconnect)
            phase = .cut
            try await connectedWait("C selected actual retained source cut", until: deadline) { gate.held }
            let evidence = try gate.evidence(), oldConnection = try #require(gate.handle(evidence.prepare.connectionID))
            try #require(!initialHandlesA.contains { $0.connectionID == oldConnection.connectionID })
            let killedConnectionIDs = gate.connectionIDs(replica: registrations.a.replica)
            retirementObservation = oldConnection.retirementObservation()
            try #require(retirementObservation?.connectionID == evidence.prepare.connectionID && retirementObservation?.peer == registrations.a.peer(0) && retirementObservation?.channel == channels[0])
            let held = try await killRecoverySample(try #require(retirementObservation), until: deadline)
            try #require(held.available && held.socketOpen && !held.lifetimeStopped && !held.nativeSetupRetired && held.nativeAvailable && held.nativeLive && !held.nativeDrained)
            try await killRecoveryLive(liveB, until: deadline)
            // No public query or child command between reconnect/cut and kill.
            phase = .kill
            let killed = try await child.killAtObservedCut()
            try #require(killed.reaped && killed.killedByOwnedSIGKILL && !killed.exitedZero && killed.spawnOrdinal == 1 && killed.instanceID == firstHello.instanceID)
            facts.killedByOwnedSIGKILL = true; facts.exactReapBeforeSnapshot = true
            phase = .snapshot
            let rawCut = try await ReceiverReapReadOnlySnapshot.capture(owner: child, retirement: killed, deadline: deadline)
            try ReceiverReapComparison.validateCut(rawCut, evidence: evidence, preimage: preimage, pendingOriginals: pending)
            facts.durableCutValidated = true; facts.matchedQ = true
            facts.matchedManifest = cut == .partial; facts.matchedPage = cut == .partial
            facts.observedCanonicalKind = (evidence.heldSecondRead ?? evidence.prepare).cutpoint?.frame.kind.rawValue
            if cut == .partial { facts.observedReadIndex = 2 }
            phase = .retirement
            try await killRecoveryRetired(try #require(retirementObservation), drained: false, until: deadline)
            facts.oldConnectionRetired = true
            try await connectedWait("C old A setups retired with B still enrolled", until: deadline) { mounts.allSatisfy { $0.recoverySessionCount == 1 } }
            try await killRecoveryLive(liveB, until: deadline)
            try #require(gate.held && gate.staleDecision == nil)
            gate.release()
            try await connectedWait("C stale held READY send refused", until: deadline) { gate.staleDecision != nil }
            try #require(gate.staleDecision == false)
            facts.staleSendRefused = true
            try await killRecoveryRetired(try #require(retirementObservation), drained: true, until: deadline)
            facts.heldResultDrained = true
            retirementObservation = nil // Operation drain is not registry/migration quiescence.
            try await killRecoveryLive(liveB, until: deadline)
            try #require(app.http.server.shared.localAddress?.port == port && (try killRecoverySourceIdentity(sourceFile)) == sourceIdentity)
            phase = .reopen
            let resumedFrom = gate.count
            let secondHello = try await child.spawn()
            try #require(secondHello.instanceID != firstHello.instanceID && secondHello.processID != firstHello.processID &&
                secondHello.configurationSHA256 == firstHello.configurationSHA256 && secondHello.configurationSHA256 == child.configurationSHA256)
            facts.sameSavedConfiguration = true; facts.distinctChildInstances = true
            _ = try await child.command(.start)
            phase = .recovery
            let recovered = try await child.command(.settle, expected: preimage)
            let recoveredImage = try #require(recovered.image)
            try #require(recovered.committedOpen == true && recoveredImage.rows == preimage.rows && recoveredImage.localValues == preimage.localValues &&
                preimage.originals.allSatisfy { original in recoveredImage.originals.filter { $0.id == original.id } == [original] })
            let expectedB = RecoveryProcessImage(rows: preimage.rows, localValues: initialB.localValues, originals: initialB.originals)
            _ = try await b.settle(expected: expectedB)
            let freshA = try gate.handles(peer: registrations.a, channels: channels, after: resumedFrom, excluding: killedConnectionIDs)
            try #require(freshA.allSatisfy { !killedConnectionIDs.contains($0.connectionID) })
            try await killRecoveryLive(freshA, until: deadline)
            try await killRecoveryLive(liveB, until: deadline)
            let refrozen = try #require(gate.recoveryBranch(after: resumedFrom, old: evidence))
            facts.actualResumeObserved = !refrozen; facts.actualRefreezeObserved = refrozen
            facts.preservedSharedOriginals = pending.count; facts.sharedRowsBeforePostWrite = recoveredImage.rows.count
            phase = .postWrite
            let postRounds = gate.count
            let write = try await child.command(.postWrite), postImage = try #require(write.image)
            try #require(postImage.rows.count == 7 && postImage.rows.filter { $0.label != "post" } == preimage.rows &&
                postImage.rows.filter { $0.label == "post" && $0.value == 99 }.count == 1 && postImage.localValues == preimage.localValues &&
                preimage.originals.allSatisfy { original in postImage.originals.filter { $0.id == original.id } == [original] })
            // Wait for actual post-write source round completion before the
            // public open-gate check; an earlier transient open is insufficient.
            try await connectedWait("C post-write canonical round on both channels", until: deadline) {
                gate.completedRounds(peer: registrations.a, channels: channels, after: postRounds)
            }
            let settledPost = try await child.command(.settle, expected: postImage)
            try #require(settledPost.committedOpen == true)
            let bPost = RecoveryProcessImage(rows: postImage.rows, localValues: initialB.localValues, originals: initialB.originals)
            _ = try await b.settle(expected: bPost)
            try await killRecoveryLive(liveB, until: deadline)
            try await killRecoveryLive(freshA, until: deadline)
            try #require(app.http.server.shared.localAddress?.port == port && (try killRecoverySourceIdentity(sourceFile)) == sourceIdentity && gate.healthy)
            facts.postRecoveryWriteObserved = true; facts.sharedRowsAfterPostWrite = postImage.rows.count
            facts.exactRowsPreserved = true; facts.localOnlyPreserved = true; facts.finalCommittedOpen = true
            let normal = try await child.closeAndReap()
            try #require(normal.reaped && normal.exitedZero && !normal.killedByOwnedSIGKILL && normal.spawnOrdinal == 2 && normal.instanceID == secondHello.instanceID)
            phase = .finalSnapshot
            let final = try await ReceiverReapReadOnlySnapshot.capture(owner: child, retirement: normal, deadline: deadline)
            try ReceiverReapComparison.validateFinal(final, after: rawCut, expected: postImage, pendingOriginals: pending)
            let oldIncarnation = try rawCut.storage.one("_lattice_producer_continuity").integer("incarnation")
            let newIncarnation = try final.storage.one("_lattice_producer_continuity").integer("incarnation")
            try #require(oldIncarnation < Int64.max && newIncarnation == oldIncarnation + 1)
            facts.finalInstallLinksValidated = true; facts.freshPhysicalIncarnation = true
            try await killRecoveryLive(liveB, until: deadline)
            try #require(app.http.server.shared.localAddress?.port == port && (try killRecoverySourceIdentity(sourceFile)) == sourceIdentity)
            facts.sourceAndBStayedLive = true
            let allChildren = await child.cleanup()
            try #require(allChildren.allSpawnedReaped && allChildren.descriptorsClosed && allChildren.successfulCase && allChildren.spawnCount == 2)
            facts.childSpawnCount = allChildren.spawnCount; facts.allChildrenReaped = true; facts.descriptorsClosed = true
            phase = .cleanup
            try await cleanup()
            try #require(gate.healthy && !gate.held)
            facts.sourceAuthorizationRetired = true; facts.heldCallbacksReleased = true
            phase = .complete
            try killRecoveryReceipt(environment, name: name, passed: true, phase: phase, facts: facts)
        } catch {
            let original = error
            // Only observed scalar facts and the fixed failing phase are saved.
            // Neither cleanup nor a late callback can turn this into a pass.
            do { try killRecoveryReceipt(environment, name: name, passed: false, phase: phase, facts: facts) }
            catch { Issue.record("C bounded failure receipt unavailable") }
            do { try await cleanup() } catch { Issue.record("C process/source cleanup failed") }
            RelayIngressTesting.remove(hooks, for: storage)
            throw original
        }
    }
}
