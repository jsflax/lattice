import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice

@Suite("Dynamic query hardening")
struct DynamicQueryHardeningTests {
    private var schema: [PropertyInfo] {
        ["value", "select", "quoted\"name", "value OR 1"].map {
            PropertyInfo(name: $0, kind: .primitive, columnType: .text)
        }
    }

    private func predicate(_ json: String) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(decoded as? [String: Any])
    }

    /// Execute the public translator's output against a private in-memory SQLite
    /// table, so identifier tests pin query behavior rather than quote spelling.
    private func matchingRows(_ predicate: [String: Any]) throws -> Int32 {
        let clause = try DynamicQuery.whereSQL(predicate, schema: schema)
        var pointer: OpaquePointer?
        let opened = sqlite3_open(":memory:", &pointer)
        defer { if let pointer { sqlite3_close(pointer) } }
        try #require(opened == SQLITE_OK)
        let db = try #require(pointer)
        let fixture = #"""
            CREATE TABLE fixture (
                id INTEGER, globalId TEXT, value TEXT, "select" TEXT,
                "quoted""name" TEXT, "value OR 1" TEXT
            );
            INSERT INTO fixture VALUES (1, 'first', 'match', 'match', 'match', 'match');
            INSERT INTO fixture VALUES (2, 'second', 'other', 'other', 'other', 'other');
            """#
        let created = sqlite3_exec(db, fixture, nil, nil, nil)
        try #require(created == SQLITE_OK)
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        let prepared = sqlite3_prepare_v2(db, "SELECT count(*) FROM fixture WHERE \(clause)", -1, &statement, nil)
        try #require(prepared == SQLITE_OK, "Generated predicate must be valid SQLite: \(clause)")
        let stepped = sqlite3_step(statement)
        try #require(stepped == SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }

    @Test(arguments: ["select", "quoted\"name", "value OR 1"])
    func approvedIdentifiersKeepTheirColumnMeaning(column: String) throws {
        let count = try matchingRows([column: "match"])
        #expect(count == 1)
    }

    @Test func emptyDisjunctionMatchesNothingWhileEmptyConjunctionMatchesEverything() throws {
        let disjunction = try matchingRows(["$or": []])
        let conjunction = try matchingRows(["$and": []])
        let negatedDisjunction = try matchingRows(["$not": ["$or": []]])
        #expect(disjunction == 0)
        #expect(conjunction == 2)
        #expect(negatedDisjunction == 2)
    }

    @Test(arguments: [#"{"value": []}"#, #"{"value": [1, 2]}"#, #"{"value": {}}"#])
    func bareArraysAndEmptyOperatorObjectsAreRejected(json: String) throws {
        let input = try predicate(json)
        #expect(throws: DynamicQueryError.self) {
            _ = try DynamicQuery.whereSQL(input, schema: schema)
        }
    }

    @Test(arguments: ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$contains", "$hasPrefix", "$hasSuffix"],
          ["[]", #"{"nested": 1}"#])
    func scalarOperatorsRejectContainers(operation: String, operand: String) throws {
        let input = try predicate("{\"value\": {\"\(operation)\": \(operand)}}")
        #expect(throws: DynamicQueryError.self) {
            _ = try DynamicQuery.whereSQL(input, schema: schema)
        }
    }

    @Test(arguments: [
        #"{"value": {"$in": ["match", []]}}"#,
        #"{"value": {"$in": [{"nested": 1}]}}"#,
        #"{"value": {"$between": [[], "z"]}}"#,
        #"{"value": {"$between": ["a", {"nested": 1}]}}"#
    ])
    func collectionOperatorsRejectContainerElements(json: String) throws {
        let input = try predicate(json)
        #expect(throws: DynamicQueryError.self) {
            _ = try DynamicQuery.whereSQL(input, schema: schema)
        }
    }

    @Test(arguments: ["null", "true", "false", "42", "42.5", #""match""#])
    func jsonScalarsRemainAccepted(scalar: String) throws {
        let input = try predicate("{\"value\": \(scalar)}")
        let count = try matchingRows(input)
        #expect(count == (scalar == #""match""# ? 1 : 0))
    }

    @Test func scalarCollectionsAndImplicitIdentityColumnsRemainAccepted() throws {
        let included = try matchingRows(["id": ["$in": [1, 2]]])
        let bounded = try matchingRows(["id": ["$between": [1, 1]]])
        let empty = try matchingRows(["id": ["$in": []]])
        let identity = try matchingRows(["globalId": "first"])
        #expect(included == 2)
        #expect(bounded == 1)
        #expect(empty == 0)
        #expect(identity == 1)
    }

    @Test func identifiersStillRequireSchemaAdmission() {
        #expect(throws: DynamicQueryError.unknownProperty("value) OR 1=1 --")) {
            _ = try DynamicQuery.whereSQL(["value) OR 1=1 --": "match"], schema: schema)
        }
    }
}
