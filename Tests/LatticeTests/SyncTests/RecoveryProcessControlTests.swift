import Foundation
import Testing
import Lattice
import RecoveryProcessSupport

/// Copied bytes/public configuration only. These tests do not spawn children,
/// open stores, inspect trust, or claim real kill/reopen qualification.
@Suite("Recovery process control validation")
struct RecoveryProcessControlTests {
    private let nonce = "01234567-89ab-cdef-0123-456789abcdef"
    private func rejects(_ body: () throws -> Void) {
        do { try body(); Issue.record("invalid C control/configuration was accepted") } catch {}
    }
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
        return try .init(nonce: UUID(uuidString: nonce)!, deadlineNanoseconds: 100_000_000_000,
            storeDirectory: "receiver-a.lattice-continuous", authorizationToken: "c-test-token", channels: channels)
    }
    private func mutated(_ data: Data, _ transform: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); transform(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    @Test func completePublicPolicyAndClaimsRoundTripByteExact() throws {
        let value = try configuration(), bytes = try RecoveryProcessCodec.encode(value)
        let decoded = try RecoveryProcessCodec.decode(RecoveryProcessConfiguration.self, from: bytes)
        try decoded.validate(); try decoded.validateDeadline(now: 1)
        #expect(value == decoded)
        #expect(try RecoveryProcessCodec.encode(decoded) == bytes)
        #expect(decoded.channels[0].incomingGrantClaim == decoded.channels[1].incomingGrantClaim)
        #expect(decoded.channels[0].replicaID == decoded.channels[1].replicaID)
        #expect(decoded.channels[0].channelIncarnation != decoded.channels[1].channelIncarnation)
        #expect(decoded.recovery == "automatic" && decoded.limits == .standard)
        for channel in decoded.channels {
            let expectation = try channel.expectation()
            #expect(try RecoveryProcessCodec.encode(expectation.incomingScope) == channel.incomingGrantClaim)
        }
    }
    @Test func changedSavedPolicyPathsIdentityAndNumericTypesRefuse() throws {
        let bytes = try RecoveryProcessCodec.encode(configuration())
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["recovery"] = "disabled" }, { $0["storeDirectory"] = "../other.sqlite" },
            { $0["unknown"] = 1 }, { $0["version"] = true }, { $0["deadlineNanoseconds"] = 1.5 },
            { var limits = $0["limits"] as! [String: Any]; limits["owners"] = 9; $0["limits"] = limits },
            { var channels = $0["channels"] as! [[String: Any]]; channels[1]["replicaID"] = "other"; $0["channels"] = channels },
            { var channels = $0["channels"] as! [[String: Any]]; channels[1]["incomingGrantClaim"] = Data("{}".utf8).base64EncodedString(); $0["channels"] = channels }
        ]
        for mutation in mutations {
            let changed = try mutated(bytes, mutation)
            rejects { let value = try RecoveryProcessCodec.decode(RecoveryProcessConfiguration.self, from: changed); try value.validate() }
        }
        rejects { try configuration().validateDeadline(now: 100_000_000_000) }
    }
    @Test func duplicateEscapedKeysRealNumbersUnknownFieldsAndMalformedUnicodeRefuse() throws {
        let command = RecoveryProcessCommand(nonce: nonce, sequence: 1, operation: .start, role: .initial)
        let bytes = try RecoveryProcessCodec.encode(command), text = String(decoding: bytes, as: UTF8.self)
        let invalid = [text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"v\\u0065rsion\":1"),
            text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.0"),
            text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1e0"),
            text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":true"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"extra\":null,\"version\":1"),
            text.replacingOccurrences(of: nonce, with: "\\uD800"), text + " ", String(text.dropLast())]
        for value in invalid { rejects { _ = try RecoveryProcessCodec.decode(RecoveryProcessCommand.self, from: Data(value.utf8)) } }
        #expect(try RecoveryProcessCodec.decode(RecoveryProcessCommand.self, from: bytes) == command)
    }
    @Test func frameAndSyntaxCapsRefuseBeforeUnboundedAccumulation() throws {
        rejects { _ = try RecoveryProcessCodec.frame(Data(repeating: 0, count: 65_537)) }
        var frame = RecoveryProcessFramer()
        rejects { try frame.append(Data([0, 1, 0, 1])) }
        var zero = RecoveryProcessFramer(); rejects { try zero.append(Data([0, 0, 0, 0])) }
        let nested = Data((String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)).utf8)
        rejects { _ = try RecoveryProcessCodec.decode([Int].self, from: nested) }
        let large = Data(("[" + Array(repeating: "0", count: 257).joined(separator: ",") + "]").utf8)
        rejects { _ = try RecoveryProcessCodec.decode([Int].self, from: large) }
        let payload = Data("{}".utf8), encoded = try RecoveryProcessCodec.frame(payload)
        var split = RecoveryProcessFramer()
        for byte in encoded.dropLast() { try split.append(Data([byte])); #expect(split.take() == nil) }
        try split.append(Data([encoded.last!])); #expect(split.take() == payload); #expect(split.count == 0)
        var doubled = RecoveryProcessFramer(); rejects { try doubled.append(encoded + encoded) }
    }
    @Test func immutableCommandSequenceDoesNotPermitInspectAfterReconnectOrSecondWrite() throws {
        var initial = RecoveryProcessCommandState(), reopened = RecoveryProcessCommandState()
        let image = RecoveryProcessImage(rows: [], localValues: [], originals: [])
        func command(_ n: Int, _ op: RecoveryProcessOperation, role: RecoveryProcessRole? = nil) -> RecoveryProcessCommand {
            .init(nonce: nonce, sequence: n, operation: op, role: role, expected: op == .settle ? image : nil)
        }
        try initial.accept(command(1, .start, role: .initial), nonce: nonce)
        rejects { try initial.accept(command(3, .settle), nonce: nonce) }
        try initial.accept(command(2, .settle), nonce: nonce)
        try initial.accept(command(3, .offlineEdit), nonce: nonce)
        try initial.accept(command(4, .reconnect), nonce: nonce)
        rejects { try initial.accept(command(5, .settle), nonce: nonce) }
        #expect(initial.lastSequence == 4)
        try reopened.accept(command(1, .start, role: .reopened), nonce: nonce)
        try reopened.accept(command(2, .settle), nonce: nonce)
        rejects { try reopened.accept(command(3, .offlineEdit), nonce: nonce) }
        try reopened.accept(command(3, .postWrite), nonce: nonce)
        try reopened.accept(command(4, .settle), nonce: nonce)
        rejects { try reopened.accept(command(5, .postWrite), nonce: nonce) }
        try reopened.accept(command(5, .close), nonce: nonce)
        #expect(reopened.phase == .closed)
    }
    @Test func repliesCannotConvertFailureToCommittedStateOrChangeCorrelation() throws {
        let command = RecoveryProcessCommand(nonce: nonce, sequence: 2, operation: .settle,
            expected: .init(rows: [], localValues: [], originals: []))
        let failed = RecoveryProcessReply(command: command, failure: .deadline)
        try failed.validate(for: command)
        rejects { try RecoveryProcessReply(command: command, failure: .deadline, image: command.expected, committedOpen: true).validate(for: command) }
        rejects { try RecoveryProcessReply(command: command, image: command.expected, committedOpen: false).validate(for: command) }
        let changed = RecoveryProcessCommand(nonce: nonce, sequence: 3, operation: .settle, expected: command.expected)
        rejects { try failed.validate(for: changed) }
        try RecoveryProcessReply(command: command, image: command.expected, committedOpen: true).validate(for: command)
    }
    @Test func incrementalCommitmentsUseExactBytesAcrossBlockBoundaries() throws {
        #expect(try RecoveryProcessSHA256.hash(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(try RecoveryProcessSHA256.hash(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let message = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        var hash = RecoveryProcessSHA256()
        for byte in message { try hash.update(Data([byte])) }
        #expect(hash.finish() == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(hash.finish() == (try RecoveryProcessSHA256.hash(message)))
    }
}
