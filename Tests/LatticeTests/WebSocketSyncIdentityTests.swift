import Foundation
import Testing
@testable import Lattice

@Suite("Stable WSS channel identity")
struct WebSocketSyncIdentityTests {
    private let legacy = URL(string: "wss://fixture.invalid/sync?schema=5")!
    private let current = URL(string: "wss://fixture.invalid/sync?schema=6")!

    @Test func defaultAndExplicitIdentityReachNativeConfigurationAsIndependentValues() {
        let original = Lattice.Configuration(storage: .memory(named: "identity-bridge"),
            wssEndpoint: current)
        #expect(original.wssSyncIdentity == nil)
        #expect(String(original.cxxConfiguration().get_websocket_sync_identity()).isEmpty)
        var configured = original
        configured.wssSyncIdentity = legacy
        // Copying a bridge getter must survive both native mutation and destruction.
        let copied = {
            var native = configured.cxxConfiguration()
            let value = native.get_websocket_sync_identity()
            native.set_websocket_sync_identity(.init(current.absoluteString))
            return value
        }()
        #expect(String(copied) == legacy.absoluteString)
        #expect(configured.wssEndpoint == current)
        #expect(original.wssEndpoint == current)
        #expect(original.wssSyncIdentity == nil)
    }

    @Test func configurationEqualityAndHashIncludeLogicalIdentity() {
        let original = Lattice.Configuration(storage: .memory(named: "identity-equality"),
            wssEndpoint: current)
        var first = original
        first.wssSyncIdentity = legacy
        var second = first
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        second.wssSyncIdentity = current
        #expect(first != original)
        #expect(first != second)
        #expect(Set([original, first, second]).count == 3)
    }

    @Test func derivedManagedReaderDropsLogicalIdentityWithTransport() {
        let original = Lattice.Configuration(fileURL: URL(fileURLWithPath: "/unused/identity-policy.sqlite"),
            authorizationToken: "fixture", wssEndpoint: current, wssSyncIdentity: legacy,
            backgroundSync: .appRefresh(identifier: "fixture.identity.refresh"))
        let derived = original.withoutBackgroundTaskOwnership(queryOnly: true)
        #expect(derived.wssEndpoint == nil)
        #expect(derived.wssSyncIdentity == nil)
        #expect(derived.authorizationToken == nil)
        #expect(derived.backgroundSync == nil)
        #expect(derived.backgroundSyncManaged)
        #expect(String(derived.cxxConfiguration().get_websocket_sync_identity()).isEmpty)
        #expect(original.wssSyncIdentity == legacy)
    }

    @Test func distinctLogicalIdentitiesDoNotShareTheCachedNativeHandle() throws {
        let original = Lattice.Configuration(storage: .memory(named: "identity-cache-" + UUID().uuidString),
            authorizationToken: "fixture", wssEndpoint: current, syncStartup: .deferred)
        var configured = original
        configured.wssSyncIdentity = legacy
        let first = try Lattice(configuration: original)
        defer { first.close() }
        let second = try Lattice(configuration: configured)
        defer { second.close() }
        #expect(first.backend.identityHash != second.backend.identityHash)
        #expect(!first.backend.isSyncAgent())
        #expect(!second.backend.isSyncAgent())
        #expect(!first.isSyncConnected && !second.isSyncConnected)
    }
}
