import Foundation

/// SDK-independent metadata shared by the provider and MCP executable.
public struct LatticeToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String
    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public enum LatticeToolCatalog {
    public static let version = "0.2.1"
    public static var toolNames: [String] { tools.map(\.name) }
    public static let tools: [LatticeToolDescriptor] = {
        let string: [String: Any] = ["type": "string", "minLength": 1]
        let db: [String: Any] = ["type": "string", "minLength": 1,
            "description": "Absolute database path; optional with --db. No filesystem discovery."]
        let fields: [String: Any] = ["type": "array", "items": string, "uniqueItems": true,
            "description": "Selected top-level properties; identities remain included."]
        let depth: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 3, "default": 0]
        let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 500, "default": 25]
        let predicate: [String: Any] = ["type": "object",
            "description": "{field:{$op:value}}; $eq $ne $gt $gte $lt $lte $contains $hasPrefix $hasSuffix $in $between; $and/$or/$not."]
        let view: [String: Any] = ["db": db, "model": string, "fields": fields, "depth": depth]
        func tool(_ name: String, _ description: String, _ properties: [String: Any],
                  required: [String] = [], extra: [String: Any] = [:]) -> LatticeToolDescriptor {
            var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            if !required.isEmpty { schema["required"] = required }
            schema.merge(extra) { _, new in new }
            // Catalog values are static JSON literals, never user input.
            guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else {
                preconditionFailure("Invalid built-in tool schema: \(name)")
            }
            return .init(name: name, description: description, inputSchemaJSON: String(decoding: data, as: UTF8.self))
        }
        func withView(_ extra: [String: Any]) -> [String: Any] { view.merging(extra) { _, new in new } }
        return [
            tool("lattice_schema", "Inspect model properties, links and search capabilities. Filter by model for a smaller result.",
                 ["db": db, "model": string]),
            tool("lattice_query", "Read matching objects. Default 25 rows, depth 0; use fields and pagination for smaller responses.",
                 withView(["where": predicate, "limit": limit, "offset": ["type": "integer", "minimum": 0, "default": 0],
                    "sort": ["type": "array", "items": ["type": "object", "properties": ["field": string,
                        "order": ["type": "string", "enum": ["asc", "desc"]]], "required": ["field"], "additionalProperties": false]]]),
                 required: ["model"]),
            tool("lattice_get", "Read one object by primaryKey or globalId, optionally selecting fields.",
                 withView(["primaryKey": ["type": "integer"], "globalId": string]), required: ["model"],
                 extra: ["oneOf": [["required": ["primaryKey"]], ["required": ["globalId"]]]]),
            tool("lattice_count", "Count objects matching a structured predicate.",
                 ["db": db, "model": string, "where": predicate], required: ["model"]),
            tool("lattice_search", "Search a full-text indexed field, ordered by relevance score.",
                 withView(["field": string, "match": string, "limit": limit]), required: ["model", "field", "match"]),
            tool("lattice_nearest", "Search a vector field, ordered by distance. Supply every numeric vector component.",
                 withView(["field": string, "vector": ["type": "array", "items": ["type": "number"], "minItems": 1],
                    "k": limit, "metric": ["type": "string", "enum": ["l2", "cosine", "l1"], "default": "l2"]]),
                 required: ["model", "field", "vector"]),
            tool("lattice_geo", "Search a geo field near a point, ordered by distanceMeters.",
                 withView(["field": string, "limit": limit, "near": ["type": "object", "properties": [
                    "lat": ["type": "number", "minimum": -90, "maximum": 90],
                    "lon": ["type": "number", "minimum": -180, "maximum": 180]],
                    "required": ["lat", "lon"], "additionalProperties": false],
                    "radiusMeters": ["type": "number", "minimum": 0, "default": 1000]]), required: ["model", "field", "near"]),
            tool("lattice_status", "Report server capabilities or a database's identity, freshness, audit availability and persisted sync evidence.",
                 ["db": db]),
            tool("lattice_changes", "Read bounded audit changes with a resumable cursor. Start now for later actions, or retained for available history.",
                 ["db": db, "cursor": string, "start": ["type": "string", "enum": ["now", "retained"], "default": "now"],
                  "models": ["type": "array", "items": string, "uniqueItems": true],
                  "operations": ["type": "array", "items": ["type": "string", "enum": ["INSERT", "UPDATE", "DELETE"]], "uniqueItems": true],
                  "origin": ["type": "string", "enum": ["local", "remote", "all"], "default": "all"], "globalRowId": string,
                  "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 100],
                  "waitMs": ["type": "integer", "minimum": 0, "maximum": 25000, "default": 0],
                  "includeValues": ["type": "boolean", "default": false]], extra: ["not": ["required": ["cursor", "start"]]])
        ]
    }()
}
