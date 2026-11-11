import Foundation
import MCP
import LatticeMCP
import LatticeMCPTransport

struct CommandOptions {
    var db: URL?
    var doctor = false
    var version = false
    var help = false

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--version": version = true
            case "--doctor": doctor = true
            case "--help", "-h": help = true
            case "--db":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-"), db == nil else {
                    throw CLIError.message("--db requires one database path")
                }
                db = Self.url(arguments[index])
            default:
                guard !argument.hasPrefix("-"), db == nil else {
                    throw CLIError.message("Unexpected argument: \(argument)")
                }
                db = Self.url(argument)
            }
            index += 1
        }
    }
    private static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let message): message } }
}

func argumentsJSON(_ arguments: [String: Value]?) throws -> String {
    String(decoding: try JSONEncoder().encode(arguments ?? [:]), as: UTF8.self)
}

func toolDefinitions() throws -> [Tool] {
    try LatticeToolCatalog.tools.map { descriptor in
        Tool(name: descriptor.name, description: descriptor.description,
             inputSchema: try JSONDecoder().decode(Value.self, from: Data(descriptor.inputSchemaJSON.utf8)),
             annotations: .init(readOnlyHint: true))
    }
}

do {
    let options = try CommandOptions(Array(CommandLine.arguments.dropFirst()))
    if options.help {
        print("""
        lattice-mcp [--db /absolute/database/path]
        lattice-mcp --version
        lattice-mcp --doctor [--db /absolute/database/path]

        Read-only MCP over newline-delimited stdio. Pass db per tool call when
        no launch default is configured. Ordinary startup writes no stdout logs.
        """)
        exit(0)
    }
    if options.version {
        print("lattice-mcp \(LatticeToolCatalog.version)")
        exit(0)
    }
    let pool = LatticeProviderPool(defaultDB: options.db)
    if options.doctor {
        let result = await pool.handle(tool: "lattice_status", argumentsJSON: "{}")
        print(result.json)
        exit(result.isError ? 1 : 0)
    }
    let server = Server(name: "lattice", version: LatticeToolCatalog.version,
                        capabilities: .init(tools: .init(listChanged: false)))
    let definitions = try toolDefinitions()
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: definitions) }
    await server.withMethodHandler(CallTool.self) { parameters in
        let result = await pool.handle(tool: parameters.name,
                                       argumentsJSON: try argumentsJSON(parameters.arguments))
        return CallTool.Result(content: [.text(text: result.json, annotations: nil, _meta: nil)],
                               isError: result.isError)
    }
    try await server.start(transport: LatticeSerializedStdioTransport())
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("lattice-mcp: \(error)\n".utf8))
    exit(1)
}
