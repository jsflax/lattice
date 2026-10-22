import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Lattice

@Suite("WebSocket message byte ownership")
struct WebSocketMessageTests {
    private static func binary(_ bytes: [UInt8]) -> lattice.transport_message {
        var vector = lattice.ByteVector()
        for byte in bytes { vector.push_back(byte) }
        return lattice.transport_message.from_binary(vector)
    }

    @Test func emptyBinaryRemainsABinaryMessage() {
        let result = Lattice.WebsocketClient.webSocketMessage(Self.binary([]))
        guard case .data(let data) = result else {
            Issue.record("An empty binary frame must remain binary")
            return
        }
        #expect(data.isEmpty)
    }

    @Test func binaryPreservesEveryByteIncludingNULAndInvalidUTF8() {
        let expected = (0...255).map(UInt8.init)
        let result = Lattice.WebsocketClient.webSocketMessage(Self.binary(expected))
        guard case .data(let data) = result else {
            Issue.record("A binary frame must not become text")
            return
        }
        #expect(data == Data(expected))
    }

    @Test func copiedBinaryOutlivesTheTransportMessageAndOwnsItsBytes() {
        let expected = (0..<65_536).map { UInt8(truncatingIfNeeded: $0) }
        func copied() -> Data {
            var message = Self.binary(expected)
            guard case .data(let data) = Lattice.WebsocketClient.webSocketMessage(message) else {
                Issue.record("A binary frame must not become text")
                return Data()
            }
            // The send completion outlives the C++ callback's borrowed input. Mutating the original
            // before returning, then destroying it here, must not alter the queued Foundation value.
            message.data.clear()
            return data
        }
        let data = copied()
        #expect(data.count == expected.count)
        #expect(data == Data(expected))
    }

    @Test func textStillUsesTheStringMessageCase() {
        let expected = "Sync ready · café · 日本語 · 🛰️"
        let input = lattice.transport_message.from_string(std.string(expected))
        let result = Lattice.WebsocketClient.webSocketMessage(input)
        guard case .string(let text) = result else {
            Issue.record("A text frame must remain text")
            return
        }
        #expect(text == expected)
    }
}
