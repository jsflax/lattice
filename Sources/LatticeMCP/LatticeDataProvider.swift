import Foundation
import Lattice

/// Result of a tool call: a JSON string payload + an error flag.
public struct ProviderResult: Sendable {
    public let json: String
    public let isError: Bool

    public init(json: String, isError: Bool) {
        self.json = json
        self.isError = isError
    }

    static func error(_ code: String, _ message: String) -> ProviderResult {
        let payload: [String: Any] = ["error": code, "details": message]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return ProviderResult(json: String(data: data, encoding: .utf8) ?? "{}", isError: true)
    }
}

/// The Lattice side of the MCP server: opens a `.lattice` file dynamically
/// (read-only, no compile-time `@Model` types) and answers tool calls. The whole
/// API is JSON-string in / JSON-string out (Sendable), so the MCP executable can
/// use it WITHOUT enabling C++ interop — keeping the Cxx boundary inside this
/// module and off the MCP SDK's dependency graph.
///
/// An `actor` so the non-Sendable `Lattice` it owns stays isolated — created and
/// queried entirely on the actor's own isolation (the same pattern used widely
/// across the Lattice codebases, e.g. Engram's MemoryTools).
public actor LatticeDataProvider {
    private let fileURL: URL
    private let defaultLimit: Int
    private let maxLimit: Int
    private let maxDepthCap: Int
    private var lattice: Lattice!
    private var schemaByTable: [String: ObjectSchema] = [:]

    /// The tool names this provider answers.
    public static let toolNames = ["lattice_schema", "lattice_query", "lattice_get", "lattice_count",
                                   "lattice_search", "lattice_nearest", "lattice_geo"]

    public init(fileURL: URL,
                defaultLimit: Int = 100,
                maxLimit: Int = 10_000,
                maxDepthCap: Int = 5) async throws {
        self.fileURL = fileURL
        self.defaultLimit = defaultLimit
        self.maxLimit = maxLimit
        self.maxDepthCap = maxDepthCap
        let l = try Lattice.dynamic(fileURL: fileURL)
        self.lattice = l
        for s in l.dynamicSchema { schemaByTable[s.name] = s }
    }

    /// Handle a tool call. `argumentsJSON` is the JSON object of arguments.
    public func handle(tool: String, argumentsJSON: String) -> ProviderResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        do {
            let payload: Any
            switch tool {
            case "lattice_schema": payload = schemaPayload()
            case "lattice_query":  payload = try queryPayload(args)
            case "lattice_get":    payload = try getPayload(args)
            case "lattice_count":  payload = try countPayload(args)
            case "lattice_search": payload = try searchPayload(args)
            case "lattice_nearest": payload = try nearestPayload(args)
            case "lattice_geo":    payload = try geoPayload(args)
            default: return .error("unknown_tool", "No tool named '\(tool)'")
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return ProviderResult(json: String(data: data, encoding: .utf8) ?? "{}", isError: false)
        } catch let e as DynamicQueryError {
            return .error(Self.code(for: e), e.description)
        } catch let e as ToolError {
            return .error(e.code, e.message)
        } catch {
            return .error("error", "\(error)")
        }
    }

    // MARK: - Payloads

    private struct ToolError: Error { let code: String; let message: String }

    private func schemaPayload() -> [String: Any] {
        let models = lattice.dynamicSchema.map { s -> [String: Any] in
            ["name": s.name,
             "properties": s.properties.map { p -> [String: Any] in
                var d: [String: Any] = ["name": p.name, "kind": p.kind.rawValue,
                                        "type": p.columnType.rawValue, "optional": p.isOptional]
                if p.isIndexed { d["indexed"] = true }
                if p.isUnique { d["unique"] = true }
                if p.isFullText { d["fullText"] = true }
                if p.isVector { d["vector"] = true }
                if p.isGeoBounds { d["geo"] = true }
                if let t = p.linkTarget { d["target"] = t }
                if !p.unionCases.isEmpty { d["unionCases"] = p.unionCases.map { $0.name } }
                return d
             }]
        }
        return ["models": models]
    }

    private func queryPayload(_ args: [String: Any]) throws -> [String: Any] {
        let model = try requireModel(args)
        let props = try properties(of: model)
        var results = lattice.dynamicObjects(model)

        if let whereObj = args["where"] as? [String: Any] {
            results = results.where(try DynamicQuery.whereSQL(whereObj, schema: props))
        }
        if let sortArr = args["sort"] as? [Any] {
            for case let s as [String: Any] in sortArr {
                guard let field = s["field"] as? String else { continue }
                guard isQueryable(field, in: props) else {
                    throw ToolError(code: "unknown_property", message: "Unknown sort field '\(field)' on '\(model)'")
                }
                let asc = (s["order"] as? String).map { $0.lowercased() != "desc" } ?? true
                results = results.sorted(by: field, ascending: asc)
            }
        }

        let depth = depthArg(args)
        let rows = results.snapshot(limit: clampLimit(args["limit"]), offset: args["offset"] as? Int)
        let serialized = rows.map { $0.jsonObject(maxDepth: depth) }
        return ["model": model, "count": serialized.count, "results": serialized]
    }

    private func getPayload(_ args: [String: Any]) throws -> [String: Any] {
        let model = try requireModel(args)
        _ = try properties(of: model)
        var results = lattice.dynamicObjects(model)
        if let pk = args["primaryKey"] as? Int {
            results = results.where("id = \(pk)")
        } else if let gid = args["globalId"] as? String {
            results = results.where("globalId = '\(gid.replacingOccurrences(of: "'", with: "''"))'")
        } else {
            throw ToolError(code: "invalid_predicate", message: "'primaryKey' or 'globalId' is required")
        }
        guard let row = results.snapshot(limit: 1).first else {
            return ["model": model, "found": false]
        }
        return ["model": model, "found": true, "object": row.jsonObject(maxDepth: depthArg(args))]
    }

    private func countPayload(_ args: [String: Any]) throws -> [String: Any] {
        let model = try requireModel(args)
        let props = try properties(of: model)
        var results = lattice.dynamicObjects(model)
        if let whereObj = args["where"] as? [String: Any] {
            results = results.where(try DynamicQuery.whereSQL(whereObj, schema: props))
        }
        return ["model": model, "count": results.count]
    }

    private func searchPayload(_ args: [String: Any]) throws -> [String: Any] {
        let model = try requireModel(args)
        let props = try properties(of: model)
        let field = try requireField(args, "field", in: props)
        guard let match = args["match"] as? String else {
            throw ToolError(code: "invalid_predicate", message: "'match' (string) is required")
        }
        let limit = clampLimit(args["limit"])
        let rows = lattice.dynamicNearest(
            table: model,
            texts: [TextConstraintParam(column: field, searchText: match, limit: Int32(limit))],
            sort: SortDescriptorParam(kind: .textRank, column: field, ascending: true),
            limit: limit)
        return resultsPayload(model, rows, field: field, distanceKey: "score", depth: depthArg(args))
    }

    private func nearestPayload(_ args: [String: Any]) throws -> [String: Any] {
        let model = try requireModel(args)
        let props = try properties(of: model)
        let field = try requireField(args, "field", in: props)
        guard let vecAny = args["vector"] as? [Any] else {
            throw ToolError(code: "invalid_predicate", message: "'vector' (array of numbers) is required")
        }
        let doubles = vecAny.compactMap { ($0 as? NSNumber)?.doubleValue }
        let k = Int32((args["k"] as? Int) ?? 10)
        let rows = lattice.dynamicNearest(
            table: model,
            vectors: [VectorConstraintParam(column: field, queryVector: Self.vectorBytes(doubles),
                                            k: k, metric: Self.metricInt(args["metric"] as? String))],
            sort: SortDescriptorParam(kind: .vectorDistance, column: field, ascending: true),
            limit: Int(k))
        return resultsPayload(model, rows, field: field, distanceKey: "distance", depth: depthArg(args))
    }

    private func geoPayload(_ args: [String: Any]) throws -> [String: Any] {
        let model = try requireModel(args)
        let props = try properties(of: model)
        let field = try requireField(args, "field", in: props)
        guard let near = args["near"] as? [String: Any],
              let lat = (near["lat"] as? NSNumber)?.doubleValue,
              let lon = (near["lon"] as? NSNumber)?.doubleValue else {
            throw ToolError(code: "invalid_predicate", message: "'near' {lat, lon} is required")
        }
        let radius = (args["radiusMeters"] as? NSNumber)?.doubleValue ?? 1000
        let limit = clampLimit(args["limit"])
        let rows = lattice.dynamicNearest(
            table: model,
            geos: [GeoConstraintParam(column: field, centerLat: lat, centerLon: lon, radiusMeters: radius)],
            sort: SortDescriptorParam(kind: .geoDistance, column: field, ascending: true),
            limit: limit)
        return resultsPayload(model, rows, field: field, distanceKey: "distanceMeters", depth: depthArg(args))
    }

    private func resultsPayload(_ model: String,
                               _ rows: [(object: DynamicObject, distances: [DistanceEntry])],
                               field: String, distanceKey: String, depth: Int) -> [String: Any] {
        let results = rows.map { row -> [String: Any] in
            var obj = row.object.jsonObject(maxDepth: depth)
            if let d = (row.distances.first { $0.column == field } ?? row.distances.first)?.distance {
                obj[distanceKey] = d
            }
            return obj
        }
        return ["model": model, "count": results.count, "results": results]
    }

    // MARK: - Helpers

    private func requireField(_ args: [String: Any], _ key: String, in props: [PropertyInfo]) throws -> String {
        guard let field = args[key] as? String else {
            throw ToolError(code: "invalid_predicate", message: "'\(key)' (string) is required")
        }
        guard isQueryable(field, in: props) else {
            throw ToolError(code: "unknown_property", message: "Unknown property '\(field)'")
        }
        return field
    }

    private static func vectorBytes(_ doubles: [Double]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(doubles.count * 4)
        for d in doubles { var f = Float(d); withUnsafeBytes(of: &f) { out.append(contentsOf: $0) } }
        return out
    }

    private static func metricInt(_ s: String?) -> Int32 {
        switch (s ?? "l2").lowercased() {
        case "cosine": return 1
        case "l1": return 2
        default: return 0
        }
    }

    private func requireModel(_ args: [String: Any]) throws -> String {
        guard let model = args["model"] as? String else {
            throw ToolError(code: "invalid_predicate", message: "'model' (string) is required")
        }
        return model
    }

    private func properties(of model: String) throws -> [PropertyInfo] {
        guard let s = schemaByTable[model] else {
            throw ToolError(code: "invalid_table",
                            message: "Unknown model '\(model)'. Known: \(schemaByTable.keys.sorted().joined(separator: ", "))")
        }
        return s.properties
    }

    private func isQueryable(_ field: String, in props: [PropertyInfo]) -> Bool {
        field == "id" || field == "globalId" || props.contains { $0.name == field }
    }

    private func clampLimit(_ v: Any?) -> Int {
        max(0, min((v as? Int) ?? defaultLimit, maxLimit))
    }

    private func depthArg(_ args: [String: Any]) -> Int {
        max(0, min((args["depth"] as? Int) ?? 1, maxDepthCap))
    }

    private static func code(for e: DynamicQueryError) -> String {
        switch e {
        case .unknownProperty: return "unknown_property"
        case .unsupportedOperator: return "unsupported_operator"
        case .malformed: return "invalid_predicate"
        }
    }
}
