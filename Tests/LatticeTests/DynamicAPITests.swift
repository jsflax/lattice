import Foundation
import Testing
import Lattice

// Models used only to WRITE a database. The dynamic open never sees these types.
@Model final class DynPerson {
    @Indexed var name: String = ""
    var age: Int = 0
    var score: Double = 0
    var dog: DynDog?
    var nicknames: [String] = []
}

@Model final class DynDog {
    var name: String = ""
    var breed: String = ""
}

@Suite("Dynamic API Tests")
final class DynamicAPITests {

    @Test func testDynamicOpenRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dyn_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        // 1. Write with typed models, then checkpoint + close so the read-only
        //    (immutable) dynamic open sees the data in the main DB file.
        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let dog = DynDog(); dog.name = "Rex"; dog.breed = "Husky"
            lattice.add(dog)
            let p = DynPerson(); p.name = "Alice"; p.age = 34; p.score = 9.5
            p.nicknames = ["Al", "Ali"]
            lattice.add(p)
            p.dog = dog
            lattice.checkpoint()
            lattice.close()
        }

        // 2. Reopen dynamically — NO compile-time @Model types.
        let dyn = try Lattice.dynamic(fileURL: url)

        // 3. Schema reconstructed from the file (kinds + flags recovered).
        let schema = dyn.dynamicSchema
        let person = try #require(schema.first { $0.name == "DynPerson" })
        let props = person.properties
        #expect(props.contains { $0.name == "name" && $0.kind == .primitive
                                 && $0.columnType == .text && $0.isIndexed })
        #expect(props.contains { $0.name == "age" && $0.columnType == .integer })
        #expect(props.contains { $0.name == "dog" && $0.kind == .link
                                 && $0.linkTarget == "DynDog" })
        #expect(schema.contains { $0.name == "DynDog" })

        // 4. Query a link-free table.
        let dogRows = dyn.dynamicObjects("DynDog").snapshot()
        #expect(dogRows.first?.name as? String == "Rex")

        // 5. Query + scalar reads (native storage types).
        let rows = dyn.dynamicObjects("DynPerson").snapshot()
        try #require(rows.count == 1)
        let row = rows[0]
        #expect(row.tableName == "DynPerson")
        #expect(row.name as? String == "Alice")
        #expect(row.age as? Int64 == 34)
        #expect(row.score as? Double == 9.5)
        #expect(row.globalId != nil)

        // 6. Link traversal: row.dog -> DynamicObject(DynDog).
        let dog = try #require(row.dog as? DynamicObject)
        #expect(dog.tableName == "DynDog")
        #expect(dog.name as? String == "Rex")

        // 7. Filter + count via SQL fragments (what the MCP will build).
        #expect(dyn.dynamicObjects("DynPerson").count == 1)
        #expect(dyn.dynamicObjects("DynPerson").where("age >= 30").snapshot().count == 1)
        #expect(dyn.dynamicObjects("DynPerson").where("age >= 99").snapshot().isEmpty)
    }

    @Test func testDynamicPredicateTranslation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dynq_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let alice = DynPerson(); alice.name = "Alice"; alice.age = 34
            let bob = DynPerson(); bob.name = "Bob"; bob.age = 20
            lattice.add(alice); lattice.add(bob)
            lattice.checkpoint()
            lattice.close()
        }

        let dyn = try Lattice.dynamic(fileURL: url)
        let schema = try #require(dyn.dynamicSchema.first { $0.name == "DynPerson" }).properties

        func run(_ pred: [String: Any]) throws -> [DynamicObject] {
            dyn.dynamicObjects("DynPerson").where(try DynamicQuery.whereSQL(pred, schema: schema)).snapshot()
        }

        // $gte
        #expect(try run(["age": ["$gte": 30]]).count == 1)
        // bare equality
        #expect(try (run(["name": "Alice"]).first?.name as? String) == "Alice")
        // $and + $contains
        let r = try run(["$and": [["age": ["$lt": 30]], ["name": ["$contains": "ob"]]]])
        #expect(r.count == 1 && (r.first?.name as? String) == "Bob")
        // $in
        #expect(try run(["age": ["$in": [20, 34]]]).count == 2)
        // $or
        #expect(try run(["$or": [["name": "Alice"], ["name": "Bob"]]]).count == 2)

        // Security: unknown property / operator throw before any SQL is built.
        #expect(throws: DynamicQueryError.self) {
            _ = try DynamicQuery.whereSQL(["ssn": ["$eq": "x"]], schema: schema)
        }
        #expect(throws: DynamicQueryError.self) {
            _ = try DynamicQuery.whereSQL(["age": ["$regex": ".*"]], schema: schema)
        }

        // Security: an injection attempt in a VALUE is escaped to a literal — it
        // can't alter query structure, so it simply matches nothing.
        #expect(try run(["name": "Alice' OR '1'='1"]).isEmpty)
    }

    @Test func testDynamicSerialization() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dyns_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let dog = DynDog(); dog.name = "Rex"; dog.breed = "Husky"
            lattice.add(dog)
            let p = DynPerson(); p.name = "Alice"; p.age = 34; p.score = 9.5
            p.nicknames = ["Al", "Ali"]
            lattice.add(p)
            p.dog = dog
            lattice.checkpoint()
            lattice.close()
        }

        let dyn = try Lattice.dynamic(fileURL: url)
        let row = try #require(dyn.dynamicObjects("DynPerson").first)

        // Depth 2: scalars native, embedded array inlined, link traversed.
        let json = row.jsonObject(maxDepth: 2)
        #expect(json["name"] as? String == "Alice")
        #expect(json["age"] as? Int64 == 34)
        #expect(json["score"] as? Double == 9.5)
        #expect(json["globalId"] != nil)
        #expect((json["nicknames"] as? [Any])?.count == 2)
        let dogJSON = try #require(json["dog"] as? [String: Any])
        #expect(dogJSON["name"] as? String == "Rex")
        // Valid JSON (round-trips through JSONSerialization).
        #expect((try? JSONSerialization.data(withJSONObject: json)) != nil)

        // Depth 0: link collapses to {globalId} (no recursion).
        let shallow = row.jsonObject(maxDepth: 0)
        let dogShallow = try #require(shallow["dog"] as? [String: Any])
        #expect(dogShallow["globalId"] != nil)
        #expect(dogShallow["name"] == nil)
    }
}
