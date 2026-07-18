import Foundation
import Testing
import Lattice
import LatticeMCP

/// Thread-safe accumulator for the subprocess's stdout (written from a
/// FileHandle readability handler on a background queue).
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

// True end-to-end: spawn the built `lattice-mcp` binary, speak MCP JSON-RPC over
// stdio (newline-delimited), and assert real tool responses incl. a tools/call
// query with link traversal. Reuses DynPerson/DynDog from DynamicAPITests.
@Suite("LatticeMCP Stdio Tests")
final class LatticeMCPStdioTests {

    @Test func testStdioRoundTrip() async throws {
        // CWD is the package root during `swift test`.
        let binary = URL(fileURLWithPath: ".build/debug/lattice-mcp")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return  // executable not built in this configuration — skip
        }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "mcpio_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        do {
            let lattice = try Lattice(DynPerson.self, DynDog.self, configuration: .init(fileURL: url))
            let dog = DynDog(); dog.name = "Rex"; try lattice.add(dog)
            let alice = DynPerson(); alice.name = "Alice"; alice.age = 34
            try lattice.add(alice); alice.dog = dog
            lattice.checkpoint()
            lattice.close()
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--db", url.path]
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        try proc.run()
        defer { proc.terminate() }

        let box = OutputBox()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { box.append(d) }
        }

        func send(_ s: String) async {
            stdin.fileHandleForWriting.write(Data((s + "\n").utf8))
            // Space sends out: the SDK's stdio read loop can mis-parse messages
            // that pile up in one read, so let each drain before the next.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        @discardableResult
        func waitFor(_ needle: String, timeout: TimeInterval = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if box.string().contains(needle) { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }

        await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#)
        let gotInit = await waitFor("\"id\":1")
        await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let gotList = await waitFor("\"id\":2")
        await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lattice_query","arguments":{"model":"DynPerson","where":{"age":{"$gte":30}},"depth":1}}}"#)
        let gotCall = await waitFor("\"id\":3")

        stdout.fileHandleForReading.readabilityHandler = nil
        let out = box.string()

        #expect(gotInit)                       // initialize handshake
        #expect(gotList)                       // tools/list responded
        #expect(out.contains("lattice_query")) // advertised our tools
        #expect(out.contains("lattice_schema"))
        // Pin the public constant to the executable's advertised tool list:
        // `LatticeDataProvider.toolNames` is the embedder's registration list
        // (1.0 public surface), and the provider's `handle` switch + main.swift's
        // `toolDefinitions()` must not drift from it.
        for name in LatticeDataProvider.toolNames {
            #expect(out.contains("\"\(name)\""),
                    "tools/list did not advertise '\(name)' from LatticeDataProvider.toolNames")
        }
        #expect(gotCall)                       // tools/call responded
        #expect(out.contains("Alice"))         // query result row
        #expect(out.contains("Rex"))           // resolved dog link (depth 1)
    }
}
