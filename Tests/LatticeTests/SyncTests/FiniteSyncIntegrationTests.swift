import Foundation
import Testing
import Vapor
import NIOConcurrencyHelpers
import LatticeTestSupport
@testable import Lattice
@testable import LatticeServerKit

private enum FiniteIntegrationFailure: Error {
    case timedOut(String)
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

    init(pausedSetup: Bool = false) async throws {
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
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        let user = UUID()
        let channel = channelID
        self.handle = Lattice.configureSyncRelay(
            on: app.routes, path: ["sync"], for: [SimpleSyncObject.self], storageURL: storage,
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

@Suite("Finite sync public API and shipping relay", .serialized)
actor FiniteSyncIntegrationTests {
    private func withRelay(pausedSetup: Bool = false,
                           _ body: (FiniteRelayHarness) async throws -> Void) async throws {
        let harness = try await FiniteRelayHarness(pausedSetup: pausedSetup)
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

    @Test(.timeLimit(.minutes(1)))
    func emptyStoreCompletesAndSettlesItsPrivateSession() async throws {
        try await withRelay { harness in
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            #expect(!client.backend.isSyncAgent())
            let identity = client.backend.identityHash
            #expect(try await client.syncOnce(maximumDuration: 10) == .completed)
            #expect(client.backend.identityHash == identity)
            #expect(!client.backend.isSyncAgent())
            #expect(!client.isSyncConnected)
            #expect(client.objects(SimpleSyncObject.self).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func completedUploadsHaveDurableRelayRowsAndNoPendingAuditWork() async throws {
        try await withRelay { harness in
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            try client.add(contentsOf: (0..<7).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
            #expect(try await client.syncOnce(maximumDuration: 15) == .completed)
            let persisted = try harness.coWriter()
            defer { persisted.close() }
            #expect(Set(persisted.objects(SimpleSyncObject.self).map(\.value)) == Set(0..<7))
            #expect(client.pendingSyncEntryCount == 0)
            #expect(!client.backend.isSyncAgent())
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func completionWaitsForEveryInitialReplayPage() async throws {
        try await withRelay { harness in
            let donor = try harness.coWriter()
            defer { donor.close() }
            // The shipping relay's initial replay pages at 1,000 entries.
            let count = 1_003
            try donor.add(contentsOf: (0..<count).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            #expect(try await client.syncOnce(maximumDuration: 30) == .completed)
            // No eventual-read wait: all pages must be present at completion.
            let values = client.objects(SimpleSyncObject.self).map(\.value)
            #expect(values.count == count)
            #expect(Set(values) == Set(0..<count))
            #expect(!client.isSyncConnected)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringRelaySetupSettlesAndSameHandleCanSyncAgain() async throws {
        try await withRelay(pausedSetup: true) { harness in
            try await self.checkCancellationDuringRelaySetup(harness)
        }
    }

    private func checkCancellationDuringRelaySetup(_ harness: FiniteRelayHarness) async throws {
        let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
        defer { client.close() }
        let identity = client.backend.identityHash
        // Both the facade and the child operation stay on this suite actor.
        // The explicit isolated parameter preserves that proof across Task.
        let operation = Task { [self] in
            try await client.syncOnce(maximumDuration: 30, isolation: self)
        }
        do {
            try await finiteWait("relay entered setup") { harness.setupStarted > 0 }
            operation.cancel()
            do {
                _ = try await operation.value
                Issue.record("Cancelled finite sync returned normally")
            } catch is CancellationError { }
        } catch {
            operation.cancel()
            harness.releaseSetup()
            _ = try? await operation.value
            throw error
        }
        #expect(!client.backend.isSyncAgent())
        #expect(!client.isSyncConnected)
        try client.add(SimpleSyncObject(value: 91, floatValue: 9.1))
        #expect(client.objects(SimpleSyncObject.self).first?.value == 91)
        harness.releaseSetup()
        #expect(try await client.syncOnce(maximumDuration: 15) == .completed)
        #expect(client.backend.identityHash == identity)
        let persisted = try harness.coWriter()
        defer { persisted.close() }
        #expect(persisted.objects(SimpleSyncObject.self).first?.value == 91)
    }

    @Test(.timeLimit(.minutes(1)))
    func ordinaryManualCycleLeavesResultsAbleToPinNewReadGenerations() async throws {
        try await withRelay { harness in
            var configuration = harness.clientConfiguration()
            configuration.auditRetention = 600
            let client = try Lattice(SimpleSyncObject.self, configuration: configuration)
            defer { client.close() }
            try client.add(SimpleSyncObject(value: 1, floatValue: 1))
            let results = client.objects(SimpleSyncObject.self)
            #expect(results.count == 1)
            try #require(client.backend.localReadGenerationsOutstanding() > 0,
                         "test premise: ordinary file Results own a read generation")
            #expect(try await client.syncOnce(maximumDuration: 15) == .completed)
            // Retire only native pins, not the Swift suppression latch, then
            // force a fresh epoch. An accidentally latched coordinator cannot
            // create a new generation here without resumeGenerations().
            client.backend.retireAllReadGenerations()
            try client.add(SimpleSyncObject(value: 2, floatValue: 2))
            #expect(results.count == 2)
            #expect(client.backend.localReadGenerationsOutstanding() > 0,
                    "manual syncOnce must not leave ordinary reads latched off")
            #expect(client.configuration.auditRetention == 600)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func preOwnershipProgressSubscriberSurvivesFiniteCyclesAndForegroundConnect() async throws {
        try await withRelay { harness in
            let client = try Lattice(SimpleSyncObject.self, configuration: harness.clientConfiguration())
            defer { client.close() }
            #expect(!client.backend.isSyncAgent())
            try await withProgress(client) { progress in
                try client.add(SimpleSyncObject(value: 1, floatValue: 1))
                #expect(try await client.syncOnce(maximumDuration: 15) == .completed)
                try await finiteWait("first finite native ACK progress") { progress.hasNativeACK(atLeast: 1) }

                try client.add(contentsOf: (2...3).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
                #expect(try await client.syncOnce(maximumDuration: 15) == .completed)
                // Per-synchronizer counters restart each cycle; >=2 cannot be
                // satisfied by a buffered event from the one-row first cycle.
                try await finiteWait("second finite native ACK progress") { progress.hasNativeACK(atLeast: 2) }

                try client.connectSync()
                try client.add(contentsOf: (4...6).map { SimpleSyncObject(value: $0, floatValue: Float($0)) })
                try await finiteWait("foreground native ACK progress") { progress.hasNativeACK(atLeast: 3) }
                let persisted = try harness.coWriter()
                defer { persisted.close() }
                #expect(Set(persisted.objects(SimpleSyncObject.self).map(\.value)) == Set(1...6))
                try client.disconnectSync()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
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
        #expect(try await client.syncOnce(maximumDuration: 3) == .budgetExhausted)
        // The old fixture ACKs before persistence; join its receive consumer
        // before claiming durable progress. It never emits completion markers.
        try await server.waitForCommandsForTesting()
        #expect(Set(server.lattice.objects(SimpleSyncObject.self).map(\.value)) == [10, 20])
        #expect(Set(client.objects(SimpleSyncObject.self).map(\.value)) == [10, 20])
        #expect(client.pendingSyncEntryCount == 0)
        #expect(!client.backend.isSyncAgent())
        #expect(!client.isSyncConnected)
    }
}
