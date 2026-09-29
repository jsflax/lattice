import Foundation
import Testing
import NIOConcurrencyHelpers
@testable import LatticeServerKit

// These tests exercise copied metadata and the optional decision only. They
// do not fabricate native acceptance, a publication token or a live socket.
// The separate public connected B case exercises the real accepted ACK path.
private struct QuietACKInputs: Sendable {
    let connection = UUID()
    let original = UUID()
    let target = UUID()
    let peer = SyncRecoveryPeerIdentity(replicaID: "quiet-producer", receiverIncarnation: UUID(), channelIncarnation: UUID())
    let channel = "wss://127.0.0.1:9443/a"
    let digest = String(repeating: "a", count: 64)

    func entry() -> [String: Any] {
        ["globalId": original.uuidString, "globalRowId": target.uuidString,
         "tableName": "ConnectedRecoverySharedRow", "operation": "UPDATE",
         "changedFields": ["value": ["kind": 0, "value": 55]],
         "changedFieldsNames": ["value"],
         "originalIdentity": ["version": 1, "changedFieldsNames": ["value"], "digest": digest]]
    }
    func frame(_ entry: [String: Any]) throws -> RelayFrame {
        RelayFrame(try JSONSerialization.data(withJSONObject: ["auditLog": [entry]], options: [.sortedKeys]))
    }
    func copy(_ entry: [String: Any]) throws -> RelayRecoveryACKObservation? {
        RelayRecoveryACKObservation.copy(frame: try frame(entry), acceptedIDs: [original],
            connectionID: connection, peer: peer, channel: channel)
    }
    func changedInteger(_ value: Any, kind: Any = 0) -> [String: Any] {
        var result = entry()
        result["changedFields"] = ["value": ["kind": kind, "value": value]]
        return result
    }
}

/// Mirrors the B fixture's one-shot selection, using immutable pre-write
/// target/route facts and the original UUID copied only after real acceptance.
private final class QuietACKSelection: Sendable {
    let input: QuietACKInputs
    private let selected = NIOLockedValueBox<UUID?>(nil)
    init(_ input: QuietACKInputs) { self.input = input }
    var original: UUID? { selected.withLockedValue { $0 } }
    func choose(_ observation: RelayRecoveryACKObservation) -> Bool {
        guard observation.connectionID == input.connection, observation.peer == input.peer,
              observation.channel == input.channel, observation.metadataFailure == nil,
              let entry = observation.entry, entry.targetID == input.target,
              entry.table == "ConnectedRecoverySharedRow", entry.operation == "UPDATE",
              entry.fieldName == "value", (entry.integerKind == 0 || entry.integerKind == 1), entry.integerValue == 55,
              entry.originalIdentityVersion == 1, entry.originalIdentityDigest == input.digest else { return false }
        return selected.withLockedValue { value in
            guard value == nil else { return false }
            value = entry.originalID; return true
        }
    }
}

@Suite("Relay quiet ACK observation")
struct RelayQuietACKObservationTests {
    @Test func validSingletonPreservesOriginalTargetTypedValueAndRoute() throws {
        let input = QuietACKInputs()
        for kind in [Int64(0), Int64(1)] {
            for number in [Int64(55), Int64.min, Int64.max] {
                let observation = try #require(try input.copy(input.changedInteger(number, kind: kind)))
                let entry = try #require(observation.entry)
                #expect(observation.connectionID == input.connection && observation.peer == input.peer)
                #expect(observation.channel == input.channel && observation.metadataFailure == nil)
                #expect(entry == .init(originalID: input.original, targetID: input.target,
                    table: "ConnectedRecoverySharedRow", operation: "UPDATE", fieldName: "value",
                    integerKind: kind, integerValue: number, originalIdentityVersion: 1,
                    originalIdentityDigest: input.digest))
            }
        }
    }

    @Test func generatedUnchangedNullFieldsAreAllowedButNoExtraValueIsCopied() throws {
        let input = QuietACKInputs()
        var entry = input.entry()
        entry["changedFields"] = ["label": ["kind": 4, "value": NSNull()], "value": ["kind": 1, "value": 55]]
        let observation = try #require(try input.copy(entry))
        let copied = try #require(observation.entry)
        #expect(copied.fieldName == "value" && copied.integerKind == 1 && copied.integerValue == 55)
        #expect(copied.originalID == input.original && copied.targetID == input.target && observation.metadataFailure == nil)
        // Exercise the actual export limit as well as the two-column app shape.
        var fields: [String: Any] = ["value": ["kind": 1, "value": 55]]
        for index in 0..<31 { fields["unchanged\(index)"] = ["kind": 4, "value": NSNull()] }
        entry["changedFields"] = fields
        let bounded = try #require(try input.copy(entry))
        #expect(bounded.entry == copied)
        fields["tooMany"] = ["kind": 4, "value": NSNull()]; entry["changedFields"] = fields
        let exceeded = try #require(try input.copy(entry))
        #expect(exceeded.entry == nil && exceeded.metadataFailure != nil)
        let invalid: [Any] = [NSNull(), ["kind": 4], ["kind": 4, "value": 55],
            ["kind": 0, "value": NSNull()], ["kind": "4", "value": NSNull()],
            ["kind": true, "value": NSNull()], ["kind": 4, "value": NSNull(), "extra": 0]]
        for placeholder in invalid {
            entry["changedFields"] = ["label": placeholder, "value": ["kind": 1, "value": 55]]
            let refused = try #require(try input.copy(entry))
            #expect(refused.entry == nil && refused.metadataFailure != nil)
        }
    }

    @Test func malformedAndNonSingletonUploadsCannotBecomeDropEvidence() throws {
        let input = QuietACKInputs()
        let malformed = RelayFrame(Data("{".utf8))
        let empty = RelayFrame(Data("{\"auditLog\":[]}".utf8))
        let ack = RelayFrame(Data("{\"ack\":[]}".utf8))
        let two = RelayFrame(try JSONSerialization.data(withJSONObject: ["auditLog": [input.entry(), input.entry()]]))
        for frame in [malformed, empty, ack, two] {
            let observation = try #require(RelayRecoveryACKObservation.copy(frame: frame, acceptedIDs: [input.original],
                connectionID: input.connection, peer: input.peer, channel: input.channel))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
            let requestsDrop = RelayRecoveryACKObservation.requestsDrop(observation, connectionID: input.connection, peer: input.peer, decision: { _ in true })
            #expect(!requestsDrop)
        }
    }

    @Test func acceptedIDMismatchAndInvalidTargetsRefuseMetadata() throws {
        let input = QuietACKInputs()
        let frame = try input.frame(input.entry())
        for ids in [[], [UUID()], [input.original, input.original]] as [[UUID]] {
            let observation = try #require(RelayRecoveryACKObservation.copy(frame: frame, acceptedIDs: ids,
                connectionID: input.connection, peer: input.peer, channel: input.channel))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
        for key in ["globalId", "globalRowId"] {
            var entry = input.entry(); entry[key] = "not-a-uuid"
            let observation = try #require(try input.copy(entry))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
    }

    @Test func booleanRealStringOverflowAndNonIntegerKindsAreRejected() throws {
        let input = QuietACKInputs()
        let invalidValues: [Any] = [true, false, "55", 55.25, NSNumber(value: UInt64.max), NSNull()]
        for value in invalidValues {
            let observation = try #require(try input.copy(input.changedInteger(value)))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
        let invalidKinds: [Any] = [true, "0", 0.25, -1, 2, 7]
        for kind in invalidKinds {
            let observation = try #require(try input.copy(input.changedInteger(55, kind: kind)))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
        for version in [true, "1", 1.25, 0, 2] as [Any] {
            var entry = input.entry()
            entry["originalIdentity"] = ["version": version, "changedFieldsNames": ["value"], "digest": input.digest]
            let observation = try #require(try input.copy(entry))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
    }

    @Test func operationNamesIdentityAndExactTypedShapeAreRequired() throws {
        let input = QuietACKInputs()
        var entries: [[String: Any]] = []
        var entry = input.entry(); entry["operation"] = "INSERT"; entries.append(entry)
        entry = input.entry(); entry["changedFieldsNames"] = ["other"]; entries.append(entry)
        entry = input.entry(); entry["changedFieldsNames"] = "[\"value\"]"; entries.append(entry)
        entry = input.entry(); entry["changedFields"] = ["value": ["kind": 0, "value": 55, "extra": 0]]; entries.append(entry)
        entry = input.entry(); entry["changedFields"] = ["value": ["kind": 0, "value": 55], "other": ["kind": 0, "value": 1]]; entries.append(entry)
        for names in [["other"], ["value", "value"]] {
            entry = input.entry(); entry["originalIdentity"] = ["version": 1, "changedFieldsNames": names, "digest": input.digest]; entries.append(entry)
        }
        for digest in [String(repeating: "A", count: 64), String(repeating: "a", count: 65), "not-a-digest"] {
            entry = input.entry(); entry["originalIdentity"] = ["version": 1, "changedFieldsNames": ["value"], "digest": digest]; entries.append(entry)
        }
        entry = input.entry(); entry["originalIdentity"] = ["version": 1, "changedFieldsNames": ["value"], "digest": input.digest, "extra": 1]; entries.append(entry)
        for value in entries {
            let observation = try #require(try input.copy(value))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
    }

    @Test func oversizedFramesAndCopiedFieldsCannotReachSelectorAsValidEvidence() throws {
        let input = QuietACKInputs()
        var entry = input.entry(); entry["unused"] = String(repeating: "x", count: 1_048_576)
        let large = try #require(try input.copy(entry))
        #expect(large.entry == nil && large.metadataFailure != nil)
        for text in [String(repeating: "t", count: 65), "bad\0table"] {
            entry = input.entry(); entry["tableName"] = text
            let observation = try #require(try input.copy(entry))
            #expect(observation.entry == nil && observation.metadataFailure != nil)
        }
        entry = input.entry()
        let field = String(repeating: "f", count: 65)
        entry["changedFields"] = [field: ["kind": 0, "value": 55]]
        entry["changedFieldsNames"] = [field]
        let observation = try #require(try input.copy(entry))
        #expect(observation.entry == nil && observation.metadataFailure != nil)
        let frame = try input.frame(input.entry())
        #expect(RelayRecoveryACKObservation.copy(frame: frame, acceptedIDs: [input.original], connectionID: input.connection,
            peer: input.peer, channel: String(repeating: "c", count: 65)) == nil)
        let peer = SyncRecoveryPeerIdentity(replicaID: String(repeating: "r", count: 257),
            receiverIncarnation: input.peer.receiverIncarnation, channelIncarnation: input.peer.channelIncarnation)
        #expect(RelayRecoveryACKObservation.copy(frame: frame, acceptedIDs: [input.original], connectionID: input.connection,
            peer: peer, channel: input.channel) == nil)
    }

    @Test func nilNonACKAndMismatchedConnectionOrPeerNeverInvokeDecision() throws {
        let input = QuietACKInputs()
        let observation = try #require(try input.copy(input.entry()))
        let calls = NIOLockedValueBox(0)
        let decision: @Sendable (RelayRecoveryACKObservation) -> Bool = { _ in calls.withLockedValue { $0 += 1 }; return true }
        #expect(!RelayRecoveryACKObservation.requestsDrop(nil, connectionID: input.connection, peer: input.peer, decision: decision))
        #expect(!RelayRecoveryACKObservation.requestsDrop(observation, connectionID: UUID(), peer: input.peer, decision: decision))
        let otherPeer = SyncRecoveryPeerIdentity(replicaID: input.peer.replicaID,
            receiverIncarnation: UUID(), channelIncarnation: input.peer.channelIncarnation)
        #expect(!RelayRecoveryACKObservation.requestsDrop(observation, connectionID: input.connection, peer: otherPeer, decision: decision))
        #expect(!RelayRecoveryACKObservation.requestsDrop(observation, connectionID: input.connection, peer: input.peer, decision: nil))
        #expect(calls.withLockedValue { $0 } == 0)
        let requestsDrop = RelayRecoveryACKObservation.requestsDrop(observation, connectionID: input.connection, peer: input.peer, decision: { _ in false })
        #expect(!requestsDrop)
    }

    @Test func invalidMetadataCanBeObservedButNeverDrops() throws {
        let input = QuietACKInputs()
        let observation = try #require(try input.copy(input.changedInteger(true)))
        let calls = NIOLockedValueBox(0)
        let dropped = RelayRecoveryACKObservation.requestsDrop(observation, connectionID: input.connection, peer: input.peer) { value in
            #expect(value.entry == nil && value.metadataFailure != nil)
            calls.withLockedValue { $0 += 1 }; return true
        }
        #expect(!dropped && calls.withLockedValue { $0 } == 1)
    }

    @Test func exactSelectionDropsOnceAndNonmatchesDoNotConsumeSelection() throws {
        let input = QuietACKInputs()
        let selector = QuietACKSelection(input)
        let valid = try #require(try input.copy(input.entry()))
        var entry = input.entry(); entry["globalRowId"] = UUID().uuidString
        let otherTarget = try #require(try input.copy(entry))
        let otherValue = try #require(try input.copy(input.changedInteger(56)))
        let otherChannel = RelayRecoveryACKObservation(connectionID: input.connection, peer: input.peer,
            channel: "wss://127.0.0.1:9443/b", entry: valid.entry, metadataFailure: nil)
        let decide: @Sendable (RelayRecoveryACKObservation) -> Bool = { selector.choose($0) }
        for observation in [otherTarget, otherValue, otherChannel] {
            #expect(!RelayRecoveryACKObservation.requestsDrop(observation, connectionID: input.connection, peer: input.peer, decision: decide))
            #expect(selector.original == nil)
        }
        #expect(RelayRecoveryACKObservation.requestsDrop(valid, connectionID: input.connection, peer: input.peer, decision: decide))
        #expect(selector.original == input.original)
        #expect(!RelayRecoveryACKObservation.requestsDrop(valid, connectionID: input.connection, peer: input.peer, decision: decide))
        #expect(selector.original == input.original)
    }

    @Test func observationDoesNotRetainLifetimeAndUnavailableCallbackIsOffLock() {
        let input = QuietACKInputs()
        var lifetime: RecoveryRelayLifetime? = RecoveryRelayLifetime()
        weak var weakLifetime = lifetime
        let observation = RelayRecoveryConnectionObservation(connectionID: input.connection, peer: input.peer,
            channel: input.channel, socket: nil, lifetime: lifetime)
        lifetime = nil
        #expect(weakLifetime == nil)
        #expect(observation.connectionID == input.connection && observation.peer == input.peer && observation.channel == input.channel)
        let calls = NIOLockedValueBox(0)
        observation.sample { first in
            #expect(!first.available && !first.socketOpen && !first.lifetimeLive)
            calls.withLockedValue { $0 += 1 }
            // Re-entry would deadlock if the foreign callback held the lock.
            observation.sample { second in
                #expect(!second.available && !second.socketOpen && !second.lifetimeLive)
                calls.withLockedValue { $0 += 1 }
            }
        }
        #expect(calls.withLockedValue { $0 } == 2)
    }
}
