import Foundation
import Testing
@testable import Lattice

@Suite("Initial replay completion codec")
struct CatchUpCompletionCodecTests {
    @Test func completionCannotBeMistakenForAnUploadAcknowledgement() throws {
        let encoded = try JSONEncoder().encode(ServerSentEvent.catchUpComplete)
        let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(payload["kind"] as? String == "catchUpComplete")
        #expect(payload["catchUpComplete"] as? Bool == true)
        #expect(payload["ack"] == nil)
        #expect(payload["auditLog"] == nil)
        guard case .catchUpComplete = try JSONDecoder().decode(ServerSentEvent.self, from: encoded) else {
            Issue.record("initial replay completion did not round-trip")
            return
        }
    }

    @Test(arguments: [
        #"{"kind":"catchUpComplete"}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":false}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":"true"}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":true,"ack":[]}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":true,"auditLog":[]}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":true,"floorReset":null}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":true,"replayRequest":[]}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":true,"nack":[]}"#,
        #"{"kind":"catchUpComplete","catchUpComplete":true,"rejected":"no"}"#
    ])
    func invalidCompletionDoesNotCertifyAReplay(_ frame: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ServerSentEvent.self, from: Data(frame.utf8))
        }
    }
}
