import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

@Model private class SelectionA { var value: String; init(value: String) { self.value = value } }
@Model private class SelectionB { var value: String; init(value: String) { self.value = value } }
@Model private class SelectionC { var value: String; init(value: String) { self.value = value } }
@Model private class SelectionD { var value: String; init(value: String) { self.value = value } }
@Model private class SelectionE { var value: String; init(value: String) { self.value = value } }
@Model private class SelectionF { var value: String; init(value: String) { self.value = value } }
nonisolated(unsafe) private let selectionSix: [any Lattice.Model.Type] = [SelectionA.self, SelectionB.self, SelectionC.self, SelectionD.self, SelectionE.self, SelectionF.self]
nonisolated(unsafe) private let selectionThree: [any Lattice.Model.Type] = [SelectionA.self, SelectionB.self, SelectionC.self]
private enum SelectionFixtureFailure: Error { case timeout, connection, overflow }

/// Real raw channel fixture; a modelOffer is only observed wire selection.
/// It cannot stand in for native capture, source identity, history or install.
private final class SelectionClient: @unchecked Sendable {
    struct State { var socket: WebSocket?; var closed = false; var failed = false; var overflow = false; var frames: [Data] = []; var bytes = 0 }
    private let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        state.withLockedValue { $0.socket = socket }
        socket.onBinary { [self] _, buffer in
            let stop = state.withLockedValue { value in
                guard value.frames.count < 8, buffer.readableBytes <= 4_096 - value.bytes else {
                    value.overflow = true; return true
                }
                value.bytes += buffer.readableBytes; value.frames.append(Data(buffer: buffer)); return false
            }
            if stop { socket.close(code: .policyViolation, promise: nil) }
        }
        socket.onClose.whenComplete { [self] _ in state.withLockedValue { $0.closed = true; $0.socket = nil } }
    }
    func failed() { state.withLockedValue { $0.failed = true } }
    var connected: Bool { state.withLockedValue { $0.socket != nil } }
    var stopped: Bool { state.withLockedValue { $0.closed || $0.failed } }
    var frames: [Data] { state.withLockedValue { $0.frames } }
    var bodies: [[String: Any]] { frames.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any] } }
    func send(_ bytes: Data) throws {
        guard let socket = state.withLockedValue({ $0.socket }), !stopped else { throw SelectionFixtureFailure.connection }
        socket.send(raw: bytes, opcode: .binary, promise: nil)
    }
    func model(_ profile: String, nonce: String = UUID().uuidString) throws {
        try send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "modelRequest", "request": nonce, "modelProfile": profile]]))
    }
    func close() { state.withLockedValue { $0.socket }?.close(promise: nil) }
}

private func selectionWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < end {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard predicate() else { throw SelectionFixtureFailure.timeout }
}

private final class SelectionHarness: @unchecked Sendable {
    let app: Application
    let directory: URL
    let writer: Lattice
    let user: UUID
    let handle: SyncRelayHandle
    let clients = NIOLockedValueBox<[SelectionClient]>([])
    var port = 0
    init(app: Application, directory: URL, writer: Lattice, user: UUID, handle: SyncRelayHandle) {
        self.app = app; self.directory = directory; self.writer = writer; self.user = user; self.handle = handle
    }
    func connect(path: String = "sync") async throws -> SelectionClient {
        let client = SelectionClient(); clients.withLockedValue { $0.append(client) }
        var config = WebSocketClient.Configuration(); config.maxFrameSize = 4_096
        WebSocket.connect(to: "ws://127.0.0.1:\(port)/\(path)", configuration: config, on: app.eventLoopGroup) { client.attach($0) }
            .whenFailure { _ in client.failed() }
        try await selectionWait { client.connected || client.stopped }
        return client
    }
}

private func withSelectionMount(schema: [any Lattice.Model.Type] = selectionSix,
                                profiles: [SyncOrdinaryModelProfile]? = nil,
                                authorize: Bool = true, handshake: SyncSchemaHandshake? = nil,
                                secondMount: Bool = false, _ body: (SelectionHarness) async throws -> Void) async throws {
    // UUID-owned localdev directory stays present while any queued destructor lives.
    let directory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "localdev/lattice-current-model-selection-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let writer = try Lattice(for: schema, configuration: .init(fileURL: directory.appending(path: "fixture.sqlite")))
    defer { let close = writer.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    let app = try await Application.make(environment)
    app.http.server.configuration.port = 0; app.http.server.configuration.shutdownTimeout = .seconds(1)
    let user = UUID()
    let declared = try profiles ?? [.init(identifier: "fixture-three-v1", models: selectionThree)]
    let handle = Lattice.configureSyncRelay(on: app.routes, path: ["sync"], for: schema, storageURL: directory,
        handshake: handshake, ordinaryModelProfiles: declared, channelExtractor: { _ in
            guard authorize else { throw Abort(.forbidden) }; return .init(id: "fixture", userId: user)
        })
    if secondMount {
        // Same canonical file, distinct actual typed mount registration. This is
        // selection/caller identity coverage, not native source/cut continuity.
        let other = try SyncOrdinaryModelProfile(identifier: "fixture-other-v1", models: [SelectionA.self])
        _ = Lattice.configureSyncRelay(on: app.routes, path: ["sync-other"], for: [SelectionA.self, SelectionB.self],
            storageURL: directory, ordinaryModelProfiles: [other], channelExtractor: { _ in .init(id: "fixture", userId: user) })
    }
    let harness = SelectionHarness(app: app, directory: directory, writer: writer, user: user, handle: handle)
    var failure: (any Error)?
    do {
        try await app.startup(); harness.port = try #require(app.http.server.shared.localAddress?.port)
        try await body(harness)
    } catch { failure = error }
    let clients = harness.clients.withLockedValue { $0 }
    clients.forEach { $0.close() }
    do { try await selectionWait { clients.allSatisfy { $0.stopped } } }
    catch { if failure == nil { failure = error } else { Issue.record("model-selection client cleanup also failed") } }
    do { try await app.asyncShutdown() }
    catch { if failure == nil { failure = error } else { Issue.record("model-selection application cleanup also failed") } }
    if let failure { throw failure }
}

@Test func currentTypedModelRegistrationRefusesUnknownDuplicateAndForeignTypes() throws {
    let profile = try SyncOrdinaryModelProfile(identifier: "fixture-three-v1", models: selectionThree)
    #expect(throws: (any Error).self) { _ = try RelayOrdinaryModelMount(schema: selectionSix, profiles: [profile, profile]) }
    #expect(throws: (any Error).self) { _ = try RelayOrdinaryModelMount(schema: [SelectionA.self], profiles: [profile]) }
    #expect(throws: (any Error).self) { _ = try SyncOrdinaryModelProfile(identifier: String(repeating: "a", count: 65), models: selectionThree) }
    #expect(throws: (any Error).self) { _ = try SyncOrdinaryModelProfile(identifier: "fixture-three-v1", models: [SelectionA.self, SelectionA.self]) }
    #expect(throws: (any Error).self) { _ = try RelayOrdinaryModelMount(schema: selectionSix, profiles: []) }
}

@Test func currentPersonalSixMountNegotiatesThreeWithoutCanonicalFallback() async throws {
    try await withSelectionMount { harness in
        try harness.writer.add(SelectionD(value: "excluded-personal-row"))
        let client = try await harness.connect(); try client.model("fixture-three-v1")
        try await selectionWait { client.bodies.contains { $0["kind"] as? String == "modelOffer" } || client.stopped }
        let offer = try #require(client.bodies.first)
        #expect(Set(offer.keys) == ["version", "kind", "request", "modelProfile"])
        #expect(offer["modelProfile"] as? String == "fixture-three-v1")
        #expect(client.frames.count == 1, "selection must send no legacy audit rows or canonical cut")
        try client.send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "request", "request": UUID().uuidString]]))
        try await selectionWait { client.stopped }
        #expect(client.frames.count == 1, "genuine effect implementation is still unavailable")
        #expect(harness.writer.objects(SelectionD.self).count == 1)
    }
}

@Test func currentGroupThreeMountNegotiatesSameTypedScopeWithoutHistoryProof() async throws {
    try await withSelectionMount(schema: selectionThree) { harness in
        let client = try await harness.connect(); let nonce = UUID().uuidString
        try client.model("fixture-three-v1", nonce: nonce)
        try await selectionWait { !client.bodies.isEmpty || client.stopped }
        let offer = try #require(client.bodies.first)
        #expect(offer["request"] as? String == nonce)
        #expect(client.frames.count == 1)
        #expect(offer["source"] == nil && offer["cut"] == nil && offer["priorMountedSource"] == nil)
    }
}

@Test func currentUnknownSelectedProfileAndLegacyUploadRefuseWithoutLegacyFallback() async throws {
    try await withSelectionMount { harness in
        let unknown = try await harness.connect(); try unknown.model("unknown-v1")
        try await selectionWait { unknown.stopped }; #expect(unknown.frames.isEmpty)
        let upload = try await harness.connect()
        try upload.send(Data("{\"auditLog\":[]}".utf8))
        try await selectionWait { upload.stopped }; #expect(upload.frames.isEmpty)
    }
}

@Test func currentModelSelectionUsesActualExtractorAndHandshakeRefusals() async throws {
    try await withSelectionMount(authorize: false) { harness in
        let client = try await harness.connect(); try await selectionWait { client.stopped }; #expect(client.frames.isEmpty)
    }
    try await withSelectionMount(handshake: .init(headerName: "X-Selection-Schema", minimumVersion: 3, requireHeader: true)) { harness in
        let client = try await harness.connect(); try await selectionWait { client.stopped }; #expect(client.frames.isEmpty)
    }
}

@Test func currentActualPrincipalKickRevokesSelectedSocket() async throws {
    try await withSelectionMount { harness in
        let client = try await harness.connect(); try client.model("fixture-three-v1")
        try await selectionWait { !client.bodies.isEmpty || client.stopped }
        _ = try #require(client.bodies.first)
        await harness.handle.disconnect(channelId: "fixture", userId: harness.user)
        try await selectionWait { client.stopped }
        #expect(client.frames.count == 1)
    }
}

@Test func currentSameFileDistinctMountedCatalogDoesNotReuseOtherProfile() async throws {
    try await withSelectionMount(secondMount: true) { harness in
        let first = try await harness.connect(); try first.model("fixture-three-v1")
        try await selectionWait { !first.bodies.isEmpty || first.stopped }; _ = try #require(first.bodies.first)
        let other = try await harness.connect(path: "sync-other"); try other.model("fixture-three-v1")
        try await selectionWait { other.stopped }; #expect(other.frames.isEmpty)
        let accepted = try await harness.connect(path: "sync-other"); try accepted.model("fixture-other-v1")
        try await selectionWait { !accepted.bodies.isEmpty || accepted.stopped }
        let acceptedOffer = try #require(accepted.bodies.first)
        #expect(acceptedOffer["modelProfile"] as? String == "fixture-other-v1")
    }
}

@Test func currentModelControlDuplicateAndExtraFieldsCannotSelectModels() throws {
    let nonce = UUID().uuidString
    let duplicate = Data("{\"latticeOrdinarySync\":{\"version\":2,\"kind\":\"modelRequest\",\"request\":\"\(nonce)\",\"modelProfile\":\"fixture-three-v1\",\"modelProfile\":\"other-v1\"}}".utf8)
    #expect(throws: (any Error).self) { _ = try RelayOrdinaryModelRequest.decode(duplicate) }
    let extra = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "modelRequest", "request": nonce, "modelProfile": "fixture-three-v1", "models": ["SelectionD"]]])
    #expect(throws: (any Error).self) { _ = try RelayOrdinaryModelRequest.decode(extra) }
}
