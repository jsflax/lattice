import Foundation
import Testing
import Lattice
import LatticeMCP

// Exercises the full MCP tool pipeline (schema/query/get/count + DynamicQuery +
// serializer) through LatticeDataProvider — JSON string in, JSON string out —
// which is exactly what the lattice-mcp executable calls per tool request.
// (Reuses DynPerson/DynDog from DynamicAPITests, same test target.)
@Suite("LatticeMCP Provider Tests")
final class LatticeMCPProviderTests {

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mcp_\(UUID().uuidString).sqlite")
        let lattice = try Lattice(DynPerson.self, DynDog.self, configuration: .init(fileURL: url))
        let dog = DynDog(); dog.name = "Rex"; dog.breed = "Husky"
        lattice.add(dog)
        let alice = DynPerson(); alice.name = "Alice"; alice.age = 34
        lattice.add(alice); alice.dog = dog
        let bob = DynPerson(); bob.name = "Bob"; bob.age = 20
        lattice.add(bob)
        lattice.checkpoint()
        lattice.close()
        return url
    }

    @Test func testProviderToolCalls() async throws {
        let url = try fixture()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let provider = try await LatticeDataProvider(fileURL: url)

        // lattice_schema
        let schema = await provider.handle(tool: "lattice_schema", argumentsJSON: "{}")
        #expect(!schema.isError)
        #expect(schema.json.contains("DynPerson"))
        #expect(schema.json.contains("DynDog"))
        #expect(schema.json.contains("\"kind\":\"link\""))

        // lattice_query with predicate + link traversal at depth 1
        let q = await provider.handle(
            tool: "lattice_query",
            argumentsJSON: #"{"model":"DynPerson","where":{"age":{"$gte":30}},"depth":1}"#)
        #expect(!q.isError)
        #expect(q.json.contains("\"count\":1"))
        #expect(q.json.contains("Alice"))
        #expect(q.json.contains("Rex"))           // dog link resolved
        #expect(q.json.contains("\"id\":") == false || q.json.contains("globalId"))

        // lattice_count (no predicate)
        let c = await provider.handle(tool: "lattice_count", argumentsJSON: #"{"model":"DynPerson"}"#)
        #expect(!c.isError)
        #expect(c.json.contains("\"count\":2"))

        // lattice_count with predicate
        let c2 = await provider.handle(
            tool: "lattice_count",
            argumentsJSON: #"{"model":"DynPerson","where":{"name":{"$contains":"ob"}}}"#)
        #expect(c2.json.contains("\"count\":1"))

        // Error: unknown model
        let e1 = await provider.handle(tool: "lattice_query", argumentsJSON: #"{"model":"Nope"}"#)
        #expect(e1.isError)
        #expect(e1.json.contains("invalid_table"))

        // Security: unknown property rejected
        let e2 = await provider.handle(
            tool: "lattice_query",
            argumentsJSON: #"{"model":"DynPerson","where":{"ssn":{"$eq":"x"}}}"#)
        #expect(e2.isError)
        #expect(e2.json.contains("unknown_property"))

        // Unknown tool
        let e3 = await provider.handle(tool: "lattice_bogus", argumentsJSON: "{}")
        #expect(e3.isError)
        #expect(e3.json.contains("unknown_tool"))
    }
}
