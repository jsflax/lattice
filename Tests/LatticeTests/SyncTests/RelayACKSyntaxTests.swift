import Foundation
import Testing
@testable import LatticeServerKit

// Literal bytes preserve spellings that Foundation's JSON writer normalizes.
// This is copied observation coverage, not native acceptance of extreme kind0.
private struct ACKLiteralInput {
    let original = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let target = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let connection = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let peer = SyncRecoveryPeerIdentity(replicaID: "literal-producer",
        receiverIncarnation: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        channelIncarnation: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
    let channel = "literal-channel"
    let digest = String(repeating: "a", count: 64)

    func wire(value: String = "55", kind: String = "1", version: String = "1",
              placeholderKind: String = "4", field: String = #""value""#,
              names: String? = nil, identityNames: String? = nil, extra: String = "") -> String {
        """
        {"auditLog":[{"globalId":"\(original.uuidString)","globalRowId":"\(target.uuidString)","tableName":"Row","operation":"UPDATE","changedFields":{\(field):{"kind":\(kind),"value":\(value)},"label":{"kind":\(placeholderKind),"value":null}},"changedFieldsNames":[\(names ?? field)],"originalIdentity":{"version":\(version),"changedFieldsNames":[\(identityNames ?? names ?? field)],"digest":"\(digest)"}}]\(extra)}
        """
    }
    func copy(_ data: Data) -> RelayRecoveryACKObservation? {
        .copy(data: data, acceptedIDs: [original], connectionID: connection, peer: peer, channel: channel)
    }
    func valid(_ text: String, expected: Int64 = 55, kind: Int64 = 1) throws {
        let observation = try #require(copy(Data(text.utf8)))
        let entry = try #require(observation.entry)
        #expect(observation.metadataFailure == nil && observation.connectionID == connection)
        #expect(observation.peer == peer && observation.channel == channel)
        #expect(entry.originalID == original && entry.targetID == target)
        #expect(entry.integerValue == expected && entry.integerKind == kind)
        #expect(entry.originalIdentityVersion == 1 && entry.originalIdentityDigest == digest)
    }
    func refused(_ data: Data, label: String) throws {
        let observation = try #require(copy(data), "literal case \(label)")
        #expect(observation.entry == nil && observation.metadataFailure != nil, "literal case \(label)")
        let drop = RelayRecoveryACKObservation.requestsDrop(observation, connectionID: connection,
                                                            peer: peer, decision: { _ in true })
        #expect(!drop, "literal case \(label)")
    }
    func refused(_ text: String, label: String) throws { try refused(Data(text.utf8), label: label) }
}

@Suite("ACK lexical integer observation")
struct RelayACKSyntaxTests {
    @Test func literalInt64TokensPreserveBothKindsWithoutFoundationNumericConversion() throws {
        let input = ACKLiteralInput()
        let values: [(String, Int64)] = [("0", 0), ("-0", 0), ("55", 55), ("-1", -1),
            ("-9223372036854775808", .min), ("9223372036854775807", .max)]
        for kind in [Int64(0), Int64(1)] {
            for (token, expected) in values {
                let observation = try #require(input.copy(Data(input.wire(value: token, kind: String(kind)).utf8)),
                                               "kind \(kind), token \(token)")
                let entry = try #require(observation.entry, "kind \(kind), token \(token)")
                #expect(entry.integerValue == expected && entry.integerKind == kind, "kind \(kind), token \(token)")
                try input.valid(input.wire(value: token, kind: String(kind)), expected: expected, kind: kind)
            }
        }
    }

    @Test func nonIntegerSpellingsAtEveryObservedNumericPathCannotDropACKs() throws {
        let input = ACKLiteralInput()
        for token in ["55.0", "55e0", "55E+0", "-9223372036854775808.0", "true", "false", "null", #""55""#,
                      "9223372036854775808", "-9223372036854775809", "18446744073709551615", String(repeating: "9", count: 80)] {
            try input.refused(input.wire(value: token), label: "value-\(token.prefix(24))")
        }
        for token in ["1.0", "1e0", "1E+0", "true", "null", #""1""#, "9223372036854775808", "-9223372036854775809"] {
            try input.refused(input.wire(kind: token), label: "kind-\(token)")
            try input.refused(input.wire(version: token), label: "version-\(token)")
        }
        for token in ["4.0", "4e0", "4E+0", "true", "null", #""4""#, "9223372036854775808", "-9223372036854775809"] {
            try input.refused(input.wire(placeholderKind: token), label: "placeholder-kind-\(token)")
        }
    }

    @Test func completeJSONGrammarRejectsMalformedTokensUTF8AndEscapes() throws {
        let input = ACKLiteralInput()
        for token in ["+55", "055", "-01", "1.", "1e", "1e+", "--1", "NaN", "Infinity"] {
            try input.refused(input.wire(value: token), label: "grammar-\(token)")
        }
        try input.refused(input.wire() + " {}", label: "trailing-value")
        try input.refused(input.wire(extra: #", "unused":"\x20""#), label: "invalid-escape")
        for scalar in [#"\uD800"#, #"\uDC00"#, #"\uD800\u0041"#] {
            try input.refused(input.wire(extra: ",\"unused\":\"\(scalar)\""), label: "surrogate-\(scalar)")
        }
        var invalid = Data(input.wire().utf8); invalid.append(0xFF)
        try input.refused(invalid, label: "invalid-utf8")
        var bom = Data([0xEF, 0xBB, 0xBF]); bom.append(Data(input.wire().utf8))
        let accepted = try #require(input.copy(bom)); #expect(accepted.entry?.integerValue == 55)
        var doubleBOM = Data([0xEF, 0xBB, 0xBF]); doubleBOM.append(bom)
        try input.refused(doubleBOM, label: "double-bom")
        try input.refused(Data([0xEF, 0xBB]), label: "partial-bom")
    }

    @Test func exactPathsIgnoreDecoysAndUnrelatedLegalRealNumbers() throws {
        let input = ACKLiteralInput()
        let extra = #", "value":999,"kind":4,"version":2,"unused":{"auditLog":[{"changedFields":{"value":{"kind":0,"value":77}}}],"real":1.25e+2,"text":"{\"kind\":0,\"value\":77}"}"#
        try input.valid(input.wire(extra: extra))
        try input.refused(input.wire(value: "null", extra: extra), label: "decoy-selected-value")
        try input.refused(input.wire(version: "null", extra: extra), label: "decoy-version")
        // A second entry cannot provide facts or turn a non-singleton into one.
        let second = input.wire().replacingOccurrences(of: #""auditLog":["#, with: #""auditLog":[{"changedFields":{"value":{"kind":1,"value":77}}},"#)
        try input.refused(second, label: "second-entry")
    }

    @Test func escapedByteKeysBindExactlyAndUnicodeAliasesRefuseObservation() throws {
        let input = ACKLiteralInput()
        let escaped = input.wire().replacingOccurrences(of: #""auditLog""#, with: #""audit\u004cog""#)
            .replacingOccurrences(of: #""changedFields""#, with: #""changed\u0046ields""#)
            .replacingOccurrences(of: #""originalIdentity""#, with: #""original\u0049dentity""#)
            .replacingOccurrences(of: #""version""#, with: #""\u0076ersion""#)
            .replacingOccurrences(of: #""kind""#, with: #""\u006bind""#)
            .replacingOccurrences(of: #""value""#, with: #""val\u0075e""#)
        try input.valid(escaped)
        try input.valid(input.wire(field: #""caf\u00e9\uD83D\uDE00""#))
        let duplicate = input.wire().replacingOccurrences(of: #""kind":1"#, with: #""kind":1,"\u006bind":1"#)
        try input.refused(duplicate, label: "escaped-duplicate")
        try input.refused(input.wire(extra: #", "x":0,"\u0078":1"#), label: "unused-escaped-duplicate")
        try input.refused(input.wire(field: #""caf\u00e9""#, names: #""cafe\u0301""#), label: "field-name-byte-mismatch")
        try input.refused(input.wire(field: #""caf\u00e9""#, identityNames: #""cafe\u0301""#), label: "identity-name-byte-mismatch")
        let aliases = input.wire(field: #""caf\u00e9""#).replacingOccurrences(of: #""label":{"kind":4,"value":null}"#,
            with: #""cafe\u0301":{"kind":4,"value":null}"#)
        try input.refused(aliases, label: "canonical-field-key-alias")
    }

    @Test func encodedByteAndDecodedScalarLimitsHaveExactPositiveBoundaries() throws {
        let input = ACKLiteralInput()
        let base = input.wire()
        let exact = base + String(repeating: " ", count: 1_048_576 - base.utf8.count)
        try input.valid(exact)
        try input.refused(exact + " ", label: "byte-limit-plus-one")
        try input.refused(Data(), label: "empty-frame")
        for count in [65_536, 65_537] {
            let scalar = String(repeating: "s", count: count)
            let value = input.wire(extra: ",\"unused\":\"\(scalar)\"")
            let key = input.wire(extra: ",\"\(scalar)\":null")
            if count == 65_536 { try input.valid(value); try input.valid(key) }
            else { try input.refused(value, label: "scalar-plus-one"); try input.refused(key, label: "key-plus-one") }
        }
        let escapedScalar = String(repeating: #"\uD83D\uDE00"#, count: 16_384)
        try input.valid(input.wire(extra: ",\"unused\":\"\(escapedScalar)\""))
        try input.refused(input.wire(extra: ",\"unused\":\"\(escapedScalar)x\""), label: "decoded-unicode-plus-one")
    }

    @Test func nativeCallbackDepthIncludesKeysScalarsAndContainerEnds() throws {
        let input = ACKLiteralInput()
        func arrays(_ count: Int, _ middle: String) -> String {
            String(repeating: "[", count: count) + middle + String(repeating: "]", count: count)
        }
        // Root depth0; the extra value starts at1. An empty array at16 is
        // valid, but a scalar/key at17 or another container at17 is not.
        try input.valid(input.wire(extra: ",\"unused\":" + arrays(16, "")))
        try input.valid(input.wire(extra: ",\"unused\":" + arrays(15, "null")))
        try input.refused(input.wire(extra: ",\"unused\":" + arrays(16, "null")), label: "scalar-depth17")
        try input.refused(input.wire(extra: ",\"unused\":" + arrays(17, "")), label: "container-depth17")
        try input.valid(input.wire(extra: ",\"unused\":" + arrays(15, "{}")))
        try input.refused(input.wire(extra: ",\"unused\":" + arrays(15, "{\"x\":null}")), label: "key-depth17")
    }

    @Test func nativeCallbackEventBudgetCountsEndEventsAtExactLimit() throws {
        let input = ACKLiteralInput()
        // The fixed two-field upload has 47 callbacks. Adding the root key
        // and array contributes 3 (key/start/end); each null contributes 1.
        func wire(_ count: Int) -> String {
            input.wire(extra: ",\"unused\":[" + Array(repeating: "null", count: count).joined(separator: ",") + "]")
        }
        try input.valid(wire(32_768 - 50))
        try input.refused(wire(32_768 - 49), label: "callback-event-plus-one")
    }
}
