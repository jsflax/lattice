import Foundation
import Testing
@testable import Lattice

@Model final class NullableStreamedMessage {
    var title: String = ""
    @NoHistory var body: String?
    @NoHistory var checkedAt: Date?
    @NoHistory var requiredBody: String = "kept"
}

@Suite("Nullable @NoHistory · explicit wire NULL")
final class NoHistoryNullTests: BaseTest {
    private func entry() -> AuditLog {
        let row = AuditLog()
        row.globalId = UUID()
        row.globalRowId = UUID()
        row.tableName = "NullableStreamedMessage"
        row.operation = .update
        row.rowId = 1
        row.changedFields = ["body": .null, "title": .string("changed")]
        row.changedFieldsNames = ["body", "title"]
        row.timestamp = Date(timeIntervalSince1970: 0)
        row.isFromRemote = false
        row.noHistoryNulls = ["body"]
        return row
    }

    private func isNull(_ value: AnyProperty?) -> Bool {
        guard let value else { return false }
        if case .null = value { return true }
        return false
    }

    private func latestUpdate(_ store: Lattice) throws -> AuditLog {
        try #require(store.eventsAfter(id: 0).snapshot().last {
            $0.tableName == "NullableStreamedMessage" && $0.operation == .update
        })
    }

    @Test func markerRoundTripsWithoutJoiningThePhysicalModelSchema() throws {
        let row = entry()
        let encoded = try row.toCxxJSONBytes()
        let decoded = try JSONDecoder().decode(AuditLog.self, from: encoded)
        #expect(decoded.noHistoryNulls == ["body"])
        #expect(isNull(decoded.changedFields["body"]))
        #expect(!AuditLog.properties.contains { $0.0 == "noHistoryNulls" })
        #expect(!AuditLog.properties.contains { $0.0 == "synthesized" })

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "noHistoryNulls")
        legacy["futureMetadata"] = "ignored"
        let oldWire = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(AuditLog.self, from: oldWire).noHistoryNulls.isEmpty)
        row.noHistoryNulls = []
        let unmarked = try #require(JSONSerialization.jsonObject(with: row.toCxxJSONBytes()) as? [String: Any])
        #expect(unmarked["noHistoryNulls"] == nil)
    }

    @Test func cxxBridgePreservesMarkerAndRejectsMalformedValues() throws {
        let row = entry()
        var wire = try #require(JSONSerialization.jsonObject(with: row.toCxxJSONBytes()) as? [String: Any])
        wire["id"] = 1
        wire["timestamp"] = "0.0"
        let data = try JSONSerialization.data(withJSONObject: wire)
        let parsed = try AuditLog.fromCxxJSON(String(decoding: data, as: UTF8.self))
        #expect(parsed.noHistoryNulls == ["body"])
        #expect(isNull(parsed.changedFields["body"]))
        let reencoded = try JSONDecoder().decode(AuditLog.self, from: parsed.toCxxJSONBytes())
        #expect(reencoded.noHistoryNulls == ["body"])
        wire["operation"] = "INVALID"
        let badOperation = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: (any Error).self) {
            _ = try AuditLog.fromCxxJSON(String(decoding: badOperation, as: UTF8.self))
        }
        wire["noHistoryNulls"] = [String]()
        for synthesized in [false, true] {
            wire["synthesized"] = synthesized
            let unknownWithoutNulls = try JSONSerialization.data(withJSONObject: wire)
            #expect(throws: (any Error).self) {
                _ = try AuditLog.fromCxxJSON(String(decoding: unknownWithoutNulls, as: UTF8.self))
            }
        }
        wire["operation"] = "UPDATE"
        wire["noHistoryNulls"] = NSNull()
        let malformed = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: (any Error).self) {
            _ = try AuditLog.fromCxxJSON(String(decoding: malformed, as: UTF8.self))
        }
    }

    @Test func malformedMetadataCannotBecomeAnIntentionalNullThroughAnyPropertyCoercion() throws {
        let base = try #require(JSONSerialization.jsonObject(with: entry().toCxxJSONBytes()) as? [String: Any])
        var invalid: [[String: Any]] = []
        let markerValues: [Any] = [NSNull(), "body", [NSNull()], ["body", "body"], [""], ["missing"]]
        for value in markerValues {
            var wire = base; wire["noHistoryNulls"] = value; invalid.append(wire)
        }
        let malformedValues: [Any] = [[String: Any](), ["kind": 4], ["kind": 4, "value": 7],
                                     ["kind": 2, "value": NSNull()], [Any]()]
        for value in malformedValues {
            var wire = base
            wire["changedFields"] = ["body": value, "title": ["kind": 2, "value": "changed"]]
            invalid.append(wire)
        }
        var unnamed = base; unnamed["changedFieldsNames"] = ["title"]; invalid.append(unnamed)
        var deleted = base; deleted["operation"] = "DELETE"; invalid.append(deleted)
        for wire in invalid {
            let data = try JSONSerialization.data(withJSONObject: wire)
            #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(AuditLog.self, from: data) }
        }
        let typed = entry(); typed.changedFields["body"] = .string("not null")
        #expect(throws: (any Error).self) { _ = try typed.toCxxJSONBytes() }
    }

    @Test func lateBindingPreservesLiveNullAndEpochDateWithoutWritingAuditHistory() throws {
        let store = try testLattice(NullableStreamedMessage.self)
        let message = NullableStreamedMessage()
        message.body = "first"; message.checkedAt = Date(timeIntervalSince1970: 1)
        try store.add(message)
        store.transaction { message.body = nil; message.checkedAt = Date(timeIntervalSince1970: 0) }
        // Each property setter has its own UPDATE audit row, even inside one
        // transaction. A raw NULL slot in the other row is not a changed field.
        let raw = store.eventsAfter(id: 0).snapshot().filter {
            $0.tableName == "NullableStreamedMessage" && $0.operation == .update
        }
        #expect(raw.count == 2)
        let before = try JSONEncoder().encode(raw)
        let bound = store.lateBindNoHistory(raw)
        let bodyRow = try #require(bound.last { $0.changedFieldsNames?.contains("body") == true })
        let dateRow = try #require(bound.last { $0.changedFieldsNames?.contains("checkedAt") == true })
        #expect(bodyRow.noHistoryNulls == ["body"])
        #expect(isNull(bodyRow.changedFields["body"]))
        #expect(dateRow.noHistoryNulls.isEmpty)
        let epoch = try #require(dateRow.changedFields["checkedAt"])
        if case .date(let value) = epoch {
            #expect(value.timeIntervalSince1970 == 0)
        } else if case .double(let value) = epoch {
            #expect(value == 0) // SQL live values are primitives, not logical date tags.
        } else { Issue.record("epoch zero must remain a non-null numeric value") }
        #expect(raw.allSatisfy { $0.noHistoryNulls.isEmpty })
        let after = try JSONEncoder().encode(raw)
        // Foundation object order is unspecified; compare parsed JSON values.
        #expect(NSArray(array: try #require(JSONSerialization.jsonObject(with: before) as? [Any]))
            .isEqual(to: try #require(JSONSerialization.jsonObject(with: after) as? [Any])))
        store.transaction { message.checkedAt = nil }
        let cleared = try #require(store.lateBindNoHistory([try latestUpdate(store)]).first)
        #expect(cleared.noHistoryNulls == ["checkedAt"])
        #expect(isNull(cleared.changedFields["checkedAt"]))
    }

    @Test func reboundAndGoneRowsCannotKeepStaleNullMarkers() throws {
        let store = try testLattice(NullableStreamedMessage.self)
        let message = NullableStreamedMessage(); message.body = "first"
        try store.add(message)
        store.transaction { message.body = nil }
        let bound = try #require(store.lateBindNoHistory([try latestUpdate(store)]).first)
        #expect(bound.noHistoryNulls == ["body"])
        store.transaction { message.body = "again" }
        let rebound = try #require(store.lateBindNoHistory([bound]).first)
        #expect(rebound.noHistoryNulls.isEmpty)
        #expect(rebound.changedFields["body"]?.stringValue == "again")
        store.delete(NullableStreamedMessage.self)
        let gone = try #require(store.lateBindNoHistory([bound]).first)
        #expect(gone.noHistoryNulls.isEmpty)
        #expect(gone.changedFields["body"] == nil)
        #expect(gone.changedFieldsNames?.contains("body") == false)
    }

    @Test func insertNullsAreMarkedAndBothRelayHopsKeepTheClear() throws {
        let source = try testLattice(NullableStreamedMessage.self)
        let relay = try testLattice(NullableStreamedMessage.self)
        let target = try testLattice(NullableStreamedMessage.self)
        let message = NullableStreamedMessage(); message.body = "first"
        try source.add(message)
        let inserted = source.lateBindNoHistory(source.eventsAfter(id: 0).snapshot())
        let insert = try #require(inserted.first { $0.tableName == "NullableStreamedMessage" })
        #expect(insert.noHistoryNulls == ["checkedAt"])
        let insertFrame = try JSONEncoder().encode(ServerSentEvent.auditLog(inserted))
        #expect(!(try relay.receive(insertFrame)).isEmpty)
        #expect(!(try target.receive(insertFrame)).isEmpty)
        source.transaction { message.body = nil }
        let update = try #require(source.lateBindNoHistory([try latestUpdate(source)]).first)
        let frame = try JSONEncoder().encode(ServerSentEvent.auditLog([update]))
        #expect(try relay.receive(frame).contains(try #require(update.globalId)))
        let fromRelay = relay.lateBindNoHistory(relay.eventsAfter(id: 0).snapshot())
        let forwarded = try #require(fromRelay.first { $0.globalId == update.globalId })
        #expect(forwarded.noHistoryNulls == ["body"])
        #expect(try target.receive(JSONEncoder().encode(ServerSentEvent.auditLog([forwarded])))
            .contains(try #require(update.globalId)))
        #expect(target.objects(NullableStreamedMessage.self).snapshot().first?.body == nil)
    }

    @Test func legacyRawNullAndMarkedRequiredNullDoNotOverwriteRequiredValue() throws {
        let store = try testLattice(NullableStreamedMessage.self)
        let message = NullableStreamedMessage(); message.body = "first"
        try store.add(message)
        for marked in [false, true] {
            let row = entry(); row.globalRowId = message.globalId
            row.changedFields["requiredBody"] = .null
            row.changedFieldsNames?.append("requiredBody")
            row.noHistoryNulls = marked ? ["body", "requiredBody"] : []
            #expect(!(try store.receive(JSONEncoder().encode(ServerSentEvent.auditLog([row])))).isEmpty)
            let received = try #require(store.objects(NullableStreamedMessage.self).snapshot().first)
            #expect(received.requiredBody == "kept")
            #expect(received.body == (marked ? nil : "first"))
        }
    }

    @Test func actualCoreSnapshotKeepsProvenanceAcrossSwiftAndPersistedRelayEncoding() throws {
        let source = try testLattice(NullableStreamedMessage.self)
        let relay = try testLattice(NullableStreamedMessage.self)
        let target = try testLattice(NullableStreamedMessage.self)
        let message = NullableStreamedMessage(); message.body = "existing target value"
        try source.add(message)
        let first = source.lateBindNoHistory(source.eventsAfter(id: 0).snapshot())
        #expect(!(try target.receive(JSONEncoder().encode(ServerSentEvent.auditLog(first)))).isEmpty)
        source.transaction { message.body = nil }
        #expect(source.forceCompactHistory() > 0) // Core generates real synthesized INSERTs.

        let core = try #require(source.cxxLatticeRef.get())
        let snapshots = core.events_after(lattice.OptionalString())
        var snapshot: AuditLog?
        for index in 0..<snapshots.size() {
            let candidate = AuditLog(from: snapshots[index]) // Actual Core JSON → Swift manual bridge.
            if candidate.tableName == "NullableStreamedMessage" { snapshot = candidate; break }
        }
        let detached = try #require(snapshot)
        #expect(detached.synthesized)
        #expect(detached.noHistoryNulls.contains("body"))
        #expect(!(try relay.receive(JSONEncoder().encode(ServerSentEvent.auditLog([detached])))).isEmpty)

        let persisted = try #require(relay.eventsAfter(id: 0).snapshot().first {
            $0.globalId == detached.globalId
        })
        #expect(persisted.isManaged)
        let forwarded = try JSONDecoder().decode(AuditLog.self, from: JSONEncoder().encode(persisted))
        #expect(forwarded.synthesized, "encoding must read the existing Core-owned column")
        let bound = try #require(relay.lateBindNoHistory([persisted]).first)
        #expect(bound.synthesized)
        #expect(bound.noHistoryNulls.contains("body"))
        #expect(!(try target.receive(JSONEncoder().encode(ServerSentEvent.auditLog([bound])))).isEmpty)
        let kept = try #require(target.objects(NullableStreamedMessage.self).snapshot().first)
        #expect(kept.body == "existing target value", "snapshot must remain insert-if-absent after both Swift hops")
    }

    @Test func missingManagedProvenanceRefusesEncodingInsteadOfDowngradingTheSnapshot() throws {
        let store = try testLattice(NullableStreamedMessage.self)
        try store.add(NullableStreamedMessage())
        #expect(store.forceCompactHistory() > 0)
        let managed = try #require(store.eventsAfter(id: 0).snapshot().first {
            $0.tableName == "NullableStreamedMessage"
        })
        store.delete(AuditLog.self)
        #expect(throws: (any Error).self) { _ = try JSONEncoder().encode(managed) }
        let detached = entry(); detached.synthesized = true
        let encoded = try JSONEncoder().encode(detached)
        #expect(try JSONDecoder().decode(AuditLog.self, from: encoded).synthesized)
    }
}
