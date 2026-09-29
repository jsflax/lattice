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
        let localdev = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev").standardizedFileURL
        let runRoot = URL(fileURLWithPath: raw).standardizedFileURL
        root = runRoot
        guard raw.hasPrefix("/"), runRoot.path.hasPrefix(localdev.path + "/"),
              runRoot.resolvingSymlinksInPath().path == runRoot.path else { throw ConnectedRecoveryFailure.environment }
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
    let app = try await Application.make(environment)
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
    private struct State { var socket: WebSocket?; var ids = Set<String>(); var closed = false; var invalid = false }
    private let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        state.withLockedValue { $0.socket = socket }
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
        socket.onClose.whenComplete { [weak self] _ in self?.state.withLockedValue { $0.closed = true; $0.socket = nil } }
    }
    var ids: Set<String> { state.withLockedValue { $0.ids } }
    var invalid: Bool { state.withLockedValue { $0.invalid } }
    var closed: Bool { state.withLockedValue { $0.closed } }
    func close() { state.withLockedValue { $0.socket }?.close(promise: nil) }
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
            try await app.asyncShutdown()
            observation.phase(.successReceipt)
            try connectedReceipt(env, name: wrongHost ? "stockTLSRejectsReachableWrongHostCertificate" : "stockTLSAcceptsMatchingHostedCertificate",
                facts: ["stockOpens": opens, "stockErrors": errors, "stockTLS": systemTLS, "serverListening": true,
                        "identityFailureObserved": identityFailure.withLockedValue { $0 }])
        } catch {
            observation.failed(connectedFailureFact(error)); captureTLS()
            driver.close()
            observation.cleanup(.shutdownApplication)
            do { try await app.asyncShutdown(); observation.cleanup(.completed) }
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
        func cleanup() async throws {
            observation.cleanup(.releaseHeldSend)
            registrations.gate.release()
            observation.cleanup(.closeReceivers)
            for receiver in receivers { receiver.close() }
            observation.cleanup(.closeBootstrap)
            for peer in bootstrap { peer.close() }
            observation.cleanup(.retireAuthorization)
            for mount in mounts { await mount.retireRecoveryAuthorization() }
            observation.cleanup(.shutdownApplication)
            try await app.asyncShutdown()
            observation.cleanup(.waitRetirement)
            try await connectedWait("all real authorization and held-result retirement", until: ContinuousClock.now.advanced(by: .seconds(10))) {
                mounts.allSatisfy { $0.recoverySessionCount == 0 } && bootstrap.allSatisfy(\.closed)
            }
            observation.cleanup(.removeHooks)
            RelayIngressTesting.remove(hooks, for: storage)
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
                try await WebSocket.connect(to: endpoints[index] + query, headers: headers, on: app.eventLoopGroup) { peer.attach($0) }.get()
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
