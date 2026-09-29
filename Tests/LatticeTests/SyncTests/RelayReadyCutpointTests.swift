import Foundation
import Testing
import Vapor
@testable import LatticeServerKit

// Copied-input tests only. Digest labels are deliberately opaque here; the real
// native caller performs authority/digest checks before this observation seam.
private struct CutpointFixture {
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

@Suite struct RelayReadyCutpointTests {
    @Test func positivePrepareBindsCompleteNestedQAndRawBytes() throws {
        let f = CutpointFixture(), q = try f.wire(f.request())
        let cut = try #require(f.copy(f.prepare(q), f.prepared))
        #expect(cut.kind == .positivePrepareLease)
        #expect(cut.frame.kind == .request && cut.frame.canonicalVersion == 2)
        #expect(cut.frame.receiverIncarnation == f.receiver && cut.frame.channelIncarnation == f.incarnation)
        #expect(cut.frame.channel == f.channel && cut.frame.attemptID == f.attempt && cut.frame.sequence == "1")
        #expect(cut.frame.routeGeneration == "9" && cut.requestDigest == f.digest)
        #expect(cut.requestFrameSHA256 == SHA256.hash(data: q).map { String(format: "%02x", $0) }.joined())
        #expect(cut.frame.normalizedFrameSHA256.count == 64)
        #expect(cut.frame.manifestDigest == nil && cut.frame.nativePageDigest == nil)
        let spaced = Data(([UInt8(32)] + Array(q)))
        let other = try #require(f.copy(f.prepare(spaced), f.prepared))
        #expect(other.requestFrameSHA256 != cut.requestFrameSHA256)
        #expect(other.frame.normalizedFrameSHA256 == cut.frame.normalizedFrameSHA256)
    }
    @Test func positiveV3PrepareValidatesRegisteredBinding() throws {
        let f = CutpointFixture()
        let cut = try #require(f.copy(f.prepare(f.wire(f.request(version: 3))), f.prepared))
        #expect(cut.frame.canonicalVersion == 3)
        for path in [["registered_producer", "cohortRevision"], ["registered_producer", "operationCodec"]] {
            let bad = f.replacing(f.request(version: 3), path: ["latticeCanonicalRange", "body"] + path, with: true)
            #expect(try f.copy(f.prepare(f.wire(bad)), f.prepared) == nil)
        }
    }
    @Test func statusOneNegativeControlNeverSelectsCut() throws {
        let f = CutpointFixture()
        var negative = f.prepared; negative["leaseAvailable"] = false
        #expect(try f.copy(f.prepare(), negative) == nil)
        let missing: [String: Any] = ["kind": "recoveryReady", "version": 1, "operation": "read", "requestID": f.requestID, "routeGeneration": "9", "settlement": f.settlement, "frameAvailable": false]
        #expect(try f.copy(f.read, missing) == nil)
        for status in [Int32(0), 2, -1] { #expect(try f.copy(f.prepare(), f.prepared, status: status) == nil) }
    }
    @Test func positivePrepareRequiresCommittedPublicationAndRealBoolean() throws {
        let f = CutpointFixture()
        for value in [false, 1, "true", NSNull()] as [Any] {
            #expect(try f.copy(f.prepare(), f.replacing(f.prepared, path: ["leaseAvailable"], with: value)) == nil)
        }
        for state in ["refused", "rolledBack", "unsettled", "ownershipLost", "unknown"] {
            #expect(try f.copy(f.prepare(), f.replacing(f.prepared, path: ["publication", "state"], with: state)) == nil)
        }
        #expect(try f.copy(f.prepare(), f.replacing(f.prepared, path: ["publication", "primaryError"], with: 0)) == nil)
    }
    @Test func prepareRefusesAllReturnedIdentityMismatches() throws {
        let f = CutpointFixture()
        for (key, value) in ["requestID": f.attempt, "operation": "resume", "routeGeneration": "10", "requestDigest": f.pageDigest, "attemptID": f.sourceID, "sequence": "2"] {
            #expect(try f.copy(f.prepare(), f.replacing(f.prepared, path: [key], with: value)) == nil)
        }
        #expect(try f.copy(f.prepare(), f.prepared, id: f.attempt) == nil)
        #expect(try f.copy(f.prepare(), f.prepared, channel: "other") == nil)
        let other = SyncRecoveryPeerIdentity(replicaID: "receiver", receiverIncarnation: UUID(uuidString: f.sourceID)!, channelIncarnation: UUID(uuidString: f.incarnation)!)
        #expect(try f.copy(f.prepare(), f.prepared, peer: other) == nil)
    }
    @Test func prepareRejectsNestedQShapeAndBindingMutations() throws {
        let f = CutpointFixture()
        let changes: [([String], Any)] = [
            (["kind"], "end"), (["version"], true), (["route_generation"], "10"),
            (["attempt", "attempt_id"], f.sourceID), (["attempt", "sequence"], "2"),
            (["attempt", "receiver_incarnation"], f.sourceID), (["attempt", "channel_incarnation"], f.sourceID),
            (["attempt", "channel"], "other"), (["body", "request_digest"], f.pageDigest),
            (["body", "source", "unknown"], "x"), (["body", "expected_install", "revision"], "1"),
            (["body", "limits", "items_per_page"], "0"), (["body", "base"], "0")]
        for (path, value) in changes {
            let q = f.replacing(f.request(), path: ["latticeCanonicalRange"] + path, with: value)
            #expect(try f.copy(f.prepare(f.wire(q)), f.prepared) == nil)
        }
    }
    @Test func canonicalReadKindsCarryOnlyActualBoundMetadata() throws {
        let f = CutpointFixture()
        let frames: [(RelayReadyCutpoint.Kind, [String: Any])] = [(.manifest, f.manifest()), (.contentPage, f.page()), (.receiptPage, f.page(receipt: true, version: 3)), (.end, f.frame(kind: "end", body: ["manifest_digest": f.manifestDigest]))]
        for (kind, output) in frames {
            let cut = try #require(f.copy(f.read, output))
            #expect(cut.kind == kind && cut.frame.routeGeneration == "9")
            #expect(cut.requestDigest == f.digest && cut.requestFrameSHA256 == nil)
            #expect(cut.frame.manifestDigest == f.manifestDigest)
        }
        let page = try #require(f.copy(f.read, f.page()))
        #expect(page.frame.pageIndex == "0" && page.frame.itemCount == "1" && page.frame.payloadBytes == "48")
        #expect(page.frame.nativePageDigest == f.pageDigest)
        #expect(try f.copy(f.read, f.request()) == nil)
    }
    @Test func readRequiresExactOperationRouteLogicalAndManifestDigest() throws {
        let f = CutpointFixture()
        for (key, value) in ["operation": "inspect", "routeGeneration": "8", "attemptID": f.sourceID, "sequence": "2", "requestID": f.sourceID] {
            #expect(try f.copy(f.replacing(f.read, path: [key], with: value), f.page()) == nil)
        }
        #expect(try f.copy(f.replacing(f.read, path: ["requestDigest"], with: f.pageDigest), f.manifest()) == nil)
        #expect(try f.copy(f.read, f.page(), channel: "other") == nil)
        let other = SyncRecoveryPeerIdentity(replicaID: "receiver", receiverIncarnation: UUID(uuidString: f.receiver)!, channelIncarnation: UUID(uuidString: f.sourceID)!)
        #expect(try f.copy(f.read, f.page(), peer: other) == nil)
    }
    @Test func numericStringsHaveCanonicalBoundedSpelling() throws {
        let f = CutpointFixture()
        for bad in ["", "01", "+1", "-1", "1.0", " 1", "9223372036854775808", 1, true] as [Any] {
            for key in ["routeGeneration", "sequence", "index"] {
                #expect(try f.copy(f.replacing(f.read, path: [key], with: bad), f.page()) == nil)
            }
        }
        #expect(try f.copy(f.replacing(f.read, path: ["routeGeneration"], with: "0"), f.page()) == nil)
        #expect(try f.copy(f.replacing(f.read, path: ["index"], with: "0"), f.manifest()) != nil)
        #expect(try f.copy(f.replacing(f.read, path: ["index"], with: "9223372036854775807"), f.page()) != nil)
    }
    @Test func routeOnlyNormalizationMatchesStoredPage() throws {
        let f = CutpointFixture()
        let source = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.page(route: "9"))))
        let stored = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.page(route: "1"))))
        #expect(source.routeGeneration == "9" && stored.routeGeneration == "1")
        #expect(source.normalizedFrameSHA256 == stored.normalizedFrameSHA256)
    }
    @Test func mutatedItemsCannotReuseNativeDigestLabel() throws {
        let f = CutpointFixture(), original = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.page())))
        for (key, value) in ["table": "Other", "id": "different", "payload": "{\"value\":[\"real\",2.5]}"] {
            let changed = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.replacingItem(f.page(), key: key, with: value))))
            #expect(changed.nativePageDigest == original.nativePageDigest)
            #expect(changed.normalizedFrameSHA256 != original.normalizedFrameSHA256)
        }
        let tombstone = f.replacing(f.page(), path: ["latticeCanonicalRange", "body", "items"], with: [["table": "Thing", "id": "item", "tag": "tombstone"]])
        let changed = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(tombstone)))
        #expect(changed.normalizedFrameSHA256 != original.normalizedFrameSHA256)
    }
    @Test func allNonRoutePageFieldsRemainInCommitment() throws {
        let f = CutpointFixture(), original = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.page())))
        let changes: [([String], Any)] = [
            (["version"], 3), (["attempt", "receiver_incarnation"], f.sourceID),
            (["attempt", "channel_incarnation"], f.sourceID), (["attempt", "channel"], "other"),
            (["attempt", "attempt_id"], f.sourceID), (["attempt", "sequence"], "2"),
            (["body", "manifest_digest"], f.digest), (["body", "index"], "1"),
            (["body", "bytes"], "49"), (["body", "digest"], f.digest)]
        for (path, value) in changes {
            let changed = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.replacing(f.page(), path: ["latticeCanonicalRange"] + path, with: value))))
            #expect(changed.normalizedFrameSHA256 != original.normalizedFrameSHA256)
        }
        let twoItems = f.replacing(f.replacing(f.page(), path: ["latticeCanonicalRange", "body", "items"], with: [f.present, ["table": "Thing", "id": "second", "tag": "tombstone"]]), path: ["latticeCanonicalRange", "body", "count"], with: "2")
        let more = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(twoItems)))
        #expect(more.normalizedFrameSHA256 != original.normalizedFrameSHA256)
        let reversed = f.replacing(twoItems, path: ["latticeCanonicalRange", "body", "items"], with: [["table": "Thing", "id": "second", "tag": "tombstone"], f.present])
        let reverse = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(reversed)))
        #expect(reverse.normalizedFrameSHA256 != more.normalizedFrameSHA256)
    }
    @Test func everyReceiptValueAndTypeRemainsInCommitment() throws {
        let f = CutpointFixture(), page = f.page(receipt: true, version: 3)
        let original = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(page)))
        let changes: [(String, Any)] = [("original_id", "other"), ("namespace_id", "other"), ("coverage_id", "other"), ("decision", "policy"), ("position", "2"), ("accepted_target", NSNull()), ("operation_digest", f.pageDigest), ("legacy_unbound", true)]
        for (key, value) in changes {
            let changed = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.replacingItem(page, key: key, with: value))))
            #expect(changed.normalizedFrameSHA256 != original.normalizedFrameSHA256)
        }
        #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(f.replacingItem(page, key: "legacy_unbound", with: 0))) == nil)
        #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(f.replacingItem(page, key: "position", with: 1))) == nil)
    }
    @Test func payloadIsAnOpaqueExactStringIncludingRealNumbersAndUnicode() throws {
        let f = CutpointFixture()
        var hashes = Set<String>()
        for payload in ["{\"r\":[\"real\",1.5]}", "{\"r\":[\"real\",1.50]}", "{\"t\":[\"text\",\"é/雪😀\"]}", "{\"t\":[\"text\",\"e\u{301}/雪😀\"]}"] {
            let frame = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.replacingItem(f.page(), key: "payload", with: payload))))
            hashes.insert(frame.normalizedFrameSHA256)
        }
        #expect(hashes.count == 4)
        #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(f.replacingItem(f.page(), key: "payload", with: ["r": 1.5]))) == nil)
    }
    @Test func duplicateIdenticalConflictingAndEscapedKeysAreRefused() throws {
        let f = CutpointFixture(), raw = String(decoding: try f.wire(f.page()), as: UTF8.self)
        for insertion in [#""version":2,"version":2"#, #""version":3,"version":2"#, #""\u0076ersion":2,"version":2"#] {
            let changed = raw.replacingOccurrences(of: #""version":2"#, with: insertion)
            #expect(changed != raw)
            #expect(RelayReadyCutpoint.canonicalFrame(Data(changed.utf8)) == nil)
        }
        let nested = String(decoding: try f.wire(f.request()), as: UTF8.self)
        let duplicate = nested.replacingOccurrences(of: #""sequence":"1""#, with: #""sequence":"1","\u0073equence":"1""#)
        #expect(try f.copy(f.prepare(Data(duplicate.utf8)), f.prepared) == nil)
        let input = String(decoding: try f.wire(f.read), as: UTF8.self).replacingOccurrences(of: #""operation":"read""#, with: #""operation":"read","operation":"read""#)
        #expect(RelayReadyCutpoint.copy(input: Data(input.utf8), output: try f.wire(f.page()), status: 1, requestID: f.requestID, peer: f.peer, channel: f.channel) == nil)
    }
    @Test func rawTokenGrammarRejectsFloatsInvalidEscapesSurrogatesAndTrailingInput() throws {
        let f = CutpointFixture(), raw = String(decoding: try f.wire(f.page()), as: UTF8.self)
        for version in ["2.0", "2e0", "02", "true", "null", "9223372036854775808"] {
            #expect(RelayReadyCutpoint.canonicalFrame(Data(raw.replacingOccurrences(of: #""version":2"#, with: "\"version\":" + version).utf8)) == nil)
        }
        for text in [#"\x"#, #"\uD800"#, #"\uDC00"#, #"\uD800\u0041"#, #"\u00xy"#, "\n"] {
            #expect(RelayReadyCutpoint.canonicalFrame(Data(raw.replacingOccurrences(of: #""id":"item""#, with: "\"id\":\"" + text + "\"").utf8)) == nil)
        }
        #expect(RelayReadyCutpoint.canonicalFrame(Data((raw + "{} ").utf8)) == nil)
        #expect(RelayReadyCutpoint.canonicalFrame(Data([0xFF]) + Data(raw.utf8)) == nil)
        #expect(RelayReadyCutpoint.canonicalFrame(Data(raw.dropLast().utf8)) == nil)
        #expect(RelayReadyCutpoint.canonicalFrame(Data((" \n" + raw + "\t ").utf8)) != nil)
    }
    @Test func legalEscapesPreserveDecodedCommitment() throws {
        let f = CutpointFixture(), raw = String(decoding: try f.wire(f.page()), as: UTF8.self)
        let escaped = raw.replacingOccurrences(of: #""id":"item""#, with: #""\u0069d":"\u0069tem""#)
        let a = try #require(RelayReadyCutpoint.canonicalFrame(Data(raw.utf8)))
        let b = try #require(RelayReadyCutpoint.canonicalFrame(Data(escaped.utf8)))
        #expect(a.normalizedFrameSHA256 == b.normalizedFrameSHA256)
        let unicode = raw.replacingOccurrences(of: #""id":"item""#, with: #""id":"\uD83D\uDE00""#)
        let literal = raw.replacingOccurrences(of: #""id":"item""#, with: "\"id\":\"😀\"")
        let c = try #require(RelayReadyCutpoint.canonicalFrame(Data(unicode.utf8)))
        let d = try #require(RelayReadyCutpoint.canonicalFrame(Data(literal.utf8)))
        #expect(c.normalizedFrameSHA256 == d.normalizedFrameSHA256)
    }
    @Test func unknownAndMissingFieldsNeverEnterCommitment() throws {
        let f = CutpointFixture()
        for path in [["new"], ["latticeCanonicalRange", "new"], ["latticeCanonicalRange", "attempt", "new"], ["latticeCanonicalRange", "body", "new"]] {
            #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(f.replacing(f.page(), path: path, with: 0))) == nil)
        }
        var missing = f.page()["latticeCanonicalRange"] as! [String: Any]; missing.removeValue(forKey: "route_generation")
        #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(["latticeCanonicalRange": missing])) == nil)
        #expect(try f.copy(f.replacing(f.read, path: ["unknown"], with: 0), f.page()) == nil)
        #expect(try f.copy(f.prepare(), f.replacing(f.prepared, path: ["unknown"], with: 0)) == nil)
    }
    @Test func tinyCutpointBoundsRefuseOversizedEncodedBuffersAndFields() throws {
        let f = CutpointFixture(), input = try f.wire(f.read), output = try f.wire(f.page())
        for oversizedInput in [true, false] {
            let oversized = Data(repeating: 32, count: 65_537)
            #expect(RelayReadyCutpoint.copy(input: oversizedInput ? oversized : input, output: oversizedInput ? output : oversized, status: 1, requestID: f.requestID, peer: f.peer, channel: f.channel) == nil)
        }
        let tooLong = f.replacingItem(f.page(), key: "id", with: String(repeating: "x", count: 257))
        #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(tooLong)) == nil)
        let tooMany = f.replacing(f.page(), path: ["latticeCanonicalRange", "body", "items"], with: Array(repeating: f.present, count: 257))
        #expect(RelayReadyCutpoint.canonicalFrame(try f.wire(tooMany)) == nil)
        let deep = Data((String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)).utf8)
        #expect(RelayReadyCutpoint.canonicalFrame(deep) == nil)
        let manyNodes = Data(("[" + Array(repeating: "[" + Array(repeating: "0", count: 256).joined(separator: ",") + "]", count: 16).joined(separator: ",") + "]").utf8)
        #expect(manyNodes.count < 65_536)
        #expect(RelayReadyCutpoint.canonicalFrame(manyNodes) == nil)
    }
    @Test func encodedInputExactBoundaryProducesBoundedCommitment() throws {
        let f = CutpointFixture()
        let base = String(decoding: try f.wire(f.page()), as: UTF8.self)
        let padded = Data((base + String(repeating: " ", count: 65_536 - base.utf8.count)).utf8)
        #expect(padded.count == 65_536)
        #expect(RelayReadyCutpoint.canonicalFrame(padded) != nil)
        #expect(RelayReadyCutpoint.canonicalFrame(padded + Data([32])) == nil)
    }
    @Test func syntaxBoundsAreEnforcedBeforeDictionaryConstruction() throws {
        func scan(_ text: String) throws { var scanner = ReadyCutpointSyntax(Data(text.utf8)); try scanner.validate() }
        // These controls exercise syntax alone, without the canonical shape
        // validator masking which depth/member/node bound rejected the bytes.
        try scan(String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16))
        #expect(throws: (any Error).self) { try scan(String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)) }
        try scan("[" + Array(repeating: "0", count: 256).joined(separator: ",") + "]")
        #expect(throws: (any Error).self) { try scan("[" + Array(repeating: "0", count: 257).joined(separator: ",") + "]") }
        func members(_ n: Int) -> String { "{" + (0..<n).map { "\"key\($0)\":0" }.joined(separator: ",") + "}" }
        try scan(members(32)); #expect(throws: (any Error).self) { try scan(members(33)) }
        let fullChild = "[" + Array(repeating: "0", count: 256).joined(separator: ",") + "]"
        // root(1) + fifteen children(15*257) + last child(1)+239 =4096.
        let prefix = "[" + Array(repeating: fullChild, count: 15).joined(separator: ",") + ",["
        try scan(prefix + Array(repeating: "0", count: 239).joined(separator: ",") + "]]")
        #expect(throws: (any Error).self) { try scan(prefix + Array(repeating: "0", count: 240).joined(separator: ",") + "]]") }
        #expect(throws: (any Error).self) { try scan(#"{"version":2,"\u0076ersion":2}"#) }
        #expect(throws: (any Error).self) { try scan(#"{"version":2.0}"#) }
    }
    @Test func nestedReceiptRequestsValidateCompleteV2AndV3Shapes() throws {
        let f = CutpointFixture()
        for version in [2, 3] {
            let item: [String: Any] = version == 2
                ? ["original_id": "original", "provenance": ["kind": "negotiated", "namespace_id": "ns"], "targets": [["table": "Thing", "id": "item"]]]
                : ["original_id": "original", "operation_digest": f.digest, "targets": [["table": "Thing", "id": "item"]]]
            let q = f.replacing(f.request(version: version), path: ["latticeCanonicalRange", "body", "receipt_requests"], with: [item])
            #expect(try f.copy(f.prepare(f.wire(q)), f.prepared) != nil)
            var malformed = item; malformed["targets"] = [["table": "Thing", "id": "item", "extra": "x"]]
            var duplicate = item; duplicate["targets"] = [["table": "Thing", "id": "item"], ["table": "Thing", "id": "item"]]
            for entries in [[item, item], [malformed], [duplicate]] {
                let bad = f.replacing(q, path: ["latticeCanonicalRange", "body", "receipt_requests"], with: entries)
                #expect(try f.copy(f.prepare(f.wire(bad)), f.prepared) == nil)
            }
        }
    }
    @Test func manifestSourceTotalsAndLeaseRemainInCommitment() throws {
        let f = CutpointFixture(), manifest = f.manifest(version: 3)
        let original = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(manifest)))
        let changes: [([String], Any)] = [(["request_digest"], f.pageDigest), (["source", "authority"], "other"),
            (["source", "source_id"], f.attempt), (["source", "epoch"], f.attempt), (["source", "scope_digest"], f.pageDigest),
            (["source", "schema_digest"], f.pageDigest), (["head"], "2"), (["lease", "id"], "other"),
            (["lease", "duration_ms"], "29999"), (["totals", "content_bytes"], "49"),
            (["content_digest"], f.pageDigest), (["receipt_digest"], f.pageDigest), (["rebase_digest"], f.pageDigest),
            (["manifest_digest"], f.pageDigest), (["registered_producer", "producer", "registrationID"], "other"),
            (["registered_producer", "cohortRevision"], 2), (["receipt_namespace"], "other"), (["coverage_revision"], "2")]
        for (path, value) in changes {
            let changed = try #require(RelayReadyCutpoint.canonicalFrame(f.wire(f.replacing(manifest, path: ["latticeCanonicalRange", "body"] + path, with: value))))
            #expect(changed.normalizedFrameSHA256 != original.normalizedFrameSHA256)
        }
    }
    @Test func existingObservationInitializerDefaultsToNoCutpoint() {
        let f = CutpointFixture()
        let old = RelayReadyControlObservation(connectionID: UUID(), peer: f.peer, channel: f.channel,
            requestID: f.requestID, operation: "prepare", routeGeneration: "9", requestDigest: nil,
            attemptID: nil, sequence: nil, index: nil, canonicalKind: nil)
        #expect(old.cutpoint == nil)
        #expect(old.operation == "prepare" && old.requestDigest == nil && old.canonicalKind == nil)
    }
}
