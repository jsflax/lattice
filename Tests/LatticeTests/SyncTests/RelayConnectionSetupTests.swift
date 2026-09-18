import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum SetupCaseError: Error { case timedOut, ended, injectedWrite }

private final class SetupSignal<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation
    private let latest = NIOLockedValueBox<Value?>(nil)
    init() {
        let pair = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingOldest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send(_ value: Value) {
        latest.withLockedValue { $0 = value }
        continuation.yield(value); continuation.finish()
    }
    func wait() async throws -> Value {
        if let value = latest.withLockedValue({ $0 }) { return value }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { [stream] in
                for await value in stream { return value }
                throw SetupCaseError.ended
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw SetupCaseError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SetupCaseError.ended }
            return value
        }
    }
}

/// A config call may arrive before the client upgrade callback. Remember the
/// close request without a task; installing the socket performs it on NIO.
private final class SetupClient: @unchecked Sendable {
    private struct State { var socket: WebSocket?; var shouldClose = false }
    private let state = NIOLockedValueBox(State())
    func install(_ socket: WebSocket) {
        let close = state.withLockedValue { state in
            state.socket = socket; return state.shouldClose
        }
        if close { socket.close(promise: nil) }
    }
    func close() {
        let socket = state.withLockedValue { state in
            state.shouldClose = true; return state.socket
        }
        socket?.close(promise: nil)
    }
}

private final class SetupCase: @unchecked Sendable {
    struct Facts {
        var configCalls = 0
        var heldConfigCalls = 0
        var nativeGateTimedOut = false
        var finishedCount = 0
        var closedCount = 0
        var kinds: [String] = []
        var sentAuditIDs: [[String]] = []
        var preparedCatchUpIDs: [[String]] = []
    }
    let facts = NIOLockedValueBox(Facts())
    let nativeGate = DispatchSemaphore(value: 0)
    let client = SetupClient()
    let connected = SetupSignal<Result<WebSocket, any Error>>()
    let finished = SetupSignal<Bool>()
    let closed = SetupSignal<Bool>()
    let collector = PushFrameCollector()
    let holdConfigCall: Int?
    let failWrite: Int?
    init(holdConfigCall: Int? = nil, failWrite: Int? = nil) {
        self.holdConfigCall = holdConfigCall; self.failWrite = failWrite
    }
    func configure(_ url: URL) -> Lattice.Configuration {
        let number = facts.withLockedValue { $0.configCalls += 1; return $0.configCalls }
        if number == holdConfigCall {
            facts.withLockedValue { $0.heldConfigCalls += 1 }
            client.close()
            // The SERVER's close callback releases this IO worker directly.
            // No cooperative test continuation is needed to open the gate.
            let released = nativeGate.wait(timeout: .now() + 5) == .success
            facts.withLockedValue { $0.nativeGateTimedOut = !released }
        }
        return .init(fileURL: url)
    }
    func send(_ socket: WebSocket, _ bytes: Data, _ promise: EventLoopPromise<Void>) {
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let kind = object?["kind"] as? String ?? "invalid"
        let ids = (object?["auditLog"] as? [[String: Any]] ?? []).compactMap { $0["globalId"] as? String }
        let number = facts.withLockedValue { facts in
            facts.kinds.append(kind)
            if kind == "auditLog" { facts.sentAuditIDs.append(ids.map { $0.lowercased() }) }
            return facts.kinds.count
        }
        if number == failWrite { promise.fail(SetupCaseError.injectedWrite) }
        else { socket.send(raw: bytes, opcode: .binary, promise: promise) }
    }
    func hooks() -> RelayIngressTestHooks {
        RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
            didFinishAsyncSetup: { [self] in
                facts.withLockedValue { $0.finishedCount += 1 }; finished.send(true)
            }, didCloseConnection: { [self] in
                facts.withLockedValue { $0.closedCount += 1 }
                nativeGate.signal(); closed.send(true)
            }, sendCatchUp: { [self] socket, bytes, promise in send(socket, bytes, promise) })
    }
}

/// This fixture never unlinks files beneath the unchanged unstructured apply
/// consumer. Its small, UUID-owned directory is retained until the test process
/// ends; socket/app/setup/subscription cleanup is still checked. These tests send
/// no uploads and create no checkpoint-governor registration.
private func withSetupCase(
    _ state: SetupCase, seedCount: Int = 0, lastEventID: UUID? = nil,
    body: @escaping (SyncRelayHandle, URL, [String], ACKPathRecorder) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "relay-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storeURL = directory.appending(path: "fixture.sqlite")
    var seedIDs: [String] = []
    if seedCount > 0 {
        let seed = try Lattice(isolation: nil, SimpleSyncObject.self, configuration: .init(fileURL: storeURL))
        defer { seed.close() }
        try seed.transaction {
            for index in 0..<seedCount { try seed.add(SimpleSyncObject(value: index, floatValue: 1)) }
        }
        seedIDs = Array(seed.eventsAfter(globalId: nil)).compactMap { $0.globalId?.uuidString.lowercased() }
        try #require(seedIDs.count == seedCount)
    }
    let hooks = state.hooks()
    RelayIngressTesting.install(hooks, for: directory)
    defer { RelayIngressTesting.remove(hooks, for: directory) }
    let recorder = ACKPathRecorder(testRunID: UUID(), retainLatestStages: true)
    let user = UUID()
    _ = try #require(recorder.registerConnection(id: user, role: .peer))
    ACKPathDiagnostics.install(recorder, for: directory)
    defer { ACKPathDiagnostics.remove(recorder, for: directory); _ = recorder.closeSnapshot(partial: false) }
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    let app = try await Application.make(environment)
    app.http.server.configuration.port = 0
    app.http.server.configuration.shutdownTimeout = .milliseconds(500)
    var attemptedConnect = false
    var shutdownStarted = false
    func shutdown() async throws {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        // Always release our held factory first, even after a failed assertion.
        state.nativeGate.signal(); state.client.close()
        var failure: (any Error)?
        if attemptedConnect {
            do { _ = try await state.finished.wait() }
            catch { failure = error }
        }
        do { try await app.asyncShutdown() }
        catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
    do {
        let pageProbe = ObserverSendBoundaryProbe(channelID: "fixture") { route, ids, _ in
            if route == .catchup {
                state.facts.withLockedValue { $0.preparedCatchUpIDs.append(ids.compactMap { $0?.uuidString.lowercased() }) }
            }
        }
        let push = SyncObserverPush(copying: .init(reconcileInterval: nil), sendBoundaryProbe: pageProbe)
        let handle = Lattice.configureSyncRelay(
            on: app.routes, path: ["sync"], for: [SimpleSyncObject.self], storageURL: directory,
            storeConfiguration: { state.configure($0) }, observerPush: push,
            channelExtractor: { _ in SyncChannel(id: "fixture", userId: user) })
        try await app.startup()
        let port = try #require(app.http.server.shared.localAddress?.port)
        var headers = HTTPHeaders(); headers.add(name: "X-Test-User", value: user.uuidString)
        let suffix = lastEventID.map { "?last-event-id=\($0.uuidString)" } ?? ""
        attemptedConnect = true
        WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync\(suffix)", headers: headers,
                          on: app.eventLoopGroup) { socket in
            state.collector.attach(socket)
            state.client.install(socket)
            state.connected.send(.success(socket))
        }.whenFailure { state.connected.send(.failure($0)) }
        _ = try await state.connected.wait().get()
        try await body(handle, storeURL, seedIDs, recorder)
        try await shutdown()
    } catch {
        let original = error
        do { try await shutdown() }
        catch { Issue.record("Relay setup fixture cleanup did not finish: \(error)") }
        throw original
    }
}

@Suite("Relay callback setup", .timeLimit(.minutes(1)))
struct RelayConnectionSetupTests {
    @Test(arguments: [1, 2])
    func closeDuringConnectionOrWatcherOpenDrainsWithoutActivation(heldCall: Int) async throws {
        let state = SetupCase(holdConfigCall: heldCall)
        try await withSetupCase(state) { handle, url, _, recorder in
            _ = try await state.closed.wait()
            _ = try await state.finished.wait()
            let facts = state.facts.withLockedValue { $0 }
            #expect(facts.heldConfigCalls == 1)
            #expect(!facts.nativeGateTimedOut)
            #expect(facts.configCalls == heldCall)
            #expect(facts.finishedCount == 1)
            #expect(facts.closedCount == 1)
            let count = await handle.connectionCount(channelId: "fixture")
            #expect(count == 0)
            let group = await handle.pushManager?.hasGroup(forFile: url)
            #expect(group == false)
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(!snapshot.records.contains { $0.stage == .watchActivated })
        }
    }

    @Test func failedSecondCatchUpWriteDoesNotActivateOrReadAnotherPage() async throws {
        let state = SetupCase(failWrite: 2)
        try await withSetupCase(state, seedCount: 2505) { handle, url, ids, recorder in
            _ = try await state.finished.wait()
            _ = try await state.closed.wait()
            let facts = state.facts.withLockedValue { $0 }
            #expect(facts.kinds == ["auditLog", "auditLog"])
            #expect(facts.sentAuditIDs.map(\.count) == [1000, 1000])
            #expect(facts.sentAuditIDs.flatMap { $0 } == Array(ids.prefix(2000)))
            #expect(facts.preparedCatchUpIDs == facts.sentAuditIDs)
            #expect(facts.finishedCount == 1)
            let group = await handle.pushManager?.hasGroup(forFile: url)
            #expect(group == false)
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.records.filter { $0.stage == .catchUpSendReturn }.count == 1)
            #expect(!snapshot.records.contains { $0.stage == .watchActivated })
            // The failed second frame was never handed to the transport.
            let arrived = await state.collector.wait { $0.receivedGlobalIds.count == 1000 }
            #expect(arrived)
            #expect(state.collector.receivedGlobalIds == Array(ids.prefix(1000)))
        }
    }

    @Test func unknownFloorResetPrecedesReplayAndActivation() async throws {
        let state = SetupCase()
        try await withSetupCase(state, seedCount: 3, lastEventID: UUID()) { handle, url, ids, recorder in
            _ = try await state.finished.wait()
            let arrived = await state.collector.wait { $0.receivedGlobalIds.count == ids.count }
            #expect(arrived)
            let facts = state.facts.withLockedValue { $0 }
            #expect(facts.kinds == ["floorReset", "auditLog"])
            #expect(state.collector.kinds.prefix(2).elementsEqual(["floorReset", "auditLog"]))
            #expect(state.collector.receivedGlobalIds == ids)
            let subscribers = await handle.pushManager?.subscriberCount(forFile: url)
            #expect(subscribers == 1)
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.records.filter { $0.stage == .watchActivated }.count == 1)
            #expect(facts.finishedCount == 1)
        }
    }
}
