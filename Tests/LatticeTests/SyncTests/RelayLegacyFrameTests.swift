import Foundation
import Testing
@testable import LatticeServerKit

@Suite("Legacy relay audit fan-out")
struct RelayLegacyFrameTests {
    private func row(id: UUID, payloadBytes: Int) -> [String: Any] {
        ["globalId": id.uuidString,
         "payload": String(repeating: "x", count: payloadBytes),
         "futureField": ["nested": [1, 2, 3]]]
    }

    private func frame(_ rows: [[String: Any]]) throws -> RelayFrame {
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "auditLog", "auditLog": rows, "futureEnvelope": "retained"
        ])
        return RelayFrame(data)
    }

    private func decodedRows(_ data: Data) throws -> [[String: Any]] {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["kind"] as? String == "auditLog")
        #expect(root["futureEnvelope"] == nil)
        return try #require(root["auditLog"] as? [[String: Any]])
    }

    @Test func splittingPreservesOrderUnknownFieldsAndAppliedSubset() throws {
        let ids = (0..<8).map { _ in UUID() }
        let rows = ids.map { row(id: $0, payloadBytes: 120) }
        let legacy = try frame(rows)
        let applied = Set(ids.enumerated().compactMap { $0.offset == 3 ? nil : $0.element })
        let pages = try legacy.boundedAuditFrames(keeping: applied, maximumBytes: 600)
        #expect(pages.count > 1)
        #expect(pages.allSatisfy { $0.count <= 600 })
        let received = try pages.flatMap { try decodedRows($0) }
        #expect(received.compactMap { $0["globalId"] as? String } ==
                ids.filter { applied.contains($0) }.map(\.uuidString))
        for entry in received {
            #expect(entry["payload"] as? String == String(repeating: "x", count: 120))
            let unknown = try #require(entry["futureField"] as? [String: Any])
            #expect(unknown["nested"] as? [Int] == [1, 2, 3])
        }
        let empty = try legacy.boundedAuditFrames(keeping: [])
        #expect(empty.isEmpty)
    }

    @Test func oversizedSingleRowTravelsAloneAndDoesNotBlockFollowingRows() throws {
        let ids = (0..<3).map { _ in UUID() }
        let rows = [row(id: ids[0], payloadBytes: 1),
                    row(id: ids[1], payloadBytes: 2048),
                    row(id: ids[2], payloadBytes: 1)]
        let legacy = try frame(rows)
        let pages = try legacy.boundedAuditFrames(keeping: Set(ids), maximumBytes: 512)
        try #require(pages.count == 3)
        #expect(pages[0].count <= 512)
        #expect(pages[1].count > 512)
        #expect(pages[2].count <= 512)
        let received = try pages.map { try decodedRows($0) }
        #expect(received.allSatisfy { $0.count == 1 })
        #expect(received.flatMap { $0 }.compactMap { $0["globalId"] as? String } == ids.map(\.uuidString))
    }

    @Test func oversizedEnvelopeIsNotRepeatedWhenRepackingRows() throws {
        let ids = (0..<20).map { _ in UUID() }
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "auditLog", "auditLog": ids.map { row(id: $0, payloadBytes: 1) },
            "futureEnvelope": String(repeating: "x", count: 2048)
        ])
        let legacy = RelayFrame(data)
        let pages = try legacy.boundedAuditFrames(keeping: Set(ids), maximumBytes: 512)
        #expect(pages.allSatisfy { $0.count <= 512 })
        let received = try pages.flatMap { try decodedRows($0) }
        #expect(received.compactMap { $0["globalId"] as? String } == ids.map(\.uuidString))
    }
}
