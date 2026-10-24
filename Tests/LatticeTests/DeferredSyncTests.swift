import Foundation
import Testing
import LatticeTestSupport
@testable import Lattice

@Model private final class DeferredSyncItem {
    var value: String
    init(_ value: String = "") { self.value = value }
}

@Suite("Deferred sync", .serialized)
actor DeferredSyncTests {
    private let server: TestSyncServer
    private let directory: URL
    private let connects: TestSyncServer.FrameCounter

    init() async throws {
        directory = LatticeTestScratch.directory.appendingPathComponent("deferred-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counter = TestSyncServer.FrameCounter()
        connects = counter
        do {
            server = try await TestSyncServer(models: [DeferredSyncItem.self],
                configuration: .init(fileURL: directory.appendingPathComponent("server.sqlite")),
                label: "DeferredSync", hooks: .init(connectEnqueued: { counter.increment() }))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func withJoinedServer(_ body: () async throws -> Void) async throws {
        do { try await body() }
        catch {
            try await server.shutdownAndWaitForTesting()
            throw error
        }
        try await server.shutdownAndWaitForTesting()
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predicate(), "bounded local test server condition")
    }

    @Test func cachedRowsPrecedeTransportAndSurviveSameHandleReconnect() async throws {
        try await withJoinedServer { try await checkCachedRowsAndReconnect() }
    }

    private func checkCachedRowsAndReconnect() async throws {
        let path = directory.appendingPathComponent("client.sqlite")
        do {
            let seed = try Lattice(DeferredSyncItem.self, configuration: .init(fileURL: path))
            defer { seed.close() }
            try seed.add(DeferredSyncItem("cached"))
        }

        var automatic = Lattice.Configuration(fileURL: path, authorizationToken: "fixture", wssEndpoint: server.endpoint)
        var deferred = automatic
        deferred.syncStartup = .deferred
        #expect(automatic != deferred)
        #expect(Set([automatic, deferred]).count == 2)
        automatic.syncStartup = .deferred
        #expect(automatic == deferred)
        #expect(automatic.hashValue == deferred.hashValue)

        let client = try Lattice(DeferredSyncItem.self, configuration: deferred)
        defer { client.close() }
        let identity = client.backend.identityHash
        let results = client.objects(DeferredSyncItem.self)
        #expect(results.count == 1)
        #expect(results.first?.value == "cached")
        #expect(!client.backend.isSyncAgent())
        #expect(!client.isSyncConnected)
        #expect(connects.value == 0)
        // Yield as an application would while rendering its first local snapshot.
        try await Task.sleep(for: .milliseconds(100))
        #expect(connects.value == 0)
        #expect(!client.backend.isSyncAgent())

        try client.connectSync()
        try await waitUntil { client.isSyncConnected && server.lattice.objects(DeferredSyncItem.self).count == 1 }
        let firstConnects = connects.value
        try client.connectSync() // Active start is idempotent.
        #expect(client.backend.identityHash == identity)
        try client.disconnectSync()
        #expect(!client.isSyncConnected)
        try client.add(DeferredSyncItem("written-while-paused"))
        #expect(results.count == 2)
        #expect(results.contains { $0.value == "cached" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(connects.value == firstConnects)

        try client.connectSync()
        try await waitUntil { client.isSyncConnected && server.lattice.objects(DeferredSyncItem.self).count == 2 }
        let secondConnects = connects.value
        try client.reconnectSync()
        try await waitUntil { client.isSyncConnected && connects.value > secondConnects }
        try client.add(DeferredSyncItem("after-reconnect"))
        try await waitUntil { server.lattice.objects(DeferredSyncItem.self).count == 3 }
        #expect(client.backend.identityHash == identity)
        #expect(results.count == 3)
        #expect(results.contains { $0.value == "cached" })
    }

    @Test func deferredAndAutomaticConfigurationsDoNotShareNativeCacheIdentity() async throws {
        try await withJoinedServer { try checkConfigurationIdentity() }
    }

    private func checkConfigurationIdentity() throws {
        let path = directory.appendingPathComponent("cache.sqlite")
        // No endpoint: isolate cache configuration identity without starting I/O.
        let automatic = try Lattice(DeferredSyncItem.self, configuration: .init(fileURL: path))
        defer { automatic.close() }
        let deferred = try Lattice(DeferredSyncItem.self,
            configuration: .init(fileURL: path, syncStartup: .deferred))
        defer { deferred.close() }
        #expect(automatic.backend.identityHash != deferred.backend.identityHash)
        try automatic.add(DeferredSyncItem("shared-file"))
        #expect(deferred.objects(DeferredSyncItem.self).first?.value == "shared-file")
    }
}
