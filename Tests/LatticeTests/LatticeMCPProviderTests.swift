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
        let url = testTemporaryDirectory
            .appending(path: "mcp_\(UUID().uuidString).sqlite")
        let lattice = try Lattice(DynPerson.self, DynDog.self, configuration: .init(fileURL: url))
        let dog = DynDog(); dog.name = "Rex"; dog.breed = "Husky"
        try lattice.add(dog)
        let alice = DynPerson(); alice.name = "Alice"; alice.age = 34
        try lattice.add(alice); alice.dog = dog
        let bob = DynPerson(); bob.name = "Bob"; bob.age = 20
        try lattice.add(bob)
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

    // `toolNames` is the embedder's registration list (1.0 public surface):
    // every advertised name must be answered by `handle` (anything else comes
    // back `unknown_tool`), so the constant cannot drift from the dispatch
    // switch. Empty-args calls may fail validation (`invalid_predicate` etc.)
    // but must never be *unrouted*.
    @Test func testToolNamesMatchesDispatch() async throws {
        let url = try fixture()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let provider = try await LatticeDataProvider(fileURL: url)

        #expect(Set(LatticeToolCatalog.toolNames) == Set([
            "lattice_schema", "lattice_query", "lattice_get", "lattice_count",
            "lattice_search", "lattice_nearest", "lattice_geo", "lattice_status", "lattice_changes"
        ]))
        #expect(LatticeToolCatalog.toolNames == LatticeDataProvider.toolNames)
        for descriptor in LatticeToolCatalog.tools {
            let schema = try #require(JSONSerialization.jsonObject(
                with: Data(descriptor.inputSchemaJSON.utf8)) as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["properties"] is [String: Any])
            let name = descriptor.name
            let r = await provider.handle(tool: name, argumentsJSON: "{}")
            #expect(!r.json.contains("unknown_tool"),
                    "'\(name)' is in toolNames but not routed by handle(tool:)")
        }
    }

    @Test func testScopedQueriesKeepRowsFieldsAndSourcePrivate() async throws {
        let url = try fixture()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let pool = LatticeProviderPool(defaultDB: url,
            readPolicy: LatticeReadPolicy(permittedFields: ["DynPerson": ["name"]],
                requiredRowValues: ["DynPerson": ["name": "Alice"]]), sourceID: "selected-room")
        let result = await pool.handle(tool: "lattice_query",
            argumentsJSON: #"{"model":"DynPerson","depth":3}"#)
        #expect(!result.isError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        let rows = try #require(json["results"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["name"] as? String == "Alice")
        #expect(rows.allSatisfy { Set($0.keys).isSubset(of: ["id", "globalId", "name"]) })
        #expect((json["source"] as? [String: Any])?["id"] as? String == "selected-room")
        #expect(!result.json.contains(url.path))
        #expect(!result.json.contains("Bob"))
        #expect(!result.json.contains("Rex"))

        for arguments in [
            #"{"model":"DynPerson","fields":["age"]}"#,
            #"{"model":"DynPerson","where":{"age":{"$gte":0}}}"#,
            #"{"model":"DynDog"}"#
        ] {
            let refused = await pool.handle(tool: "lattice_query", argumentsJSON: arguments)
            #expect(refused.isError)
            #expect(!refused.json.contains(url.path))
        }
        let count = await pool.handle(tool: "lattice_count", argumentsJSON: #"{"model":"DynPerson"}"#)
        #expect(!count.isError)
        #expect(count.json.contains("\"count\":1"))
    }

    @Test func testScopedHistoryUsesEventTimeIdentityNotCurrentRow() async throws {
        let url = testTemporaryDirectory.appending(path: "mcphistory_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self, configuration: .init(fileURL: url))
            defer { lattice.close() }
            let person = DynPerson(); person.name = "Alice"; person.age = 34
            try lattice.add(person)
            // A current-row lookup cannot authorize historical data after this move.
            person.name = "Moved"
            lattice.checkpoint()
        }
        let pool = LatticeProviderPool(defaultDB: url,
            readPolicy: LatticeReadPolicy(permittedFields: ["DynPerson": ["name"]],
                requiredRowValues: ["DynPerson": ["name": "Alice"]]), sourceID: "original-room")
        let live = await pool.handle(tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        #expect(!live.isError)
        #expect(live.json.contains("\"count\":0"))
        let history = await pool.handle(tool: "lattice_changes",
            argumentsJSON: #"{"start":"retained","includeValues":true}"#)
        #expect(!history.isError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(history.json.utf8)) as? [String: Any])
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(events.contains { ($0["values"] as? [String: Any])?["name"] as? String == "Alice" })
        #expect(!history.json.contains("Moved"))
        #expect(!history.json.contains("\"age\""))
        #expect(events.allSatisfy { $0["auditId"] == nil })
    }

    @Test func testScopedDiagnosticsKeepAuditValuesAndCursorsPrivate() async throws {
        let url = try fixture()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let policy = LatticeReadPolicy(permittedFields: ["DynPerson": ["name"]])
        let pool = LatticeProviderPool(defaultDB: url, readPolicy: policy, sourceID: "selected-room")
        let status = await pool.handle(tool: "lattice_status", argumentsJSON: "{}")
        #expect(!status.isError)
        let statusJSON = try #require(JSONSerialization.jsonObject(with: Data(status.json.utf8)) as? [String: Any])
        let audit = try #require(statusJSON["audit"] as? [String: Any])
        #expect(audit["supported"] as? Bool == true)
        #expect(audit["countsAvailable"] as? Bool == false)
        #expect(audit["retainedCount"] is NSNull)
        #expect(audit["minimum"] is NSNull)
        #expect(audit["maximum"] is NSNull)
        #expect(!status.json.contains(url.path))

        let page = await pool.handle(tool: "lattice_changes",
            argumentsJSON: #"{"start":"retained","includeValues":true}"#)
        #expect(!page.isError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(page.json.utf8)) as? [String: Any])
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(!events.isEmpty)
        #expect(!page.json.contains(url.path))
        #expect(!page.json.contains("DynDog"))
        #expect(!page.json.contains("Rex"))
        for event in events {
            #expect(event["model"] as? String == "DynPerson")
            #expect(event["auditId"] == nil)
            let names = try #require(event["changedFields"] as? [String])
            #expect(Set(names).isSubset(of: ["id", "globalId", "name"]))
            if let values = event["values"] as? [String: Any] {
                #expect(Set(values.keys).isSubset(of: ["id", "globalId", "name"]))
            }
        }
        let cursor = try #require(json["nextCursor"] as? String)
        #expect(cursor.hasPrefix("scoped:"))
        let continuation = String(decoding: try JSONSerialization.data(withJSONObject:
            ["cursor": cursor, "includeValues": true]), as: UTF8.self)
        let next = await pool.handle(tool: "lattice_changes", argumentsJSON: continuation)
        #expect(!next.isError)
        let other = LatticeProviderPool(defaultDB: url, readPolicy: policy, sourceID: "selected-room")
        let refused = await other.handle(tool: "lattice_changes", argumentsJSON: continuation)
        #expect(refused.isError)
        #expect(refused.json.contains("cursor_expired"))
        let hidden = await pool.handle(tool: "lattice_changes", argumentsJSON: #"{"models":["DynDog"]}"#)
        #expect(hidden.isError)
        #expect(hidden.json.contains("forbidden_model"))
    }
}
