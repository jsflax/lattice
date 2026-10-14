import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
@_spi(LatticeServer) import Lattice
@testable import LatticeServerKit

private enum LineageFixtureError: Error { case timeout, connection, overflow }
private func lineageWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < end {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard predicate() else { throw LineageFixtureError.timeout }
}
/// Genuine test mount middleware, not a production membership/HTTPS proof.
/// It executes before actual upgrade; the channel extractor rechecks the same
/// retained fixture registration. Product GroupSyncGuard is a separate source
/// dependency and does not become qualified by these source case declarations.
private struct LineageFixtureAuth: AsyncMiddleware {
    let principal: UUID, group: UUID?, registration: String
    let current: NIOLockedValueBox<Bool>
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard current.withLockedValue({ $0 }), request.headers.first(name: "X-Lineage-Registration") == registration,
              request.headers.first(name: "X-Lineage-Principal") == principal.uuidString else { throw Abort(.unauthorized) }
        if let group {
            guard request.parameters.get("groupID", as: UUID.self) == group else { throw Abort(.forbidden) }
        }
        return try await next.respond(to: request)
    }
}
private final class LineageFixturePeer: @unchecked Sendable {
    struct State { var socket: WebSocket?; var closed = false, failed = false; var frames: [Data] = []; var bytes = 0 }
    let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        state.withLockedValue { $0.socket = socket }
        socket.onBinary { [self] _, buffer in
            let refuse = state.withLockedValue { value in
                guard value.frames.count < 64, buffer.readableBytes <= 8_388_608 - value.bytes else { value.failed = true; return true }
                value.bytes += buffer.readableBytes; value.frames.append(Data(buffer: buffer)); return false
            }
            if refuse { socket.close(code: .policyViolation, promise: nil) }
        }
        socket.onClose.whenComplete { [self] _ in state.withLockedValue { $0.closed = true; $0.socket = nil } }
    }
    var bodies: [[String: Any]] {
        state.withLockedValue { $0.frames }.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any] }
    }
    func send(_ body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body])
        guard data.count <= 4_096, let socket = state.withLockedValue({ $0.socket }) else { throw LineageFixtureError.connection }
        socket.send(ByteBuffer(data: data))
    }
    func request(relation: Bool) async throws -> String {
        let model = UUID().uuidString
        try send(["version": 2, "kind": "modelRequest", "request": model, "modelProfile": "lineage-selected-v1"])
        try await lineageWait { self.bodies.contains { $0["kind"] as? String == "modelOffer" } || self.state.withLockedValue { $0.closed } }
        let agreed = try #require(bodies.first { $0["kind"] as? String == "modelOffer" })
        #expect(agreed["request"] as? String == model && agreed["modelProfile"] as? String == "lineage-selected-v1")
        let request = UUID().uuidString
        var body: [String: Any] = ["version": 2, "profile": "paged-history-v1", "kind": "request", "request": request]
        if relation { body["relation"] = "mounted-lineage-frontier-v1" }
        try send(body); return request
    }
    func close() { state.withLockedValue { $0.socket }?.close(promise: nil) }
}
private final class LineageFixture: @unchecked Sendable {
    let app: Application, directory: URL
    let principal = UUID(), group: UUID?
    let registration = UUID().uuidString, authorized = NIOLockedValueBox(true)
    let peer = LineageFixturePeer(), setup = NIOLockedValueBox(0)
    let budget = RelayOrdinaryBudget(endpoints: 1, cuts: 1, staging: 1)
    let declaredRole: SyncOrdinaryHistoryRelationRole?
    let full: [any Model.Type] = [SimpleSyncObject.self, StreamedMessage.self]
    var selected: [any Model.Type] { group == nil ? [SimpleSyncObject.self] : full }
    var channel: String { group.map { "group-\($0.uuidString)" } ?? principal.uuidString }
    var key: String { FileWatchManager.canonicalKey(for: directory.appendingPathComponent("\(channel).sqlite")) }
    var oldSource: String?, oldCut: Int64?, oldHeader: [String: Any]?
    init(app: Application, directory: URL, group: Bool, declaredRole: SyncOrdinaryHistoryRelationRole?) {
        self.app = app; self.directory = directory; self.group = group ? UUID() : nil; self.declaredRole = declaredRole
    }
    func seedActualOldCut() throws {
        let owner = try Lattice(isolation: nil, for: full, configuration: .init(fileURL: directory.appendingPathComponent("\(channel).sqlite")))
        try owner.add(SimpleSyncObject(value: 41, floatValue: 41.5))
        var old: OwnedOrdinaryHistoryExport? = try owner.captureOrdinaryHistoryExport(models: full)
        let cut = try #require(old); oldSource = cut.sourceID; oldCut = cut.cut
        oldHeader = try #require((try JSONSerialization.jsonObject(with: cut.page(at: 0).data()) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any])
        withExtendedLifetime(cut) {}; old = nil
        let result = owner.closeChecked(); #expect(!result.failed && !result.cleanupFailed && result.cleanupComplete)
    }
    func fence() async {
        await withCheckedContinuation { continuation in RelayExecutionPool.io.submitRequired(for: key) { continuation.resume() } }
    }
    func open(old: Bool = true) async throws {
        if old { try seedActualOldCut() }
        try RelayOrdinaryBudgetTesting.install(budget, for: key)
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: { self.setup.withLockedValue { $0 += 1 } })
        RelayIngressTesting.install(hooks, for: directory)
        let typed = try SyncOrdinaryModelProfile(identifier: "lineage-selected-v1", models: selected, historyRelationRole: declaredRole)
        let middleware = LineageFixtureAuth(principal: principal, group: group, registration: registration, current: authorized)
        let path: [PathComponent] = group == nil ? ["sync"] : ["sync", "group", ":groupID"]
        _ = Lattice.configureSyncRelay(on: app.routes.grouped(middleware), path: path, for: full,
            storageURL: directory, ordinarySyncPolicy: .orderedRequired, ordinaryModelProfiles: [typed],
            channelExtractor: { req in
                guard self.authorized.withLockedValue({ $0 }), req.headers.first(name: "X-Lineage-Registration") == self.registration,
                      req.headers.first(name: "X-Lineage-Principal") == self.principal.uuidString else { throw Abort(.unauthorized) }
                if let group = self.group { guard req.parameters.get("groupID", as: UUID.self) == group else { throw Abort(.forbidden) } }
                return .init(id: self.channel, userId: self.principal)
            })
        RelayIngressTesting.remove(hooks, for: directory)
        app.http.server.configuration.port = 0; app.http.server.configuration.shutdownTimeout = .seconds(1)
        try await app.startup()
        let port = try #require(app.http.server.shared.localAddress?.port)
        var headers = HTTPHeaders(); headers.add(name: "X-Lineage-Registration", value: registration); headers.add(name: "X-Lineage-Principal", value: principal.uuidString)
        let suffix = group.map { "/sync/group/\($0.uuidString)" } ?? "/sync"
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 4_194_304
        WebSocket.connect(to: "ws://127.0.0.1:\(port)\(suffix)", headers: headers, configuration: configuration, on: app.eventLoopGroup) { self.peer.attach($0) }
            .whenFailure { _ in self.peer.state.withLockedValue { $0.failed = true } }
        try await lineageWait { self.peer.state.withLockedValue { $0.socket != nil || $0.failed || $0.closed } }
        guard !peer.state.withLockedValue({ $0.failed || $0.closed }) else { throw LineageFixtureError.connection }
        try await lineageWait { self.setup.withLockedValue { $0 } == 1 }
    }
    func header() async throws -> [String: Any] {
        try await lineageWait { self.peer.bodies.contains { $0["kind"] as? String == "historyCut" } || self.peer.state.withLockedValue { $0.closed } }
        return try #require(peer.bodies.first { $0["kind"] as? String == "historyCut" })
    }
    func shutdown() async throws {
        peer.close(); var failure: (any Error)?
        do { try await lineageWait { self.peer.state.withLockedValue { $0.closed || $0.failed } } } catch { failure = error }
        do { try await app.asyncShutdown() } catch { if failure == nil { failure = error } else { Issue.record("lineage app cleanup also failed: \(error)") } }
        await fence()
        #expect(budget.snapshot == .init(endpoints: 0, cuts: 0, staging: 0, stagingBytes: 0))
        RelayOrdinaryBudgetTesting.remove(budget, for: key)
        if let failure { throw failure }
    }
}
/// These actual authenticated fixture mount/storage/channel schedules observe
/// only genuine issued source controls. They do not supply a real managed
/// receiver cap, accepted old receipt, final installer, production membership,
/// origin RESULT/debt/ACK or filtered-current materializer proof.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RelayOrdinaryLineageRelationTests {
    private func run(group: Bool = false, role: SyncOrdinaryHistoryRelationRole? = .personal, old: Bool = true,
                     _ body: (LineageFixture) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-lineage-relation-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let fixture = LineageFixture(app: try await Application.make(environment), directory: directory, group: group, declaredRole: role)
        do { try await fixture.open(old: old); try await body(fixture) }
        catch { do { try await fixture.shutdown() } catch { Issue.record("lineage cleanup also failed: \(error)") }; throw error }
        try await fixture.shutdown()
    }
    private func relation(_ fixture: LineageFixture, request: String, header: [String: Any]) throws -> [String: Any] {
        let control = try #require(fixture.peer.bodies.first { $0["kind"] as? String == "historyRelation" })
        #expect(control["request"] as? String == request && control["modelProfile"] as? String == "lineage-selected-v1")
        #expect(control["principal"] as? String == fixture.principal.uuidString.lowercased() && control["serverChannel"] as? String == fixture.channel)
        #expect(control["group"] as? String == fixture.group?.uuidString.lowercased())
        let facts = try #require(control["facts"] as? [String: Any]), current = try #require(facts["current"] as? [String: Any])
        for key in ["source", "epoch", "cut", "stage", "scope", "schema", "captureDevice", "captureInode", "contentDigest"] { #expect(current[key] as? String == header[key] as? String) }
        #expect(current["headerDigest"] as? String == header["digest"] as? String)
        let kinds = fixture.peer.bodies.compactMap { $0["kind"] as? String }
        #expect(kinds.filter { $0 == "historyRelation" }.count == 1)
        let relationIndex = try #require(kinds.firstIndex(of: "historyRelation")), headerIndex = try #require(kinds.firstIndex(of: "historyCut"))
        #expect(relationIndex < headerIndex)
        #expect(!kinds.contains("historyReceipt") && !kinds.contains("uploadAck"))
        #expect(fixture.budget.snapshot.cuts == 1) // Passive wait still retains actual cut.
        return facts
    }
    @Test func actualAuthenticatedPersonalMountBindsOldFullAndNewSelectedCutBeforeHeader() async throws {
        try await run { fixture in
            let request = try await fixture.peer.request(relation: true), header = try await fixture.header()
            let facts = try relation(fixture, request: request, header: header), old = try #require(facts["mountedPredecessor"] as? [String: Any])
            #expect(old["source"] as? String == fixture.oldSource && old["issuedFrontier"] as? String == fixture.oldCut.map { String($0) })
            #expect(facts["selectedPredecessor"] is NSNull)
            #expect(old["scope"] as? String == fixture.oldHeader?["scope"] as? String)
            #expect(header["models"] as? [String] == fixture.selected.map { $0.entityName }.sorted())
        }
    }
    @Test func actualAuthenticatedGroupMountPreservesSameLineageAndPreAdvanceFrontier() async throws {
        try await run(group: true, role: .group) { fixture in
            let request = try await fixture.peer.request(relation: true), header = try await fixture.header()
            let facts = try relation(fixture, request: request, header: header), old = try #require(facts["selectedPredecessor"] as? [String: Any]), mounted = try #require(facts["mountedPredecessor"] as? [String: Any])
            #expect(old["source"] as? String == fixture.oldSource && header["source"] as? String == fixture.oldSource)
            #expect(old["issuedFrontier"] as? String == fixture.oldCut.map { String($0) })
            #expect(header["cut"] as? String == fixture.oldCut.map { String($0 + 1) })
            for key in ["scope", "source", "epoch", "issuedFrontier", "schema", "captureDevice", "captureInode"] { #expect(old[key] as? String == mounted[key] as? String) }
        }
    }
    @Test func defaultHistoryRequestDoesNotEmitRelationDespiteTypedRoleDeclaration() async throws {
        try await run { fixture in
            _ = try await fixture.peer.request(relation: false); _ = try await fixture.header(); await fixture.fence()
            #expect(!fixture.peer.bodies.contains { $0["kind"] as? String == "historyRelation" })
            #expect(fixture.budget.snapshot.cuts == 1)
        }
    }
    @Test func explicitRelationRefusesMissingActualTypedRoleAndMismatchedGroupChannel() async throws {
        try await run(role: nil) { fixture in
            _ = try await fixture.peer.request(relation: true)
            try await lineageWait { fixture.peer.state.withLockedValue { $0.closed } }
            #expect(!fixture.peer.bodies.contains { ["historyCut", "historyRelation"].contains($0["kind"] as? String ?? "") })
        }
        try await run(group: true, role: .personal) { fixture in
            _ = try await fixture.peer.request(relation: true)
            try await lineageWait { fixture.peer.state.withLockedValue { $0.closed } }
            #expect(!fixture.peer.bodies.contains { ["historyCut", "historyRelation"].contains($0["kind"] as? String ?? "") })
        }
    }
    @Test func freshAuthenticatedMountReportsNoPredecessorWithoutClaimingReceiverAbsence() async throws {
        try await run(old: false) { fixture in
            let request = try await fixture.peer.request(relation: true), header = try await fixture.header()
            let facts = try relation(fixture, request: request, header: header)
            #expect(facts["mountedPredecessor"] is NSNull && facts["selectedPredecessor"] is NSNull)
            #expect(header["cut"] as? String == "1")
            // No receiver receipt or old local archive has been supplied.
        }
    }
}
