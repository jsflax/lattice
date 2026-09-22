import Foundation
import Testing
@testable import Lattice

@Suite struct RecoverySourceExpectationTests {
    private typealias Expectation = Lattice.RecoverySourceExpectation
    private func policy(_ endpoint: String = "wss://registered.example/sync?tenant=shared", channel: String = "shared") throws -> Expectation {
        let uuid = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let hash = String(repeating: "a", count: 64)
        return try Expectation(endpoint: URL(string: endpoint)!, source: .init(authority: "registered-source", sourceID: uuid, epoch: uuid,
            scopeDigest: hash, schemaDigest: hash, receiptNamespace: "shared-peers", coverageID: "coverage", coverageRevision: 1, descriptorDigest: hash),
            peer: .init(replicaID: "registered/replica", receiverIncarnation: uuid, channelIncarnation: uuid),
            incomingScope: .init(models: [.init(table: "SharedRow", incomingOperations: [.insert, .update, .delete])],
                relations: [], scopedLinkTables: [], catalogDigest: hash), channel: channel, validForMilliseconds: 60_000)
    }
    @Test func exactRegisteredPolicyIsImmutableAndBounded() throws {
        let value = try policy()
        let root = try #require(JSONSerialization.jsonObject(with: Data(value.nativePolicy.utf8)) as? [String: Any])
        #expect(Set(root.keys) == Set(["endpoint", "source", "incomingScope", "peer", "channel", "validForMilliseconds"]))
        let source = try #require(root["source"] as? [String: Any])
        #expect(source["receiptNamespace"] as? String == "shared-peers")
        let peer = try #require(root["peer"] as? [String: Any])
        #expect(peer["replicaID"] as? String == "registered/replica")
        #expect(peer["receiverIncarnation"] as? String == "10000000-0000-4000-8000-000000000001")
        #expect(value.nativePolicy.utf8.count <= 65_536)
        #expect(try policy().nativePolicy == value.nativePolicy)
    }
    @Test func ordinaryConfigurationDefaultsAndChangedPolicyCacheIdentity() throws {
        var a = Lattice.Configuration(fileURL: URL(fileURLWithPath: "/receiver-test.sqlite"))
        #expect(a.recoverySourceExpectation == nil)
        var b = a
        a.recoverySourceExpectation = try policy()
        b.recoverySourceExpectation = try policy(channel: "another-registered-channel")
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }
    @Test func insecureCredentialsFragmentsAndReservedQueryRefuse() {
        for endpoint in ["ws://registered.example/sync", "https://registered.example/sync", "wss://user:pass@registered.example/sync",
                         "wss://registered.example/sync#fragment", "wss://registered.example/sync?recovery-v=1",
                         "wss://registered.example/sync?%72ecovery-v=1", "wss://registered.example/sync?last-event-id=old"] {
            #expect(throws: (any Error).self) { try policy(endpoint) }
        }
    }
    @Test func originComparisonCannotBindChangedActualPeerOrPath() throws {
        let expected = try #require(PlatformTLSEndpoint(URL(string: "wss://registered.example:443/sync?channel=shared")!))
        #expect(PlatformTLSEndpoint(URL(string: "https://registered.example/sync?channel=shared")!, actualTask: true) == expected)
        for actual in ["https://other.example/sync?channel=shared", "https://registered.example:444/sync?channel=shared",
                       "https://registered.example/other?channel=shared", "https://registered.example/sync?channel=other",
                       "http://registered.example/sync?channel=shared"] {
            #expect(PlatformTLSEndpoint(URL(string: actual)!, actualTask: true) != expected)
        }
        #expect(PlatformTLSEndpoint(URL(string: "https://registered.example/sync?channel=shared")!) == nil)
    }
}
