import Foundation
import MCP
import LatticeMCP

// lattice-mcp — a generic, read-only MCP query server over a .lattice file.
//
//   lattice-mcp --db /path/to/app.lattice
//   lattice-mcp /path/to/app.lattice
//
// Speaks MCP over stdio; register it with an MCP client (e.g. Claude Code/Desktop).
// This target deliberately does NOT enable C++ interop: the Lattice/C++ boundary
// lives inside LatticeMCP (LatticeDataProvider), so the MCP SDK and its
// dependencies compile normally.

func parseDBPath() -> String? {
    let args = Array(CommandLine.arguments.dropFirst())
    if let i = args.firstIndex(of: "--db"), i + 1 < args.count { return args[i + 1] }
    return args.first { !$0.hasPrefix("-") }
}

/// Encode MCP arguments (`[String: Value]`) to a JSON object string for the provider.
func argumentsJSON(_ args: [String: Value]?) -> String {
    guard let args, !args.isEmpty,
          let data = try? JSONEncoder().encode(args),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

/// Build a `Value` JSON-Schema from a plain `[String: Any]` schema dictionary.
func schemaValue(_ any: [String: Any]) -> Value {
    guard let data = try? JSONSerialization.data(withJSONObject: any),
          let v = try? JSONDecoder().decode(Value.self, from: data) else { return .object([:]) }
    return v
}

func toolDefinitions() -> [Tool] {
    let ro = Tool.Annotations(readOnlyHint: true)
    let str: [String: Any] = ["type": "string"]
    let int: [String: Any] = ["type": "integer"]
    let obj: [String: Any] = ["type": "object"]

    return [
        Tool(name: "lattice_schema",
             description: "List every model table and its property schema (kind, type, link target, indexed/unique/fullText/vector/geo flags, union cases).",
             inputSchema: schemaValue(["type": "object", "properties": [String: Any]()]),
             annotations: ro),

        Tool(name: "lattice_query",
             description: "Query a model with a structured JSON predicate; returns reconstructed object views (links resolved up to `depth`). Default limit 100.",
             inputSchema: schemaValue([
                "type": "object",
                "properties": [
                    "model": str,
                    "where": ["type": "object", "description": "JSON predicate: {col:{$op:val}} with $eq $ne $gt $gte $lt $lte $contains $hasPrefix $hasSuffix $in $between, plus $and/$or/$not."],
                    "sort": ["type": "array", "items": ["type": "object", "properties": ["field": str, "order": str]]],
                    "limit": int, "offset": int, "depth": int,
                ],
                "required": ["model"],
             ]),
             annotations: ro),

        Tool(name: "lattice_get",
             description: "Fetch a single object by primaryKey or globalId.",
             inputSchema: schemaValue([
                "type": "object",
                "properties": ["model": str, "primaryKey": int, "globalId": str, "depth": int],
                "required": ["model"],
             ]),
             annotations: ro),

        Tool(name: "lattice_count",
             description: "Count objects of a model matching an optional JSON predicate.",
             inputSchema: schemaValue([
                "type": "object",
                "properties": ["model": str, "where": obj],
                "required": ["model"],
             ]),
             annotations: ro),

        Tool(name: "lattice_search",
             description: "Full-text search (FTS5) over a @FullText column; results ordered by relevance (`score`).",
             inputSchema: schemaValue([
                "type": "object",
                "properties": ["model": str, "field": str, "match": str, "limit": int, "depth": int],
                "required": ["model", "field", "match"],
             ]),
             annotations: ro),

        Tool(name: "lattice_nearest",
             description: "Vector ANN search over a Vector column. Supply a `vector` (array of numbers); `metric` is l2|cosine|l1. Returns rows with `distance`.",
             inputSchema: schemaValue([
                "type": "object",
                "properties": [
                    "model": str, "field": str,
                    "vector": ["type": "array", "items": ["type": "number"]],
                    "k": int, "metric": str, "depth": int,
                ],
                "required": ["model", "field", "vector"],
             ]),
             annotations: ro),

        Tool(name: "lattice_geo",
             description: "Geo proximity search over a geo column within `radiusMeters` of `near` {lat, lon}; results ordered by distance (`distanceMeters`).",
             inputSchema: schemaValue([
                "type": "object",
                "properties": [
                    "model": str, "field": str,
                    "near": ["type": "object", "properties": ["lat": ["type": "number"], "lon": ["type": "number"]]],
                    "radiusMeters": ["type": "number"], "limit": int, "depth": int,
                ],
                "required": ["model", "field", "near"],
             ]),
             annotations: ro),
    ]
}

guard let path = parseDBPath() else {
    FileHandle.standardError.write(Data("usage: lattice-mcp --db <path-to-.lattice>\n".utf8))
    exit(2)
}

do {
    let providerTask = Task {
        try await LatticeDataProvider(fileURL: URL(fileURLWithPath: path))
    }
    let server = Server(name: "lattice", version: "0.1.0",
                        capabilities: .init(tools: .init(listChanged: false)))
    let tools = toolDefinitions()
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
    await server.withMethodHandler(CallTool.self) { params in
        let result = try await providerTask.value.handle(tool: params.name,
                                                         argumentsJSON: argumentsJSON(params.arguments))
        return CallTool.Result(content: [.text(text: result.json, annotations: nil, _meta: nil)],
                               isError: result.isError)
    }
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("lattice-mcp: failed to start: \(error)\n".utf8))
    exit(1)
}
