import Foundation
import Testing
import Lattice
@testable import LatticeMCP

@Suite("LatticeMCP default policy")
@MainActor
final class LatticeMCPDefaultPolicyTests {
    private let policy = LatticeReadPolicy(permittedFields: [
        "DynPerson": ["name", "age", "score", "dog", "nicknames"],
        "DynDog": ["name", "breed"],
        "Article": ["title", "content", "embedding"]
    ])

    private func fixture(rows: Int = 110, nameSize: Int = 0) throws -> (URL, Lattice) {
        let url = testTemporaryDirectory.appending(path: "mcp-defaults-\(UUID()).sqlite")
        let writer = try Lattice(DynPerson.self, DynDog.self, Article.self,
                                 configuration: .init(fileURL: url))
        try writer.withTransaction {
            let dog = DynDog(); dog.name = "Rex"
            try writer.add(dog)
            for index in 0..<rows {
                let person = DynPerson()
                person.name = nameSize > 0 ? String(repeating: "x", count: nameSize) : "person\(index)"
                try writer.add(person)
                if index == 0 { person.dog = dog }
            }
            for index in 0..<30 {
                try writer.add(Article(title: "article\(index)", content: "searchable text",
                                       embedding: [1, Float(index) / 100, 0, 0]))
            }
        }
        writer.checkpoint()
        return (url, writer)
    }

    private func json(_ result: ProviderResult) throws -> [String: Any] {
        try #require(!result.isError, "Unexpected provider error: \(result.json)")
        return try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
    }

    @Test(arguments: [false, true])
    func omittedPolicyKeepsOneHundredRowsAndOneLinkHop(throughPool: Bool) async throws {
        let (url, writer) = try fixture()
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let result: ProviderResult
        if throughPool {
            result = await LatticeProviderPool(defaultDB: url).handle(
                tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        } else {
            let provider = try await LatticeDataProvider(fileURL: url)
            result = await provider.handle(tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        }
        let payload = try json(result)
        let rows = try #require(payload["results"] as? [[String: Any]])
        #expect(rows.count == 100)
        #expect((rows.first?["dog"] as? [String: Any])?["name"] as? String == "Rex")
    }

    @Test(arguments: [false, true])
    func explicitPolicyKeepsBoundedDefaults(throughPool: Bool) async throws {
        let (url, writer) = try fixture()
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let result: ProviderResult
        if throughPool {
            result = await LatticeProviderPool(defaultDB: url, readPolicy: policy).handle(
                tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        } else {
            let provider = try await LatticeDataProvider(fileURL: url, readPolicy: policy)
            result = await provider.handle(tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        }
        let rows = try #require(try json(result)["results"] as? [[String: Any]])
        #expect(rows.count == 25)
        #expect((rows.first?["dog"] as? [String: Any])?["name"] == nil)
    }

    @Test(arguments: [false, true])
    func legacyLimitsClampWhilePolicyLimitsRefuse(throughPool: Bool) async throws {
        let (url, writer) = try fixture(rows: 12)
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let legacy = try await LatticeDataProvider(fileURL: url, maxLimit: 7)
        let scoped = try await LatticeDataProvider(fileURL: url, maxLimit: 7, readPolicy: policy)
        let legacyPool = LatticeProviderPool(defaultDB: url, maxLimit: 7)
        let scopedPool = LatticeProviderPool(defaultDB: url, maxLimit: 7, readPolicy: policy)
        for (arguments, count) in [
            (#"{"model":"DynPerson","limit":-1}"#, 0),
            (#"{"model":"DynPerson","limit":50000}"#, 7),
            (#"{"model":"DynPerson","depth":-1}"#, 7),
            (#"{"model":"DynPerson","depth":99}"#, 7)
        ] {
            let accepted = throughPool
                ? await legacyPool.handle(tool: "lattice_query", argumentsJSON: arguments)
                : await legacy.handle(tool: "lattice_query", argumentsJSON: arguments)
            let refused = throughPool
                ? await scopedPool.handle(tool: "lattice_query", argumentsJSON: arguments)
                : await scoped.handle(tool: "lattice_query", argumentsJSON: arguments)
            let payload = try json(accepted)
            #expect(payload["count"] as? Int == count)
            if count == 0 {
                #expect(payload["hasMore"] as? Bool == false)
                #expect(payload["nextOffset"] == nil)
            }
            #expect(refused.isError)
            #expect(refused.json.contains("invalid_arguments"))
        }
    }

    @Test func legacyReadsKeepHostCapsAndLargeUntruncatedValues() async throws {
        let (url, writer) = try fixture(rows: 36, nameSize: 4_000)
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let legacy = LatticeProviderPool(defaultDB: url, maxLimit: 20_000, maxDepthCap: 8)
        let result = await legacy.handle(tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        let rows = try #require(try json(result)["results"] as? [[String: Any]])
        #expect(rows.count == 36)
        #expect(result.json.utf8.count > 32_768)
        #expect((rows.first?["name"] as? String)?.utf8.count == 4_000)

        let scoped = LatticeProviderPool(defaultDB: url, readPolicy: policy)
        let bounded = await scoped.handle(tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        let boundedRows = try #require(try json(bounded)["results"] as? [[String: Any]])
        #expect(boundedRows.count < 25)
        #expect(bounded.json.utf8.count <= 32_768)
        #expect((boundedRows.first?["name"] as? String)?.utf8.count == 2_048)
    }

    @Test func unscopedDefaultMaximumExceedsThePolicyMaximum() async throws {
        let (url, writer) = try fixture(rows: 550)
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let provider = try await LatticeDataProvider(fileURL: url)
        let result = await provider.handle(tool: "lattice_query",
            argumentsJSON: #"{"model":"DynPerson","limit":550,"fields":["name"]}"#)
        let payload = try json(result)
        #expect(payload["count"] as? Int == 550)
    }

    @Test(arguments: [false, true])
    func omittedNearestKRemainsTenWithoutPolicy(throughPool: Bool) async throws {
        let (url, writer) = try fixture(rows: 1)
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let arguments = #"{"model":"Article","field":"embedding","vector":[1,0,0,0],"fields":["title"]}"#
        let result: ProviderResult
        let bounded: ProviderResult
        if throughPool {
            result = await LatticeProviderPool(defaultDB: url).handle(tool: "lattice_nearest", argumentsJSON: arguments)
            bounded = await LatticeProviderPool(defaultDB: url, readPolicy: policy).handle(tool: "lattice_nearest", argumentsJSON: arguments)
        } else {
            let provider = try await LatticeDataProvider(fileURL: url)
            let scoped = try await LatticeDataProvider(fileURL: url, readPolicy: policy)
            result = await provider.handle(tool: "lattice_nearest", argumentsJSON: arguments)
            bounded = await scoped.handle(tool: "lattice_nearest", argumentsJSON: arguments)
        }
        let payload = try json(result)
        let boundedPayload = try json(bounded)
        #expect(payload["count"] as? Int == 10)
        #expect(boundedPayload["count"] as? Int == 25)
    }

    @Test func legacyUnknownArgumentsAndEmptyDBKeepTheirMeaning() async throws {
        let (url, writer) = try fixture(rows: 1)
        defer { writer.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        let arguments = #"{"db":"","model":"DynPerson","limit":"default","unused":"ignored"}"#
        let legacy = await LatticeProviderPool(defaultDB: url).handle(tool: "lattice_query", argumentsJSON: arguments)
        let payload = try json(legacy)
        #expect(payload["count"] as? Int == 1)
        let scoped = await LatticeProviderPool(defaultDB: url, readPolicy: policy).handle(tool: "lattice_query", argumentsJSON: arguments)
        #expect(scoped.isError)
    }

    @Test func capabilitiesAndDefaultCatalogDescribeTheirLimits() async throws {
        let legacy = await LatticeProviderPool().handle(tool: "lattice_status", argumentsJSON: "{}")
        let scoped = await LatticeProviderPool(readPolicy: LatticeReadPolicy(permittedFields: [:])).handle(
            tool: "lattice_status", argumentsJSON: "{}")
        let custom = await LatticeProviderPool(maxLimit: 20_000, maxDepthCap: 8).handle(
            tool: "lattice_status", argumentsJSON: "{}")
        let legacyLimits = try #require(try json(legacy)["limits"] as? [String: Any])
        let scopedLimits = try #require(try json(scoped)["limits"] as? [String: Any])
        let customLimits = try #require(try json(custom)["limits"] as? [String: Any])
        #expect(legacyLimits["defaultRows"] as? Int == 100)
        #expect(legacyLimits["maxRows"] as? Int == 10_000)
        #expect(legacyLimits["maxDepth"] as? Int == 5)
        #expect(legacyLimits["defaultDepth"] as? Int == 1)
        #expect(legacyLimits["defaultNearest"] as? Int == 10)
        #expect(legacyLimits["maxOutputBytes"] == nil)
        #expect(scopedLimits["defaultRows"] as? Int == 25)
        #expect(scopedLimits["maxRows"] as? Int == 500)
        #expect(scopedLimits["maxDepth"] as? Int == 3)
        #expect(scopedLimits["defaultDepth"] as? Int == 0)
        #expect(scopedLimits["maxOutputBytes"] as? Int == 32_768)
        #expect(customLimits["maxRows"] as? Int == 20_000)
        #expect(customLimits["maxDepth"] as? Int == 8)
        let query = try #require(LatticeToolCatalog.tools.first { $0.name == "lattice_query" })
        let schema = try #require(JSONSerialization.jsonObject(with: Data(query.inputSchemaJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(properties["limit"]?["default"] as? Int == 100)
        #expect(properties["depth"]?["default"] as? Int == 1)
        #expect(properties["limit"]?["maximum"] == nil)
        let nearest = try #require(LatticeToolCatalog.tools.first { $0.name == "lattice_nearest" })
        let nearestSchema = try #require(JSONSerialization.jsonObject(with: Data(nearest.inputSchemaJSON.utf8)) as? [String: Any])
        let nearestProperties = try #require(nearestSchema["properties"] as? [String: [String: Any]])
        #expect(nearestProperties["k"]?["default"] as? Int == 10)
    }

    @Test func standaloneDoctorUsesTheUnscopedDefaults() async throws {
        // Executable target dependencies share the test products directory.
        // Match the existing cross-process fixture on macOS and Linux, including
        // external SwiftPM scratch paths; this test never silently skips.
        let bundleURL = Bundle(for: LatticeMCPDefaultPolicyTests.self).bundleURL
        let productsURL = bundleURL.pathExtension == "xctest"
            ? bundleURL.deletingLastPathComponent() : bundleURL
        let binary = productsURL.appending(path: "lattice-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "The lattice-mcp test dependency must be built beside the test bundle.")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--doctor"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning, "The standalone doctor did not exit.")
        #expect(process.terminationStatus == 0)
        let payload = try #require(JSONSerialization.jsonObject(
            with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let limits = try #require(payload["limits"] as? [String: Any])
        #expect(limits["defaultRows"] as? Int == 100)
        #expect(limits["defaultDepth"] as? Int == 1)
        #expect(limits["defaultNearest"] as? Int == 10)
    }
}
