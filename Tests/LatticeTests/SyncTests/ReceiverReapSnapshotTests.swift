import Foundation
import Testing
@testable import LatticeServerKit
import RecoveryProcessSupport
import Lattice
import Vapor

private struct ReapFrameFixture {
    let receiver = "11111111-1111-4111-8111-111111111111"
    let incarnation = "22222222-2222-4222-8222-222222222222"
    let attempt = "33333333-3333-4333-8333-333333333333"
    let requestID = "44444444-4444-4444-8444-444444444444"
    let sourceID = "55555555-5555-4555-8555-555555555555"
    let digest = String(repeating: "a", count: 64)
    let manifestDigest = String(repeating: "b", count: 64)
    let pageDigest = String(repeating: "c", count: 64)
    let channel = "main"
    var peer: SyncRecoveryPeerIdentity {
        .init(replicaID: "receiver", receiverIncarnation: UUID(uuidString: receiver)!, channelIncarnation: UUID(uuidString: incarnation)!)
    }
    var source: [String: Any] { ["authority": "authority", "source_id": sourceID, "epoch": sourceID, "scope_digest": digest, "schema_digest": digest] }
    var logical: [String: Any] { ["receiver_incarnation": receiver, "channel_incarnation": incarnation, "channel": channel, "sequence": "1", "attempt_id": attempt] }
    var registered: [String: Any] { ["producer": ["registrationID": "producer", "incarnation": receiver], "cohortID": sourceID, "cohortRevision": 1, "operationCodec": 1] }
    var settlement: [String: Any] { ["state": "committed", "unexpectedCommitObserved": false, "primaryError": false, "cleanupError": false, "postcommitError": false, "notificationError": false] }
    func wire(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    func frame(kind: String, body: [String: Any], route: String = "9", version: Int = 2) -> [String: Any] {
        ["latticeCanonicalRange": ["version": version, "attempt": logical, "route_generation": route, "kind": kind, "body": body]]
    }
    func request(version: Int = 2) -> [String: Any] {
        var body: [String: Any] = ["source": source, "mode": "full", "base": NSNull(),
            "expected_install": ["revision": "0", "binding": NSNull(), "frontier": ["kind": "uninitialized"]],
            "limits": ["frame_bytes": "65536", "payload_bytes": "32768", "items_per_page": "64", "content_pages": "8", "content_identities": "128", "content_bytes": "65536", "receipt_pages": "8", "receipts": "128", "receipt_bytes": "65536"],
            "receipt_requests": [], "request_digest": digest]
        if version == 3 { body["registered_producer"] = registered; body["receipt_namespace"] = "ns" }
        return frame(kind: "request", body: body, version: version)
    }
    func prepare(_ nested: Data? = nil) throws -> [String: Any] {
        let bytes = try nested ?? wire(request())
        return ["kind": "recoveryReady", "version": 1, "operation": "prepare", "requestID": requestID,
                "routeGeneration": "9", "durationMilliseconds": 30000,
                "request": String(decoding: bytes, as: UTF8.self)]
    }
    var prepared: [String: Any] {
        ["kind": "recoveryReady", "version": 1, "operation": "prepare", "requestID": requestID, "routeGeneration": "9",
         "expiration": settlement, "preparation": settlement, "publication": settlement,
         "captureError": false, "requiresFullRequest": false, "leaseAvailable": true, "leaseID": "9:1",
         "requestDigest": digest, "attemptID": attempt, "sequence": "1", "frames": "3", "wireBytes": "1200", "durationMilliseconds": 30000]
    }
    var read: [String: Any] { ["kind": "recoveryReady", "version": 1, "operation": "read", "requestID": requestID, "routeGeneration": "9", "leaseID": "9:1", "requestDigest": digest, "attemptID": attempt, "sequence": "1", "index": "1"] }
    var present: [String: Any] { ["table": "Thing", "id": "item", "tag": "present", "payload": "{\"value\":[\"real\",1.5]}"] }
    func page(receipt: Bool = false, version: Int = 2, route: String = "9") -> [String: Any] {
        var item: [String: Any] = present
        if receipt {
            item = ["original_id": "original", "status": "committed", "namespace_id": "ns", "coverage_id": "coverage", "decision": "applied", "position": "1", "accepted_target": ["table": "Thing", "id": "item"]]
            if version == 3 { item["operation_digest"] = digest; item["legacy_unbound"] = false }
        }
        return frame(kind: receipt ? "receipt_page" : "content_page", body: ["manifest_digest": manifestDigest, "index": "0", "count": "1", "bytes": "48", "digest": pageDigest, "items": [item]], route: route, version: version)
    }
    func manifest(version: Int = 2) -> [String: Any] {
        var body: [String: Any] = ["request_digest": digest, "source": source, "mode": "full", "base": NSNull(), "head": "1",
            "lease": ["id": "lease", "duration_ms": "30000"],
            "totals": ["content_pages": "1", "identities": "1", "present": "1", "tombstones": "0", "content_bytes": "48", "receipt_pages": "0", "receipts": "0", "receipt_bytes": "0", "rebase_identities": "0", "rebase_bytes": "0"],
            "content_digest": digest, "receipt_digest": digest, "rebase_digest": digest, "manifest_digest": manifestDigest]
        if version == 3 { body["registered_producer"] = registered; body["receipt_namespace"] = "ns"; body["coverage_revision"] = "1" }
        return frame(kind: "manifest", body: body, version: version)
    }
    func copy(_ input: [String: Any], _ output: [String: Any], status: Int32 = 1,
              id: String? = nil, peer: SyncRecoveryPeerIdentity? = nil, channel: String? = nil) throws -> RelayReadyCutpoint? {
        RelayReadyCutpoint.copy(input: try wire(input), output: try wire(output), status: status,
            requestID: id ?? requestID, peer: peer ?? self.peer, channel: channel ?? self.channel)
    }
    func replacing(_ value: [String: Any], path: [String], with replacement: Any) -> [String: Any] {
        var result = value
        if path.count == 1 { result[path[0]] = replacement }
        else { result[path[0]] = replacing(value[path[0]] as! [String: Any], path: Array(path.dropFirst()), with: replacement) }
        return result
    }
    func replacingItem(_ value: [String: Any], key: String, with replacement: Any) -> [String: Any] {
        let envelope = value["latticeCanonicalRange"] as! [String: Any], body = envelope["body"] as! [String: Any]
        var items = body["items"] as! [[String: Any]]; items[0][key] = replacement
        return replacing(value, path: ["latticeCanonicalRange", "body", "items"], with: items)
    }
}


private extension ReapFrameFixture {
    func progress(receipt: Bool = false) -> [String: Any] {
        let q = request(), m = manifest(), qEnvelope = q["latticeCanonicalRange"] as! [String: Any]
        let mEnvelope = m["latticeCanonicalRange"] as! [String: Any]
        return ["latticeCanonicalRangeState": ["version": 2, "attempt": logical,
            "request": qEnvelope["body"]!, "manifest": mEnvelope["body"]!, "phase": "receiving",
            "next_content_page": receipt ? "0" : "1", "next_receipt_page": receipt ? "1" : "0",
            "identities": receipt ? "0" : "1", "present": receipt ? "0" : "1", "tombstones": "0",
            "content_bytes": receipt ? "0" : "48", "receipts": receipt ? "1" : "0", "receipt_bytes": receipt ? "48" : "0",
            "last_identity": receipt ? NSNull() : ["table": "Thing", "id": "item"], "rebase_seen": ""]]
    }
    func check(_ state: [String: Any]? = nil, page changed: [String: Any]? = nil,
               observed: [String: Any]? = nil, q: [String: Any]? = nil, m: [String: Any]? = nil) throws {
        let metadata = try #require(RelayReadyCutpoint.canonicalFrame(wire(observed ?? page())))
        try ReceiverReapComparison.partialState(wire(state ?? progress()), q: wire(q ?? request()),
            manifest: wire(m ?? manifest()), page: wire(changed ?? page(route: "1")), observedPage: metadata)
    }
}

@Suite struct ReceiverReapSnapshotTests {
    private func configuration() throws -> RecoveryProcessConfiguration {
        let source = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let epoch = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let receiver = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let digest = String(repeating: "a", count: 64)
        let scope = Lattice.RecoverySourceExpectation.Scope(models: [.init(table: "RecoveryProcessSharedRow", incomingOperations: [.insert, .update, .delete])],
            relations: [], scopedLinkTables: [], catalogDigest: digest)
        let claim = try RecoveryProcessCodec.encode(scope)
        let coverage = try Lattice.RecoverySourceExpectation.ReceiptCoverage(cohortID: source, cohortRevision: 1, namespaces: ["a", "b"])
        let channels = try ["a", "b"].enumerated().map { index, namespace in
            let endpoint = URL(string: "wss://127.0.0.1:1234/\(namespace)")!
            let channel = UUID(uuidString: index == 0 ? "44444444-4444-4444-4444-444444444444" : "55555555-5555-5555-5555-555555555555")!
            let expected = try Lattice.RecoverySourceExpectation(endpoint: endpoint,
                source: .init(authority: "c-service", sourceID: source, epoch: epoch, scopeDigest: digest, schemaDigest: digest,
                    receiptNamespace: namespace, coverageID: "shared-v1", coverageRevision: 1, descriptorDigest: digest, receiptCoverage: coverage),
                peer: .init(replicaID: "receiver-a", receiverIncarnation: receiver, channelIncarnation: channel),
                incomingScope: scope, channel: "wss:" + endpoint.absoluteString, validForMilliseconds: 600_000)
            return try RecoveryProcessChannelConfiguration(expectation: expected, incomingGrantClaim: claim)
        }
        return try .init(nonce: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!, deadlineNanoseconds: 100_000_000_000,
            storeDirectory: "receiver-a.lattice-continuous", authorizationToken: "c-test-token", channels: channels)
    }

    @Test func policyManifestBindsPhysicalPathAndNormalizesOnlyContributionOrder() throws {
        let c = try configuration(), file = URL(fileURLWithPath: "/owned/case/receiver-a.lattice-continuous/store.sqlite")
        let expected = try ReceiverReapComparison.policyManifest(c, file: file)
        let reversed = try RecoveryProcessConfiguration(nonce: UUID(uuidString: c.nonce)!, deadlineNanoseconds: c.deadlineNanoseconds,
            storeDirectory: c.storeDirectory, authorizationToken: c.authorizationToken, channels: Array(c.channels.reversed()))
        #expect(try ReceiverReapComparison.policyManifest(reversed, file: file) == expected)
        #expect(try ReceiverReapComparison.policyManifest(c, file: URL(fileURLWithPath: "/other/case/receiver-a.lattice-continuous/store.sqlite")) != expected)
        #expect(expected.range(of: Data("lattice-continuous-canonical-receiver-v2".utf8)) != nil)
        #expect(expected.suffix(file.path.utf8.count) == Data(file.path.utf8))
    }
    @Test func actualPrepareObserverUsesNestedCutpointInsteadOfAbsentTopLevelFields() throws {
        let f = ReapFrameFixture(), c = try configuration().channels[0]
        var q = f.request()
        for (key,value) in [("receiver_incarnation",c.receiverIncarnation),("channel_incarnation",c.channelIncarnation),("channel",c.channel)] {
            q = f.replacing(q, path: ["latticeCanonicalRange","attempt",key], with: value)
        }
        let peer = SyncRecoveryPeerIdentity(replicaID: c.replicaID, receiverIncarnation: UUID(uuidString: c.receiverIncarnation)!,
            channelIncarnation: UUID(uuidString: c.channelIncarnation)!)
        let qData = try f.wire(q), control = try f.wire(f.prepare(qData))
        let cut = try #require(RelayReadyCutpoint.copy(input: control, output: f.wire(f.prepared), status: 1,
            requestID: f.requestID, peer: peer, channel: c.channel))
        let observed = RelayReadyControlObservation(connectionID: UUID(), peer: peer, channel: c.channel,
            requestID: f.requestID, operation: "prepare", routeGeneration: "9", requestDigest: nil,
            attemptID: nil, sequence: nil, index: nil, canonicalKind: nil, cutpoint: cut)
        let qMeta = try ReceiverReapComparison.frame(qData)
        _ = try ReceiverReapComparison.boundObservation(observed, to: qMeta, channel: c)
        let malformed = RelayReadyControlObservation(connectionID: observed.connectionID, peer: peer, channel: c.channel,
            requestID: f.requestID, operation: "prepare", routeGeneration: "9", requestDigest: f.digest,
            attemptID: nil, sequence: nil, index: nil, canonicalKind: nil, cutpoint: cut)
        #expect(throws: (any Error).self) { _ = try ReceiverReapComparison.boundObservation(malformed, to: qMeta, channel: c) }
    }
    @Test func exactPartialPageAcceptsOnlyRouteNormalization() throws {
        let f = ReapFrameFixture()
        try f.check()
        let stored = try f.wire(f.page(route: "1")), observed = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.page())))
        try ReceiverReapComparison.sameFrame(stored, observed: observed, storedRoute: "1")
        #expect(throws: (any Error).self) { try ReceiverReapComparison.sameFrame(f.wire(f.page(route: "9")), observed: observed, storedRoute: "1") }
    }
    @Test func alteredPayloadCannotHideBehindUnchangedNativeDigestLabel() throws {
        let f = ReapFrameFixture()
        let changed = f.replacingItem(f.page(route: "1"), key: "payload", with: "{\"value\":[\"real\",2.5]}")
        #expect(throws: (any Error).self) { try f.check(page: changed) }
        #expect((changed["latticeCanonicalRange"] as! [String: Any])["body"] is [String: Any])
    }
    @Test func changedLogicalIdentityProfileOrManifestCannotPassStoredPageProof() throws {
        let f = ReapFrameFixture()
        for (path, value) in [(["attempt","sequence"], "2"), (["attempt","attempt_id"], f.sourceID),
                              (["body","manifest_digest"], f.digest), (["body","digest"], f.digest)] {
            let bad = f.replacing(f.page(route: "1"), path: ["latticeCanonicalRange"] + path, with: value)
            #expect(throws: (any Error).self) { try f.check(page: bad) }
        }
        #expect(throws: (any Error).self) { try f.check(page: f.page(version: 3, route: "1")) }
    }
    @Test func progressMustBeExactlyOnePageAndStillReceiving() throws {
        let f = ReapFrameFixture()
        for (key, value) in [("next_content_page","0"),("next_content_page","2"),("next_receipt_page","1"),
                             ("phase","sequence_complete_unverified"),("identities","0"),("present","0"),
                             ("tombstones","1"),("content_bytes","47"),("receipts","1"),("receipt_bytes","1")] {
            let state = f.replacing(f.progress(), path: ["latticeCanonicalRangeState",key], with: value)
            #expect(throws: (any Error).self) { try f.check(state) }
        }
    }
    @Test func restartBodiesMustMatchCompleteQAndManifest() throws {
        let f = ReapFrameFixture()
        for (path, value) in [(["request","request_digest"], f.manifestDigest),
                              (["request","limits","items_per_page"], "63"),
                              (["manifest","lease","id"], "other-lease"),
                              (["manifest","content_digest"], f.pageDigest)] {
            let state = f.replacing(f.progress(), path: ["latticeCanonicalRangeState"] + path, with: value)
            #expect(throws: (any Error).self) { try f.check(state) }
        }
    }
    @Test func lastIdentityAndRebaseBitmapAreNotOnlyNonemptyChecks() throws {
        let f = ReapFrameFixture()
        for (key, value) in [("last_identity", NSNull() as Any),
                             ("last_identity", ["table":"Thing","id":"wrong"] as Any),
                             ("rebase_seen", "1" as Any)] {
            #expect(throws: (any Error).self) { try f.check(f.replacing(f.progress(), path: ["latticeCanonicalRangeState",key], with: value)) }
        }
    }
    @Test func receiptFirstPageRequiresEmptyContentStreamAndExactReceiptProgress() throws {
        let f = ReapFrameFixture()
        var m = f.manifest()
        for key in ["content_pages","identities","present","content_bytes"] {
            m = f.replacing(m, path: ["latticeCanonicalRange","body","totals",key], with: "0")
        }
        for (key,value) in [("receipt_pages","1"),("receipts","1"),("receipt_bytes","48")] {
            m = f.replacing(m, path: ["latticeCanonicalRange","body","totals",key], with: value)
        }
        let body = (m["latticeCanonicalRange"] as! [String:Any])["body"]!
        let state = f.replacing(f.progress(receipt: true), path: ["latticeCanonicalRangeState","manifest"], with: body)
        try f.check(state, page: f.page(receipt: true, route: "1"), observed: f.page(receipt: true), m: m)
        #expect(throws: (any Error).self) {
            try f.check(f.replacing(state, path: ["latticeCanonicalRangeState","receipts"], with: "0"),
                page: f.page(receipt: true, route: "1"), observed: f.page(receipt: true), m: m)
        }
    }
    @Test func rebaseBitmapMustTrackActualPageLastIdentity() throws {
        let f = ReapFrameFixture()
        let q = f.replacing(f.request(), path: ["latticeCanonicalRange","body","receipt_requests"], with:
            [["original_id":"original", "targets":[["table":"Thing","id":"item"]], "provenance":["kind":"unknown"]]])
        let qBody = (q["latticeCanonicalRange"] as! [String:Any])["body"]!
        var state = f.replacing(f.progress(), path: ["latticeCanonicalRangeState","request"], with: qBody)
        state = f.replacing(state, path: ["latticeCanonicalRangeState","rebase_seen"], with: "1")
        try f.check(state, q: q)
        #expect(throws: (any Error).self) { try f.check(f.replacing(state, path: ["latticeCanonicalRangeState","rebase_seen"], with: "0"), q: q) }
    }
    @Test func duplicateKeysInvalidUTF8AndOversizedRawNeverReachDictionaryComparison() throws {
        for raw in [Data("{\"x\":0,\"x\":1}".utf8), Data("{\"x\":0,\"\\u0078\":1}".utf8),
                    Data([123,34,120,34,58,34,255,34,125]), Data(repeating: 32, count: 65_537)] {
            #expect(throws: (any Error).self) { _ = try ReceiverReapComparison.object(raw) }
        }
    }
    @Test func stateCountersRejectBooleanFloatLeadingZeroAndOverflow() throws {
        let f = ReapFrameFixture()
        for value in [true, 1.0, "01", "9223372036854775808", "-1"] as [Any] {
            #expect(throws: (any Error).self) { try f.check(f.replacing(f.progress(), path: ["latticeCanonicalRangeState","identities"], with: value)) }
        }
    }
    @Test func strictTypedOriginalComparisonRetainsNullsAndIntegerKind() throws {
        let raw = Data("{\"label\":null,\"value\":101}".utf8)
        let typed = Data("{\"label\":{\"kind\":4,\"value\":null},\"value\":{\"kind\":0,\"value\":101}}".utf8)
        try ReceiverReapComparison.rawFields(raw, match: typed, table: "RecoveryProcessSharedRow")
        for altered in ["{\"label\":null,\"value\":true}", "{\"label\":null,\"value\":101.0}", "{\"value\":101}", "{\"label\":\"lost\",\"value\":101}"] {
            #expect(throws: (any Error).self) { try ReceiverReapComparison.rawFields(Data(altered.utf8), match: typed, table: "RecoveryProcessSharedRow") }
        }
        for kind in [2,3,5,6,7] {
            let bad = Data("{\"label\":{\"kind\":4,\"value\":null},\"value\":{\"kind\":\(kind),\"value\":101}}".utf8)
            #expect(throws: (any Error).self) { try ReceiverReapComparison.rawFields(raw, match: bad, table: "RecoveryProcessSharedRow") }
        }
    }
    @Test func originalFieldInventoryCannotAddOrSilentlyNormalizeUnsupportedValues() throws {
        let unknown = Data("{\"extra\":{\"kind\":4,\"value\":null}}".utf8)
        #expect(throws: (any Error).self) { try ReceiverReapComparison.rawFields(Data("{\"extra\":null}".utf8), match: unknown, table: "RecoveryProcessSharedRow") }
        #expect(throws: (any Error).self) { try ReceiverReapComparison.rawFields(Data("{\"value\":101}".utf8), match: Data("{\"value\":{\"kind\":true,\"value\":101}}".utf8), table: "RecoveryProcessSharedRow") }
    }
    @Test func duplicateChannelCannotSatisfyExactSingleRowLookup() throws {
        let channel = Data("channel".utf8), row = QuietACKRow(cells: ["channel": .blob(channel)])
        #expect(try ReceiverReapComparison.row([row], channel: channel) == row)
        #expect(throws: (any Error).self) { _ = try ReceiverReapComparison.row([], channel: channel) }
        #expect(throws: (any Error).self) { _ = try ReceiverReapComparison.row([row,row], channel: channel) }
    }
}
