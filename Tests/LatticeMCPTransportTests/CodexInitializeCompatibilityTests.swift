import Foundation
import Testing
import MCP
import LatticeMCPTransport

@Suite("Codex initialization preserves native capability validation")
struct CodexInitializeCompatibilityTests {
    private func message(experimental: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "exact-request-id", "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "codex", "version": "0.154.0"],
                       "capabilities": ["roots": ["listChanged": true], "experimental": experimental]],
        ], options: [.sortedKeys])
    }

    @Test func emptyUnsupportedAdvertisementNoLongerBreaksActualSDKInitialization() throws {
        // Exact synthetic loaded-thread initialize frame captured from installed Codex 0.154.0.
        let original = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.154.0"}}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Request<Initialize>.self, from: original) }
        let normalized = LatticeSerializedStdioTransport.compatibleCodexInitialize(original)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: normalized)
        #expect(request.id == .number(0))
        #expect(request.params.protocolVersion == "2025-06-18")
        #expect(request.params.clientInfo.name == "codex-mcp-client")
        #expect(request.params.capabilities.experimental == nil)
        let root = try #require(try JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        let params = try #require(root["params"] as? [String: Any])
        let caps = try #require(params["capabilities"] as? [String: Any])
        let elicitation = try #require(caps["elicitation"] as? NSDictionary)
        #expect(elicitation.isEqual(to: ["form": [:], "url": [:]]))
    }

    @Test func otherSupportedCapabilitiesAndRequestFieldsRemainExact() throws {
        let original = try message(experimental: ["codex/auth-change": [:], "fixture/string-extension": "retained"])
        let normalized = LatticeSerializedStdioTransport.compatibleCodexInitialize(original)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: normalized)
        #expect(request.id == .string("exact-request-id"))
        #expect(request.params.capabilities.roots?.listChanged == true)
        #expect(request.params.capabilities.experimental == ["fixture/string-extension": "retained"])
        var expected = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var params = try #require(expected["params"] as? [String: Any])
        var capabilities = try #require(params["capabilities"] as? [String: Any])
        capabilities["experimental"] = ["fixture/string-extension": "retained"]
        params["capabilities"] = capabilities; expected["params"] = params
        let actual = try #require(try JSONSerialization.jsonObject(with: normalized) as? NSDictionary)
        #expect(actual.isEqual(to: expected))
    }

    @Test(arguments: ["null", "true", "\"supported-string\"", "{\"required\":true}"])
    func nonemptyOrDifferentAuthChangeShapesKeepNativeValidation(_ value: String) throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
        let data = try message(experimental: ["codex/auth-change": parsed])
        #expect(LatticeSerializedStdioTransport.compatibleCodexInitialize(data) == data)
        if value != "\"supported-string\"" {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Request<Initialize>.self, from: data) }
        }
    }

    @Test func anotherUnsupportedExtensionStillFailsTheActualSDK() throws {
        let data = try message(experimental: ["codex/auth-change": [:], "unknown/object-extension": [:]])
        let normalized = LatticeSerializedStdioTransport.compatibleCodexInitialize(data)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Request<Initialize>.self, from: normalized) }
        let root = try #require(try JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        let params = try #require(root["params"] as? [String: Any])
        let caps = try #require(params["capabilities"] as? [String: Any])
        let experimental = try #require(caps["experimental"] as? [String: Any])
        #expect(experimental["unknown/object-extension"] != nil)
    }

    @Test(arguments: ["tools/call", "notifications/initialized", "other/initialize"])
    func everyNonInitializeFrameRemainsByteIdentical(_ method: String) {
        let data = Data(" { \"jsonrpc\":\"2.0\", \"id\":17, \"method\":\"\(method)\", \"params\":{\"capabilities\":{\"experimental\":{\"codex/auth-change\":{}}}}, \"auth\":\"unchanged\" } ".utf8)
        #expect(LatticeSerializedStdioTransport.compatibleCodexInitialize(data) == data)
    }

    @Test func malformedJSONRetainsOriginalDecoderFailure() {
        let data = Data("{invalid initialize".utf8)
        #expect(LatticeSerializedStdioTransport.compatibleCodexInitialize(data) == data)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Request<Initialize>.self, from: data) }
    }
}
