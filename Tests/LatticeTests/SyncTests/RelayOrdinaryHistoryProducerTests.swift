import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum HistoryRouteFailure: Error { case timeout, connection, overflow }

/// This bounded raw peer reports only protocol input copied from a real native
/// source cut. It is not a native receiver, COMMIT witness, model authorization
/// factory, final installer or ACK issuer. Positive durable receiver staging
/// remains the actual separate native history suite/paired qualification.
private final class HistoryRoutePeer: @unchecked Sendable {
    struct State {
        var socket: WebSocket?
        var closed = false, failed = false, overflow = false, closing = false
        var frames: [Data] = []
        var bytes = 0
    }
    let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        let closing = state.withLockedValue { $0.socket = socket; return $0.closing }
        socket.onBinary { [self] _, buffer in
            let close = state.withLockedValue { value in
                guard value.frames.count < 64, buffer.readableBytes <= 8_388_608 - value.bytes else { value.overflow = true; return true }
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
    func send(_ body: [String: Any]) throws {
        guard let socket = state.withLockedValue({ $0.socket }) else { throw HistoryRouteFailure.connection }
        let data = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body])
        guard data.count <= 4_096 else { throw HistoryRouteFailure.overflow }
        socket.send(ByteBuffer(data: data))
    }
    func request(profile: String? = nil) async throws {
        if let profile {
            let nonce = UUID().uuidString
            try send(["version": 2, "kind": "modelRequest", "request": nonce, "modelProfile": profile])
            try await historyRouteWait { self.bodies().contains { $0["kind"] as? String == "modelOffer" } || self.state.withLockedValue { $0.closed } }
            let answer = try #require(bodies().first { $0["kind"] as? String == "modelOffer" })
            #expect(answer["request"] as? String == nonce && answer["modelProfile"] as? String == profile)
        }
        try send(["version": 2, "profile": "paged-history-v1", "kind": "request", "request": UUID().uuidString])
    }
    func progress(header: [String: Any], index: Int, page: Data?, complete: Bool, wrongStage: Bool = false) throws {
        var body: [String: Any] = ["version": 2, "profile": "paged-history-v1", "kind": "historyProgress",
                                 "nextPage": String(index), "previousDigest": page.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "", "stagedComplete": complete]
        for field in ["source", "epoch", "cut", "stage"] { body[field] = try #require(header[field]) }
        if wrongStage { body["stage"] = UUID().uuidString }
        try send(body)
    }
    func close() { state.withLockedValue { $0.closing = true; return $0.socket }?.close(promise: nil) }
}
private func historyRouteWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < end {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard predicate() else { throw HistoryRouteFailure.timeout }
}
private final class HistoryRouteFixture: @unchecked Sendable {
    let app: Application, directory: URL
    let budget = RelayOrdinaryBudget(endpoints: 1, cuts: 1, staging: 1)
    let setup = NIOLockedValueBox(0)
    let peer = HistoryRoutePeer()
    let key: String
    var writer: Lattice?
    let policy: OrdinarySyncPolicy
    init(app: Application, directory: URL, policy: OrdinarySyncPolicy) {
        self.app = app; self.directory = directory; self.policy = policy
        key = FileWatchManager.canonicalKey(for: directory.appendingPathComponent("fixture.sqlite"))
    }
    func fence() async {
        await withCheckedContinuation { continuation in RelayExecutionPool.io.submitRequired(for: key) { continuation.resume() } }
    }
    func open(historical: Bool = false) async throws {
        if historical {
            let old = try Lattice(isolation: nil, for: [SimpleSyncObject.self, StreamedMessage.self],
                                  configuration: .init(fileURL: directory.appendingPathComponent("fixture.sqlite")))
            try old.add(SimpleSyncObject(value: 11, floatValue: 11.25))
            let result = old.closeChecked()
            #expect(!result.failed && !result.cleanupFailed && result.cleanupComplete)
            // This real closed/reopened legacy file has never issued a source
            // cut or receiver receipt. The actual mount issuer must say so.
        }
        try RelayOrdinaryBudgetTesting.install(budget, for: key)
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: { self.setup.withLockedValue { $0 += 1 } })
        RelayIngressTesting.install(hooks, for: directory)
        let typed = try SyncOrdinaryModelProfile(identifier: "selected-simple-v1", models: [SimpleSyncObject.self])
        _ = Lattice.configureSyncRelay(on: app.routes, path: ["sync"], for: [SimpleSyncObject.self, StreamedMessage.self],
            storageURL: directory, ordinarySyncPolicy: policy, ordinaryModelProfiles: [typed],
            channelExtractor: { _ in .init(id: "fixture", userId: UUID()) })
        RelayIngressTesting.remove(hooks, for: directory)
        app.http.server.configuration.port = 0; app.http.server.configuration.shutdownTimeout = .seconds(1)
        try await app.startup()
        let port = try #require(app.http.server.shared.localAddress?.port)
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 4_194_304
        WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync", configuration: configuration, on: app.eventLoopGroup) { self.peer.attach($0) }
            .whenFailure { _ in self.peer.state.withLockedValue { $0.failed = true } }
        try await historyRouteWait { self.peer.state.withLockedValue { $0.socket != nil || $0.failed || $0.closed } }
        guard !peer.state.withLockedValue({ $0.failed || $0.closed }) else { throw HistoryRouteFailure.connection }
        try await historyRouteWait { self.setup.withLockedValue { $0 } == 1 }
        // The actual relay owner creates the fresh schema FIRST. Only now open
        // a writer/commit data. This does not promote a historical file or forge
        // a fresh-origin/managed enrollment capability for the source issuer.
        writer = try Lattice(isolation: nil, for: [SimpleSyncObject.self, StreamedMessage.self],
                             configuration: .init(fileURL: directory.appendingPathComponent("fixture.sqlite")))
        try writer?.add(SimpleSyncObject(value: 7, floatValue: 7.25))
    }
    func header() async throws -> [String: Any] {
        try await historyRouteWait { self.peer.bodies().contains { $0["kind"] as? String == "historyCut" } || self.peer.state.withLockedValue { $0.closed } }
        return try #require(peer.bodies().first { $0["kind"] as? String == "historyCut" })
    }
    func stageProtocolInput(_ header: [String: Any]) async throws {
        let pages = try #require(Int(try #require(header["pages"] as? String)))
        #expect((1...8).contains(pages), "fixture remains bounded; no full-history unbounded peer buffer")
        guard (1...8).contains(pages) else { throw HistoryRouteFailure.overflow }
        try peer.progress(header: header, index: 0, page: nil, complete: false)
        for index in 1...pages {
            try await historyRouteWait { self.peer.bodies().filter { $0["kind"] as? String == "historyPage" }.count >= index || self.peer.state.withLockedValue { $0.closed } }
            let data = try #require(peer.frames.filter { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any] != nil }.first { bytes in
                let body = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any]
                return body?["kind"] as? String == "historyPage" && body?["index"] as? String == String(index - 1)
            })
            try peer.progress(header: header, index: index, page: data, complete: index == pages)
        }
        try await historyRouteWait { self.budget.snapshot.staging == 0 }
        await fence()
    }
    func shutdown() async throws {
        peer.close()
        var failure: (any Error)?
        do { try await historyRouteWait { self.peer.state.withLockedValue { $0.closed || $0.failed } } } catch { failure = error }
        do { try await app.asyncShutdown() } catch { if failure == nil { failure = error } else { Issue.record("history app cleanup also failed: \(error)") } }
        await fence()
        #expect(budget.snapshot == .init(endpoints: 0, cuts: 0, staging: 0, stagingBytes: 0))
        RelayOrdinaryBudgetTesting.remove(budget, for: key)
        if let writer { let close = writer.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        writer = nil
        if let failure { throw failure }
    }
}
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RelayOrdinaryHistoryProducerTests {
    private func run(policy: OrdinarySyncPolicy = .orderedRequired, historical: Bool = false, _ body: (HistoryRouteFixture) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-history-relay-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let fixture = HistoryRouteFixture(app: try await Application.make(environment), directory: directory, policy: policy)
        do { try await fixture.open(historical: historical); try await body(fixture) }
        catch {
            do { try await fixture.shutdown() } catch { Issue.record("history route cleanup also failed: \(error)") }
            throw error
        }
        try await fixture.shutdown()
    }
    @Test func actualAuthenticatedTypedSelectionReachesHistoryIssuerAndWaitsForProgress() async throws {
        try await run { fixture in
            try await fixture.peer.request(profile: "selected-simple-v1")
            let header = try await fixture.header()
            #expect(header["models"] as? [String] == [SimpleSyncObject.entityName])
            #expect(fixture.peer.bodies().filter { $0["kind"] as? String == "historyPage" }.isEmpty)
            try await historyRouteWait { fixture.budget.snapshot.staging == 0 }
            #expect(fixture.budget.snapshot == .init(endpoints: 1, cuts: 1, staging: 0, stagingBytes: 0))
            #expect(fixture.peer.bodies().filter { $0["kind"] as? String == "offer" }.allSatisfy { $0["uploadObservation"] == nil && $0["uploadAcknowledgment"] == nil })
        }
    }
    @Test func finalPassiveProgressRetainsActualCutWithoutCanonicalReceiptACKOrSuccessor() async throws {
        try await run { fixture in
            try await fixture.peer.request(profile: "selected-simple-v1")
            let header = try await fixture.header()
            try await fixture.stageProtocolInput(header)
            #expect(fixture.budget.snapshot == .init(endpoints: 1, cuts: 1, staging: 0, stagingBytes: 0))
            #expect(fixture.peer.bodies().filter { $0["kind"] as? String == "historyCut" }.count == 1)
            #expect(fixture.peer.bodies().allSatisfy { !["receipt", "historyReceipt", "uploadAck"].contains($0["kind"] as? String ?? "") })
            let writer = try #require(fixture.writer)
            #expect(writer.count(SimpleSyncObject.self) == 1 && !Array(writer.eventsAfter(globalId: nil)).isEmpty)
            await fixture.fence()
            #expect(fixture.budget.snapshot.cuts == 1)
            // Protocol input does not claim native receiver COMMIT/final install.
            // Actual route retirement below is the only release in this case.
        }
    }
    @Test func wrongActualStageProgressRefusesAndRetiresWithoutPruningOriginals() async throws {
        try await run { fixture in
            try await fixture.peer.request(profile: "selected-simple-v1")
            let header = try await fixture.header()
            try fixture.peer.progress(header: header, index: 0, page: nil, complete: false, wrongStage: true)
            try await historyRouteWait { fixture.peer.state.withLockedValue { $0.closed } }
            await fixture.fence()
            #expect(fixture.budget.snapshot.cuts == 0)
            #expect(fixture.peer.bodies().filter { $0["kind"] as? String == "historyPage" }.isEmpty)
            let writer = try #require(fixture.writer)
            #expect(writer.count(SimpleSyncObject.self) == 1 && !Array(writer.eventsAfter(globalId: nil)).isEmpty)
        }
    }
    @Test func explicitHistoryMountUsesActualLegacyTypedRegistrationAfterOriginalEffectRequest() async throws {
        try await run(policy: .orderedHistoryRequired) { fixture in
            #expect(fixture.peer.frames.isEmpty, "required history mount must not emit legacy data before effect negotiation")
            try await fixture.peer.request()
            let header = try await fixture.header()
            #expect(header["models"] as? [String] == [SimpleSyncObject.entityName, StreamedMessage.entityName].sorted())
            #expect(header["profile"] as? String == "paged-history-v1")
            #expect(fixture.budget.snapshot.cuts == 1)
            // Explicit default typed registration came from the actual issuer;
            // no selected-profile failure fell back to nil/full-source scope.
        }
    }
    @Test func unknownAuthenticatedModelSelectorCannotFallBackToFullHistoryScope() async throws {
        try await run { fixture in
            try fixture.peer.send(["version": 2, "kind": "modelRequest", "request": UUID().uuidString, "modelProfile": "unregistered-model-v1"])
            try await historyRouteWait { fixture.peer.state.withLockedValue { $0.closed } }
            await fixture.fence()
            #expect(fixture.budget.snapshot.cuts == 0)
            #expect(fixture.peer.bodies().allSatisfy { !["modelOffer", "offer", "historyCut", "historyPage"].contains($0["kind"] as? String ?? "") })
        }
    }
    @Test func actualAuthenticatedHistoricalMountCapturesSelectedRowsWithoutInventingOldReceipt() async throws {
        try await run(historical: true) { fixture in
            try await fixture.peer.request(profile: "selected-simple-v1")
            let header = try await fixture.header()
            #expect(header["models"] as? [String] == [SimpleSyncObject.entityName])
            #expect(header["rows"] as? String == "2")
            #expect(header["source"] as? String != nil && header["cut"] as? String == "1")
            #expect(header["priorSource"] == nil && header["receipt"] == nil)
            try await fixture.stageProtocolInput(header)
            #expect(fixture.budget.snapshot.cuts == 1)
            #expect(fixture.peer.bodies().allSatisfy { !["receipt", "historyReceipt", "uploadAck"].contains($0["kind"] as? String ?? "") })
            let writer = try #require(fixture.writer)
            #expect(writer.count(SimpleSyncObject.self) == 2 && !Array(writer.eventsAfter(globalId: nil)).isEmpty)
            // The bounded peer submits protocol input only. It is not an actual
            // native receiver/final installer or a witness of durable install.
        }
    }

}
