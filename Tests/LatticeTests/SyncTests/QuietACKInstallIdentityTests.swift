import Foundation
import Testing

// Copied-byte format tests only. No native owner, database, grant or network is
// created. The fixed vector follows Core receive_install_state.cpp v1 encoding.
private enum QuietACKIdentityVector {
    static var bytes: Data {
        // version=1, sequence=9, expectedRevision=4, position-kind=2,
        // base=17, head=19, full-mode=0; four distinct 64-byte opaque digests.
        var value = Data([
            0,0,0,0,0,0,0,1, 0,0,0,0,0,0,0,9, 0,0,0,0,0,0,0,4,
            0,0,0,0,0,0,0,2, 0,0,0,0,0,0,0,17, 0,0,0,0,0,0,0,19,
            0,0,0,0,0,0,0,0
        ])
        for byte in [UInt8(0x61), 0x62, 0x63, 0x64] {
            value.append(contentsOf: [0,0,0,0,0,0,0,64])
            value.append(Data(repeating: byte, count: 64))
        }
        return value
    }
    static func replacing(_ input: Data, offset: Int, number: UInt64) -> Data {
        var value = input
        for index in 0..<8 { value[offset + index] = UInt8(truncatingIfNeeded: number >> ((7 - index) * 8)) }
        return value
    }
    static func decode(_ bytes: Data) throws -> QuietACKInstallIdentity {
        try QuietACKInstallIdentity.decode(bytes, maximumFieldBytes: 256, maximumEncodedBytes: 4_096)
    }
    static var store: QuietACKRow { .init(cells: ["max_field_bytes": .integer(256), "max_bytes": .integer(4_096)]) }
    static var channel: QuietACKRow { .init(cells: [
        "last_sequence": .integer(9), "frontier": .integer(19), "revision": .integer(5), "last_install": .blob(bytes)
    ]) }
    static var scope: QuietACKRow { .init(cells: [
        "installed_sequence": .integer(9), "installed_head": .integer(19), "installed_revision": .integer(5),
        "installed_manifest": .blob(Data(repeating: 0x64, count: 64))
    ]) }
}

@Suite("Quiet ACK retained installation identity")
struct QuietACKInstallIdentityTests {
    @Test func exactCoreV1VectorAndOpaqueDigestsRemainByteExact() throws {
        let bytes = QuietACKIdentityVector.bytes
        let identity = try QuietACKIdentityVector.decode(bytes)
        #expect(bytes.count == 344)
        #expect(identity.sequence == 9 && identity.expectedRevision == 4 && identity.baseKind == 2)
        #expect(identity.basePosition == 17 && identity.head == 19 && identity.mode == 0)
        #expect(identity.requestDigest == Data(repeating: 0x61, count: 64))
        #expect(identity.receiptDigest == Data(repeating: 0x62, count: 64))
        #expect(identity.contentDigest == Data(repeating: 0x63, count: 64))
        #expect(identity.manifestDigest == Data(repeating: 0x64, count: 64))
        try quietACKValidateInstalledIdentity(channel: QuietACKIdentityVector.channel,
            scope: QuietACKIdentityVector.scope, store: QuietACKIdentityVector.store)
        var opaque = bytes; opaque[64] = 0; opaque[65] = 255
        let copied = try QuietACKIdentityVector.decode(opaque)
        #expect(copied.requestDigest == Data(opaque[64..<128]))
        #expect(copied.manifestDigest == identity.manifestDigest)
        let delta = try QuietACKIdentityVector.decode(QuietACKIdentityVector.replacing(bytes, offset: 48, number: 1))
        #expect(delta.mode == 1 && delta.sequence == identity.sequence)
        for kind in [UInt64(0), 1] {
            var initial = bytes
            let initialFields: [(Int, UInt64)] = [(8, 1), (16, 0), (24, kind), (32, 0), (40, 0)]
            for (offset, value) in initialFields {
                initial = QuietACKIdentityVector.replacing(initial, offset: offset, number: value)
            }
            let first = try QuietACKIdentityVector.decode(initial)
            #expect(first.sequence == 1 && first.expectedRevision == 0 && first.baseKind == Int64(kind) && first.head == 0)
        }
    }

    @Test func everyTruncationAndTrailingByteRefuses() {
        let bytes = QuietACKIdentityVector.bytes
        for count in 0..<bytes.count {
            #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(Data(bytes.prefix(count))) }
        }
        var trailing = bytes; trailing.append(0)
        #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(trailing) }
    }

    @Test func scalarContradictionsAndUnrepresentableNumbersRefuse() {
        let bytes = QuietACKIdentityVector.bytes
        let invalid: [(Int, UInt64)] = [
            (0, 0), (0, 2), (8, 0), (8, 4), (16, 9), (16, UInt64(Int64.max)),
            (24, 3), (24, 0), (24, 1), (32, 20), (48, 2)
        ]
        for (offset, value) in invalid {
            let changed = QuietACKIdentityVector.replacing(bytes, offset: offset, number: value)
            #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(changed) }
        }
        for offset in stride(from: 0, to: 56, by: 8) {
            let highBit = QuietACKIdentityVector.replacing(bytes, offset: offset, number: UInt64(Int64.max) + 1)
            #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(highBit) }
        }
        // A delta without a numeric base is invalid even when the rest of the
        // initial-frontier encoding is canonical and its revision is zero.
        var initialDelta = bytes
        let deltaFields: [(Int, UInt64)] = [(8, 1), (16, 0), (24, 1), (32, 0), (48, 1)]
        for (offset, value) in deltaFields {
            initialDelta = QuietACKIdentityVector.replacing(initialDelta, offset: offset, number: value)
        }
        #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(initialDelta) }
        // Non-position initial frontiers must encode zero, not an ignored base.
        let noncanonicalNull = QuietACKIdentityVector.replacing(initialDelta, offset: 48, number: 0)
        let nonzero = QuietACKIdentityVector.replacing(noncanonicalNull, offset: 32, number: 1)
        #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(nonzero) }
    }

    @Test func invalidDigestLengthsAndStoredLimitsRefuse() {
        let bytes = QuietACKIdentityVector.bytes
        for offset in [56, 128, 200, 272] {
            for length in [UInt64(0), 257, UInt64(Int64.max), UInt64.max] {
                let changed = QuietACKIdentityVector.replacing(bytes, offset: offset, number: length)
                #expect(throws: QuietACKFailure.receiverSettlement) { try QuietACKIdentityVector.decode(changed) }
            }
        }
        let badLimits: [(Int64, Int64)] = [(0, 4096), (-1, 4096), (63, 4096), (256, 0), (256, -1), (256, 343)]
        for (field, total) in badLimits {
            #expect(throws: QuietACKFailure.receiverSettlement) {
                try QuietACKInstallIdentity.decode(bytes, maximumFieldBytes: field, maximumEncodedBytes: total)
            }
        }
        #expect(throws: QuietACKFailure.receiverSettlement) {
            try QuietACKInstallIdentity.decode(Data(repeating: 0, count: 65_537),
                maximumFieldBytes: Int64.max, maximumEncodedBytes: Int64.max)
        }
    }

    @Test func everyChannelAndScopeLinkMustMatchTheRetainedIdentity() {
        for key in ["last_sequence", "frontier", "revision"] {
            var cells = QuietACKIdentityVector.channel.cells; cells[key] = .integer(999)
            #expect(throws: QuietACKFailure.receiverSettlement) {
                try quietACKValidateInstalledIdentity(channel: .init(cells: cells),
                    scope: QuietACKIdentityVector.scope, store: QuietACKIdentityVector.store)
            }
        }
        for key in ["installed_sequence", "installed_head", "installed_revision"] {
            var cells = QuietACKIdentityVector.scope.cells; cells[key] = .integer(999)
            #expect(throws: QuietACKFailure.receiverSettlement) {
                try quietACKValidateInstalledIdentity(channel: QuietACKIdentityVector.channel,
                    scope: .init(cells: cells), store: QuietACKIdentityVector.store)
            }
        }
        var changedScope = QuietACKIdentityVector.scope.cells
        changedScope["installed_manifest"] = .blob(Data(repeating: 0x65, count: 64))
        #expect(throws: QuietACKFailure.receiverSettlement) {
            try quietACKValidateInstalledIdentity(channel: QuietACKIdentityVector.channel,
                scope: .init(cells: changedScope), store: QuietACKIdentityVector.store)
        }
        var changedBlob = QuietACKIdentityVector.bytes; changedBlob[280] = 0x65
        var changedChannel = QuietACKIdentityVector.channel.cells; changedChannel["last_install"] = .blob(changedBlob)
        #expect(throws: QuietACKFailure.receiverSettlement) {
            try quietACKValidateInstalledIdentity(channel: .init(cells: changedChannel),
                scope: QuietACKIdentityVector.scope, store: QuietACKIdentityVector.store)
        }
    }
}
