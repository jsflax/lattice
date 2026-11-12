import Foundation
import XCTest
import Vapor
import NIOConcurrencyHelpers
import LatticeTestSupport
@testable import Lattice
@testable import LatticeServerKit

@Model private final class FiniteAssetPayload {
    var ordinal: Int = 0
    var payload: Data = Data()
}

private enum FiniteIntegrationFailure: Error {
    case timedOut(String)
    case invalidPremise(String)
    case noPort
}

/// A test-only suspension point before the shipping relay opens its store.
/// It never blocks an event loop and is released before joined server cleanup.
private final class FiniteRelaySetupGate: Sendable {
    private struct State {
        var released: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state: NIOLockedValueBox<State>
    init(paused: Bool) { state = .init(State(released: !paused)) }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLockedValue { state in
                if state.released { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLockedValue { state in
            state.released = true
            let retired = state.waiters
            state.waiters = []
            return retired
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// The real public relay route, with ordinary bearer authorization accepted by
/// the native client. Mount-scoped hooks only observe/gate setup, not the wire.
final class FiniteRelayHarness: @unchecked Sendable {
    private struct Counts { var started = 0; var finished = 0 }
    let app: Application
    let directory: URL
    let storageURL: URL
    let endpoint: URL
    let handle: SyncRelayHandle
    let channelID = "finite-integration"
    private let gate: FiniteRelaySetupGate
    private let counts: NIOLockedValueBox<Counts>
    private let hooks: RelayIngressTestHooks

    init(isolation: isolated (any Actor)? = #isolation,
         pausedSetup: Bool = false,
         schema: [any Lattice.Model.Type] = [SimpleSyncObject.self]) async throws {
        let directory = LatticeTestScratch.directory.appendingPathComponent("finite-relay-\(UUID().uuidString)")
        let storage = directory.appendingPathComponent("relay")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        self.directory = directory
        self.storageURL = storage
        let gate = FiniteRelaySetupGate(paused: pausedSetup)
        self.gate = gate
        let counts = NIOLockedValueBox(Counts())
        self.counts = counts
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: {
            counts.withLockedValue { $0.started += 1 }
            await gate.wait()
        }, didBufferFrame: { _ in }, didFinishAsyncSetup: {
            counts.withLockedValue { $0.finished += 1 }
        })
        self.hooks = hooks
        RelayIngressTesting.install(hooks, for: storage)
        var environment = try Environment.detect()
        environment.arguments = ["vapor"]
        let app: Application
        do { app = try await Application.make(environment) }
        catch {
            RelayIngressTesting.remove(hooks, for: storage)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.app = app
        app.http.server.configuration.port = 0
        app.http.server.configuration.shutdownTimeout = testHTTPServerShutdownTimeout
        let user = UUID()
        let channel = channelID
        self.handle = Lattice.configureSyncRelay(
            on: app.routes, path: ["sync"], for: schema, storageURL: storage,
            channelExtractor: { request in
                guard request.headers.first(name: "Authorization") == "Bearer finite-test-token" else {
                    throw Abort(.unauthorized)
                }
                return SyncChannel(id: channel, userId: user)
            })
        do {
            try await app.startup()
            guard let port = app.http.server.shared.localAddress?.port else {
                throw FiniteIntegrationFailure.noPort
            }
            endpoint = URL(string: "ws://127.0.0.1:\(port)/sync")!
        } catch {
            gate.release()
            try? await app.asyncShutdown()
            RelayIngressTesting.remove(hooks, for: storage)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    var setupStarted: Int { counts.withLockedValue { $0.started } }
    func releaseSetup() { gate.release() }
    var channelFile: URL { storageURL.appendingPathComponent("\(channelID).sqlite") }

    func clientConfiguration(name: String = "client") -> Lattice.Configuration {
        .init(fileURL: directory.appendingPathComponent("\(name).sqlite"),
              authorizationToken: "finite-test-token", wssEndpoint: endpoint,
              syncStartup: .deferred)
    }

    func coWriter() throws -> Lattice {
        try Lattice(isolation: nil, SimpleSyncObject.self, configuration: .init(fileURL: channelFile))
    }

    func shutdown() async throws {
        gate.release()
        // Join every admitted async setup before unlinking its mount. The
        // client has already settled/closed on the test body's exit path.
        var drainError: (any Error)?
        do {
            try await finiteWait("relay setup settlement") {
                self.counts.withLockedValue { $0.started == $0.finished }
            }
        } catch { drainError = error }
        await handle.disconnectAll(channelId: channelID)
        var shutdownError: (any Error)?
        do { try await app.asyncShutdown() } catch { shutdownError = error }
        RelayIngressTesting.remove(hooks, for: storageURL)
        // Preserve files on unconfirmed teardown; never unlink under workers.
        if let drainError { throw drainError }
        if let shutdownError { throw shutdownError }
        RelayCheckpointGovernor.shared.unregister(storePath: channelFile.path)
        try FileManager.default.removeItem(at: directory)
    }
}

/// Polling only waits for positive observable receipts. No test infers an
/// absence of work from a fixed delay; negative checks follow settlement.
private func finiteWait(_ description: String, seconds: TimeInterval = 10,
                        until predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw FiniteIntegrationFailure.timedOut(description) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class FiniteProgressLog: Sendable {
    private let values = NIOLockedValueBox<[Lattice.SyncProgress]>([])
    func append(_ progress: Lattice.SyncProgress) { values.withLockedValue { $0.append(progress) } }
    func hasNativeACK(atLeast count: Int) -> Bool {
        values.withLockedValue { $0.contains { !$0.syncId.isEmpty && $0.acked >= count } }
    }
}

/// Keep the client facade and its callbacks on one actor even though XCTest
/// owns test discovery and ordering.
private actor FiniteSyncIntegrationDriver {
    private func withRelay(pausedSetup: Bool = false,
                           schema: [any Lattice.Model.Type] = [SimpleSyncObject.self],
                           _ body: (FiniteRelayHarness) async throws -> Void) async throws {
        let harness = try await FiniteRelayHarness(isolation: self, pausedSetup: pausedSetup, schema: schema)
        do { try await body(harness) }
        catch {
            try await harness.shutdown()
            throw error
        }
        try await harness.shutdown()
    }

    private func withProgress(_ client: Lattice,
                              _ body: (FiniteProgressLog) async throws -> Void) async throws {
        let log = FiniteProgressLog()
        // Subscription is synchronous and deliberately precedes native ownership.
        let stream = client.syncProgressStream
        let consumer = Task.detached {
            for await progress in stream { log.append(progress) }
        }
        do { try await body(log) }
        catch {
            consumer.cancel()
            await consumer.value
            throw error
        }
        consumer.cancel()
        await consumer.value
    }

    func emptyStoreCompletesAndSettlesItsPrivateSession() async throws {
        try await withRelay { harness in
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            XCTAssertFalse(client.backend.isSyncAgent())
            let identity = client.backend.identityHash
            do {
                let started = ContinuousClock.now
                let outcome = try await client.syncOnce(maximumDuration: 10)
                XCTAssertEqual(outcome, .completed,
                               "Finite sync budget=10s, elapsed=\(started.duration(to: ContinuousClock.now))")
            }
            XCTAssertEqual(client.backend.identityHash, identity)
            XCTAssertFalse(client.backend.isSyncAgent())
            XCTAssertFalse(client.isSyncConnected)
            XCTAssertTrue(client.objects(SimpleSyncObject.self).isEmpty)
        }
    }

    func completedUploadsHaveDurableRelayRowsAndNoPendingAuditWork() async throws {
        try await withRelay { harness in
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            try client.add(contentsOf: (0..<7).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
            do {
                let started = ContinuousClock.now
                let outcome = try await client.syncOnce(maximumDuration: 15)
                XCTAssertEqual(outcome, .completed,
                               "Finite sync budget=15s, elapsed=\(started.duration(to: ContinuousClock.now))")
            }
            let persisted = try harness.coWriter()
            defer { persisted.close() }
            XCTAssertEqual(Set(persisted.objects(SimpleSyncObject.self).map(\.value)), Set(0..<7))
            XCTAssertEqual(client.pendingSyncEntryCount, 0)
            XCTAssertFalse(client.backend.isSyncAgent())
        }
    }

    func completionWaitsForEveryInitialReplayPage() async throws {
        try await withRelay { harness in
            let donor = try harness.coWriter()
            defer { donor.close() }
            // The shipping relay's initial replay pages at 1,000 entries.
            let count = 1_003
            try donor.add(contentsOf: (0..<count).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            do {
                let started = ContinuousClock.now
                let outcome = try await client.syncOnce(maximumDuration: 30)
                XCTAssertEqual(outcome, .completed,
                               "Finite sync budget=30s, elapsed=\(started.duration(to: ContinuousClock.now))")
            }
            // No eventual-read wait: all pages must be present at completion.
            let values = client.objects(SimpleSyncObject.self).map(\.value)
            XCTAssertEqual(values.count, count)
            XCTAssertEqual(Set(values), Set(0..<count))
            XCTAssertFalse(client.isSyncConnected)
        }
    }

    func completionWaitsForEveryBoundedBinaryReplayFrame() async throws {
        try await withRelay(schema: [FiniteAssetPayload.self]) { harness in
            let payload = Data(repeating: 0x6d, count: 512 * 1024)
            let count = 9
            XCTAssertGreaterThan(count * payload.count, Lattice.maximumEncodedSyncMessageBytes,
                                 "Even raw payloads require more than one encoded frame")
            do {
                let donor = try Lattice(FiniteAssetPayload.self,
                    configuration: .init(fileURL: harness.channelFile))
                defer { donor.close() }
                try donor.withTransaction {
                    for ordinal in 0..<count {
                        let row = FiniteAssetPayload()
                        row.ordinal = ordinal; row.payload = payload
                        try donor.add(row)
                    }
                }
            }
            let client = try Lattice(FiniteAssetPayload.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            let outcome = try await client.syncOnce(maximumDuration: 30)
            XCTAssertEqual(outcome, .completed)
            // No eventual-read loop: the negotiated marker follows every admitted byte-bounded
            // frame, including the last short page; binary values retain their exact bytes.
            let rows = client.objects(FiniteAssetPayload.self).materializedSnapshot(limit: Int64(count + 1))
            XCTAssertEqual(rows.count, count)
            XCTAssertEqual(Set(rows.map(\.ordinal)), Set(0..<count))
            XCTAssertTrue(rows.allSatisfy { $0.payload == payload })
            XCTAssertFalse(client.backend.isSyncAgent())
            XCTAssertFalse(client.isSyncConnected)
        }
    }

    func cancellationDuringRelaySetupSettlesAndSameHandleCanSyncAgain() async throws {
        try await withRelay(pausedSetup: true) { harness in
            try await self.checkCancellationDuringRelaySetup(harness)
        }
    }

    private func checkCancellationDuringRelaySetup(_ harness: FiniteRelayHarness) async throws {
        let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
        defer { client.close() }
        let identity = client.backend.identityHash
        // Both the facade and the child operation stay on this driver actor.
        // The explicit isolated parameter preserves that proof across Task.
        let operation = Task { [self] in
            try await client.syncOnce(maximumDuration: 30, isolation: self)
        }
        do {
            try await finiteWait("relay entered setup") { harness.setupStarted > 0 }
            operation.cancel()
            do {
                _ = try await operation.value
                XCTFail("Cancelled finite sync returned normally")
            } catch is CancellationError { }
        } catch {
            operation.cancel()
            harness.releaseSetup()
            _ = try? await operation.value
            throw error
        }
        XCTAssertFalse(client.backend.isSyncAgent())
        XCTAssertFalse(client.isSyncConnected)
        try client.add(SimpleSyncObject(value: 91, floatValue: 9.1))
        XCTAssertEqual(client.objects(SimpleSyncObject.self).first?.value, 91)
        harness.releaseSetup()
        do {
            let started = ContinuousClock.now
            let outcome = try await client.syncOnce(maximumDuration: 15)
            XCTAssertEqual(outcome, .completed,
                           "Finite sync budget=15s, elapsed=\(started.duration(to: ContinuousClock.now))")
        }
        XCTAssertEqual(client.backend.identityHash, identity)
        let persisted = try harness.coWriter()
        defer { persisted.close() }
        XCTAssertEqual(persisted.objects(SimpleSyncObject.self).first?.value, 91)
    }

    func ordinaryManualCycleLeavesResultsAbleToPinNewReadGenerations() async throws {
        try await withRelay { harness in
            var configuration = harness.clientConfiguration()
            configuration.auditRetention = 600
            let client = try Lattice(SimpleSyncObject.self, configuration: configuration)
            defer { client.close() }
            try client.add(SimpleSyncObject(value: 1, floatValue: 1))
            let results = client.objects(SimpleSyncObject.self)
            XCTAssertEqual(results.count, 1)
            guard client.backend.localReadGenerationsOutstanding() > 0 else {
                let message = "test premise: ordinary file Results own a read generation"
                XCTFail(message)
                throw FiniteIntegrationFailure.invalidPremise(message)
            }
            do {
                let started = ContinuousClock.now
                let outcome = try await client.syncOnce(maximumDuration: 15)
                XCTAssertEqual(outcome, .completed,
                               "Finite sync budget=15s, elapsed=\(started.duration(to: ContinuousClock.now))")
            }
            // Retire only native pins, not the Swift suppression latch, then
            // force a fresh epoch. An accidentally latched coordinator cannot
            // create a new generation here without resumeGenerations().
            client.backend.retireAllReadGenerations()
            try client.add(SimpleSyncObject(value: 2, floatValue: 2))
            XCTAssertEqual(results.count, 2)
            XCTAssertGreaterThan(client.backend.localReadGenerationsOutstanding(), 0,
                    "manual syncOnce must not leave ordinary reads latched off")
            XCTAssertEqual(client.configuration.auditRetention, 600)
        }
    }

    func preOwnershipProgressSubscriberSurvivesFiniteCyclesAndForegroundConnect() async throws {
        try await withRelay { harness in
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            XCTAssertFalse(client.backend.isSyncAgent())
            try await withProgress(client) { progress in
                try client.add(SimpleSyncObject(value: 1, floatValue: 1))
                do {
                    let started = ContinuousClock.now
                    let outcome = try await client.syncOnce(maximumDuration: 15)
                    XCTAssertEqual(outcome, .completed,
                                   "Finite sync budget=15s, elapsed=\(started.duration(to: ContinuousClock.now))")
                }
                try await finiteWait("first finite native ACK progress") { progress.hasNativeACK(atLeast: 1) }

                try client.add(contentsOf: (2...3).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
                do {
                    let started = ContinuousClock.now
                    let outcome = try await client.syncOnce(maximumDuration: 15)
                    XCTAssertEqual(outcome, .completed,
                                   "Finite sync budget=15s, elapsed=\(started.duration(to: ContinuousClock.now))")
                }
                // Per-synchronizer counters restart each cycle; >=2 cannot be
                // satisfied by a buffered event from the one-row first cycle.
                try await finiteWait("second finite native ACK progress") { progress.hasNativeACK(atLeast: 2) }

                try client.connectSync()
                try client.add(contentsOf: (4...6).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
                try await finiteWait("foreground native ACK progress") { progress.hasNativeACK(atLeast: 3) }
                let persisted = try harness.coWriter()
                defer { persisted.close() }
                XCTAssertEqual(Set(persisted.objects(SimpleSyncObject.self).map(\.value)), Set(1...6))
                try client.disconnectSync()
            }
        }
    }

    func olderServerWithoutMarkerReturnsBudgetExhaustedAfterDurableProgress() async throws {
        let directory = LatticeTestScratch.directory.appendingPathComponent("finite-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = try await TestSyncServer(models: [SimpleSyncObject.self],
            configuration: .init(fileURL: directory.appendingPathComponent("server.sqlite")),
            label: "FiniteLegacy")
        do {
            try await checkLegacyServer(server, directory: directory)
        } catch {
            try await server.shutdownAndWaitForTesting()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        try await server.shutdownAndWaitForTesting()
        try FileManager.default.removeItem(at: directory)
    }

    private func checkLegacyServer(_ server: TestSyncServer, directory: URL) async throws {
        try server.lattice.add(SimpleSyncObject(value: 10, floatValue: 1))
        let client = try Lattice(SimpleSyncObject.self, configuration: .init(
            fileURL: directory.appendingPathComponent("client.sqlite"), authorizationToken: "fixture",
            wssEndpoint: server.endpoint, syncStartup: .deferred))
        defer { client.close() }
        try client.add(SimpleSyncObject(value: 20, floatValue: 2))
        do {
            let started = ContinuousClock.now
            let outcome = try await client.syncOnce(maximumDuration: 3)
            XCTAssertEqual(outcome, .budgetExhausted,
                           "Finite sync budget=3s, elapsed=\(started.duration(to: ContinuousClock.now))")
        }
        // The old fixture ACKs before persistence; join its receive consumer
        // before claiming durable progress. It never emits completion markers.
        try await server.waitForCommandsForTesting()
        XCTAssertEqual(Set(server.lattice.objects(SimpleSyncObject.self).map(\.value)), [10, 20])
        XCTAssertEqual(Set(client.objects(SimpleSyncObject.self).map(\.value)), [10, 20])
        XCTAssertEqual(client.pendingSyncEntryCount, 0)
        XCTAssertFalse(client.backend.isSyncAgent())
        XCTAssertFalse(client.isSyncConnected)
    }
}

/// Preserve the former per-case Swift Testing limits. The timeout cancels and
/// joins the actor operation, including its native/relay cleanup; no abandoned
/// detached work can escape into the next test.
private func withFiniteIntegrationDeadline(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { try await operation() }
        tasks.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw FiniteIntegrationFailure.timedOut("finite integration test exceeded \(seconds)s")
        }
        defer { tasks.cancelAll() }
        _ = try await tasks.next()
    }
}

/// SwiftPM runs XCTest before the parallel Swift Testing phase. The shipping
/// relay's async setup must not compete with the package-wide SQL stress burst
/// when these conformance checks require completion within 10/15/30 seconds.
/// Every case and its native budget remains unchanged; there are no retries.
final class FiniteSyncIntegrationTests: XCTestCase {
    func testEmptyStoreCompletesAndSettlesItsPrivateSession() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 60) {
            try await driver.emptyStoreCompletesAndSettlesItsPrivateSession()
        }
    }

    func testCompletedUploadsHaveDurableRelayRowsAndNoPendingAuditWork() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 60) {
            try await driver.completedUploadsHaveDurableRelayRowsAndNoPendingAuditWork()
        }
    }

    func testCompletionWaitsForEveryInitialReplayPage() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 120) {
            try await driver.completionWaitsForEveryInitialReplayPage()
        }
    }

    func testCompletionWaitsForEveryBoundedBinaryReplayFrame() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 120) {
            try await driver.completionWaitsForEveryBoundedBinaryReplayFrame()
        }
    }

    func testCancellationDuringRelaySetupSettlesAndSameHandleCanSyncAgain() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 60) {
            try await driver.cancellationDuringRelaySetupSettlesAndSameHandleCanSyncAgain()
        }
    }

    func testOrdinaryManualCycleLeavesResultsAbleToPinNewReadGenerations() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 60) {
            try await driver.ordinaryManualCycleLeavesResultsAbleToPinNewReadGenerations()
        }
    }

    func testPreOwnershipProgressSubscriberSurvivesFiniteCyclesAndForegroundConnect() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 120) {
            try await driver.preOwnershipProgressSubscriberSurvivesFiniteCyclesAndForegroundConnect()
        }
    }

    func testOlderServerWithoutMarkerReturnsBudgetExhaustedAfterDurableProgress() async throws {
        let driver = FiniteSyncIntegrationDriver()
        try await withFiniteIntegrationDeadline(seconds: 60) {
            try await driver.olderServerWithoutMarkerReturnsBudgetExhaustedAfterDurableProgress()
        }
    }
}
