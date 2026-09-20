import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum SetupCaseError: Error { case timedOut, ended, injectedWrite }
private let setupClientFrameLimit = 1 << 20

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
        var sentFrameBytes: [Int] = []
        var injectedWriteFailures = 0
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
    let stages: SyncTestStageLog
    private struct DiagnosticState {
        var frozen = false
        var recorderCreated = false
        var retainedACK: ACKPathRecorder.Snapshot?
        var ackEmitted = false
    }
    private let diagnostic = NIOLockedValueBox(DiagnosticState())
    init(holdConfigCall: Int? = nil, failWrite: Int? = nil) {
        self.holdConfigCall = holdConfigCall; self.failWrite = failWrite
        stages = SyncTestStageLog(label: "relay-setup-held-\(holdConfigCall ?? 0)-write-\(failWrite ?? 0)",
                                  store: "fixture")
    }
    func recorderCreated() {
        diagnostic.withLockedValue { $0.recorderCreated = true }
        stages.record("ack_recorder_created")
    }
    // The unchanged assertion owns closeSnapshot. Cancellation never closes
    // it: retaining its result preserves both that oracle and its real cutoff.
    func retainACK(_ snapshot: ACKPathRecorder.Snapshot?) {
        guard let snapshot else { return }
        diagnostic.withLockedValue {
            if $0.retainedACK == nil { $0.retainedACK = snapshot }
        }
        stages.record("ack_snapshot_retained", count: snapshot.records.count,
                      detail: "cutoff_ns=\(snapshot.cutoffUptime) partial=\(snapshot.partial)")
        emitACKIfReady()
    }
    func freeze(reason: StaticString) {
        let ackStatus: String? = diagnostic.withLockedValue { state in
            guard !state.frozen else { return nil }
            state.frozen = true
            if state.retainedACK != nil { return "retained_assertion_or_unwind_cutoff" }
            return state.recorderCreated ? "not_yet_closed" : "unavailable_recorder_not_created"
        }
        guard let ackStatus else { return }
        // Fixed scalar summary only. Existing assertion facts retain IDs and
        // wire kinds, but neither those arrays nor payloads enter this log.
        let summary = facts.withLockedValue {
            "config=\($0.configCalls) held=\($0.heldConfigCalls) gate_timed_out=\($0.nativeGateTimedOut)"
            + " finished=\($0.finishedCount) closed=\($0.closedCount) sends=\($0.kinds.count)"
            + " injected_failures=\($0.injectedWriteFailures) prepared_pages=\($0.preparedCatchUpIDs.count)"
        }
        stages.record("facts_at_cutoff", detail: summary)
        stages.record("ack_snapshot_status", detail: ackStatus)
        stages.emit(reason: reason)
        emitACKIfReady()
    }
    private func emitACKIfReady() {
        let snapshot: ACKPathRecorder.Snapshot? = diagnostic.withLockedValue { state in
            guard state.frozen, !state.ackEmitted, let snapshot = state.retainedACK else { return nil }
            state.ackEmitted = true
            return snapshot
        }
        // This may arrive after a cancellation phase snapshot. It carries its
        // own cutoff, and the same test ID, rather than pretending both froze
        // together. There is no empty/success substitute if it is unavailable.
        if let snapshot { ACKPathRecorder.emitSnapshot(snapshot) }
    }
    func configure(_ url: URL) -> Lattice.Configuration {
        let number = facts.withLockedValue { $0.configCalls += 1; return $0.configCalls }
        stages.record("config_entered", phase: number)
        if number == holdConfigCall {
            facts.withLockedValue { $0.heldConfigCalls += 1 }
            stages.record("config_client_close_requested", phase: number)
            client.close()
            // The SERVER's close callback releases this IO worker directly.
            // No cooperative test continuation is needed to open the gate.
            stages.record("config_gate_wait_begin", phase: number)
            let released = nativeGate.wait(timeout: .now() + 5) == .success
            facts.withLockedValue { $0.nativeGateTimedOut = !released }
            stages.record("config_gate_wait_end", phase: number, detail: "released=\(released)")
        }
        stages.record("config_returning", phase: number)
        return .init(fileURL: url)
    }
    func send(_ socket: WebSocket, _ bytes: Data, _ promise: EventLoopPromise<Void>) {
        stages.record("catchup_send_entered", count: bytes.count)
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let kind = object?["kind"] as? String ?? "invalid"
        let ids = (object?["auditLog"] as? [[String: Any]] ?? []).compactMap { $0["globalId"] as? String }
        let number = facts.withLockedValue { facts in
            facts.kinds.append(kind)
            facts.sentFrameBytes.append(bytes.count)
            if kind == "auditLog" { facts.sentAuditIDs.append(ids.map { $0.lowercased() }) }
            return facts.kinds.count
        }
        if number == failWrite {
            facts.withLockedValue { $0.injectedWriteFailures += 1 }
            stages.record("catchup_send_injected_failure", phase: number, count: bytes.count)
            promise.fail(SetupCaseError.injectedWrite)
        }
        else { socket.send(raw: bytes, opcode: .binary, promise: promise) }
        stages.record("catchup_send_returned", phase: number, count: bytes.count)
    }
    func hooks() -> RelayIngressTestHooks {
        RelayIngressTestHooks(beforeAsyncSetup: { [self] in stages.record("async_setup_entered") },
            didBufferFrame: { [self] bytes in stages.record("ingress_buffered", count: bytes) },
            didFinishAsyncSetup: { [self] in
                stages.record("async_setup_finished")
                facts.withLockedValue { $0.finishedCount += 1 }; finished.send(true)
            }, didCloseConnection: { [self] in
                stages.record("server_connection_closed")
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
    state.stages.record("case_entered", count: seedCount)
    do {
        try await withTaskCancellationHandler {
            try await runSetupCase(state, seedCount: seedCount, lastEventID: lastEventID, body: body)
        } onCancel: {
            state.stages.record("case_cancelled")
            state.freeze(reason: "setup_case_cancelled")
        }
    } catch {
        state.stages.record("case_threw")
        state.freeze(reason: "setup_case_failed")
        throw error
    }
    // Completion is a control-flow boundary, not an assertion/pass verdict.
    state.freeze(reason: "setup_case_finished")
}

private func runSetupCase(
    _ state: SetupCase, seedCount: Int, lastEventID: UUID?,
    body: @escaping (SyncRelayHandle, URL, [String], ACKPathRecorder) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "relay-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    state.stages.record("fixture_created", detail: "directory=\(directory.lastPathComponent)")
    let storeURL = directory.appending(path: "fixture.sqlite")
    var seedIDs: [String] = []
    if seedCount > 0 {
        state.stages.record("seed_open_begin")
        let seed = try Lattice(isolation: nil, SimpleSyncObject.self, configuration: .init(fileURL: storeURL))
        state.stages.record("seed_open_end")
        defer {
            state.stages.record("seed_close_begin")
            seed.close()
            state.stages.record("seed_close_end")
        }
        state.stages.record("seed_transaction_begin", count: seedCount)
        try seed.transaction {
            for index in 0..<seedCount { try seed.add(SimpleSyncObject(value: index, floatValue: 1)) }
        }
        state.stages.record("seed_transaction_end")
        state.stages.record("seed_ids_begin")
        seedIDs = Array(seed.eventsAfter(globalId: nil)).compactMap { $0.globalId?.uuidString.lowercased() }
        state.stages.record("seed_ids_end", count: seedIDs.count)
        try #require(seedIDs.count == seedCount)
    }
    let hooks = state.hooks()
    RelayIngressTesting.install(hooks, for: directory)
    defer { RelayIngressTesting.remove(hooks, for: directory) }
    let recorder = ACKPathRecorder(testRunID: state.stages.id, retainLatestStages: true)
    state.recorderCreated()
    let user = UUID()
    _ = try #require(recorder.registerConnection(id: user, role: .peer))
    ACKPathDiagnostics.install(recorder, for: directory)
    defer {
        ACKPathDiagnostics.remove(recorder, for: directory)
        state.retainACK(recorder.closeSnapshot(partial: false))
    }
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    state.stages.record("application_make_begin")
    let app = try await Application.make(environment)
    state.stages.record("application_make_end")
    app.http.server.configuration.port = 0
    app.http.server.configuration.shutdownTimeout = .milliseconds(500)
    var attemptedConnect = false
    var shutdownStarted = false
    func shutdown() async throws {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        state.stages.record("shutdown_begin")
        // Always release our held factory first, even after a failed assertion.
        state.nativeGate.signal(); state.client.close()
        var failure: (any Error)?
        if attemptedConnect {
            state.stages.record("shutdown_setup_wait_begin")
            do {
                _ = try await state.finished.wait()
                state.stages.record("shutdown_setup_wait_end")
            }
            catch {
                state.stages.record("shutdown_setup_wait_threw")
                state.freeze(reason: "setup_shutdown_failed")
                failure = error
            }
        }
        state.stages.record("application_shutdown_begin")
        do {
            try await app.asyncShutdown()
            state.stages.record("application_shutdown_end")
        }
        catch {
            state.stages.record("application_shutdown_threw")
            state.freeze(reason: "setup_shutdown_failed")
            if failure == nil { failure = error }
        }
        state.stages.record("shutdown_end")
        if let failure { throw failure }
    }
    do {
        let pageProbe = ObserverSendBoundaryProbe(channelID: "fixture") { route, ids, _ in
            if route == .catchup {
                state.stages.record("catchup_page_prepared", count: ids.count)
                state.facts.withLockedValue { $0.preparedCatchUpIDs.append(ids.compactMap { $0?.uuidString.lowercased() }) }
            }
        }
        let push = SyncObserverPush(copying: .init(reconcileInterval: nil), sendBoundaryProbe: pageProbe)
        state.stages.record("relay_configure_begin")
        let handle = Lattice.configureSyncRelay(
            on: app.routes, path: ["sync"], for: [SimpleSyncObject.self], storageURL: directory,
            storeConfiguration: { state.configure($0) }, observerPush: push,
            channelExtractor: { _ in SyncChannel(id: "fixture", userId: user) })
        state.stages.record("relay_configure_end")
        state.stages.record("application_startup_begin")
        try await app.startup()
        state.stages.record("application_startup_end")
        let port = try #require(app.http.server.shared.localAddress?.port)
        var headers = HTTPHeaders(); headers.add(name: "X-Test-User", value: user.uuidString)
        let suffix = lastEventID.map { "?last-event-id=\($0.uuidString)" } ?? ""
        attemptedConnect = true
        // A full 1000-entry catch-up page exceeds WebSocketKit's 16 KiB
        // client default. Admit this fixture's bounded page before injecting
        // the intended second-write failure.
        var clientConfiguration = WebSocketClient.Configuration()
        clientConfiguration.maxFrameSize = setupClientFrameLimit
        state.stages.record("connect_requested")
        WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync\(suffix)", headers: headers,
                          configuration: clientConfiguration, on: app.eventLoopGroup) { socket in
            state.stages.record("client_upgraded")
            state.collector.attach(socket)
            state.client.install(socket)
            state.connected.send(.success(socket))
        }.whenFailure {
            state.stages.record("connect_failed")
            state.connected.send(.failure($0))
        }
        state.stages.record("connected_wait_begin")
        _ = try await state.connected.wait().get()
        state.stages.record("connected_wait_end")
        state.stages.record("body_begin")
        try await body(handle, storeURL, seedIDs, recorder)
        state.stages.record("body_end")
        try await shutdown()
    } catch {
        let original = error
        state.stages.record("body_or_setup_threw")
        state.freeze(reason: "setup_case_failed")
        // The body has unwound: no assertion can still own a future cutoff.
        // If it already closed the recorder, retainACK kept that exact result.
        state.retainACK(recorder.closeSnapshot(partial: true))
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
            state.stages.record("closed_wait_begin")
            _ = try await state.closed.wait()
            state.stages.record("closed_wait_end")
            state.stages.record("finished_wait_begin")
            _ = try await state.finished.wait()
            state.stages.record("finished_wait_end")
            let facts = state.facts.withLockedValue { $0 }
            #expect(facts.heldConfigCalls == 1)
            #expect(!facts.nativeGateTimedOut)
            #expect(facts.configCalls == heldCall)
            #expect(facts.finishedCount == 1)
            #expect(facts.closedCount == 1)
            state.stages.record("connection_count_begin")
            let count = await handle.connectionCount(channelId: "fixture")
            state.stages.record("connection_count_end", count: count)
            #expect(count == 0)
            state.stages.record("has_group_begin")
            let group = await handle.pushManager?.hasGroup(forFile: url)
            state.stages.record("has_group_end")
            #expect(group == false)
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            state.retainACK(snapshot)
            #expect(!snapshot.records.contains { $0.stage == .watchActivated })
        }
    }

    @Test func failedSecondCatchUpWriteDoesNotActivateOrReadAnotherPage() async throws {
        let state = SetupCase(failWrite: 2)
        try await withSetupCase(state, seedCount: 2505) { handle, url, ids, recorder in
            state.stages.record("finished_wait_begin")
            _ = try await state.finished.wait()
            state.stages.record("finished_wait_end")
            state.stages.record("closed_wait_begin")
            _ = try await state.closed.wait()
            state.stages.record("closed_wait_end")
            let facts = state.facts.withLockedValue { $0 }
            #expect(facts.kinds == ["auditLog", "auditLog"])
            #expect(facts.injectedWriteFailures == 1)
            #expect(facts.sentFrameBytes.count == 2)
            #expect(facts.sentFrameBytes.allSatisfy { $0 > 16 * 1024 && $0 <= setupClientFrameLimit })
            #expect(facts.sentAuditIDs.map(\.count) == [1000, 1000])
            #expect(facts.sentAuditIDs.flatMap { $0 } == Array(ids.prefix(2000)))
            #expect(facts.preparedCatchUpIDs == facts.sentAuditIDs)
            #expect(facts.finishedCount == 1)
            state.stages.record("has_group_begin")
            let group = await handle.pushManager?.hasGroup(forFile: url)
            state.stages.record("has_group_end")
            #expect(group == false)
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            state.retainACK(snapshot)
            #expect(snapshot.records.filter { $0.stage == .catchUpSendReturn }.count == 1)
            #expect(!snapshot.records.contains { $0.stage == .watchActivated })
            // The failed second frame was never handed to the transport.
            state.stages.record("collector_wait_begin")
            let arrived = await state.collector.wait { $0.receivedGlobalIds.count == 1000 }
            state.stages.record("collector_wait_end")
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
            state.retainACK(snapshot)
            #expect(snapshot.records.filter { $0.stage == .watchActivated }.count == 1)
            #expect(facts.finishedCount == 1)
        }
    }
}
