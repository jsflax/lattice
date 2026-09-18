import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum IngressWaitError: Error { case timedOut, ended, unconfirmedApply }

/// One retained signal and one waiter. The timeout cancels AsyncStream.next;
/// it never parks an event loop or a cooperative executor thread.
private final class IngressSignal<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() {
        let pair = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingOldest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ value: Value) {
        continuation.yield(value)
        continuation.finish()
    }

    func wait() async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
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

@Suite("Relay ingress registration", .timeLimit(.minutes(1)))
struct RelayIngressRegistrationTests {
    @Test func uploadAtUpgradeBuffersBeforeAsyncSetupStarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relay-ingress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mayRemoveDirectory = true
        defer {
            if mayRemoveDirectory { try? FileManager.default.removeItem(at: directory) }
        }
        let storageURL = directory.appending(path: "relay")
        let donor = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: directory.appending(path: "donor.sqlite")))
        defer { donor.close() }
        var verifiedStore: Lattice?
        defer { verifiedStore?.close() }
        try donor.add(SimpleSyncObject(value: 731, floatValue: 1))
        let entries = Array(donor.eventsAfter(globalId: nil))
        try #require(entries.count == 1)
        let auditID = try #require(entries.first?.globalId)
        let frame = Array(try JSONEncoder().encode(ServerSentEvent.auditLog(entries)))

        let gate = IngressSetupGate()
        defer { gate.release() }
        let counts = NIOLockedValueBox(IngressTestCounts())
        let buffered = IngressSignal<Bool>()
        let setupFinished = IngressSignal<Bool>()
        let acknowledged = IngressSignal<Bool>()
        let sent = IngressSignal<Result<Void, any Error>>()
        let connected = IngressSignal<Result<WebSocket, any Error>>()
        let hooks = RelayIngressTestHooks(
            beforeAsyncSetup: { await gate.wait() },
            didBufferFrame: { bytes in
                let released = gate.isReleased
                counts.withLockedValue {
                    $0.bufferedFrames += 1
                    $0.bufferedBytes += bytes
                    $0.bufferedAfterRelease = $0.bufferedAfterRelease || released
                }
                buffered.send(true)
            },
            didFinishAsyncSetup: { setupFinished.send(true) })
        RelayIngressTesting.install(hooks, for: storageURL)
        defer { RelayIngressTesting.remove(hooks, for: storageURL) }

        let recorder = ACKPathRecorder(testRunID: UUID())
        let user = UUID()
        let probe = try #require(recorder.registerConnection(id: user, role: .uploader))
        probe.selectWarmID(auditID, entryCount: entries.count)
        ACKPathDiagnostics.install(recorder, for: storageURL)
        defer {
            ACKPathDiagnostics.remove(recorder, for: storageURL)
            _ = recorder.closeSnapshot(partial: true)
        }

        var environment = try Environment.detect()
        environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.port = 0
        var attemptedConnect = false
        func shutdown() async throws {
            gate.release()
            var drainFailure: (any Error)?
            if attemptedConnect {
                do { _ = try await setupFinished.wait() }
                catch { drainFailure = error }
            }
            // App shutdown must still be attempted if the setup-drain bound
            // expires. Never unlink this fixture beneath an unconfirmed task.
            var shutdownFailure: (any Error)?
            do { try await app.asyncShutdown() }
            catch { shutdownFailure = error }
            let settled = counts.withLockedValue { $0.bufferedFrames == 0 || $0.matchingAckIDs > 0 }
            if drainFailure == nil, shutdownFailure == nil, settled {
                RelayCheckpointGovernor.shared.unregister(
                    storePath: storageURL.appending(path: "ingress.sqlite").path)
                mayRemoveDirectory = true
            }
            if let drainFailure { throw drainFailure }
            if let shutdownFailure { throw shutdownFailure }
            // The separate apply consumer is not the setup Task. A received
            // ACK proves this test's one apply reached past governor registration;
            // without it, do not unlink or race a late governor registration.
            if !settled { throw IngressWaitError.unconfirmedApply }
        }
        do {
            Lattice.configureSyncRelay(
                on: app.routes, path: ["sync"], for: [SimpleSyncObject.self], storageURL: storageURL,
                channelExtractor: { _ in
                    counts.withLockedValue { $0.extractorCalls += 1 }
                    return SyncChannel(id: "ingress", userId: user)
                })
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            var headers = HTTPHeaders()
            headers.add(name: "X-Test-User", value: user.uuidString)
            attemptedConnect = true
            mayRemoveDirectory = false
            WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync", headers: headers,
                              on: app.eventLoopGroup) { ws in
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
                        if matches > 0 { acknowledged.send(true) }
                    } else if kind == "nack" || kind == "rejected" {
                        counts.withLockedValue { $0.nackOrRejectedFrames += 1 }
                    }
                }
                // The first upload is sent INSIDE the client's synchronous
                // upgrade callback, before any continuation resumes test code.
                let promise = ws.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { sent.send($0) }
                ws.send(frame, promise: promise)
                connected.send(.success(ws))
            }.whenFailure { error in
                connected.send(.failure(error))
                sent.send(.failure(error))
            }

            let socket = try await connected.wait().get()
            try await sent.wait().get()
            _ = try await gate.entered.wait()
            // Waiting only for a suspended channelExtractor would let the
            // former async-upgrade ordering pass. This gate is before the
            // ENTIRE async setup body, while ingress must already be live.
            _ = try await buffered.wait()
            let beforeRelease = counts.withLockedValue { $0 }
            #expect(!gate.isReleased)
            #expect(beforeRelease.bufferedFrames == 1)
            #expect(beforeRelease.bufferedBytes == frame.count)
            #expect(!beforeRelease.bufferedAfterRelease)
            #expect(beforeRelease.extractorCalls == 0)
            #expect(beforeRelease.ackFrames == 0)

            gate.release()
            _ = try await acknowledged.wait()
            let afterAck = counts.withLockedValue { $0 }
            #expect(afterAck.ackFrames == 1)
            #expect(afterAck.matchingAckIDs == 1)
            #expect(afterAck.nackOrRejectedFrames == 0)
            #expect(afterAck.extractorCalls == 1)

            let capture = try #require(recorder.closeSnapshot(partial: false))
            #expect(capture.dropped == 0)
            #expect(capture.records.filter { $0.stage == .ingressBuffered }.count == 1)
            #expect(capture.records.filter { $0.stage == .frameParsed && $0.warmMatch == true }.count == 1)
            // Send-begin precedes client receipt even when send-return is
            // preempted on another thread; do not require the later marker.
            #expect(capture.records.filter { $0.stage == .ackSendBegin }.count == 1)

            let persisted = try Lattice(SimpleSyncObject.self, configuration: .init(
                fileURL: storageURL.appending(path: "ingress.sqlite")))
            verifiedStore = persisted
            #expect(persisted.objects(SimpleSyncObject.self).count == 1)
            #expect(persisted.objects(SimpleSyncObject.self).first?.value == 731)
            #expect(persisted.objects(AuditLog.self).where { $0.globalId == auditID }.count == 1)
            // Start close without waiting on a peer handshake. Application
            // shutdown below owns connection cleanup and is awaited.
            socket.close(promise: nil)
        } catch let failure {
            // A timeout/assertion/connect error must release setup BEFORE
            // server shutdown waits for its request/socket tasks to finish.
            do { try await shutdown() }
            catch { Issue.record("relay ingress cleanup did not drain: \(error); fixture retained") }
            throw failure
        }
        try await shutdown()
    }
}
