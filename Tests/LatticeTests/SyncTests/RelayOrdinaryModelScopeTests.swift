import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum ModelScopeRouteFailure: Error { case timeout, overflow, connect }

/// Bounded raw client observes actual native-issued frames. Its manually sent
/// receipt is a delivery-protocol test input, not proof of native receiver commit;
/// the separate native/client receiver suite owns that qualification.
private final class ModelScopeRouteClient: @unchecked Sendable {
    struct State {
        var socket: WebSocket?
        var closed = false, connectFailed = false, overflow = false, closing = false
        var frames: [Data] = []
        var bytes = 0
    }
    let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        let closing = state.withLockedValue { $0.socket = socket; return $0.closing }
        socket.onBinary { [self] _, buffer in
            let close = state.withLockedValue { value in
                guard value.frames.count < 64, buffer.readableBytes <= 8_388_608 - value.bytes else {
                    value.overflow = true; return true
                }
                value.bytes += buffer.readableBytes; value.frames.append(Data(buffer: buffer)); return false
            }
            if close { socket.close(code: .policyViolation, promise: nil) }
        }
        socket.onClose.whenComplete { [self] _ in state.withLockedValue { $0.closed = true; $0.socket = nil } }
        if closing { socket.close(promise: nil) }
    }
    var frames: [Data] { state.withLockedValue { $0.frames } }
    func bodies() -> [[String: Any]] {
        frames.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any] }
    }
    func headers() -> [[String: Any]] { bodies().filter { $0["kind"] as? String == "cut" } }
    func complete(_ ordinal: Int) -> Bool {
        let all = bodies(), headers = all.filter { $0["kind"] as? String == "cut" }
        guard ordinal < headers.count, let rawPages = headers[ordinal]["pages"] as? String, let pages = Int(rawPages),
              let cut = headers[ordinal]["cut"] as? String else { return false }
        return all.filter { $0["kind"] as? String == "page" && $0["cut"] as? String == cut }.count == pages
    }
    func textValues(_ ordinal: Int, table: String, column: String) -> [String] {
        let all = bodies(), headers = all.filter { $0["kind"] as? String == "cut" }
        guard ordinal < headers.count, let cut = headers[ordinal]["cut"] as? String,
              let tables = headers[ordinal]["tables"] as? [[String: Any]],
              let columns = tables.first(where: { $0["name"] as? String == table })?["columns"] as? [String],
              let position = columns.firstIndex(of: column) else { return [] }
        return all.filter { $0["kind"] as? String == "page" && $0["cut"] as? String == cut }.flatMap { page in
            (page["records"] as? [[String: Any]] ?? []).compactMap { record -> String? in
                guard let row = record["row"] as? [String: Any], row["table"] as? String == table,
                      let values = row["values"] as? [[Any]], position < values.count,
                      values[position].count == 2, values[position][0] as? String == "text" else { return nil }
                return values[position][1] as? String
            }
        }
    }
    func send(_ bytes: Data) throws {
        guard let socket = state.withLockedValue({ $0.socket }) else { throw ModelScopeRouteFailure.connect }
        socket.send(ByteBuffer(data: bytes))
    }
    func modelRequest(_ profile: String, request: String = UUID().uuidString) throws {
        try send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "modelRequest", "request": request, "modelProfile": profile]]))
    }
    func nacks() -> [[UUID]] {
        frames.compactMap { data in
            guard let event = try? JSONDecoder().decode(ServerSentEvent.self, from: data),
                  case .nack(let ids, _) = event else { return nil }
            return ids
        }
    }
    func request() throws {
        try send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "request", "request": UUID().uuidString]]))
    }
    func receipt(_ ordinal: Int, wrong: Bool = false) throws {
        let header = try #require(headers().dropFirst(ordinal).first)
        var body: [String: Any] = ["version": 2, "kind": "receipt"]
        for key in ["source", "epoch", "cut", "contentDigest"] { body[key] = try #require(header[key]) }
        if wrong { body["contentDigest"] = String(repeating: "0", count: 64) }
        try send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body]))
    }
    func close() { state.withLockedValue { $0.closing = true; return $0.socket }?.close(promise: nil) }
}

private func modelScopeRouteWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < end {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard predicate() else { throw ModelScopeRouteFailure.timeout }
}

private final class ModelScopeRouteHarness: @unchecked Sendable {
    let app: Application
    let directory: URL
    let writer: Lattice
    let setupCount = NIOLockedValueBox(0)
    let clients = NIOLockedValueBox<[ModelScopeRouteClient]>([])
    var port = 0
    init(app: Application, directory: URL, writer: Lattice) {
        self.app = app; self.directory = directory; self.writer = writer
    }
    func connect(path: String = "sync") async throws -> ModelScopeRouteClient {
        let client = ModelScopeRouteClient()
        clients.withLockedValue { $0.append(client) }
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 4_194_304
        WebSocket.connect(to: "ws://127.0.0.1:\(port)/\(path)", configuration: configuration, on: app.eventLoopGroup) {
            client.attach($0)
        }.whenFailure { _ in client.state.withLockedValue { $0.connectFailed = true } }
        try await modelScopeRouteWait { client.state.withLockedValue { $0.socket != nil || $0.connectFailed || $0.closed } }
        guard !client.state.withLockedValue({ $0.connectFailed || $0.closed }) else { throw ModelScopeRouteFailure.connect }
        return client
    }
}

private func withModelScopeRoute(push: Bool, secondaryMount: Bool = false, policy: OrdinarySyncPolicy = .orderedRequired,
                               seed: Bool = false, schema: [any Lattice.Model.Type] = modelScopeMountedTypes,
                               profiles: [SyncOrdinaryModelProfile]? = nil, authorize: Bool = true, _ body: (ModelScopeRouteHarness) async throws -> Void) async throws {
    // Retain this UUID-owned directory for the process lifetime; teardown never
    // unlinks a live SQLite file beneath a queued IO destructor.
    let directory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "localdev/lattice-ordinary-model-scope-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let writer = try Lattice(for: schema, configuration: .init(fileURL: directory.appending(path: "fixture.sqlite")))
    defer { let close = writer.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
    if seed {
        try writer.add(ModelScopeA(value: "selected-a")); try writer.add(ModelScopeB(value: "selected-b")); try writer.add(ModelScopeC(value: "selected-c"))
        try writer.add(ModelScopeD(value: "excluded-d")); try writer.add(ModelScopeE(value: "excluded-e")); try writer.add(ModelScopeF(value: "excluded-f"))
    }
    let registered = try profiles ?? [.init(identifier: "fixture-three-v1", models: modelScopeSelectedTypes)]
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    let app = try await Application.make(environment)
    let harness = ModelScopeRouteHarness(app: app, directory: directory, writer: writer)
    app.http.server.configuration.port = 0
    app.http.server.configuration.shutdownTimeout = .seconds(1)
    let setupCount = harness.setupCount
    let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
                                     didFinishAsyncSetup: { setupCount.withLockedValue { $0 += 1 } })
    RelayIngressTesting.install(hooks, for: directory)
    let user = UUID()
    _ = Lattice.configureSyncRelay(on: app.routes, path: ["sync"], for: schema, storageURL: directory,
            observerPush: push ? .init(reconcileInterval: nil) : nil, ordinarySyncPolicy: policy, ordinaryModelProfiles: registered,
            channelExtractor: { _ in guard authorize else { throw Abort(.forbidden) }; return .init(id: "fixture", userId: user) })
    if secondaryMount {
        _ = Lattice.configureSyncRelay(on: app.routes, path: ["sync-other"], for: schema, storageURL: directory,
            ordinarySyncPolicy: policy, ordinaryModelProfiles: registered, channelExtractor: { _ in .init(id: "fixture", userId: user) })
    }
    RelayIngressTesting.remove(hooks, for: directory)
    var failure: (any Error)?
    do {
        try await app.startup()
        harness.port = try #require(app.http.server.shared.localAddress?.port)
        try await body(harness)
    } catch { failure = error }
    let clients = harness.clients.withLockedValue { $0 }
    clients.forEach { $0.close() }
    do {
        try await modelScopeRouteWait { clients.allSatisfy { $0.state.withLockedValue { $0.closed || $0.connectFailed } } }
    } catch { if failure == nil { failure = error } else { Issue.record("ordinary route client cleanup also failed") } }
    do { try await app.asyncShutdown() }
    catch { if failure == nil { failure = error } else { Issue.record("ordinary route application cleanup also failed") } }
    if let failure { throw failure }
}


// Scalar fixtures exercise real typed mount/storage selection. They do not
// impersonate Engram, a managed installation issuer, TLS or membership proof.
@Model class ModelScopeA { var value: String; init(value: String) { self.value = value } }
@Model class ModelScopeB { var value: String; init(value: String) { self.value = value } }
@Model class ModelScopeC { var value: String; init(value: String) { self.value = value } }
@Model class ModelScopeD { var value: String; init(value: String) { self.value = value } }
@Model class ModelScopeE { var value: String; init(value: String) { self.value = value } }
@Model class ModelScopeF { var value: String; init(value: String) { self.value = value } }
nonisolated(unsafe) private let modelScopeMountedTypes: [any Lattice.Model.Type] = [ModelScopeA.self, ModelScopeB.self, ModelScopeC.self, ModelScopeD.self, ModelScopeE.self, ModelScopeF.self]
nonisolated(unsafe) private let modelScopeSelectedTypes: [any Lattice.Model.Type] = [ModelScopeA.self, ModelScopeB.self, ModelScopeC.self]

private func modelScopeNegotiate(_ client: ModelScopeRouteClient) async throws {
    let nonce = UUID().uuidString
    try client.modelRequest("fixture-three-v1", request: nonce)
    try await modelScopeRouteWait { client.bodies().contains { $0["kind"] as? String == "modelOffer" } }
    let offer = try #require(client.bodies().first)
    #expect(Set(offer.keys) == ["version", "kind", "request", "modelProfile"])
    #expect(offer["request"] as? String == nonce)
    #expect(offer["modelProfile"] as? String == "fixture-three-v1")
    #expect(client.headers().isEmpty, "model agreement alone sends no current rows")
    try client.request() // May race the sender's local callback; ownership still fences it.
    try await modelScopeRouteWait { client.complete(0) }
}

// Actual local originals + actual native captured field observation. These are
// upload inputs only; no cut/source/scope/receipt field is relabelled as authority.
private func modelScopeUpload(_ donor: Lattice) throws -> (Data, UUID) {
    let local = try donor.captureOrdinarySyncExport()
    var originals: [[String: Any]] = []
    for page in 1..<local.frameCount {
        let root = try #require(JSONSerialization.jsonObject(with: local.frame(at: page)) as? [String: Any])
        let body = try #require(root["latticeOrdinarySync"] as? [String: Any])
        for record in body["records"] as? [[String: Any]] ?? [] {
            guard var entry = record["original"] as? [String: Any], let observed = record["originalDescriptor"] as? [String: Any] else { continue }
            entry["uploadOriginal"] = ["version": 1, "fields": try #require(observed["fields"]), "names": try #require(observed["names"])]
            entry["deliveryVersion"] = "0"; originals.append(entry)
        }
    }
    #expect(originals.count == 1)
    let id = try #require(UUID(uuidString: try #require(originals.first?["globalId"] as? String)))
    return (try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "upload", "auditLog": originals]]), id)
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RelayOrdinaryModelScopeTests {
    @Test func selectedThreeModelsKeepSixMountedTablesAndExcludeOtherBytes() async throws {
        try await withModelScopeRoute(push: false, seed: true) { harness in
            let client = try await harness.connect(); try await modelScopeNegotiate(client)
            let header = try #require(client.headers().first)
            #expect(header["models"] as? [String] == modelScopeSelectedTypes.map { $0.entityName }.sorted())
            #expect(header["rows"] as? String == "3")
            #expect(client.textValues(0, table: ModelScopeA.entityName, column: "value") == ["selected-a"])
            for data in client.frames {
                let text = String(decoding: data, as: UTF8.self)
                #expect(!text.contains("excluded-") && !text.contains(ModelScopeF.entityName))
            }
            #expect(harness.writer.objects(ModelScopeD.self).count == 1)
            #expect(harness.writer.objects(ModelScopeE.self).count == 1)
            #expect(harness.writer.objects(ModelScopeF.self).count == 1)
            try client.receipt(0)
        }
    }
    @Test func unknownProfileRefusesWithoutFullSourceFallback() async throws {
        try await withModelScopeRoute(push: false, seed: true) { harness in
            let client = try await harness.connect(); try client.modelRequest("unknown-v1")
            try await modelScopeRouteWait { client.state.withLockedValue { $0.closed } }
            #expect(client.frames.isEmpty)
            #expect(harness.writer.objects(ModelScopeF.self).count == 1)
        }
    }
    @Test(arguments: [false, true]) func duplicateOrChangedSelectionRefusesOnSameLiveSocket(switchToOtherRegisteredProfile: Bool) async throws {
        let profiles = [try SyncOrdinaryModelProfile(identifier: "fixture-three-v1", models: modelScopeSelectedTypes),
                        try SyncOrdinaryModelProfile(identifier: "fixture-six-v1", models: modelScopeMountedTypes)]
        try await withModelScopeRoute(push: false, seed: true, profiles: profiles) { harness in
            let client = try await harness.connect(); try await modelScopeNegotiate(client)
            try client.modelRequest(switchToOtherRegisteredProfile ? "fixture-six-v1" : "fixture-three-v1")
            try await modelScopeRouteWait { client.state.withLockedValue { $0.closed } }
            #expect(client.headers().count == 1)
        }
    }
    @Test func foreignMetatypeCannotBeRegisteredByAnAuthenticatedMount() async throws {
        let profile = try SyncOrdinaryModelProfile(identifier: "fixture-three-v1", models: [SimpleSyncObject.self])
        try await withModelScopeRoute(push: false, profiles: [profile]) { harness in
            let client = ModelScopeRouteClient()
            harness.clients.withLockedValue { $0.append(client) }
            var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 4_194_304
            WebSocket.connect(to: "ws://127.0.0.1:\(harness.port)/sync", configuration: configuration, on: harness.app.eventLoopGroup) { client.attach($0) }
                .whenFailure { _ in client.state.withLockedValue { $0.connectFailed = true } }
            try await modelScopeRouteWait { client.state.withLockedValue { $0.closed || $0.connectFailed } }
            #expect(client.frames.isEmpty)
        }
    }
    @Test func refusedActualChannelCannotIssueAModelSelection() async throws {
        try await withModelScopeRoute(push: false, authorize: false) { harness in
            let client = ModelScopeRouteClient()
            harness.clients.withLockedValue { $0.append(client) }
            WebSocket.connect(to: "ws://127.0.0.1:\(harness.port)/sync", on: harness.app.eventLoopGroup) { client.attach($0) }
                .whenFailure { _ in client.state.withLockedValue { $0.connectFailed = true } }
            try await modelScopeRouteWait { client.state.withLockedValue { $0.closed || $0.connectFailed } }
            #expect(client.frames.isEmpty)
        }
    }
    @Test func explicitLegacyRequestStillUsesExactOfferAndAllMountedModels() async throws {
        try await withModelScopeRoute(push: false, seed: true) { harness in
            let client = try await harness.connect(); try client.request()
            try await modelScopeRouteWait { client.complete(0) }
            let offer = try #require(client.bodies().first)
            #expect(Set(offer.keys) == ["version", "kind", "request", "uploadObservation", "uploadAcknowledgment"])
            #expect(client.headers().first?["models"] as? [String] == modelScopeMountedTypes.map { $0.entityName }.sorted())
            try client.receipt(0)
        }
    }
    @Test func sourceScopeChangeIssuesNewIdentityAndPreservesOldScope() async throws {
        try await withModelScopeRoute(push: false, seed: true) { harness in
            let legacy = try await harness.connect(); try legacy.request()
            try await modelScopeRouteWait { legacy.complete(0) }; try legacy.receipt(0)
            let selected = try await harness.connect(); try await modelScopeNegotiate(selected)
            let old = try #require(legacy.headers().first), fresh = try #require(selected.headers().first)
            #expect(old["source"] as? String != fresh["source"] as? String)
            #expect(old["scope"] as? String != fresh["scope"] as? String)
            #expect(old["models"] as? [String] == modelScopeMountedTypes.map { $0.entityName }.sorted())
            // This proves source issuance only. A receiver with an overlapping
            // historical baseline still needs the separate owned rebind.
            try selected.receipt(0)
        }
    }
    @Test func staleFullScopeReceiptCannotSettleSelectedCut() async throws {
        try await withModelScopeRoute(push: false, seed: true) { harness in
            let legacy = try await harness.connect(); try legacy.request()
            try await modelScopeRouteWait { legacy.complete(0) }; try legacy.receipt(0)
            let selected = try await harness.connect(); try await modelScopeNegotiate(selected)
            var body: [String: Any] = ["version": 2, "kind": "receipt"]
            let old = try #require(legacy.headers().first)
            for key in ["source", "epoch", "cut", "contentDigest"] { body[key] = try #require(old[key]) }
            try selected.send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body]))
            try await modelScopeRouteWait { selected.state.withLockedValue { $0.closed } }
            #expect(selected.headers().count == 1)
        }
    }
    @Test func observerAndLaterCaptureRetainTheSameSelectedModelSet() async throws {
        try await withModelScopeRoute(push: true, seed: true) { harness in
            let client = try await harness.connect(); try await modelScopeNegotiate(client); try client.receipt(0)
            try harness.writer.add(ModelScopeF(value: "excluded-later"))
            try harness.writer.add(ModelScopeA(value: "selected-later"))
            try await modelScopeRouteWait { client.complete(1) }
            #expect(client.headers()[1]["models"] as? [String] == modelScopeSelectedTypes.map { $0.entityName }.sorted())
            #expect(client.textValues(1, table: ModelScopeA.entityName, column: "value").contains("selected-later"))
            #expect(!client.frames.contains { String(decoding: $0, as: UTF8.self).contains("excluded-later") })
            #expect(harness.writer.objects(ModelScopeF.self).count == 2)
            try client.receipt(1)
        }
    }
    @Test func selectedUploadIsAcceptedButAnUnselectedMountedTableIsNot() async throws {
        try await withModelScopeRoute(push: false, seed: true) { harness in
            let client = try await harness.connect(); try await modelScopeNegotiate(client); try client.receipt(0)
            let selected = try Lattice(ModelScopeA.self, configuration: .init(fileURL: harness.directory.appending(path: "selected-original.sqlite")))
            let excluded = try Lattice(ModelScopeF.self, configuration: .init(fileURL: harness.directory.appending(path: "excluded-original.sqlite")))
            defer {
                for donor in [selected, excluded] {
                    let close = donor.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete)
                }
            }
            try selected.add(ModelScopeA(value: "selected-upload")); let allowed = try modelScopeUpload(selected)
            try client.send(allowed.0)
            try await modelScopeRouteWait { client.complete(1) }
            #expect(client.textValues(1, table: ModelScopeA.entityName, column: "value").contains("selected-upload"))
            try client.receipt(1)
            try excluded.add(ModelScopeF(value: "excluded-upload")); let forbidden = try modelScopeUpload(excluded)
            try client.send(forbidden.0)
            try await modelScopeRouteWait { client.nacks().contains { $0.contains(forbidden.1) } }
            #expect(harness.writer.objects(ModelScopeF.self).count == 1)
            #expect(!client.bodies().contains { ($0["kind"] as? String) == "uploadAck" && (($0["accepted"] as? [[String: String]]) ?? []).contains { $0["globalId"]?.lowercased() == forbidden.1.uuidString.lowercased() } })
        }
    }
}
