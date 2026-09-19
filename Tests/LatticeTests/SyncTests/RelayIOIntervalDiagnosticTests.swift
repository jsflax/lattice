import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOCore
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private final class IntervalGate: Sendable {
    let entered = NIOLockedValueBox(false)
    let release = DispatchSemaphore(value: 0)
    let timedOut = NIOLockedValueBox(false)
    func block() {
        entered.withLockedValue { $0 = true }
        let expired = release.wait(timeout: .now() + 5) != .success
        timedOut.withLockedValue { $0 = expired }
    }
}

private func intervalUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    while !predicate() {
        try #require(DispatchTime.now().uptimeNanoseconds < deadline, "bounded diagnostic wait expired")
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func withIntervalService(workers: Int = 2,
    body: (RelayExecutionPool, RelayApplyAdmission) async throws -> Void) async throws {
    let pool = RelayExecutionPool(workerCount: workers, name: "relay.test.io-interval")
    let service = RelayApplyAdmission(pool: pool)
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
    @Test func sameFileQueuedFramesKeepDistinctAdmissionAndParsedSpans() async throws {
        try await withIntervalService { pool, service in
            let recorder = ACKPathRecorder(testRunID: UUID())
            let connection = try #require(recorder.registerConnection(id: UUID(), role: .uploader))
            let first = ACKPathAdmission(connection: connection,
                span: connection.record(.applyAdmissionRequested, bytes: 10))
            let gate = IntervalGate()
            defer { gate.release.signal() }
            let firstTask = Task {
                try await service.withAdmission(for: "same-file", buffer: ByteBuffer(string: "{\"ack\":[]}"),
                    diagnostic: first, operation: { data in
                        #expect(pool.isCurrentWorker)
                        gate.block()
                        return intervalParse(data, diagnostic: first)
                    }, completion: { result in #expect(result != nil) })
            }
            try await intervalUntil { gate.entered.withLockedValue { $0 } }
            let second = ACKPathAdmission(connection: connection,
                span: connection.record(.applyAdmissionRequested, bytes: 10))
            let secondTask = Task {
                try await service.withAdmission(for: "same-file", buffer: ByteBuffer(string: "{\"ack\":[]}"),
                    diagnostic: second, operation: { data in
                        #expect(pool.isCurrentWorker)
                        return intervalParse(data, diagnostic: second)
                    }, completion: { result in #expect(result != nil) })
            }
            try await intervalUntil { service.snapshot.running == 1 && service.snapshot.queued == 1 }
            gate.release.signal()
            try await firstTask.value; try await secondTask.value
            #expect(!gate.timedOut.withLockedValue { $0 })
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.dropped == 0 && snapshot.outputOmittedRecords == 0)
            #expect(first.span != 0 && second.span != 0 && first.span != second.span)
            for request in [first, second] {
                let stages: [ACKPathStage] = [.applyAdmissionReserved, .applyInputCopyBegin,
                    .applyInputCopyEnd, .applyInputPrepared, .applyPoolSubmit, .applyWorkerEntered,
                    .frameParseBegin, .frameParsed]
                let records = try stages.map { try uniqueInterval(snapshot, $0, span: request.span) }
                for (left, right) in zip(records, records.dropFirst()) { #expect(left.uptime <= right.uptime) }
                #expect(records[2].result == true && records[2].bytes == 10)
                let parsed = try #require(records.last)
                let applied = try uniqueInterval(snapshot, .applyBodyReturned, span: parsed.sequence)
                #expect(applied.uptime >= parsed.uptime)
            }
            let prepared = try uniqueInterval(snapshot, .applyInputPrepared, span: second.span)
            let firstParse = try uniqueInterval(snapshot, .frameParseBegin, span: first.span)
            let secondWorker = try uniqueInterval(snapshot, .applyWorkerEntered, span: second.span)
            #expect(prepared.uptime <= firstParse.uptime)
            #expect(firstParse.uptime <= secondWorker.uptime)
        }
    }

    @Test func submittedCancellationHasWorkerTurnWithoutFabricatedParse() async throws {
        try await withIntervalService(workers: 1) { pool, service in
            let gate = IntervalGate()
            defer { gate.release.signal() }
            pool.submitRequired(for: "occupied") { gate.block() }
            try await intervalUntil { gate.entered.withLockedValue { $0 } }
            let recorder = ACKPathRecorder(testRunID: UUID())
            let connection = try #require(recorder.registerConnection(id: UUID(), role: .uploader))
            let request = ACKPathAdmission(connection: connection,
                span: connection.record(.applyAdmissionRequested, bytes: 1))
            let task = Task {
                try await service.withAdmission(for: "other-file", buffer: ByteBuffer(bytes: [1]),
                    diagnostic: request, operation: { _ in Issue.record("cancelled operation ran") },
                    completion: { _ in Issue.record("cancelled operation published") })
            }
            try await intervalUntil { service.snapshot.submitted == 1 }
            task.cancel()
            gate.release.signal()
            do { try await task.value; Issue.record("expected cancelled request") }
            catch { #expect(error as? RelayApplyAdmissionError == .cancelled) }
            let snapshot = try #require(recorder.closeSnapshot(partial: false))
            #expect(snapshot.dropped == 0)
            _ = try uniqueInterval(snapshot, .applyPoolSubmit, span: request.span)
            _ = try uniqueInterval(snapshot, .applyWorkerEntered, span: request.span)
            #expect(!snapshot.records.contains { $0.stage == .frameParseBegin || $0.stage == .frameParsed })
            #expect(service.snapshot.requests == 0)
            #expect(!gate.timedOut.withLockedValue { $0 })
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
        let finished = NIOLockedValueBox(false)
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
            didFinishAsyncSetup: { finished.withLockedValue { $0 = true } })
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
            try await intervalUntil { finished.withLockedValue { $0 } && collector.receivedGlobalIds.count == 1001 }
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
