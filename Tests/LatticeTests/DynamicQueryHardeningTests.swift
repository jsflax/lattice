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

    /// Execute the public translator's output against an isolated in-memory SQLite
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
            INSERT INTO fixture VALUES (1, 'first', 'match', 'other', 'other', 'other');
            INSERT INTO fixture VALUES (2, 'second', 'other', 'match', 'other', 'other');
            INSERT INTO fixture VALUES (3, 'third', 'other', 'other', 'match', 'other');
            INSERT INTO fixture VALUES (4, 'fourth', 'other', 'other', 'other', 'match');
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
        let expectedID = try #require(["select": 2, "quoted\"name": 3, "value OR 1": 4][column])
        let count = try matchingRows(["$and": [[column: "match"], ["id": expectedID]]])
        #expect(count == 1)
    }

    @Test func emptyDisjunctionMatchesNothingWhileEmptyConjunctionMatchesEverything() throws {
        let disjunction = try matchingRows(["$or": []])
        let conjunction = try matchingRows(["$and": []])
        let negatedDisjunction = try matchingRows(["$not": ["$or": []]])
        #expect(disjunction == 0)
        #expect(conjunction == 4)
        #expect(negatedDisjunction == 4)
    }

    @Test(arguments: [#"{"value": []}"#, #"{"value": [1, 2]}"#, #"{"value": {}}"#])
    func bareArraysAndEmptyOperatorObjectsAreRejected(json: String) throws {
        let input = try predicate(json)
        let message = json.contains("{}")
            ? "field \"value\": operator object cannot be empty"
            : "field \"value\": $eq operands must be scalar JSON values"
        #expect(throws: DynamicQueryError.malformed(message)) {
            _ = try DynamicQuery.whereSQL(input, schema: schema)
        }
    }

    @Test(arguments: ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$contains", "$hasPrefix", "$hasSuffix"],
          ["[]", #"{"nested": 1}"#])
    func scalarOperatorsRejectContainers(operation: String, operand: String) throws {
        let input = try predicate("{\"value\": {\"\(operation)\": \(operand)}}")
        #expect(throws: DynamicQueryError.malformed("field \"value\": \(operation) operands must be scalar JSON values")) {
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
        let operation = json.contains("$in") ? "$in" : "$between"
        #expect(throws: DynamicQueryError.malformed("field \"value\": \(operation) operands must be scalar JSON values")) {
            _ = try DynamicQuery.whereSQL(input, schema: schema)
        }
    }

    @Test func unknownOperatorWithContainerStillReportsUnsupportedOperator() {
        #expect(throws: DynamicQueryError.unsupportedOperator("$nin")) {
            _ = try DynamicQuery.whereSQL(["value": ["$nin": ["match"]]], schema: schema)
        }
    }

    @Test(arguments: [PropertyKind.link, .list, .virtualLink, .virtualList, .unionType])
    func nonPrimitivePropertiesAreNotColumnPredicates(kind: PropertyKind) {
        let properties = [PropertyInfo(name: "relation", kind: kind, columnType: .text)]
        #expect(throws: DynamicQueryError.unknownProperty("relation")) {
            _ = try DynamicQuery.whereSQL(["relation": "match"], schema: properties)
        }
    }

    @Test func primitiveGeoBoundsAreNotColumnPredicates() {
        let properties = [PropertyInfo(name: "location", kind: .primitive, columnType: .integer, isGeoBounds: true)]
        #expect(throws: DynamicQueryError.unknownProperty("location")) {
            _ = try DynamicQuery.whereSQL(["location": 0], schema: properties)
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
