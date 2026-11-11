import Foundation
import CoreFoundation
import Lattice

public struct ProviderResult: Sendable {
    public let json: String
    public let isError: Bool
    public init(json: String, isError: Bool) { self.json = json; self.isError = isError }
    static func error(_ code: String, _ message: String) -> ProviderResult {
        var prefix = Array(message.utf8.prefix(4_096))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        var payload: [String: Any] = ["error": code, "details": String(decoding: prefix, as: UTF8.self)]
        if prefix.count < message.utf8.count { payload["detailsTruncated"] = true }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return .init(json: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"encoding_failed\"}", isError: true)
    }
}

private final class QueryFailureCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    func record(_ text: String) { lock.lock(); defer { lock.unlock() }; if failure == nil { failure = text } }
    func clear() { lock.lock(); defer { lock.unlock() }; failure = nil }
    func value() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
}

/// Read-only model queries. One actor owns each dynamic reader. An explicit read policy
/// bounds and projects values before relationship hydration; unscoped reads retain the
/// original serialization contract. Backend query errors are captured instead of becoming []/0.
public actor LatticeDataProvider {
    private let fileURL: URL
    private let limits: LatticeQueryLimits
    private let readPolicy: LatticeReadPolicy?
    private let lattice: Lattice
    private let diagnostics: LatticeDiagnostics
    private var schemaByTable: [String: ObjectSchema] = [:]
    private var scopePredicates: [String: String] = [:]
    private var serializationPolicy: [String: Set<String>]?
    private let failures = QueryFailureCapture()
    public static var toolNames: [String] { LatticeToolCatalog.toolNames }

    /// Without a policy, rows default to 100, depth to 1, and numeric limits clamp.
    /// Passing a policy opts into the bounded defaults and strict argument ranges.
    public init(fileURL: URL, defaultLimit: Int? = nil, maxLimit: Int? = nil,
                maxDepthCap: Int? = nil, readPolicy: LatticeReadPolicy? = nil) async throws {
        self.fileURL = fileURL
        self.limits = LatticeQueryLimits(defaultRows: defaultLimit, maxRows: maxLimit,
                                         maxDepth: maxDepthCap, scoped: readPolicy != nil)
        self.readPolicy = readPolicy
        self.serializationPolicy = readPolicy?.permittedFields
        diagnostics = LatticeDiagnostics(fileURL: fileURL, readPolicy: readPolicy)
        _ = try LatticeFilePreflight.signature(fileURL)
        lattice = try Lattice.dynamic(fileURL: fileURL)
        let capture = failures
        lattice.onQueryError { capture.record($0) }
        for schema in lattice.dynamicSchema where readPolicy?.allows(model: schema.name) ?? true {
            if let identities = readPolicy?.requiredRowValues?[schema.name] {
                scopePredicates[schema.name] = try Self.scopePredicate(identities, schema: schema)
            }
            let properties = schema.properties.filter {
                (readPolicy?.allows(model: schema.name, field: $0.name) ?? true)
                    && (readPolicy?.requiredRowValues == nil || $0.kind == .primitive)
            }
            if readPolicy?.requiredRowValues != nil {
                // A root-row predicate does not authorize relationship targets
                // or their counts. Row-scoped inspection therefore stays scalar.
                serializationPolicy?[schema.name] = Set(properties.map(\.name))
            }
            schemaByTable[schema.name] = ObjectSchema(name: schema.name, properties: properties)
        }
        if let failure = failures.value() { throw ToolError("query_failed", failure) }
        guard !schemaByTable.isEmpty || readPolicy != nil else {
            throw ToolError("unsupported_database", "No readable Lattice model schema was found.")
        }
    }

    public func handle(tool: String, argumentsJSON: String) async -> ProviderResult {
        if tool == "lattice_status" || tool == "lattice_changes" {
            return await diagnostics.handle(tool: tool, argumentsJSON: argumentsJSON)
        }
        failures.clear()
        do {
            guard readPolicy == nil || argumentsJSON.utf8.count <= 65_536,
                  let data = argumentsJSON.data(using: .utf8),
                  let parsedArgs = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ToolError("invalid_arguments", "Arguments must be a JSON object of at most 64 KiB.")
            }
            // Unscoped optional nulls mean omitted arguments; predicate values stay intact.
            let args = readPolicy == nil ? parsedArgs.filter { !($0.value is NSNull) } : parsedArgs
            try validateArguments(tool: tool, args: args)
            var payload: [String: Any]
            switch tool {
            case "lattice_schema": payload = try schemaPayload(args)
            case "lattice_query": payload = try queryPayload(args)
            case "lattice_get": payload = try getPayload(args)
            case "lattice_count": payload = try countPayload(args)
            case "lattice_search", "lattice_nearest", "lattice_geo": payload = try searchPayload(tool, args)
            default: throw ToolError("unknown_tool", "Unknown query tool '\(tool)'.")
            }
            try checkQuery()
            payload["source"] = ["id": fileURL.path, "kind": "file", "observedAt": ISO8601DateFormatter().string(from: Date()), "consistency": "live_read"]
            var encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            if readPolicy == nil {
                return .init(json: String(decoding: encoded, as: UTF8.self), isError: false)
            }
            // Never return a silently cut JSON frame. Rows are removed at complete-object boundaries.
            if tool == "lattice_query", readPolicy?.requiredRowValues == nil,
               var rows = payload["results"] as? [[String: Any]] {
                let start = (args["offset"] as? Int) ?? 0
                while encoded.count > 32_768 && rows.count > 1 {
                    rows.removeLast(); payload["results"] = rows; payload["count"] = rows.count
                    payload["hasMore"] = true; payload["nextOffset"] = start + rows.count; payload["truncated"] = true
                    encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                }
            }
            if tool == "lattice_schema", args["model"] == nil, encoded.count > 32_768 {
                payload["models"] = schemaByTable.values.sorted { $0.name < $1.name }.map {
                    ["name": $0.name, "propertyCount": $0.properties.count] as [String: Any]
                }
                payload["truncated"] = true
                payload["nextAction"] = "Select a model to inspect its full property schema."
                encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            }
            guard encoded.count <= 32_768 else {
                throw ToolError("result_too_large", "The selected object/schema exceeds 32 KiB. Select fewer fields, a single model, or depth 0.")
            }
            return .init(json: String(decoding: encoded, as: UTF8.self), isError: false)
        } catch let error as ToolError { return .error(error.code, error.message) }
        catch is CancellationError { return .error("cancelled", "The read was cancelled.") }
        catch let error as LatticeScopedProjection.Failure { return .error("query_failed", error.description) }
        catch let error as DynamicDebugReadError { return .error("query_failed", String(describing: error)) }
        catch let error as DynamicQueryError { return .error(Self.code(for: error), error.description) }
        catch { return .error("invalid_arguments", String(describing: error)) }
    }

    private struct ToolError: Error {
        let code: String; let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }
    private func checkQuery() throws {
        if let message = failures.value() { throw ToolError("query_failed", message) }
    }
    private static func scopePredicate(_ identities: [String: String], schema: ObjectSchema) throws -> String {
        var clauses: [String] = []
        for (field, expected) in identities.sorted(by: { $0.key < $1.key }) {
            let property = schema.properties.first(where: { $0.name == field })
            guard field == "globalId" || (property?.kind == .primitive && property?.columnType == .text) else {
                if expected.isEmpty && !schema.properties.contains(where: { $0.name == field }) { continue }
                throw ToolError("scope_schema_unavailable", "The source cannot establish its authorized container identity.")
            }
            let column = identifier(field)
            let value = "'" + expected.replacingOccurrences(of: "'", with: "''") + "'"
            let comparison = "\(column) = \(value) COLLATE NOCASE"
            clauses.append(expected.isEmpty ? "(\(column) IS NULL OR \(comparison))" : comparison)
        }
        return clauses.isEmpty ? "1=1" : clauses.map { "(\($0))" }.joined(separator: " AND ")
    }
    private func scopedObjects(_ model: String) -> DynamicResults {
        let rows = lattice.dynamicObjects(model)
        return scopePredicates[model].map { rows.where($0) } ?? rows
    }
    private func combinedScope(_ model: String, predicate: String? = nil) -> String? {
        let clauses = [scopePredicates[model], predicate].compactMap { $0 }
        return clauses.isEmpty ? nil : clauses.map { "(\($0))" }.joined(separator: " AND ")
    }
    private func immutableRows(_ rows: [DynamicObject], model: String, fields: Set<String>?,
                               predicate: String? = nil) throws -> (ids: [Int64?], objects: [Int64: [String: Any]]) {
        // Core's snapshots contain live handles. Their IDs are query keys only;
        // the returned identities and values all come from one authorized SQLite snapshot.
        let ids = try rows.map { try $0.debugPrimaryKey() }
        try checkQuery()
        let objects = try LatticeScopedProjection.rows(fileURL: fileURL, schema: schemaByTable[model]!,
            fields: fields, ids: ids.compactMap { $0 }, scopePredicate: combinedScope(model, predicate: predicate))
        return (ids, objects)
    }
    private func validateArguments(tool: String, args: [String: Any]) throws {
        guard let descriptor = LatticeToolCatalog.tools(readPolicy: readPolicy).first(where: { $0.name == tool }),
              let data = descriptor.inputSchemaJSON.data(using: .utf8),
              let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { throw ToolError("unknown_tool", "Unknown tool.") }
        let unknown = Set(args.keys).subtracting(properties.keys)
        guard readPolicy == nil || unknown.isEmpty else { throw ToolError("invalid_arguments", "Unknown arguments: \(unknown.sorted().joined(separator: ", ")).") }
        for (key, value) in args {
            if readPolicy == nil && ["limit", "offset", "depth", "k"].contains(key) { continue }
            guard let property = properties[key] as? [String: Any], let type = property["type"] as? String else { continue }
            let valid: Bool
            switch type {
            case "string": valid = value is String
            case "object": valid = value is [String: Any]
            case "array": valid = value is [Any]
            case "integer": valid = Self.isInteger(value)
            case "number": valid = Self.number(value) != nil
            case "boolean": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            default: valid = true
            }
            guard valid else { throw ToolError("invalid_arguments", "'\(key)' must be \(type).") }
        }
        for required in schema["required"] as? [String] ?? [] where args[required] == nil {
            throw ToolError("invalid_arguments", "'\(required)' is required.")
        }
        if readPolicy != nil, let predicate = args["where"] as? [String: Any] { var count = 0; try validatePredicate(predicate, depth: 0, count: &count) }
        _ = try integer(args, "limit", default: limits.defaultRows, range: limits.rowRange)
        _ = try integer(args, "offset", default: 0, range: 0...Int.max)
        _ = try integer(args, "depth", default: limits.defaultDepth, range: 0...limits.maxDepth)
    }
    private static func isInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return false }
        return number.doubleValue.rounded(.towardZero) == number.doubleValue &&
               number.doubleValue >= Double(Int.min) && number.doubleValue < Double(Int.max)
    }
    private static func number(_ value: Any) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private func integer(_ args: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        if readPolicy == nil && ["limit", "offset", "depth", "k"].contains(key) {
            return max(range.lowerBound, min((args[key] as? Int) ?? fallback, range.upperBound))
        }
        guard let value = args[key] else { return fallback }
        guard Self.isInteger(value), let number = value as? NSNumber, range.contains(number.intValue) else {
            throw ToolError("invalid_arguments", "'\(key)' must be an integer in \(range.lowerBound)...\(range.upperBound).")
        }
        return number.intValue
    }
    private func validatePredicate(_ value: Any, depth: Int, count: inout Int) throws {
        count += 1
        guard depth <= 16 && count <= 1_024 else { throw ToolError("invalid_predicate", "Predicate is too complex.") }
        if let object = value as? [String: Any] {
            for (_, child) in object { try validatePredicate(child, depth: depth + 1, count: &count) }
        } else if let array = value as? [Any] {
            for child in array { try validatePredicate(child, depth: depth + 1, count: &count) }
        } else if !(value is NSNull || value is String || value is NSNumber) {
            throw ToolError("invalid_predicate", "Predicate operands must be JSON values.")
        }
    }
    private func model(_ args: [String: Any]) throws -> String {
        guard let name = args["model"] as? String, schemaByTable[name] != nil else {
            throw ToolError("invalid_table", "Unknown or unavailable model. Use lattice_schema to inspect permitted models.")
        }
        return name
    }
    private func fields(_ args: [String: Any], model: String) throws -> Set<String>? {
        guard let value = args["fields"] else { return nil }
        guard let names = value as? [String], readPolicy == nil || names.count <= 100 else { throw ToolError("invalid_arguments", "'fields' must contain at most 100 field names.") }
        for name in names { try requireField(name, model: model) }
        return Set(names)
    }
    private func requireField(_ name: String, model: String) throws {
        guard name == "id" || name == "globalId" || schemaByTable[model]!.properties.contains(where: { $0.name == name }) else {
            throw ToolError("unknown_property", "Unknown or unavailable field '\(name)'.")
        }
    }
    private func schemaPayload(_ args: [String: Any]) throws -> [String: Any] {
        let selected = try args["model"].map { _ in try model(args) }
        let models = schemaByTable.values.filter { selected == nil || $0.name == selected }.sorted { $0.name < $1.name }.map { schema -> [String: Any] in
            ["name": schema.name, "properties": schema.properties.map { p -> [String: Any] in
                var item: [String: Any] = ["name": p.name, "kind": p.kind.rawValue, "type": p.columnType.rawValue, "optional": p.isOptional]
                if p.isIndexed { item["indexed"] = true }; if p.isUnique { item["unique"] = true }
                if p.isFullText { item["fullText"] = true }; if p.isVector { item["vector"] = true }; if p.isGeoBounds { item["geo"] = true }
                if let target = p.linkTarget, readPolicy?.allows(model: target) ?? true { item["target"] = target }
                if !p.unionCases.isEmpty { item["unionCases"] = p.unionCases.map(\.name) }
                return item
            }]
        }
        return ["models": models]
    }
    private func queryPayload(_ args: [String: Any]) throws -> [String: Any] {
        let name = try model(args); let projection = try fields(args, model: name)
        var results = scopedObjects(name)
        let predicate = try (args["where"] as? [String: Any]).map { try DynamicQuery.whereSQL($0, schema: schemaByTable[name]!.properties) }
        if let predicate { results = results.where(predicate) }
        if let sort = args["sort"] as? [Any] {
            guard readPolicy == nil || sort.count <= 16 else { throw ToolError("invalid_arguments", "At most 16 sort fields are allowed.") }
            for entry in sort {
                guard let entry = entry as? [String: Any], let field = entry["field"] as? String,
                      Set(entry.keys).isSubset(of: ["field", "order"]),
                      entry["order"] == nil || entry["order"] is String else { throw ToolError("invalid_arguments", "Sort entries require a field and optional asc/desc order.") }
                try requireField(field, model: name)
                let order = entry["order"] as? String ?? "asc"
                guard ["asc", "desc"].contains(order) else { throw ToolError("invalid_arguments", "Sort order must be asc or desc.") }
                results = results.sortedBy(Self.identifier(field), ascending: order == "asc")
            }
        }
        results = results.sortedBy("id")
        let limit = try integer(args, "limit", default: limits.defaultRows, range: limits.rowRange)
        if limit == 0 { return ["model": name, "count": 0, "results": [], "hasMore": false] }
        let offset = try integer(args, "offset", default: 0, range: 0...Int.max)
        let rows = results.snapshot(limit: limit == Int.max ? limit : limit + 1, offset: offset); try checkQuery()
        let depth = try integer(args, "depth", default: limits.defaultDepth, range: 0...limits.maxDepth)
        if readPolicy?.requiredRowValues != nil {
            let snapshot = try immutableRows(Array(rows.prefix(limit)), model: name, fields: projection, predicate: predicate)
            var serialized: [[String: Any]] = []; var bytes = 0; var consumed = 0
            for id in snapshot.ids {
                guard let id, let object = snapshot.objects[id] else { consumed += 1; continue }
                let size = try JSONSerialization.data(withJSONObject: object).count
                guard size <= 28_000 else { throw ToolError("result_too_large", "Select fewer fields or depth 0.") }
                if bytes + size > 28_000 { break }
                serialized.append(object); bytes += size; consumed += 1
            }
            var payload: [String: Any] = ["model": name, "count": serialized.count,
                "results": serialized, "hasMore": rows.count > consumed]
            if rows.count > consumed { payload["nextOffset"] = offset + consumed }
            return payload
        }
        let serialized = try boundedRows(Array(rows.prefix(limit)), fields: projection, depth: depth)
        var payload: [String: Any] = ["model": name, "count": serialized.count, "results": serialized, "hasMore": rows.count > serialized.count]
        if rows.count > serialized.count { payload["nextOffset"] = offset + serialized.count }
        return payload
    }
    private func getPayload(_ args: [String: Any]) throws -> [String: Any] {
        let name = try model(args); let projection = try fields(args, model: name)
        guard (args["primaryKey"] != nil) != (args["globalId"] != nil) else { throw ToolError("invalid_arguments", "Supply exactly one of primaryKey or globalId.") }
        var results = scopedObjects(name)
        let predicate: String
        if args["primaryKey"] != nil {
            let id = try integer(args, "primaryKey", default: 0, range: 0...Int.max)
            predicate = "id = \(id)"
        } else {
            guard let text = args["globalId"] as? String, let id = UUID(uuidString: text) else { throw ToolError("invalid_arguments", "globalId must be a UUID.") }
            predicate = "globalId = '\(id.uuidString.lowercased())'"
        }
        results = results.where(predicate)
        let row = results.snapshot(limit: 1).first; try checkQuery()
        guard let row else { return ["model": name, "found": false] }
        if readPolicy?.requiredRowValues != nil {
            let snapshot = try immutableRows([row], model: name, fields: projection, predicate: predicate)
            guard let id = snapshot.ids.first ?? nil, let object = snapshot.objects[id] else {
                return ["model": name, "found": false]
            }
            return ["model": name, "found": true, "object": object]
        }
        let depth = try integer(args, "depth", default: limits.defaultDepth, range: 0...limits.maxDepth)
        return ["model": name, "found": true, "object": try serialize(row, fields: projection, depth: depth)]
    }
    private func countPayload(_ args: [String: Any]) throws -> [String: Any] {
        let name = try model(args); var results = scopedObjects(name)
        if let predicate = args["where"] as? [String: Any] { results = results.where(try DynamicQuery.whereSQL(predicate, schema: schemaByTable[name]!.properties)) }
        let count = results.count; try checkQuery()
        return ["model": name, "count": count]
    }
    private func searchPayload(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        let name = try model(args); let projection = try fields(args, model: name)
        guard let field = args["field"] as? String,
              let property = schemaByTable[name]!.properties.first(where: { $0.name == field }) else { throw ToolError("unknown_property", "Unknown or unavailable search field.") }
        let nearest = tool == "lattice_nearest"
        let limit = try integer(args, nearest ? "k" : "limit",
                                default: nearest ? limits.defaultNearest : limits.defaultRows,
                                range: nearest ? limits.nearestRange : limits.rowRange)
        if limit == 0 { return ["model": name, "count": 0, "results": [], "limited": true] }
        let rows: [(object: DynamicObject, distances: [DistanceEntry])]
        let distanceKey: String
        switch tool {
        case "lattice_search":
            guard property.isFullText else { throw ToolError("unsupported_search", "The field has no full-text index.") }
            guard let match = args["match"] as? String, !match.isEmpty else { throw ToolError("invalid_arguments", "match must be nonempty.") }
            rows = lattice.dynamicNearest(table: name, texts: [TextConstraintParam(column: field, searchText: match, limit: Int32(clamping: limit))], where: scopePredicates[name], sort: SortDescriptorParam(kind: .textRank, column: field, ascending: true), limit: limit)
            distanceKey = "score"
        case "lattice_nearest":
            guard property.isVector else { throw ToolError("unsupported_search", "The field is not a vector column.") }
            guard let vector = args["vector"] as? [Any], !vector.isEmpty, readPolicy == nil || vector.count <= 65_536 else { throw ToolError("invalid_arguments", "vector must be a nonempty numeric array.") }
            var bytes = [UInt8](); bytes.reserveCapacity(vector.count * 4)
            for member in vector {
                guard let value = Self.number(member), Float(value).isFinite else { throw ToolError("invalid_arguments", "Every vector component must be a finite Float32 number.") }
                var component = Float(value); withUnsafeBytes(of: &component) { bytes.append(contentsOf: $0) }
            }
            let metric = args["metric"] as? String ?? "l2"
            guard let metricID = ["l2": Int32(0), "cosine": Int32(1), "l1": Int32(2)][metric] else { throw ToolError("invalid_arguments", "metric must be l2, cosine, or l1.") }
            rows = lattice.dynamicNearest(table: name, vectors: [VectorConstraintParam(column: field, queryVector: bytes, k: Int32(limit), metric: metricID)], where: scopePredicates[name], sort: SortDescriptorParam(kind: .vectorDistance, column: field, ascending: true), limit: limit)
            distanceKey = "distance"
        default:
            guard property.isGeoBounds else { throw ToolError("unsupported_search", "The field is not a geographic column.") }
            let radius = args["radiusMeters"].flatMap(Self.number) ?? 1000
            guard let near = args["near"] as? [String: Any], Set(near.keys) == ["lat", "lon"],
                  let lat = near["lat"].flatMap(Self.number), let lon = near["lon"].flatMap(Self.number),
                  (-90...90).contains(lat), (-180...180).contains(lon), radius > 0 else { throw ToolError("invalid_arguments", "Supply valid latitude/longitude and a positive radiusMeters.") }
            rows = lattice.dynamicNearest(table: name, geos: [GeoConstraintParam(column: field, centerLat: lat, centerLon: lon, radiusMeters: radius)], where: scopePredicates[name], sort: SortDescriptorParam(kind: .geoDistance, column: field, ascending: true), limit: limit)
            distanceKey = "distanceMeters"
        }
        try checkQuery()
        let depth = try integer(args, "depth", default: limits.defaultDepth, range: 0...limits.maxDepth)
        let snapshot = try readPolicy?.requiredRowValues == nil ? nil
            : immutableRows(rows.map(\.object), model: name, fields: projection)
        var objects: [[String: Any]] = []; var bytes = 0
        var byteTruncated = false
        for (index, row) in rows.enumerated() {
            var object: [String: Any]
            if let snapshot {
                guard let id = snapshot.ids[index], let projected = snapshot.objects[id] else { continue }
                object = projected
            } else {
                object = try serialize(row.object, fields: projection, depth: depth)
            }
            try checkQuery()
            if let distance = row.distances.first(where: { $0.column == field })?.distance, distance.isFinite { object[distanceKey] = distance }
            let size = try JSONSerialization.data(withJSONObject: object).count
            guard readPolicy == nil || size <= 28_000 else { throw ToolError("result_too_large", "Select fewer fields or depth 0.") }
            if readPolicy != nil && bytes + size > 28_000 { byteTruncated = true; break }
            objects.append(object); bytes += size
        }
        var payload: [String: Any] = ["model": name, "count": objects.count, "results": objects, "limited": rows.count == limit || objects.count < rows.count]
        if byteTruncated {
            payload["truncated"] = true; payload["nextAction"] = "Select fewer fields or reduce depth to retrieve the complete requested search result."
        } else if objects.count < rows.count {
            payload["nextAction"] = "The authorized rows changed during this live read. Run the search again for current results."
        }
        return payload
    }
    private func serialize(_ row: DynamicObject, fields: Set<String>?, depth: Int) throws -> [String: Any] {
        if readPolicy != nil {
            return try row.debugJSON(fields: fields, maxDepth: depth, permittedFields: serializationPolicy)
        }
        let object = row.jsonObject(maxDepth: depth)
        guard let fields else { return object }
        return object.filter { fields.contains($0.key) || $0.key == "id" || $0.key == "globalId" }
    }
    private func boundedRows(_ rows: [DynamicObject], fields: Set<String>?, depth: Int) throws -> [[String: Any]] {
        var output: [[String: Any]] = []; var bytes = 0
        for row in rows {
            let object = try serialize(row, fields: fields, depth: depth)
            try checkQuery()
            let size = try JSONSerialization.data(withJSONObject: object).count
            guard readPolicy == nil || size <= 28_000 else { throw ToolError("result_too_large", "Select fewer fields or depth 0.") }
            if readPolicy != nil && bytes + size > 28_000 { break }
            output.append(object); bytes += size
        }
        return output
    }
    private static func identifier(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func code(for error: DynamicQueryError) -> String {
        switch error { case .unknownProperty: return "unknown_property"; case .unsupportedOperator: return "unsupported_operator"; case .malformed: return "invalid_predicate" }
    }
}
