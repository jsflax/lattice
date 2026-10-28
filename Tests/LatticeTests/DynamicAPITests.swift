import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice

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
    private static func fixtureURL(_ prefix: String) throws -> URL {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["LATTICE_TMPDIR"] {
            try #require(path.hasPrefix("/"), "LATTICE_TMPDIR must be absolute")
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = testTemporaryDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(prefix)_\(UUID().uuidString).sqlite")
    }

    /// Test-only main-file oracle: immutable deliberately ignores the WAL.
    /// The production dynamic reader must not use this mode.
    private static func immutableDogCount(_ url: URL) throws -> Int64 {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.absoluteString + "?immutable=1", &pointer,
                                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        try #require(result == SQLITE_OK)
        let db = try #require(pointer)
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        try #require(sqlite3_prepare_v2(db, "SELECT count(*) FROM DynDog", -1, &statement, nil) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    @Test(arguments: ["missing", "directory", "corrupt"])
    func testDynamicOpenFailureIsCatchableAndSamePathRecovers(kind: String) throws {
        let url = try Self.fixtureURL("dyn_failure")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let corrupt = Data("SQLite format 3\0".utf8) + Data(repeating: 0, count: 496)
        switch kind {
        case "missing": break
        case "directory":
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case "corrupt": try corrupt.write(to: url)
        default: throw Lattice.Error.databaseError("unknown dynamic-open fixture")
        }

        var failure: (any Error)?
        do {
            let unexpected = try Lattice.dynamic(fileURL: url)
            unexpected.close()
        } catch { failure = error }
        let error = try #require(failure)
        let databaseError = try #require(error as? Lattice.Error)
        switch databaseError {
        case .databaseError(let message):
            #expect(!message.isEmpty, "the checked factory must preserve the native failure message")
            #expect(String(describing: error).contains(message), "callers must see the native message")
        }
        switch kind {
        case "missing": #expect(!FileManager.default.fileExists(atPath: url.path))
        case "directory":
            #expect(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
            try FileManager.default.removeItem(at: url)
        case "corrupt":
            #expect(try Data(contentsOf: url) == corrupt)
            try FileManager.default.removeItem(at: url)
        default: break
        }

        // A failed open must not poison the path cache or the next error result.
        let writer = try Lattice(DynDog.self, configuration: .init(fileURL: url))
        defer { writer.close() }
        let dog = DynDog(); dog.name = "Recovered"
        try writer.add(dog)
        let reader = try Lattice.dynamic(fileURL: url)
        defer { reader.close() }
        #expect(reader.configuration.isReadOnly)
        #expect(reader.dynamicObjects("DynDog").first?.name as? String == "Recovered")
    }

    @Test func testDynamicReadersRemainIndependentAndSeeUncheckpointedWAL() throws {
        let url = try Self.fixtureURL("dyn_wal")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        let writer = try Lattice(DynDog.self, configuration: .init(fileURL: url))
        defer { writer.close() }
        writer.checkpoint()
        #expect(try Self.immutableDogCount(url) == 0)
        let firstDog = DynDog(); firstDog.name = "First WAL row"
        try writer.add(firstDog)
        try #require(try Self.immutableDogCount(url) == 0, "fixture row must still live only in the WAL")

        let first = try Lattice.dynamic(fileURL: url)
        defer { first.close() }
        let second = try Lattice.dynamic(fileURL: url)
        defer { second.close() }
        #expect(first.backend.identityHash != writer.backend.identityHash)
        #expect(second.backend.identityHash != writer.backend.identityHash)
        #expect(first.backend.identityHash != second.backend.identityHash)
        #expect(first.isolation == nil && second.isolation == nil)
        #expect(first.configuration.isReadOnly && second.configuration.isReadOnly)
        #expect(first.dynamicObjects("DynDog").count == 1)
        #expect(second.dynamicObjects("DynDog").first?.name as? String == "First WAL row")

        first.close()
        let secondDog = DynDog(); secondDog.name = "Second WAL row"
        try writer.add(secondDog)
        #expect(second.dynamicObjects("DynDog").count == 2,
                "closing one dynamic connection must not close its sibling or the writer")
    }

    @Test func testDynamicOpenRoundTrip() async throws {
        let url = try Self.fixtureURL("dyn")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        // 1. Write with typed models, then checkpoint + close before reopening.
        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let dog = DynDog(); dog.name = "Rex"; dog.breed = "Husky"
            try lattice.add(dog)
            let p = DynPerson(); p.name = "Alice"; p.age = 34; p.score = 9.5
            p.nicknames = ["Al", "Ali"]
            try lattice.add(p)
            p.dog = dog
            lattice.checkpoint()
            lattice.close()
        }

        // 2. Reopen dynamically — NO compile-time @Model types.
        let dyn = try Lattice.dynamic(fileURL: url)
        defer { dyn.close() }

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
        let url = try Self.fixtureURL("dynq")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let alice = DynPerson(); alice.name = "Alice"; alice.age = 34
            let bob = DynPerson(); bob.name = "Bob"; bob.age = 20
            try lattice.add(alice); try lattice.add(bob)
            lattice.checkpoint()
            lattice.close()
        }

        let dyn = try Lattice.dynamic(fileURL: url)
        defer { dyn.close() }
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
        let url = try Self.fixtureURL("dyns")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let dog = DynDog(); dog.name = "Rex"; dog.breed = "Husky"
            try lattice.add(dog)
            let p = DynPerson(); p.name = "Alice"; p.age = 34; p.score = 9.5
            p.nicknames = ["Al", "Ali"]
            try lattice.add(p)
            p.dog = dog
            lattice.checkpoint()
            lattice.close()
        }

        let dyn = try Lattice.dynamic(fileURL: url)
        defer { dyn.close() }
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

    // Regression: a NIL to-one link must not crash. Previously
    // dynamic_object::get_object dereferenced a null managed<T*> (get_value()
    // == nullptr) via m->table_name(), segfaulting whenever an object with an
    // unset link was serialized at depth > 0.
    @Test func testDynamicNilLinkSerialization() async throws {
        let url = try Self.fixtureURL("dynnil")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self,
                                      configuration: .init(fileURL: url))
            let p = DynPerson(); p.name = "Loner"; p.age = 50  // no dog
            try lattice.add(p)
            lattice.checkpoint()
            lattice.close()
        }

        let dyn = try Lattice.dynamic(fileURL: url)
        defer { dyn.close() }
        let row = try #require(dyn.dynamicObjects("DynPerson").first)

        // Accessing the nil link returns nil rather than crashing.
        #expect(row.dog as? DynamicObject == nil)

        // Serializing with link traversal must not crash; the nil link is
        // simply omitted (no `dog` key).
        let json = row.jsonObject(maxDepth: 2)
        #expect(json["name"] as? String == "Loner")
        #expect(json["dog"] == nil)
        #expect((try? JSONSerialization.data(withJSONObject: json)) != nil)
    }
}
