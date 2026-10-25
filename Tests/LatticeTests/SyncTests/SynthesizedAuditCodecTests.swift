import Foundation
import CxxStdlib
import LatticeSwiftCppBridge
import Testing
@testable import Lattice

@Suite("Synthesized audit transport provenance")
struct SynthesizedAuditCodecTests {
    private func payload(flag: Bool?, cxx: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            "id": 1,
            "globalId": "9956b68b-e020-430c-9053-d8e634db437a",
            "tableName": "CodecRecord",
            "operation": "UPDATE",
            "rowId": 73,
            "globalRowId": "29b92ed5-d3e9-4beb-a81f-719630667df4",
            "changedFields": ["title": ["kind": 2, "value": "stale snapshot"]],
            "changedFieldsNames": ["title"],
            "timestamp": cxx ? "1792957328.0" : 814650128.0,
            "isFromRemote": true,
            "isSynchronized": true,
        ]
        if let flag { result["synthesized"] = flag }
        return result
    }

    private func encodedObject(_ entry: AuditLog) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: entry.toCxxJSONBytes()) as? [String: Any])
    }

    @Test(arguments: [true, false])
    func codablePreservesSnapshotProvenance(_ flag: Bool) throws {
        let bytes = try JSONSerialization.data(withJSONObject: payload(flag: flag))
        let entry = try JSONDecoder().decode(AuditLog.self, from: bytes)
        let encoded = try encodedObject(entry)
        #expect((encoded["synthesized"] as? Bool) == (flag ? true : nil))
        #expect(encoded["globalId"] as? String == "9956b68b-e020-430c-9053-d8e634db437a")
        #expect(encoded["operation"] as? String == "UPDATE")
    }

    @Test(arguments: [true, false])
    func cxxJSONBridgePreservesSnapshotProvenance(_ flag: Bool) throws {
        let bytes = try JSONSerialization.data(withJSONObject: payload(flag: flag, cxx: true))
        let entry = try AuditLog.fromCxxJSON(try #require(String(data: bytes, encoding: .utf8)))
        let encoded = try encodedObject(entry)
        #expect((encoded["synthesized"] as? Bool) == (flag ? true : nil))
        #expect(entry.timestamp.timeIntervalSince1970 == 1792957328.0)
    }

    @Test func legacyAbsentFlagRemainsAnOrdinaryAudit() throws {
        let bytes = try JSONSerialization.data(withJSONObject: payload(flag: nil))
        let entry = try JSONDecoder().decode(AuditLog.self, from: bytes)
        #expect(try encodedObject(entry)["synthesized"] == nil)

        let cxxBytes = try JSONSerialization.data(withJSONObject: payload(flag: nil, cxx: true))
        let bridged = try AuditLog.fromCxxJSON(try #require(String(data: cxxBytes, encoding: .utf8)))
        #expect(try encodedObject(bridged)["synthesized"] == nil)
    }

    @Test func nativeEntryInitializerPreservesSnapshotProvenance() throws {
        var native = lattice.audit_log_entry()
        native.global_id = std.string("9956b68b-e020-430c-9053-d8e634db437a")
        native.table_name = std.string("CodecRecord")
        native.operation = std.string("UPDATE")
        native.global_row_id = std.string("29b92ed5-d3e9-4beb-a81f-719630667df4")
        native.timestamp = std.string("1792957328.0")
        native.synthesized = true
        let entry = AuditLog(from: native)
        #expect(try encodedObject(entry)["synthesized"] as? Bool == true)
        #expect(entry.tableName == "CodecRecord")
    }
}
