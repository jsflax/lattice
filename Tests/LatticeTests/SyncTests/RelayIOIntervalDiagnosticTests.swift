import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOCore
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

/// Event completion for the real setup callback. No poll task or held native
/// worker is required to observe it. A timeout is failure, never a teardown claim.
private final class IntervalCompletion: Sendable {
    private struct State {
        var result: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }
    private let state = NIOLockedValueBox(State())
    func finish() { resolve(true) }
    private func resolve(_ result: Bool) {
        let waiter = state.withLockedValue { value in
            guard value.result == nil else { return nil as CheckedContinuation<Bool, Never>? }
            value.result = result
            let waiter = value.waiter; value.waiter = nil
            return waiter
        }
        waiter?.resume(returning: result)
    }
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready = state.withLockedValue { value in
                if let result = value.result { return result }
                precondition(value.waiter == nil)
                value.waiter = continuation
                return nil as Bool?
            }
            if let ready { continuation.resume(returning: ready) }
            else {
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in
                    self?.resolve(false)
                }
            }
        }
    }
}

private func withIntervalService(cancelOnReserve: Bool = false,
    body: (RelayExecutionPool, RelayApplyAdmission) async throws -> Void) async throws {
    let pool = RelayExecutionPool(workerCount: 2, name: "relay.test.io-interval")
    let service = RelayApplyAdmission(pool: pool, didReserveForTesting: { cancellation in
        if cancelOnReserve { cancellation.cancel() }
    })
    do { try await body(pool, service) }
    catch {
        await service.closeAdmissionAndDrain(); await pool.shutdown()
        throw error
    }
    await service.closeAdmissionAndDrain(); await pool.shutdown()
    #expect(pool.snapshot.liveWorkers == 0)
}

private func intervalParse(_ data: Data, diagnostic: ACKPathAdmission) -> RelayProcessedFrame? {
    do {
        // Native facade is created, used and closed on the actual IO worker.
        let lattice = try Lattice(isolation: nil, SimpleSyncObject.self,
                                  configuration: .init(storage: .memory()))
        defer { lattice.close() }
        return processRelayApplyOnWorker(data: data, lattice: lattice,
            channel: SyncChannel(id: "interval", userId: UUID()), policy: nil,
            revocation: RevocationFlag(), diagnostic: diagnostic.connection,
            needsFanOut: false, admissionSpan: diagnostic.span)
    } catch { Issue.record("worker fixture could not open: \(error)"); return nil }
}

private func uniqueInterval(_ snapshot: ACKPathRecorder.Snapshot, _ stage: ACKPathStage,
                            span: UInt64) throws -> ACKPathRecorder.Record {
    let matches = snapshot.records.filter { $0.stage == stage && $0.span == span }
    try #require(matches.count == 1, "expected exactly one stage for this request/page")
    return matches[0]
}

@Suite("Relay IO interval diagnostics", .timeLimit(.minutes(1)))
struct RelayIOIntervalDiagnosticTests {
    @Test func concurrentFramesKeepDistinctAdmissionAndParsedSpansAcrossBothInputRoutes() async throws {
        try await withIntervalService { pool, service in
            let recorder = ACKPathRecorder(testRunID: UUID())
            let connection = try #require(recorder.registerConnection(id: UUID(), role: .uploader))
            let buffer = ByteBuffer(string: "{\"ack\":[]}")
            let ingress = RelayIngressAdmission()
            let frame = try ingress.makeAccount().copyFrame(ByteBuffer(string: "{ \"ack\": [] }"))
            let first = ACKPathAdmission(connection: connection,
                span: connection.record(.applyAdmissionRequested, bytes: buffer.readableBytes))
            let second = ACKPathAdmission(connection: connection,
                span: connection.record(.applyAdmissionRequested, bytes: frame.byteCount))
            // Real calls can overlap without a wall-clock blocking gate. Either
            // FIFO order is valid; each immutable request must retain its identity.
            async let a: Void = service.withAdmission(for: "same-file", buffer: buffer,
                diagnostic: first, operation: { data in
                    #expect(pool.isCurrentWorker)
                    return intervalParse(data, diagnostic: first)
                }, completion: { result in #expect(result != nil) })
            async let b: Void = service.withAdmission(for: "same-file", frame: frame,
                diagnostic: second, operation: { data in
                    #expect(pool.isCurrentWorker)
                    return intervalParse(data, diagnostic: second)
                }, completion: { result in #expect(result != nil) })
            _ = try await (a, b)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.dropped == 0 && snapshot.outputOmittedRecords == 0)
            #expect(first.span != 0 && second.span != 0 && first.span != second.span)
            for (request, expectedBytes) in [(first, buffer.readableBytes), (second, frame.byteCount)] {
                let stages: [ACKPathStage] = [.applyAdmissionReserved, .applyInputCopyBegin,
                    .applyInputCopyEnd, .applyInputPrepared, .applyPoolSubmit, .applyWorkerEntered,
                    .frameParseBegin, .frameParsed, .applyWorkerBodyReturned]
                let records = try stages.map { try uniqueInterval(snapshot, $0, span: request.span) }
                for (left, right) in zip(records, records.dropFirst()) { #expect(left.uptime <= right.uptime) }
                #expect(records.allSatisfy { $0.connection == connection.id && $0.role == .uploader })
                #expect(records[2].result == true && records[2].bytes == expectedBytes)
                let parsed = records[7]
                let applied = try uniqueInterval(snapshot, .applyBodyReturned, span: parsed.sequence)
                #expect(applied.uptime >= parsed.uptime && applied.uptime <= records[8].uptime)
            }
        }
    }

    @Test func preparationCancellationRecordsSkippedCopyWithoutFabricatedWorkerOrParse() async throws {
        try await withIntervalService(cancelOnReserve: true) { _, service in
            let recorder = ACKPathRecorder(testRunID: UUID())
            let connection = try #require(recorder.registerConnection(id: UUID(), role: .uploader))
            let request = ACKPathAdmission(connection: connection,
                span: connection.record(.applyAdmissionRequested, bytes: 1))
            do {
                try await service.withAdmission(for: "cancelled", buffer: ByteBuffer(bytes: [1]),
                    diagnostic: request, operation: { _ in Issue.record("cancelled operation ran") },
                    completion: { _ in Issue.record("cancelled operation published") })
                Issue.record("expected cancelled request")
            } catch { #expect(error as? RelayApplyAdmissionError == .cancelled) }
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.dropped == 0)
            _ = try uniqueInterval(snapshot, .applyAdmissionReserved, span: request.span)
            let copy = try uniqueInterval(snapshot, .applyInputCopyEnd, span: request.span)
            #expect(copy.bytes == 0 && copy.result == false)
            #expect(!snapshot.records.contains {
                [.applyPoolSubmit, .applyWorkerEntered, .frameParseBegin, .frameParsed,
                 .applyWorkerBodyReturned].contains($0.stage)
            })
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        }
    }

    @Test func nilProbeLeavesOrdinaryAdmissionAndResultUnchanged() async throws {
        try await withIntervalService { pool, service in
            let result = NIOLockedValueBox<Int?>(nil)
            try await service.withAdmission(for: "ordinary", buffer: ByteBuffer(bytes: [1, 2, 3]),
                operation: { bytes in #expect(pool.isCurrentWorker); return bytes.count },
                completion: { count in result.withLockedValue { $0 = count } })
            #expect(result.withLockedValue { $0 } == 3)
            #expect(service.snapshot.requests == 0 && service.snapshot.inputBytes == 0)
        }
    }

    @Test func everyCatchUpPageHasItsOwnMaterializeBindEncodeInterval() async throws {
        // Follow the setup fixture's retained-directory policy: no unlink
        // beneath async native owners. Runner TMPDIR controls the localdev root.
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-io-interval-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "fixture.sqlite")
        let seed = try Lattice(isolation: nil, SimpleSyncObject.self, configuration: .init(fileURL: url))
        do {
            try seed.transaction {
                for index in 0..<1001 { try seed.add(SimpleSyncObject(value: index, floatValue: 1)) }
            }
        } catch { seed.close(); throw error }
        seed.close()

        let recorder = ACKPathRecorder(testRunID: UUID())
        let user = UUID()
        _ = try #require(recorder.registerConnection(id: user, role: .peer))
        let finished = IntervalCompletion()
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
            didFinishAsyncSetup: { finished.finish() })
        ACKPathDiagnostics.install(recorder, for: directory)
        RelayIngressTesting.install(hooks, for: directory)
        defer {
            ACKPathDiagnostics.remove(recorder, for: directory)
            RelayIngressTesting.remove(hooks, for: directory)
        }
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.port = 0
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        let collector = PushFrameCollector()
        do {
            Lattice.configureSyncRelay(on: app.routes, path: ["sync"], for: [SimpleSyncObject.self],
                storageURL: directory, channelExtractor: { _ in SyncChannel(id: "fixture", userId: user) })
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            var headers = HTTPHeaders(); headers.add(name: "X-Test-User", value: user.uuidString)
            var clientConfiguration = WebSocketClient.Configuration()
            clientConfiguration.maxFrameSize = 1 << 20
            try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync", headers: headers,
                configuration: clientConfiguration, on: app.eventLoopGroup) { socket in
                    collector.attach(socket)
                }.get()
            let setupFinished = await finished.wait()
            try #require(setupFinished, "real catch-up setup did not complete within its bounded observation")
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.dropped == 0 && snapshot.outputOmittedRecords == 0)
            let pages = snapshot.records.filter { $0.stage == .catchUpPageRequested }
            #expect(pages.count == 3) // Two pages followed by the terminal read.
            #expect(Set(pages.map(\.sequence)).count == pages.count)
            var counts: [Int] = []
            for requested in pages {
                let worker = try uniqueInterval(snapshot, .catchUpPageWorkerEntered, span: requested.sequence)
                let returned = try uniqueInterval(snapshot, .catchUpPageBodyReturned, span: requested.sequence)
                #expect(requested.uptime <= worker.uptime && worker.uptime <= returned.uptime)
                let materialize = snapshot.records.filter {
                    $0.stage == .catchUpPageMaterializeBegin && $0.span == requested.sequence
                }
                if materialize.isEmpty { continue }
                let stages: [ACKPathStage] = [.catchUpPageMaterializeBegin, .catchUpPageMaterializeEnd,
                    .catchUpPageBindingEnd, .catchUpPageEncodingEnd, .catchUpPageBodyReturned]
                let records = try stages.map { try uniqueInterval(snapshot, $0, span: requested.sequence) }
                for (left, right) in zip(records, records.dropFirst()) { #expect(left.uptime <= right.uptime) }
                #expect(worker.uptime <= records[0].uptime)
                #expect(records[3].bytes > 0)
                counts.append(records[3].count)
            }
            #expect(counts == [1000, 1])
            collector.socket?.close(promise: nil)
            try await app.asyncShutdown()
        } catch {
            collector.socket?.close(promise: nil)
            try? await app.asyncShutdown()
            throw error
        }
    }
}
