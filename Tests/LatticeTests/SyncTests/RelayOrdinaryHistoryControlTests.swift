import Foundation
import Testing
import Lattice
@testable import LatticeServerKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayOrdinaryHistoryControlTests {
    private func decode(_ body: [String: Any]) throws -> RelayOrdinaryControl {
        try .decode(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body]))
    }
    private func refused(_ body: () throws -> Void) {
        do { try body(); Issue.record("expected closed history control refusal") } catch {}
    }
    @Test func originalScalarRequestAndDistinctHistoryEffectKeepClosedByteShapes() throws {
        let nonce = UUID().uuidString
        #expect(try decode(["version": 2, "kind": "request", "request": nonce]) == .request(nonce))
        #expect(try decode(["version": 2, "profile": "paged-history-v1", "kind": "request", "request": nonce]) == .historyRequest(nonce))
        for profile in ["", "unknown-v1", "paged-history-v1 "] {
            refused { _ = try decode(["version": 2, "profile": profile, "kind": "request", "request": nonce]) }
        }
        refused { _ = try decode(["version": 2, "profile": "paged-history-v1", "kind": "request", "request": nonce, "modelProfile": "unregistered"]) }
        refused { _ = try decode(["version": true, "profile": "paged-history-v1", "kind": "request", "request": nonce]) }
        let duplicate = "{\"latticeOrdinarySync\":{\"version\":2,\"profile\":\"paged-history-v1\",\"\\u0070rofile\":\"paged-history-v1\",\"kind\":\"request\",\"request\":\"\(nonce)\"}}"
        refused { _ = try RelayOrdinaryControl.decode(Data(duplicate.utf8)) }
    }
    @Test func passiveProgressCannotDecodeCanonicalReceiptACKOrNoncanonicalFields() throws {
        // These untrusted scalar coordinates test only wire syntax. They do not
        // construct an issued native cut, selection, route or accepted receipt.
        let source = UUID().uuidString, stage = UUID().uuidString
        let good: [String: Any] = ["version": 2, "profile": "paged-history-v1", "kind": "historyProgress", "source": source,
                                 "epoch": "1", "cut": "1", "stage": stage, "nextPage": "0", "previousDigest": "", "stagedComplete": false]
        guard case .historyProgress(let observed) = try decode(good) else { Issue.record("expected passive progress"); return }
        #expect(observed.source == source && observed.stage == stage && observed.nextPage == 0 && !observed.stagedComplete)
        for (field, value) in [("nextPage", "01"), ("nextPage", "65537"), ("epoch", "+1"), ("cut", "0"), ("previousDigest", "a")] {
            var bad = good; bad[field] = value; refused { _ = try decode(bad) }
        }
        for kind in ["historyReceipt", "receipt", "uploadAck"] { var bad = good; bad["kind"] = kind; refused { _ = try decode(bad) } }
        var numericBool = good; numericBool["stagedComplete"] = 1; refused { _ = try decode(numericBool) }
        var extra = good; extra["ack"] = []; refused { _ = try decode(extra) }
    }
}
