import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

@Suite("Configured bootstrap bounded diagnostics", .timeLimit(.minutes(1)))
@MainActor
struct ConfiguredBootstrapDiagnosticTests {
    @Test func errnoDoesNotCopyItsDescription() throws {
        let detail = ConfiguredBootstrapErrorDetail(IOError(errnoCode: 13, reason: "private endpoint and token must not escape")).json
        #expect(detail["errno"] as? Int == 13)
        #expect(detail["connection"] is NSNull)
        let bytes = try JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys])
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("private endpoint"))
        #expect(!text.contains("description"))
    }

    @Test func connectionPrefixIsBoundedBeforeAccess() {
        var visited: [Int] = []
        let selected = ConfiguredBootstrapConnectionFailures(count: 1_000_000) { index in
            visited.append(index)
            return IOError(errnoCode: 13, reason: "not exported")
        }
        #expect(visited == [0, 1, 2, 3])
        #expect(selected.leaves.count == 4)
        #expect(selected.truncated)
        let empty = ConfiguredBootstrapConnectionFailures(count: 0) { _ in
            Issue.record("empty collection accessed a leaf")
            return IOError(errnoCode: 13, reason: "not exported")
        }
        #expect(empty.leaves.isEmpty)
        #expect(!empty.truncated)
    }

    @Test func originalPublicTLSAndUpgradeFactsRemainAvailable() throws {
        let error = NIOSSLError.handshakeFailed(.sslError(Array(repeating: .eofDuringHandshake, count: 9)))
        let tls = ConfiguredBootstrapErrorDetail(error).json
        #expect(tls["family"] as? String == "nioTLS")
        #expect(tls["wrapper"] as? String == "handshakeFailed")
        #expect(tls["tls"] as? String == "sslError")
        #expect(tls["stackCount"] as? Int == 8)
        #expect(tls["stackTruncated"] as? Bool == true)
        #expect(tls["eofDuringHandshake"] as? Bool == true)
        #expect(tls["connection"] is NSNull)
        let leaf = ConfiguredBootstrapErrorLeaf(error).json
        let fact = try #require(leaf["fact"] as? [String: Any])
        #expect(fact["kind"] as? String == "tls")
        #expect(fact["category"] as? String == "handshakeFailed")
        #expect(leaf["nestedConnection"] as? Bool == false)
        let upgrade = ConfiguredBootstrapErrorDetail(NIOHTTPClientUpgradeError.receivedResponseAfterUpgradeCompleted).json
        #expect(upgrade["family"] as? String == "nioHTTPUpgrade")
        #expect(upgrade["upgrade"] as? String == "receivedResponseAfterUpgradeCompleted")
    }

    @Test func actualPublicBootstrapWrapperRetainsOnlyItsBoundedLeaf() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var observed: (any Error)?
        do {
            // Happy Eyeballs creates the actual NIOConnectionError. Its real
            // channel initializer fails before connecting; no private wrapper
            // initializer, target or endpoint is read by the diagnostic.
            let channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
                .channelInitializer { channel in
                    channel.eventLoop.makeFailedFuture(IOError(errnoCode: 13, reason: "private initializer diagnostic"))
                }.connect(host: "127.0.0.1", port: 0).get()
            do { try await channel.close().get() }
            catch { observed = error }
            Issue.record("failing initializer unexpectedly connected")
        } catch { observed = error }
        // Always join the real event-loop owner before any throwing assertion.
        do { try await group.shutdownGracefully() }
        catch { Issue.record("owned event-loop shutdown failed"); throw error }
        let error = try #require(observed)
        #expect(error is NIOConnectionError)
        let detail = ConfiguredBootstrapErrorDetail(error).json
        let connection = try #require(detail["connection"] as? [String: Any])
        let leaves = try #require(connection["failures"] as? [[String: Any]])
        #expect(!leaves.isEmpty && leaves.count <= 4)
        #expect(leaves.allSatisfy { $0["errno"] as? Int == 13 })
        let nested = ConfiguredBootstrapErrorLeaf(error).json
        #expect(nested["nestedConnection"] as? Bool == true)
        let nestedDetail = try #require(nested["detail"] as? [String: Any])
        #expect(nestedDetail["family"] as? String == "unclassified")
        #expect(nestedDetail["connection"] == nil)
        let bytes = try JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys])
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("127.0.0.1"))
        #expect(!text.contains("private initializer"))
        #expect(!text.contains("target"))
    }

    @Test func conservativeFullReceiptBoundFitsExistingLimit() throws {
        // An upper bound, deliberately including mutually incompatible maximum
        // fields: longest allowlisted strings, negative Int32, false (five bytes),
        // all six leaves and every larger-case scalar key at its maximum. Actual
        // valid receipts are no longer than this compact ASCII representation.
        let base: [String: Any] = ["family": "nioHTTPUpgrade", "upgrade": "writingToHandlerAfterUpgradeCompleted",
            "wrapper": "handshakeFailed", "tls": "wantCertificateVerify", "stackCount": 8,
            "stackTruncated": false, "eofDuringHandshake": false, "eofDuringAdditionalValidation": false]
        let fact: [String: Any] = ["kind": "administrationInProgress", "domain": "recoveryConfiguration",
            "code": -2_147_483_648, "category": "unableToValidateCertificate"]
        let leaf: [String: Any] = ["fact": fact, "detail": base, "errno": -2_147_483_648, "nestedConnection": false]
        var detail = base
        detail["errno"] = -2_147_483_648
        detail["connection"] = ["dnsA": leaf, "dnsAAAA": leaf, "failures": Array(repeating: leaf, count: 4),
                                "failureCount": 4, "failuresTruncated": false] as [String: Any]
        let row = Dictionary(uniqueKeysWithValues: ["clientAttempt", "clientUpgrade", "channelEntered", "channelAccepted",
                                                   "authorizationEntered", "authorizationAccepted"].map { ($0, 32) })
        let observed: [String: Any] = ["currentIndex": NSNull(), "channels": [row, row], "sourceSetupEntered": 32,
                                      "sourceSetupFinished": 32, "overflow": false]
        let facts = Dictionary(uniqueKeysWithValues: ["freshAuthorizedConnections", "retiredConnectionsDrained",
            "lateConnectedReplays", "committedOriginals", "peerVisibleRows", "actualCollectedAttempts",
            "actualChildClosesAndSchedulerJoins"].map { ($0, 1024) })
        let receipt: [String: Any] = ["version": 4, "name": "publicConfiguredWrongHostFailureRetiresStockAttempt",
            "passed": false, "phase": "bootstrapRetirement", "scalarFacts": facts, "failure": fact,
            "diagnostic": ["bootstrap": observed, "error": detail]]
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        #expect(bytes.count == 3828)
        #expect(bytes.count <= 4096)
    }
}
