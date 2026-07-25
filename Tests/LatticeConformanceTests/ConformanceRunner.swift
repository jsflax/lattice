import Foundation
import Lattice

// MARK: - Table adapters
//
// One `Adapter<M>` per compiled catalog shape, type-erased behind
// `TableAdapter` so the interpreter can dispatch by the corpus's table
// names while every Lattice call happens through the typed public API.

struct SnapshotSpec {
    var whereJV: JV?
    var sort: JV?
    var limit: Int64?
    var offset: Int64?
    var distinctBy: String?
    var columns: [String]
}

protocol TableAdapter: Sendable {
    var table: String { get }
    var version: Int { get }
    var properties: Set<String> { get }
    var modelType: any Model.Type { get }
    /// Present on version-2 adapters: folds this table's from→to pair (and
    /// interpreted transform steps) into the reopen Migration.
    var migrationFrom: ((Migration, JV?) throws -> Migration)? { get }

    func insert(_ lattice: Lattice, values: [String: JV], env: ScenarioEnv) throws -> any Model
    func get(_ lattice: Lattice, id: Int64) -> (any Model)?
    func delete(_ lattice: Lattice, _ obj: any Model) throws
    func deleteWhere(_ lattice: Lattice, whereJV: JV?) throws
    func count(_ lattice: Lattice, whereJV: JV?) throws -> Int
    func rows(_ lattice: Lattice, _ spec: SnapshotSpec) throws -> [JV]
    func fts(_ lattice: Lattice, column: String, match: String, limit: Int,
             whereJV: JV?, columns: [String]) throws -> [JV]
    func knn(_ lattice: Lattice, column: String, query: [Float], k: Int,
             metric: DistanceMetric, whereJV: JV?, columns: [String]) throws -> (rows: [JV], distances: [Double])
    func geoWithin(_ lattice: Lattice, column: String,
                   minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                   whereJV: JV?, columns: [String]) throws -> [JV]
    func setValues(_ obj: any Model, values: [String: JV], env: ScenarioEnv) throws
    func readField(_ obj: any Model, path: String, env: ScenarioEnv) throws -> JV
    func listAppend(_ obj: any Model, property: String, item: any Model) throws
    func listRemoveAt(_ obj: any Model, property: String, index: Int) throws
    func listSize(_ obj: any Model, property: String) throws -> Int
    func listElements(_ obj: any Model, property: String) throws -> [any Model]
}

// @unchecked Sendable: stateless beyond immutable configuration closures.
struct Adapter<M: ConfModel>: TableAdapter, @unchecked Sendable {
    let version: Int
    let migrationFrom: ((Migration, JV?) throws -> Migration)?

    init(_ type: M.Type, version: Int = 1,
         migrationFrom: ((Migration, JV?) throws -> Migration)? = nil) {
        self.version = version
        self.migrationFrom = migrationFrom
    }

    var table: String { M.entityName }
    var properties: Set<String> { Set(M.confFields.keys) }
    var modelType: any Model.Type { M.self }

    private func field(_ name: String) throws -> FieldSpec<M> {
        guard let f = M.confFields[name] else {
            throw ConformanceError.corpus("unknown property \(table).\(name)")
        }
        return f
    }

    private func typed(_ obj: any Model) throws -> M {
        guard let m = obj as? M else {
            throw ConformanceError.corpus("handle is a \(type(of: obj)), expected \(table)")
        }
        return m
    }

    // Where-DSL → typed Query<Bool>
    private func buildWhere(_ jv: JV) throws -> Query<Bool> {
        let q = Query<M>()
        return try buildWhere(jv, q: q)
    }

    private func buildWhere(_ jv: JV, q: Query<M>) throws -> Query<Bool> {
        if let all = jv["all"] {
            let parts = try all.requireArray().map { try buildWhere($0, q: q) }
            guard var acc = parts.first else { throw ConformanceError.corpus("empty all") }
            for p in parts.dropFirst() { acc = acc && p }
            return acc
        }
        if let any = jv["any"] {
            let parts = try any.requireArray().map { try buildWhere($0, q: q) }
            guard var acc = parts.first else { throw ConformanceError.corpus("empty any") }
            for p in parts.dropFirst() { acc = acc || p }
            return acc
        }
        if let not = jv["not"] {
            return !(try buildWhere(not, q: q))
        }
        guard case .string(let name)? = jv["field"], case .string(let op)? = jv["op"] else {
            throw ConformanceError.corpus("malformed where leaf: \(jv)")
        }
        guard let predicate = try field(name).predicate else {
            throw ConformanceError.corpus("property \(table).\(name) is not queryable")
        }
        return try predicate(q, op, jv["value"] ?? .null)
    }

    private func base(_ lattice: Lattice, whereJV: JV?) throws -> TableResults<M> {
        var r = lattice.objects(M.self)
        if let whereJV {
            let built = try buildWhere(whereJV)
            r = r.where { _ in built }
        }
        return r
    }

    private func extract(_ objects: [M], columns: [String]) throws -> [JV] {
        try objects.map { obj in
            .array(try columns.map { col in
                guard let get = try field(col).get else {
                    throw ConformanceError.corpus("property \(table).\(col) is not readable")
                }
                return get(obj)
            })
        }
    }

    // MARK: TableAdapter

    func insert(_ lattice: Lattice, values: [String: JV], env: ScenarioEnv) throws -> any Model {
        let obj = M(isolation: nil)
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let set = try field(name).set else {
                throw ConformanceError.corpus("property \(table).\(name) is not settable at insert")
            }
            try set(obj, value, env)
        }
        try lattice.add(obj)
        return obj
    }

    func get(_ lattice: Lattice, id: Int64) -> (any Model)? {
        lattice.object(M.self, primaryKey: id)
    }

    func delete(_ lattice: Lattice, _ obj: any Model) throws {
        lattice.delete(try typed(obj))
    }

    func deleteWhere(_ lattice: Lattice, whereJV: JV?) throws {
        if let whereJV {
            let built = try buildWhere(whereJV)
            lattice.delete(M.self, where: { _ in built })
        } else {
            lattice.delete(M.self)
        }
    }

    func count(_ lattice: Lattice, whereJV: JV?) throws -> Int {
        // Maps to the SDK's dedicated count API (`Lattice.count`) — the
        // closest semantic match for the corpus `count` op. (Historical
        // note: this mapping once mattered for transaction scenarios; since
        // the §4.1 in-txn writer-connection carve-out was extended to file
        // stores, `objects().count` observes a transaction's own
        // uncommitted writes too.)
        if let whereJV {
            let built = try buildWhere(whereJV)
            return lattice.count(M.self, where: { _ in built })
        }
        return lattice.count(M.self)
    }

    func rows(_ lattice: Lattice, _ spec: SnapshotSpec) throws -> [JV] {
        var r = try base(lattice, whereJV: spec.whereJV)
        if let sort = spec.sort {
            let by = try (sort["by"] ?? .null).requireString()
            let ascending: Bool
            if case .string(let o)? = sort["order"] { ascending = (o != "desc") } else { ascending = true }
            guard let s = try field(by).sort else {
                throw ConformanceError.corpus("property \(table).\(by) is not sortable")
            }
            r = s(r, ascending)
        }
        if let d = spec.distinctBy {
            guard let dist = try field(d).distinct else {
                throw ConformanceError.corpus("property \(table).\(d) does not support distinct")
            }
            r = dist(r)
        }
        let objects = r.snapshot(limit: spec.limit, offset: spec.offset)
        return try extract(objects, columns: spec.columns)
    }

    func fts(_ lattice: Lattice, column: String, match: String, limit: Int,
             whereJV: JV?, columns: [String]) throws -> [JV] {
        guard let kp = try field(column).ftsKeyPath else {
            throw ConformanceError.corpus("property \(table).\(column) is not a text column")
        }
        let r = try base(lattice, whereJV: whereJV)
        let matches = r.matching(.raw(match), on: kp, limit: limit).snapshot(limit: nil, offset: nil)
        return try extract(matches.map(\.object), columns: columns)
    }

    func knn(_ lattice: Lattice, column: String, query: [Float], k: Int,
             metric: DistanceMetric, whereJV: JV?, columns: [String]) throws -> (rows: [JV], distances: [Double]) {
        guard let kp = try field(column).vectorKeyPath else {
            throw ConformanceError.corpus("property \(table).\(column) is not a vector column")
        }
        let r = try base(lattice, whereJV: whereJV)
        let matches = r.nearest(to: FloatVector(query), on: kp, limit: k, distance: metric)
            .snapshot(limit: nil, offset: nil)
        return (try extract(matches.map(\.object), columns: columns),
                matches.map(\.distance))
    }

    func geoWithin(_ lattice: Lattice, column: String,
                   minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                   whereJV: JV?, columns: [String]) throws -> [JV] {
        guard let geo = try field(column).geoWithin else {
            throw ConformanceError.corpus("property \(table).\(column) is not a geo column")
        }
        let r = geo(try base(lattice, whereJV: whereJV), minLat, maxLat, minLon, maxLon)
        return try extract(r.snapshot(limit: nil, offset: nil), columns: columns)
    }

    func setValues(_ obj: any Model, values: [String: JV], env: ScenarioEnv) throws {
        let m = try typed(obj)
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let set = try field(name).set else {
                throw ConformanceError.corpus("property \(table).\(name) is not settable")
            }
            try set(m, value, env)
        }
    }

    func readField(_ obj: any Model, path: String, env: ScenarioEnv) throws -> JV {
        let m = try typed(obj)
        guard let dot = path.firstIndex(of: ".") else {
            guard let get = try field(path).get else {
                throw ConformanceError.corpus("property \(table).\(path) is not readable")
            }
            return get(m)
        }
        let head = String(path[..<dot])
        let rest = String(path[path.index(after: dot)...])
        guard let traverse = try field(head).traverse else {
            throw ConformanceError.corpus("property \(table).\(head) is not traversable")
        }
        guard let target = traverse(m) else { return .null }
        let targetTable = type(of: target).entityName
        guard let adapter = env.adapters[targetTable] else {
            throw ConformanceError.corpus("no adapter for traversal target \(targetTable)")
        }
        return try adapter.readField(target, path: rest, env: env)
    }

    func listAppend(_ obj: any Model, property: String, item: any Model) throws {
        guard let append = try field(property).listAppend else {
            throw ConformanceError.corpus("property \(table).\(property) is not a list")
        }
        try append(try typed(obj), item)
    }

    func listRemoveAt(_ obj: any Model, property: String, index: Int) throws {
        guard let remove = try field(property).listRemoveAt else {
            throw ConformanceError.corpus("property \(table).\(property) is not a list")
        }
        remove(try typed(obj), index)
    }

    func listSize(_ obj: any Model, property: String) throws -> Int {
        guard let size = try field(property).listSize else {
            throw ConformanceError.corpus("property \(table).\(property) is not a list")
        }
        return size(try typed(obj))
    }

    func listElements(_ obj: any Model, property: String) throws -> [any Model] {
        guard let elements = try field(property).listElements else {
            throw ConformanceError.corpus("property \(table).\(property) is not a list")
        }
        return elements(try typed(obj))
    }
}

// MARK: - Migration pair plumbing

/// Interpreted transform steps (parsed up-front so the non-throwing
/// migration block cannot hit corpus errors at row time).
private enum TransformStep {
    case const(String, JV)
    case copy(String, String)
    case parseInt(String, String)

    static func parse(_ jv: JV?) throws -> [TransformStep] {
        guard let jv else { return [] }
        return try jv.requireArray().map { step in
            let target = try (step["set"] ?? .null).requireString()
            if let c = step["const"] { return .const(target, c) }
            if let f = step["from"] { return .copy(target, try f.requireString()) }
            if let p = step["parse_int_from"] { return .parseInt(target, try p.requireString()) }
            throw ConformanceError.corpus("unknown transform step: \(step)")
        }
    }
}

/// Builds the `(Migration, transforms) -> Migration` closure for one
/// from→to model pair. Registered on the version-2 adapter of each
/// migration table.
func migrationPair<From: ConfModel, To: ConfModel>(
    _ from: From.Type, _ to: To.Type
) -> (Migration, JV?) throws -> Migration {
    { migration, transformsJV in
        let steps = try TransformStep.parse(transformsJV)
        return migration.add(from: From.self, to: To.self) { old, new in
            for step in steps {
                switch step {
                case .const(let target, let value):
                    try? To.confFields[target]?.set?(new, value, nil)
                case .copy(let target, let source):
                    if let value = From.confFields[source]?.get?(old) {
                        try? To.confFields[target]?.set?(new, value, nil)
                    }
                case .parseInt(let target, let source):
                    let raw = From.confFields[source]?.get?(old)
                    var parsed: Int64 = 0
                    if case .string(let s)? = raw { parsed = Int64(s) ?? 0 }
                    try? To.confFields[target]?.set?(new, .int(parsed), nil)
                }
            }
        }
    }
}

// MARK: - The adapter registry

enum ConformanceRegistry {
    /// Every compiled catalog shape this runner knows. Scenario schemas
    /// resolve against this list by (table name, schema version, exact
    /// property-name set) — any mismatch is a hard corpus/catalog error.
    static let all: [any TableAdapter] = {
        var list: [any TableAdapter] = [
            Adapter(CfPerson.self),
            Adapter(CfPet.self),
            Adapter(CfOwner.self),
            Adapter(CfCard.self),
            Adapter(CfArticle.self),
            Adapter(CfDoc.self),
            Adapter(CfCounter.self),
            Adapter(CfNoteA.self),
            Adapter(CfNoteB.self),
            Adapter(CfBinder.self),
            Adapter(ConfV1.CfWidget.self),
            Adapter(ConfV1.CfMigPerson.self),
            Adapter(ConfV1.CfBlobDoc.self),
            Adapter(CfWidget.self, version: 2,
                    migrationFrom: migrationPair(ConfV1.CfWidget.self, CfWidget.self)),
            Adapter(CfMigPerson.self, version: 2,
                    migrationFrom: migrationPair(ConfV1.CfMigPerson.self, CfMigPerson.self)),
            Adapter(CfBlobDoc.self, version: 2,
                    migrationFrom: migrationPair(ConfV1.CfBlobDoc.self, CfBlobDoc.self)),
            Adapter(ConfV2T.CfBlobDoc.self, version: 2,
                    migrationFrom: migrationPair(ConfV1.CfBlobDoc.self, ConfV2T.CfBlobDoc.self)),
        ]
        #if canImport(MapKit)
        list.append(Adapter(CfPlace.self))
        #endif
        return list
    }()

    /// The capabilities this runner declares. Core areas are implicit.
    static var capabilities: Set<String> {
        var caps: Set<String> = ["virtual", "migration-row-transform", "row-cache", "increment"]
        #if canImport(MapKit)
        caps.insert("geo")
        #endif
        return caps
    }

    static func resolve(table: String, version: Int, properties: Set<String>) throws -> any TableAdapter {
        let candidates = all.filter { $0.table == table }
        guard !candidates.isEmpty else {
            throw ConformanceError.corpus("no compiled model for table \(table)")
        }
        guard let match = candidates.first(where: { $0.properties == properties && $0.version == version }) else {
            let shapes = candidates.map { "v\($0.version)\($0.properties.sorted())" }
            throw ConformanceError.corpus(
                "schema mismatch for \(table)@v\(version): corpus declares \(properties.sorted()), compiled shapes: \(shapes)")
        }
        return match
    }
}

// MARK: - Scenario environment

final class ScenarioEnv {
    var lattice: Lattice?
    var handles: [String: any Model] = [:]
    var vars: [String: JV] = [:]
    var adapters: [String: any TableAdapter] = [:]
    let dbURL: URL

    init(dbURL: URL) {
        self.dbURL = dbURL
    }

    func requireLattice() throws -> Lattice {
        guard let lattice else { throw ConformanceError.corpus("database is closed") }
        return lattice
    }

    func requireAdapter(_ table: String) throws -> any TableAdapter {
        guard let a = adapters[table] else {
            throw ConformanceError.corpus("table \(table) is not in this scenario's schema")
        }
        return a
    }

    func requireHandle(_ ref: String) throws -> any Model {
        guard let h = handles[ref] else { throw ConformanceError.corpus("unknown handle \(ref)") }
        return h
    }

    func adapterFor(_ obj: any Model) throws -> any TableAdapter {
        try requireAdapter(type(of: obj).entityName)
    }
}

// MARK: - Error canonicalization

func canonicalErrorID(_ error: any Error) -> String {
    if let e = error as? LatticeError {
        switch e {
        case .alreadyManaged: return "already_managed"
        case .addFailed: return "add_failed"
        case .transactionError: return "transaction_error"
        case .attachFailed, .detachFailed: return "attach_failed"
        case .syncReceiveFailed, .missingLatticeContext: return "sdk_error"
        }
    }
    let message = String(describing: error).lowercased()
    if message.contains("blob") { return "migration_blob_unsupported" }
    if message.contains("unique") || message.contains("constraint") { return "add_failed" }
    return "sdk_error"
}

// MARK: - The interpreter

struct ScenarioResult {
    var name: String
    var status: Status
    enum Status: Equatable {
        case passed
        case skipped(missing: [String])
        case failed(String)
    }
}

struct ConformanceInterpreter {

    func run(scenario: JV, suite: String) -> ScenarioResult {
        let name = (try? (scenario["name"] ?? .null).requireString()) ?? "<unnamed>"

        // Capability gate: SKIP (visibly) when the runner lacks a declared
        // capability; never silently pass.
        if let caps = scenario["capabilities"] {
            let required = (try? caps.requireArray().map { try $0.requireString() }) ?? []
            let missing = required.filter { !ConformanceRegistry.capabilities.contains($0) }
            if !missing.isEmpty {
                return ScenarioResult(name: name, status: .skipped(missing: missing))
            }
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice_conformance_\(suite)_\(name)_\(UUID().uuidString).sqlite")
        let env = ScenarioEnv(dbURL: dbURL)
        defer {
            env.handles.removeAll()
            env.lattice?.close()
            env.lattice = nil
            try? Lattice.delete(for: .init(fileURL: dbURL))
        }

        do {
            try open(env: env, schemaJV: scenario["schema"] ?? .null, migration: nil)
            let ops = try (scenario["ops"] ?? .array([])).requireArray()
            try runOps(ops, env: env, insideTransaction: false)
            let expects = try (scenario["expect"] ?? .array([])).requireArray()
            for (index, expect) in expects.enumerated() {
                try evaluate(expect: expect, env: env, label: "expect[\(index)]")
            }
            return ScenarioResult(name: name, status: .passed)
        } catch {
            return ScenarioResult(name: name, status: .failed(String(describing: error)))
        }
    }

    // MARK: open / reopen

    private func open(env: ScenarioEnv, schemaJV: JV, migration: [Int: Migration]?) throws {
        let version = Int((try? (schemaJV["version"] ?? .int(1)).requireInt()) ?? 1)
        let tables = try (schemaJV["tables"] ?? .null).requireObject()
        var adapters: [String: any TableAdapter] = [:]
        var types: [any Model.Type] = []
        for (table, decl) in tables.sorted(by: { $0.key < $1.key }) {
            let props = try (decl["properties"] ?? .null).requireObject()
            let adapter = try ConformanceRegistry.resolve(
                table: table, version: version, properties: Set(props.keys))
            adapters[table] = adapter
            types.append(adapter.modelType)
        }
        env.adapters = adapters
        env.lattice = try Lattice(for: types,
                                  configuration: .init(fileURL: env.dbURL, migration: migration))
    }

    private func reopen(env: ScenarioEnv, op: JV) throws {
        guard env.lattice == nil else {
            throw ConformanceError.corpus("reopen requires a close op first")
        }
        let schemaJV = op["schema"] ?? .null
        let version = Int((try? (schemaJV["version"] ?? .int(1)).requireInt()) ?? 1)

        var migrationDict: [Int: Migration]? = nil
        // A versioned reopen always carries the from→to schema pairs so the
        // core can auto-add columns; corpus `migration.transforms` adds the
        // interpreted row-transform steps on top.
        if version > 1 {
            let transforms = op["migration"]?["transforms"]
            var migration = Migration()
            let tables = try (schemaJV["tables"] ?? .null).requireObject()
            for (table, decl) in tables.sorted(by: { $0.key < $1.key }) {
                let props = try (decl["properties"] ?? .null).requireObject()
                let adapter = try ConformanceRegistry.resolve(
                    table: table, version: version, properties: Set(props.keys))
                guard let fold = adapter.migrationFrom else {
                    throw ConformanceError.corpus("no migration pair compiled for \(table)@v\(version)")
                }
                migration = try fold(migration, transforms?[table])
            }
            migrationDict = [version: migration]
        }
        try open(env: env, schemaJV: schemaJV, migration: migrationDict)
    }

    // MARK: ops

    private func runOps(_ ops: [JV], env: ScenarioEnv, insideTransaction: Bool) throws {
        for op in ops {
            try runOp(op, env: env, insideTransaction: insideTransaction)
        }
    }

    private func runOp(_ op: JV, env: ScenarioEnv, insideTransaction: Bool) throws {
        let kind = try (op["op"] ?? .null).requireString()

        if let expected = op["expect_error"] {
            let expectedID = try expected.requireString()
            do {
                try execute(kind, op, env: env, insideTransaction: insideTransaction)
            } catch let e as ConformanceError {
                throw e // corpus/assertion problems are never "the expected error"
            } catch {
                let actual = canonicalErrorID(error)
                guard actual == expectedID else {
                    throw ConformanceError.failed(
                        "op \(kind): expected error \(expectedID), got \(actual) (\(error))")
                }
                return
            }
            throw ConformanceError.failed("op \(kind): expected error \(expectedID) but the op succeeded")
        }

        try execute(kind, op, env: env, insideTransaction: insideTransaction)
    }

    private func execute(_ kind: String, _ op: JV, env: ScenarioEnv, insideTransaction: Bool) throws {
        switch kind {
        case "insert":
            let table = try (op["table"] ?? .null).requireString()
            let values = try (op["values"] ?? .object([:])).requireObject()
            let obj = try env.requireAdapter(table)
                .insert(try env.requireLattice(), values: values, env: env)
            if case .string(let handle)? = op["as"] { env.handles[handle] = obj }
            if case .string(let idVar)? = op["save_id"] {
                guard let id = obj.primaryKey else {
                    throw ConformanceError.failed("insert into \(table) produced no primary key")
                }
                env.vars[idVar] = .int(id)
            }

        case "add_existing":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            try readdExisting(obj, lattice: env.requireLattice())

        case "get":
            let table = try (op["table"] ?? .null).requireString()
            let id: Int64
            if let idRef = op["id"]?["$id_of"] {
                let source = try env.requireHandle(try idRef.requireString())
                guard let pk = source.primaryKey else {
                    throw ConformanceError.corpus("handle has no primary key")
                }
                id = pk
            } else if let savedRef = op["id"]?["$saved_id"] {
                guard let saved = env.vars[try savedRef.requireString()] else {
                    throw ConformanceError.corpus("no saved id \(savedRef)")
                }
                id = try saved.requireInt()
            } else {
                throw ConformanceError.corpus("get.id must be {\"$id_of\": handle} or {\"$saved_id\": var}")
            }
            let found = try env.requireAdapter(table).get(try env.requireLattice(), id: id)
            if case .string(let handle)? = op["as"], let found { env.handles[handle] = found }
            if case .string(let flag)? = op["save_found"] { env.vars[flag] = .bool(found != nil) }

        case "update":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            let values = try (op["values"] ?? .object([:])).requireObject()
            try env.adapterFor(obj).setValues(obj, values: values, env: env)

        case "delete":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            try env.adapterFor(obj).delete(try env.requireLattice(), obj)

        case "delete_where":
            let table = try (op["table"] ?? .null).requireString()
            try env.requireAdapter(table).deleteWhere(try env.requireLattice(), whereJV: op["where"])

        case "count":
            let table = try (op["table"] ?? .null).requireString()
            let n = try env.requireAdapter(table).count(try env.requireLattice(), whereJV: op["where"])
            env.vars[try (op["save"] ?? .null).requireString()] = .int(Int64(n))

        case "snapshot":
            let table = try (op["table"] ?? .null).requireString()
            let rows = try env.requireAdapter(table).rows(try env.requireLattice(), snapshotSpec(op))
            env.vars[try (op["save"] ?? .null).requireString()] = .array(rows)

        case "read":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            let fields = try (op["fields"] ?? .null).requireArray().map { try $0.requireString() }
            let adapter = try env.adapterFor(obj)
            let values = try fields.map { try adapter.readField(obj, path: $0, env: env) }
            env.vars[try (op["save"] ?? .null).requireString()] = .array(values)

        case "fts":
            let table = try (op["table"] ?? .null).requireString()
            let rows = try env.requireAdapter(table).fts(
                try env.requireLattice(),
                column: try (op["column"] ?? .null).requireString(),
                match: try (op["match"] ?? .null).requireString(),
                limit: Int((try? (op["limit"] ?? .int(100)).requireInt()) ?? 100),
                whereJV: op["where"],
                columns: try (op["columns"] ?? .null).requireArray().map { try $0.requireString() })
            env.vars[try (op["save"] ?? .null).requireString()] = .array(rows)

        case "knn":
            let table = try (op["table"] ?? .null).requireString()
            let metricName = try (op["metric"] ?? .null).requireString()
            let metric: DistanceMetric
            switch metricName {
            case "l2": metric = .l2
            case "cosine": metric = .cosine
            default: throw ConformanceError.corpus("unknown metric \(metricName)")
            }
            let (rows, distances) = try env.requireAdapter(table).knn(
                try env.requireLattice(),
                column: try (op["column"] ?? .null).requireString(),
                query: try (op["query"] ?? .null).requireArray().map { Float(try $0.requireDouble()) },
                k: Int(try (op["k"] ?? .null).requireInt()),
                metric: metric,
                whereJV: op["where"],
                columns: try (op["columns"] ?? .null).requireArray().map { try $0.requireString() })
            env.vars[try (op["save"] ?? .null).requireString()] = .array(rows)
            if case .string(let dv)? = op["save_distances"] {
                env.vars[dv] = .array(distances.map { .double($0) })
            }

        case "geo_within":
            let table = try (op["table"] ?? .null).requireString()
            let rows = try env.requireAdapter(table).geoWithin(
                try env.requireLattice(),
                column: try (op["column"] ?? .null).requireString(),
                minLat: try (op["min_lat"] ?? .null).requireDouble(),
                maxLat: try (op["max_lat"] ?? .null).requireDouble(),
                minLon: try (op["min_lon"] ?? .null).requireDouble(),
                maxLon: try (op["max_lon"] ?? .null).requireDouble(),
                whereJV: op["where"],
                columns: try (op["columns"] ?? .null).requireArray().map { try $0.requireString() })
            env.vars[try (op["save"] ?? .null).requireString()] = .array(rows)

        case "list_append":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            guard let itemRef = op["item"]?["$ref"] else {
                throw ConformanceError.corpus("list_append.item must be {\"$ref\": handle}")
            }
            let item = try env.requireHandle(try itemRef.requireString())
            try env.adapterFor(obj).listAppend(
                obj, property: try (op["property"] ?? .null).requireString(), item: item)

        case "list_remove_at":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            try env.adapterFor(obj).listRemoveAt(
                obj, property: try (op["property"] ?? .null).requireString(),
                index: Int(try (op["index"] ?? .null).requireInt()))

        case "list_size":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            let n = try env.adapterFor(obj).listSize(
                obj, property: try (op["property"] ?? .null).requireString())
            env.vars[try (op["save"] ?? .null).requireString()] = .int(Int64(n))

        case "list_read":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            let property = try (op["property"] ?? .null).requireString()
            let fieldName = try (op["field"] ?? .null).requireString()
            let elements = try env.adapterFor(obj).listElements(obj, property: property)
            let values = try elements.map { element in
                try env.adapterFor(element).readField(element, path: fieldName, env: env)
            }
            env.vars[try (op["save"] ?? .null).requireString()] = .array(values)

        case "transaction":
            guard !insideTransaction else {
                throw ConformanceError.corpus("nested transaction ops are not in the corpus contract")
            }
            let nested = try (op["ops"] ?? .array([])).requireArray()
            do {
                try env.requireLattice().transaction {
                    try runOps(nested, env: env, insideTransaction: true)
                }
            } catch is ConformanceAbort {
                // Rolled back by the SDK; the scenario continues.
            }

        case "abort":
            guard insideTransaction else {
                throw ConformanceError.corpus("abort outside a transaction")
            }
            throw ConformanceAbort()

        case "materialize":
            // Corpus semantics: snapshot-now. Capture the current row image,
            // then serve reads from it.
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            obj.refreshMaterialized()
            _ = obj.materialize()

        case "dematerialize":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            obj.dematerialize()

        case "refresh":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            obj.refreshMaterialized()

        case "increment":
            let obj = try env.requireHandle(try (op["ref"] ?? .null).requireString())
            obj.increment(try (op["field"] ?? .null).requireString(),
                          by: try (op["by"] ?? .int(1)).requireInt())

        case "close":
            env.handles.removeAll()
            env.lattice?.close()
            env.lattice = nil

        case "reopen":
            do {
                try reopen(env: env, op: op)
                if case .string(let out)? = op["save_outcome"] { env.vars[out] = .string("ok") }
            } catch let e as ConformanceError {
                throw e
            } catch {
                guard case .string(let out)? = op["save_outcome"] else { throw error }
                env.vars[out] = .string(canonicalErrorID(error))
                env.lattice = nil
            }

        default:
            throw ConformanceError.corpus("unknown op \(kind)")
        }
    }

    /// `add_existing` needs the concrete type to call `lattice.add`; open the
    /// existential through the adapter-free generic hop.
    private func readdExisting(_ obj: any Model, lattice: Lattice) throws {
        func hop<T: Model>(_ typed: T) throws { try lattice.add(typed) }
        try hop(obj)
    }

    private func snapshotSpec(_ op: JV) throws -> SnapshotSpec {
        SnapshotSpec(
            whereJV: op["where"],
            sort: op["sort"],
            limit: op["limit"].map { Int64((try? $0.requireInt()) ?? 0) },
            offset: op["offset"].map { Int64((try? $0.requireInt()) ?? 0) },
            distinctBy: try op["distinct_by"].map { try $0.requireString() },
            columns: try (op["columns"] ?? .null).requireArray().map { try $0.requireString() })
    }

    // MARK: expects

    private func evaluate(expect: JV, env: ScenarioEnv, label: String) throws {
        if let branches = expect["one_of"] {
            let all = try branches.requireArray()
            var failures: [String] = []
            for (i, branch) in all.enumerated() {
                do {
                    for (j, entry) in (try branch.requireArray()).enumerated() {
                        try evaluate(expect: entry, env: env, label: "\(label).branch[\(i)][\(j)]")
                    }
                    return // a branch fully passed
                } catch {
                    failures.append("branch \(i): \(error)")
                }
            }
            throw ConformanceError.failed("\(label): no one_of branch passed — \(failures.joined(separator: " | "))")
        }

        if let varName = expect["var"] {
            let name = try varName.requireString()
            guard let actual = env.vars[name] else {
                throw ConformanceError.failed("\(label): no captured variable \(name)")
            }
            let expected = expect["equals"] ?? .null
            try compare(actual: actual, expected: expected,
                        unordered: expect["unordered"] == .bool(true), label: "\(label) var \(name)")
            return
        }

        if let countSpec = expect["count"] {
            let table = try (countSpec["table"] ?? .null).requireString()
            let n = try env.requireAdapter(table).count(try env.requireLattice(), whereJV: countSpec["where"])
            let expected = Int(try (countSpec["equals"] ?? .null).requireInt())
            guard n == expected else {
                throw ConformanceError.failed("\(label): count(\(table)) == \(n), expected \(expected)")
            }
            return
        }

        if let rowsSpec = expect["rows"] {
            let table = try (rowsSpec["table"] ?? .null).requireString()
            let spec = try snapshotSpec(rowsSpec)
            let actual = try env.requireAdapter(table).rows(try env.requireLattice(), spec)
            let expected = rowsSpec["equals"] ?? .array([])
            try compare(actual: .array(actual), expected: expected,
                        unordered: rowsSpec["unordered"] == .bool(true), label: "\(label) rows(\(table))")
            return
        }

        if let fieldSpec = expect["field"] {
            let obj = try env.requireHandle(try (fieldSpec["ref"] ?? .null).requireString())
            let path = try (fieldSpec["name"] ?? .null).requireString()
            let actual = try env.adapterFor(obj).readField(obj, path: path, env: env)
            try compare(actual: actual, expected: fieldSpec["equals"] ?? .null,
                        unordered: false, label: "\(label) field \(path)")
            return
        }

        throw ConformanceError.corpus("unknown expect form: \(expect)")
    }

    private func compare(actual: JV, expected: JV, unordered: Bool, label: String) throws {
        if unordered {
            guard case .array(let a) = actual, case .array(let e) = expected else {
                throw ConformanceError.failed("\(label): unordered compare needs arrays (actual \(actual), expected \(expected))")
            }
            guard JV.multisetEqual(a, e) else {
                throw ConformanceError.failed("\(label): \(actual) ≠ (unordered) \(expected)")
            }
            return
        }
        guard actual == expected else {
            throw ConformanceError.failed("\(label): \(actual) ≠ \(expected)")
        }
    }
}

// MARK: - Corpus loading

struct CorpusFile: Sendable, CustomStringConvertible {
    let name: String
    let path: String
    var description: String { name }
}

enum CorpusLoader {
    static func corpusDirectory() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["LATTICE_CONFORMANCE_DIR"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        // Default: the sibling-checkout edit override, resolved from this
        // source file so it is independent of the test process's CWD:
        // <lattice repo>/../latticecore/conformance/corpus
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LatticeConformanceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let sibling = repoRoot.deletingLastPathComponent()
            .appendingPathComponent("latticecore/conformance/corpus", isDirectory: true)
        return fm.fileExists(atPath: sibling.path) ? sibling : nil
    }

    static func discover() -> [CorpusFile] {
        guard let dir = corpusDirectory() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".json") }.sorted().map {
            CorpusFile(name: $0, path: dir.appendingPathComponent($0).path)
        }
    }

    static func load(_ file: CorpusFile) throws -> JV {
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let raw = try JSONSerialization.jsonObject(with: data)
        let doc = try JV(json: raw)
        guard doc["format_version"] == .int(1) else {
            throw ConformanceError.corpus(
                "unsupported format_version \(doc["format_version"]?.description ?? "<missing>") — this runner implements 1")
        }
        return doc
    }
}
