import Foundation
import Testing
import Lattice
import LatticeMCP

// The pool makes one server generic: route each call to a DB by its `db` arg,
// fall back to a launch default, and reuse the same provider across calls.
// Reuses DynPerson/DynDog from DynamicAPITests.
@Suite("LatticeMCP Provider Pool")
final class LatticeMCPPoolTests {

    private func makeDB() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mcppool_\(UUID().uuidString).sqlite")
        let l = try Lattice(DynPerson.self, DynDog.self, configuration: .init(fileURL: url))
        let p = DynPerson(); p.name = "Ada"; p.age = 42
        try l.add(p)
        l.checkpoint(); l.close()
        return url
    }

    // `db` arg selects the database; no default needed.
    @Test func testRoutesByDBArgument() async throws {
        let url = try makeDB()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        let pool = LatticeProviderPool()   // no launch default
        let args = #"{"db":"\#(url.path)","model":"DynPerson"}"#
        let r = await pool.handle(tool: "lattice_query", argumentsJSON: args)
        #expect(!r.isError)
        #expect(r.json.contains("Ada"))

        // A second call to the same DB reuses the cached provider.
        let again = await pool.handle(tool: "lattice_count", argumentsJSON: args)
        #expect(!again.isError)
        #expect(again.json.contains("\"count\":1"))
    }

    // With no `db` arg and no launch default, the call errors cleanly.
    @Test func testMissingDatabaseErrors() async throws {
        let pool = LatticeProviderPool()
        let r = await pool.handle(tool: "lattice_schema", argumentsJSON: "{}")
        #expect(r.isError)
        #expect(r.json.contains("no_database"))
    }

    // A bad path surfaces an open error, not a crash.
    @Test func testUnknownDatabaseErrors() async throws {
        let pool = LatticeProviderPool()
        let r = await pool.handle(tool: "lattice_schema",
                                  argumentsJSON: #"{"db":"/nope/missing.lattice"}"#)
        #expect(r.isError)
        #expect(r.json.contains("open_failed"))
    }

    // An empty / non-SQLite file is rejected cleanly (must not hang the call).
    @Test func testEmptyFileErrors() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mcpempty_\(UUID().uuidString).lattice")
        try Data().write(to: url)                 // 0-byte file
        defer { try? FileManager.default.removeItem(at: url) }

        let pool = LatticeProviderPool()
        let r = await pool.handle(tool: "lattice_schema",
                                  argumentsJSON: #"{"db":"\#(url.path)"}"#)
        #expect(r.isError)
        #expect(r.json.contains("open_failed"))
    }

    // A launch default is used when `db` is omitted.
    @Test func testLaunchDefaultUsedWhenDBOmitted() async throws {
        let url = try makeDB()
        defer { try? Lattice.delete(for: .init(fileURL: url)) }

        let pool = LatticeProviderPool(defaultDB: url)
        let r = await pool.handle(tool: "lattice_query", argumentsJSON: #"{"model":"DynPerson"}"#)
        #expect(!r.isError)
        #expect(r.json.contains("Ada"))
    }
}
