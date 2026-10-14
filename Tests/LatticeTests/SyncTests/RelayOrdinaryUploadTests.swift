import Foundation
import Testing
import Lattice
@testable import LatticeServerKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayOrdinaryUploadTests {
    private func upload(_ id: UUID = UUID(), value: Int = 7) throws -> Data {
        let fields: [String: Any] = ["value": ["kind": 0, "value": value], "floatValue": ["kind": 5, "value": 1.234567890123]]
        let entry: [String: Any] = ["id": 0, "globalId": id.uuidString, "tableName": "SimpleSyncObject",
            "operation": "INSERT", "rowId": 0, "globalRowId": UUID().uuidString,
            "changedFields": fields, "changedFieldsNames": ["value", "floatValue"],
            "timestamp": "2026-09-30T01:02:03.123456789Z", "isFromRemote": false, "isSynchronized": false,
            "uploadOriginal": ["version": 1, "fields": ["floatValue", "value"], "names": ["value", "floatValue"]]]
        // This is a provisional test peer input, not an issued canonical cut.
        return try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "upload", "auditLog": [entry]]])
    }
    @Test func actualSwiftBridgeAndRelayRetryPreserveOriginalIntoIssuedCut() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ordinary-source-upload-\(UUID().uuidString).sqlite")
        let store = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: path))
        defer { let close = store.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        let id = UUID(), bytes = try upload(id), frame = RelayFrame(bytes)
        #expect(frame.requestedIds == [id] && frame.claimsUpload && !frame.isAcknowledgment)
        let first = applyWithRetry(lattice: store, data: bytes, frame: frame, channelId: "ordinary-intake", userId: UUID(), ordinaryUpload: true)
        #expect(first.applied == [id] && first.unapplied.isEmpty)
        let replay = try store.receiveOrdinarySyncUpload(bytes)
        #expect(replay == [id] && store.count(SimpleSyncObject.self) == 1)
        let cut = try store.captureOrdinarySyncExport(); var found = false
        for page in 1..<cut.frameCount {
            let raw = try JSONSerialization.jsonObject(with: cut.frame(at: page)) as? [String: Any]
            let body = raw?["latticeOrdinarySync"] as? [String: Any]
            for record in body?["records"] as? [[String: Any]] ?? [] {
                guard let original = record["original"] as? [String: Any], original["globalId"] as? String == id.uuidString else { continue }
                found = true
                #expect(original["timestamp"] as? String == "2026-09-30T01:02:03.123456789Z")
                #expect(original["changedFieldsNames"] as? [String] == ["value", "floatValue"])
                #expect(record["originalDescriptor"] != nil)
            }
        }
        #expect(found)
    }
    @Test func ordinaryFrameKeepsActualRequestedIDsAndPartialShapeWithoutLegacyMixing() throws {
        let id = UUID(), bytes = try upload(id), frame = RelayFrame(bytes)
        #expect(frame.ordinaryUpload != nil && frame.requestedIds == [id])
        let partial = try #require(frame.reencoded(keeping: [id]))
        let root = try #require(JSONSerialization.jsonObject(with: partial) as? [String: Any])
        #expect(root.count == 1 && root["auditLog"] == nil)
        #expect(RelayFrame(partial).requestedIds == [id])
    }
}

extension RelayOrdinaryUploadTests {
    private func versioned(_ data: Data, _ version: String) throws -> Data {
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(root["latticeOrdinarySync"] as? [String: Any])
        var entries = try #require(body["auditLog"] as? [[String: Any]])
        for index in entries.indices { entries[index]["deliveryVersion"] = version }
        body["auditLog"] = entries; root["latticeOrdinarySync"] = body
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func accepted(_ value: OrdinarySyncUploadAcceptance) throws -> [[String: String]] {
        let root = try #require(JSONSerialization.jsonObject(with: value.acknowledgmentData()) as? [String: Any])
        #expect(Set(root.keys) == ["latticeOrdinarySync"])
        let body = try #require(root["latticeOrdinarySync"] as? [String: Any])
        #expect(Set(body.keys) == ["version", "kind", "accepted"])
        #expect(body["kind"] as? String == "uploadAck")
        #expect((body["version"] as? NSNumber)?.intValue == 2)
        return try #require(body["accepted"] as? [[String: String]])
    }
    @Test func actualVersionedBridgeRefusesMissingOrMalformedVersionsBeforeApply() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ordinary-version-refusal-\(UUID().uuidString).sqlite")
        let store = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: path))
        defer { let close = store.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        let raw = try upload()
        var refused = false
        do { _ = try store.receiveOrdinarySyncUploadWithAcknowledgment(raw) } catch { refused = true }
        #expect(refused && store.count(SimpleSyncObject.self) == 0)
        for version in ["", "00", "1", String(repeating: "A", count: 64), String(repeating: "a", count: 65)] {
            let invalid = try versioned(raw, version); var rejected = false
            do { _ = try store.receiveOrdinarySyncUploadWithAcknowledgment(invalid) } catch { rejected = true }
            #expect(rejected && store.count(SimpleSyncObject.self) == 0)
        }
        let actual = try store.receiveOrdinarySyncUploadWithAcknowledgment(versioned(raw, "0"))
        #expect(actual.ids.count == 1 && store.count(SimpleSyncObject.self) == 1)
        #expect(try accepted(actual).first?["deliveryVersion"] == "0")
    }

    @Test func nativeIssuedMergeDeduplicatesVersionsAndPreservesPriorOnConflictingMerge() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ordinary-version-merge-\(UUID().uuidString).sqlite")
        let store = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: path))
        defer { let close = store.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        let id = UUID(), raw = try upload(id), initial = try versioned(raw, "0")
        let first = try store.receiveOrdinarySyncUploadWithAcknowledgment(initial)
        let before = try first.acknowledgmentData()
        let retry = try store.receiveOrdinarySyncUploadWithAcknowledgment(initial)
        let merged = try first.merging(retry)
        #expect(merged.ids == [id])
        #expect(try accepted(merged) == [["globalId": id.uuidString, "deliveryVersion": "0"]])
        let currentVersion = String(repeating: "a", count: 64)
        let later = try store.receiveOrdinarySyncUploadWithAcknowledgment(versioned(raw, currentVersion))
        #expect(try accepted(later) == [["globalId": id.uuidString, "deliveryVersion": currentVersion]])
        var refused = false
        do { _ = try first.merging(later) } catch { refused = true }
        #expect(refused)
        #expect(try first.acknowledgmentData() == before)
        #expect(first.ids == [id] && later.ids == [id] && store.count(SimpleSyncObject.self) == 1)
    }

    @Test func actualWorkerCarriesNativeVersionBytesWithoutLegacyAcknowledgmentSynthesis() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ordinary-version-worker-\(UUID().uuidString).sqlite")
        let store = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: path))
        defer { let close = store.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        let id = UUID(), data = try versioned(upload(id), "0")
        let result = applyWithRetry(lattice: store, data: data, frame: RelayFrame(data), channelId: "version-worker", userId: UUID(), ordinaryUpload: true, ordinaryVersioned: true)
        #expect(result.applied == [id] && result.unapplied.isEmpty && result.lastError == nil)
        let issued = try #require(result.ordinaryAcknowledgment)
        #expect(try accepted(issued.acceptance) == [["globalId": id.uuidString, "deliveryVersion": "0"]])
        #expect(store.count(SimpleSyncObject.self) == 1)
    }
}


private enum RelayVersionRetryFailure: Error { case laterAttempt }
@Model private final class RelayVersionUniqueObject {
    @Unique var name: String = ""
}

extension RelayOrdinaryUploadTests {
    @Test func actualPartialCommitKeepsIssuedVersionAcknowledgmentWhenLaterRetryThrows() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ordinary-version-partial-\(UUID().uuidString).sqlite")
        let store = try Lattice(RelayVersionUniqueObject.self, configuration: .init(fileURL: path))
        defer { let close = store.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        let existing = RelayVersionUniqueObject(); existing.name = "occupied"
        try store.add(existing)
        let acceptedID = UUID(), refusedID = UUID()
        func entry(_ id: UUID, name: String) -> [String: Any] {
            ["id": 0, "globalId": id.uuidString, "tableName": RelayVersionUniqueObject.entityName,
             "operation": "INSERT", "rowId": 0, "globalRowId": UUID().uuidString,
             "changedFields": ["name": ["kind": 2, "value": name]], "changedFieldsNames": ["name"],
             "timestamp": "2026-09-30T01:02:03.123Z", "isFromRemote": false, "isSynchronized": false,
             "uploadOriginal": ["version": 1, "fields": ["name"], "names": ["name"]], "deliveryVersion": "0"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "upload",
            "auditLog": [entry(acceptedID, name: "accepted"), entry(refusedID, name: "occupied")]]])
        let channel = "ordinary-version-partial-\(UUID().uuidString)"
        let previous = _applyFaultForTesting.withLockedValue { value in
            let old = value
            value = { incoming, attempt in
                if incoming == channel {
                    if attempt == 2 { throw RelayVersionRetryFailure.laterAttempt }
                } else { try old?(incoming, attempt) }
            }
            return old
        }
        defer { _applyFaultForTesting.withLockedValue { $0 = previous } }
        // Attempt one uses the real declared UNIQUE index and per-entry SQL
        // savepoint; only the conflicting row fails. Attempt two throws before
        // native intake, so it cannot overwrite the earlier issued acceptance.
        let result = applyWithRetry(lattice: store, data: data, frame: RelayFrame(data), channelId: channel,
                                    userId: UUID(), ordinaryUpload: true, ordinaryVersioned: true)
        #expect(result.attempts == 2 && result.lastError != nil)
        #expect(result.applied == [acceptedID] && result.unapplied == [refusedID])
        let issued = try #require(result.ordinaryAcknowledgment)
        #expect(try accepted(issued.acceptance) == [["globalId": acceptedID.uuidString, "deliveryVersion": "0"]])
        let names = store.objects(RelayVersionUniqueObject.self).snapshot().map { $0.name }.sorted()
        #expect(names == ["accepted", "occupied"])
        #expect(!store.objects(AuditLog.self).snapshot().contains { $0.globalId == refusedID })
    }
}
