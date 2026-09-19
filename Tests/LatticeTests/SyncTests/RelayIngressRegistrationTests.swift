import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum IngressWaitError: Error { case timedOut, ended, unconfirmedApply }

/// One retained signal and one waiter. Already-delivered values do not need
/// task-group admission. Pending or already-cancelled waits retain the original
/// timeout race; no event loop or cooperative executor thread is parked.
private final class IngressSignal<Value: Sendable>: Sendable {
    private struct State {
        var sent = false
        var waited = false
        var buffered: Value?
    }
    private enum Admission { case ready(Value), pending, ended }
    private let state = NIOLockedValueBox(State())
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() {
        let pair = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingOldest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ value: Value) {
        let first = state.withLockedValue { state in
            guard !state.sent else { return false }
            state.sent = true
            if !state.waited { state.buffered = .some(value) }
            return true
        }
        guard first else { return }
        continuation.yield(value)
        continuation.finish()
    }

    // The optional callback is used only by the helper regressions below. It
    // observes slow-path admission off-lock; the ingress fixture never sets it.
    func wait(beforeSlowWait: (@Sendable () -> Void)? = nil) async throws -> Value {
        let admission: Admission = state.withLockedValue { state in
            guard !state.waited else { return .ended }
            state.waited = true
            if let value = state.buffered {
                state.buffered = nil
                return .ready(value)
            }
            return .pending
        }
        switch admission {
        case .ready(let value) where !Task.isCancelled:
            return value
        case .ended:
            throw IngressWaitError.ended
        default:
            break
        }
        // Keep cancellation compatible with the former stream/group path,
        // including cleanup waits made after the test task was cancelled.
        beforeSlowWait?()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { [stream] in
                for await value in stream { return value }
                throw IngressWaitError.ended
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw IngressWaitError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw IngressWaitError.ended }
            return value
        }
    }
}


@Suite("Relay ingress signals", .timeLimit(.minutes(1)))
struct RelayIngressSignalTests {
    @Test func bufferedSignalSkipsTaskGroupAndIsConsumedOnce() async throws {
        let signal = IngressSignal<Int?>()
        let slowAdmissions = NIOLockedValueBox(0)
        signal.send(nil)
        signal.send(99) // The first value wins, including an optional nil.
        let value = try await signal.wait {
            slowAdmissions.withLockedValue { $0 += 1 }
        }
        #expect(value == nil)
        #expect(slowAdmissions.withLockedValue { $0 } == 0)
        do {
            _ = try await signal.wait {
                slowAdmissions.withLockedValue { $0 += 1 }
            }
            Issue.record("one-shot signal was consumed twice")
        } catch IngressWaitError.ended {
            // Expected: returning the buffered value consumed this signal.
        }
        #expect(slowAdmissions.withLockedValue { $0 } == 0)
    }

    @Test func pendingSignalKeepsOriginalRace() async throws {
        let signal = IngressSignal<Int>()
        let slowAdmissions = NIOLockedValueBox(0)
        let value = try await signal.wait {
            slowAdmissions.withLockedValue { $0 += 1 }
            signal.send(23) // Publish after pending admission, before children run.
        }
        #expect(value == 23)
        #expect(slowAdmissions.withLockedValue { $0 } == 1)
    }

    @Test func alreadyCancelledBufferedWaitUsesOriginalPath() async {
        let signal = IngressSignal<Int>()
        let slowAdmissions = NIOLockedValueBox(0)
        signal.send(77)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            guard Task.isCancelled else { return false }
            do {
                let value = try await signal.wait {
                    slowAdmissions.withLockedValue { $0 += 1 }
                }
                // The original group can race buffered delivery with cancellation.
                return value == 77
            } catch is CancellationError {
                return true
            } catch IngressWaitError.ended {
                return true
            } catch {
                return false // A timeout or unrelated failure is not accepted.
            }
        }
        #expect(await task.value)
        #expect(slowAdmissions.withLockedValue { $0 } == 1)
    }
}

private final class IngressSetupGate: Sendable {
    private struct State {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = NIOLockedValueBox(State())
    let entered = IngressSignal<Bool>()

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLockedValue { state in
                if state.released { return true }
                precondition(state.continuation == nil, "one setup task per test connection")
                state.continuation = continuation
                return false
            }
            entered.send(true)
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = state.withLockedValue { state in
            state.released = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    var isReleased: Bool { state.withLockedValue { $0.released } }
}

private struct IngressTestCounts: Sendable {
    var bufferedFrames = 0
    var bufferedBytes = 0
    var bufferedAfterRelease = false
    var extractorCalls = 0
    var ackFrames = 0
    var matchingAckIDs = 0
    var nackOrRejectedFrames = 0
}


/// Test-only bounded scalar phases. Cancellation records immediately; the ACK
/// recorder is closed only after assertions finish or their throwing path leaves.
/// This preserves the original success oracle if cancellation races cleanup.
private final class IngressPhaseDiagnostics: Sendable {
    enum Phase: String, Codable, Sendable {
        case testEntered, donorOpenBegin, donorOpenEnd, donorSeedBegin, donorSeedEnd
        case applicationMakeBegin, applicationMakeEnd, startupBegin, startupEnd
        case connectRequested, clientUpgraded, sendCompleted, connectFailed
        case connectedWaitBegin, connectedWaitEnd, sentWaitBegin, sentWaitEnd
        case setupGateEntered, setupGateWaitBegin, setupGateWaitEnd
        case bufferReceived, bufferWaitBegin, bufferWaitEnd, gateReleased
        case ackReceived, ackWaitBegin, ackWaitEnd, assertionSnapshotCaptured
        case persistedOpenBegin, persistedOpenEnd, persistedChecksEnd, socketCloseRequested
        case setupFinished, cancelled, failureCaught, shutdownBegin
        case setupDrainBegin, setupDrainEnd, setupDrainFailed
        case applicationShutdownBegin, applicationShutdownEnd, applicationShutdownFailed
        case governorUnregistered, shutdownEnd, cleanupFailed, testBodyReturned
    }
    private struct Event: Codable, Sendable { let phase: Phase; let uptime: UInt64 }
    private struct Snapshot: Encodable, Sendable {
        let schema = "lattice.ingress-test-phases/1"
        let test: UUID
        let reason: String
        let cutoffUptime: UInt64
        let cancelled: Bool
        let failed: Bool
        let dropped: Int
        let events: [Event]
    }
    private struct State {
        var events: [Event] = []
        var dropped = 0
        var cancelled = false
        var finalEmitted = false
        var failed = false
        var ackEmitted = false
        var recorder: ACKPathRecorder?
        var retainedSnapshot: ACKPathRecorder.Snapshot?
    }
    let testID = UUID()
    private let enabled = ProcessInfo.processInfo.environment["LATTICE_ACK_PATH_DIAGNOSTICS"] == "1"
    private let state = NIOLockedValueBox(State())

    func attach(_ recorder: ACKPathRecorder) {
        guard enabled else { return }
        state.withLockedValue { $0.recorder = recorder }
    }
    func mark(_ phase: Phase) {
        guard enabled else { return }
        let event = Event(phase: phase, uptime: DispatchTime.now().uptimeNanoseconds)
        state.withLockedValue { state in
            if state.events.count < 64 { state.events.append(event) }
            else if state.dropped < Int.max { state.dropped += 1 }
        }
    }
    func assertionsCaptured(_ snapshot: ACKPathRecorder.Snapshot) {
        guard enabled else { return }
        state.withLockedValue { $0.retainedSnapshot = snapshot }
        mark(.assertionSnapshotCaptured)
    }
    func recorderClosing(_ snapshot: ACKPathRecorder.Snapshot?) {
        guard enabled, let snapshot else { return }
        state.withLockedValue { $0.retainedSnapshot = snapshot }
    }
    func cancelled() {
        guard enabled else { return }
        let first = state.withLockedValue { state in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        guard first else { return }
        mark(.cancelled)
        // This is a scalar cancellation cutoff, NOT an ACK snapshot cutoff.
        emitPhases(reason: "cancellation")
    }
    func failed() {
        guard enabled else { return }
        let first = state.withLockedValue { state in
            guard !state.failed else { return false }
            state.failed = true
            return true
        }
        guard first else { return }
        mark(.failureCaught)
        emitACKOnce()
    }
    func finish() {
        guard enabled else { return }
        mark(.testBodyReturned)
        let shouldEmit = state.withLockedValue { state in
            guard (state.cancelled || state.failed), !state.finalEmitted else { return false }
            state.finalEmitted = true
            return true
        }
        guard shouldEmit else { return }
        emitACKOnce()
        emitPhases(reason: "final")
    }
    private func emitACKOnce() {
        let captured = state.withLockedValue { state -> (ACKPathRecorder?, ACKPathRecorder.Snapshot?)? in
            guard !state.ackEmitted else { return nil }
            state.ackEmitted = true
            return (state.recorder, state.retainedSnapshot)
        }
        guard let captured else { return }
        if let snapshot = captured.1 ?? captured.0?.closeSnapshot(partial: true) {
            ACKPathRecorder.emitSnapshot(snapshot)
        } else {
            print("INGRESS_PHASE_DIAGNOSTIC ack_unavailable test=\(testID)")
        }
    }
    private func emitPhases(reason: String) {
        let snapshot = state.withLockedValue {
            Snapshot(test: testID, reason: reason, cutoffUptime: DispatchTime.now().uptimeNanoseconds,
                     cancelled: $0.cancelled, failed: $0.failed, dropped: $0.dropped,
                     events: $0.events)
        }
        // Encode and print only after dropping the state lock. At most 64
        // fixed-enum events; two emissions (cancellation and final), <=16KiB each.
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 16 * 1024 else {
            print("INGRESS_PHASE_DIAGNOSTIC unavailable test=\(testID)")
            return
        }
        print("INGRESS_PHASE_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
    }
}

@Suite("Relay ingress registration", .timeLimit(.minutes(1)))
struct RelayIngressRegistrationTests {
    @Test func uploadAtUpgradeBuffersBeforeAsyncSetupStarts() async throws {
        let diagnostics = IngressPhaseDiagnostics()
        try await withTaskCancellationHandler {
        diagnostics.mark(.testEntered)
        defer { diagnostics.finish() }
        do {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relay-ingress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mayRemoveDirectory = true
        defer {
            if mayRemoveDirectory { try? FileManager.default.removeItem(at: directory) }
        }
        let storageURL = directory.appending(path: "relay")
        diagnostics.mark(.donorOpenBegin)
        let donor = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: directory.appending(path: "donor.sqlite")))
        diagnostics.mark(.donorOpenEnd)
        defer { donor.close() }
        var verifiedStore: Lattice?
        defer { verifiedStore?.close() }
        diagnostics.mark(.donorSeedBegin)
        try donor.add(SimpleSyncObject(value: 731, floatValue: 1))
        let entries = Array(donor.eventsAfter(globalId: nil))
        try #require(entries.count == 1)
        let auditID = try #require(entries.first?.globalId)
        let frame = Array(try JSONEncoder().encode(ServerSentEvent.auditLog(entries)))
        diagnostics.mark(.donorSeedEnd)

        let gate = IngressSetupGate()
        defer { gate.release() }
        let counts = NIOLockedValueBox(IngressTestCounts())
        let buffered = IngressSignal<Bool>()
        let setupFinished = IngressSignal<Bool>()
        let acknowledged = IngressSignal<Bool>()
        let sent = IngressSignal<Result<Void, any Error>>()
        let connected = IngressSignal<Result<WebSocket, any Error>>()
        let hooks = RelayIngressTestHooks(
            beforeAsyncSetup: { diagnostics.mark(.setupGateEntered); await gate.wait() },
            didBufferFrame: { bytes in
                let released = gate.isReleased
                counts.withLockedValue {
                    $0.bufferedFrames += 1
                    $0.bufferedBytes += bytes
                    $0.bufferedAfterRelease = $0.bufferedAfterRelease || released
                }
                diagnostics.mark(.bufferReceived)
                buffered.send(true)
            },
            didFinishAsyncSetup: { diagnostics.mark(.setupFinished); setupFinished.send(true) })
        RelayIngressTesting.install(hooks, for: storageURL)
        defer { RelayIngressTesting.remove(hooks, for: storageURL) }

        let recorder = ACKPathRecorder(testRunID: diagnostics.testID)
        diagnostics.attach(recorder)
        let user = UUID()
        let probe = try #require(recorder.registerConnection(id: user, role: .uploader))
        probe.selectWarmID(auditID, entryCount: entries.count)
        ACKPathDiagnostics.install(recorder, for: storageURL)
        defer {
            ACKPathDiagnostics.remove(recorder, for: storageURL)
            diagnostics.recorderClosing(recorder.closeSnapshot(partial: true))
        }

        var environment = try Environment.detect()
        environment.arguments = ["vapor"]
        diagnostics.mark(.applicationMakeBegin)
        let app = try await Application.make(environment)
        diagnostics.mark(.applicationMakeEnd)
        app.http.server.configuration.port = 0
        var attemptedConnect = false
        func shutdown() async throws {
            diagnostics.mark(.shutdownBegin)
            gate.release()
            var drainFailure: (any Error)?
            if attemptedConnect {
                diagnostics.mark(.setupDrainBegin)
                do { _ = try await setupFinished.wait(); diagnostics.mark(.setupDrainEnd) }
                catch { diagnostics.mark(.setupDrainFailed); drainFailure = error }
            }
            // App shutdown must still be attempted if the setup-drain bound
            // expires. Never unlink this fixture beneath an unconfirmed task.
            var shutdownFailure: (any Error)?
            diagnostics.mark(.applicationShutdownBegin)
            do { try await app.asyncShutdown(); diagnostics.mark(.applicationShutdownEnd) }
            catch { diagnostics.mark(.applicationShutdownFailed); shutdownFailure = error }
            let settled = counts.withLockedValue { $0.bufferedFrames == 0 || $0.matchingAckIDs > 0 }
            if drainFailure == nil, shutdownFailure == nil, settled {
                RelayCheckpointGovernor.shared.unregister(
                    storePath: storageURL.appending(path: "ingress.sqlite").path)
                diagnostics.mark(.governorUnregistered)
                mayRemoveDirectory = true
            }
            if let drainFailure { throw drainFailure }
            if let shutdownFailure { throw shutdownFailure }
            // The separate apply consumer is not the setup Task. A received
            // ACK proves this test's one apply reached past governor registration;
            // without it, do not unlink or race a late governor registration.
            if !settled { throw IngressWaitError.unconfirmedApply }
            diagnostics.mark(.shutdownEnd)
        }
        do {
            Lattice.configureSyncRelay(
                on: app.routes, path: ["sync"], for: [SimpleSyncObject.self], storageURL: storageURL,
                channelExtractor: { _ in
                    counts.withLockedValue { $0.extractorCalls += 1 }
                    return SyncChannel(id: "ingress", userId: user)
                })
            diagnostics.mark(.startupBegin)
            try await app.startup()
            diagnostics.mark(.startupEnd)
            let port = try #require(app.http.server.shared.localAddress?.port)
            var headers = HTTPHeaders()
            headers.add(name: "X-Test-User", value: user.uuidString)
            attemptedConnect = true
            mayRemoveDirectory = false
            diagnostics.mark(.connectRequested)
            WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync", headers: headers,
                              on: app.eventLoopGroup) { ws in
                diagnostics.mark(.clientUpgraded)
                ws.onBinary { _, buffer in
                    guard let root = (try? JSONSerialization.jsonObject(with: Data(buffer: buffer))) as? [String: Any],
                          let kind = root["kind"] as? String else { return }
                    if kind == "ack" {
                        let ids = (root["ack"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
                        let matches = ids.filter { $0 == auditID }.count
                        counts.withLockedValue {
                            $0.ackFrames += 1
                            $0.matchingAckIDs += matches
                        }
                        if matches > 0 { diagnostics.mark(.ackReceived); acknowledged.send(true) }
                    } else if kind == "nack" || kind == "rejected" {
                        counts.withLockedValue { $0.nackOrRejectedFrames += 1 }
                    }
                }
                // The first upload is sent INSIDE the client's synchronous
                // upgrade callback, before any continuation resumes test code.
                let promise = ws.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { diagnostics.mark(.sendCompleted); sent.send($0) }
                ws.send(frame, promise: promise)
                connected.send(.success(ws))
            }.whenFailure { error in
                diagnostics.mark(.connectFailed)
                connected.send(.failure(error))
                sent.send(.failure(error))
            }

            diagnostics.mark(.connectedWaitBegin)
            let socket = try await connected.wait().get()
            diagnostics.mark(.connectedWaitEnd)
            diagnostics.mark(.sentWaitBegin)
            try await sent.wait().get()
            diagnostics.mark(.sentWaitEnd)
            diagnostics.mark(.setupGateWaitBegin)
            _ = try await gate.entered.wait()
            diagnostics.mark(.setupGateWaitEnd)
            // Waiting only for a suspended channelExtractor would let the
            // former async-upgrade ordering pass. This gate is before the
            // ENTIRE async setup body, while ingress must already be live.
            diagnostics.mark(.bufferWaitBegin)
            _ = try await buffered.wait()
            diagnostics.mark(.bufferWaitEnd)
            let beforeRelease = counts.withLockedValue { $0 }
            #expect(!gate.isReleased)
            #expect(beforeRelease.bufferedFrames == 1)
            #expect(beforeRelease.bufferedBytes == frame.count)
            #expect(!beforeRelease.bufferedAfterRelease)
            #expect(beforeRelease.extractorCalls == 0)
            #expect(beforeRelease.ackFrames == 0)

            gate.release()
            diagnostics.mark(.gateReleased)
            diagnostics.mark(.ackWaitBegin)
            _ = try await acknowledged.wait()
            diagnostics.mark(.ackWaitEnd)
            let afterAck = counts.withLockedValue { $0 }
            #expect(afterAck.ackFrames == 1)
            #expect(afterAck.matchingAckIDs == 1)
            #expect(afterAck.nackOrRejectedFrames == 0)
            #expect(afterAck.extractorCalls == 1)

            let capture = try #require(recorder.closeSnapshot(partial: false))
            diagnostics.assertionsCaptured(capture)
            #expect(capture.dropped == 0)
            #expect(capture.records.filter { $0.stage == .ingressBuffered }.count == 1)
            #expect(capture.records.filter { $0.stage == .frameParsed && $0.warmMatch == true }.count == 1)
            // Send-begin precedes client receipt even when send-return is
            // preempted on another thread; do not require the later marker.
            #expect(capture.records.filter { $0.stage == .ackSendBegin }.count == 1)

            diagnostics.mark(.persistedOpenBegin)
            let persisted = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: storageURL.appending(path: "ingress.sqlite")))
            diagnostics.mark(.persistedOpenEnd)
            verifiedStore = persisted
            #expect(persisted.objects(SimpleSyncObject.self).count == 1)
            #expect(persisted.objects(SimpleSyncObject.self).first?.value == 731)
            #expect(persisted.objects(AuditLog.self).where { $0.globalId == auditID }.count == 1)
            diagnostics.mark(.persistedChecksEnd)
            // Start close without waiting on a peer handshake. Application
            // shutdown below owns connection cleanup and is awaited.
            diagnostics.mark(.socketCloseRequested)
            socket.close(promise: nil)
        } catch let failure {
            diagnostics.failed()
            // A timeout/assertion/connect error must release setup BEFORE
            // server shutdown waits for its request/socket tasks to finish.
            do { try await shutdown() }
            catch { diagnostics.mark(.cleanupFailed); Issue.record("relay ingress cleanup did not drain: \(error); fixture retained") }
            throw failure
        }
        try await shutdown()
        } catch {
            diagnostics.failed()
            throw error
        }
        } onCancel: {
            diagnostics.cancelled()
        }
    }
}
