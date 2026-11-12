import Foundation
import Testing
import LatticeTestSupport
@testable import Lattice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Model final class MainFileCurrentnessItem {
    var value: String
    init(value: String = "unchanged") { self.value = value }
}

@Suite("Exact primary main-file currentness", .serialized)
struct MainFileCurrentnessTests {
    private func directory() throws -> URL {
        let value = LatticeTestScratch.directory.appending(path: "main-currentness-swift-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func openedPath(_ file: URL) throws -> String {
        try file.withUnsafeFileSystemRepresentation { path in
            let path = try #require(path)
            let resolved = try #require(realpath(path, nil))
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
    @Test func existingFileChecksAndClosedHandleRefuses() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "main.sqlite")
        let owner = try Lattice(MainFileCurrentnessItem.self, configuration: .init(fileURL: file))
        defer { owner.close() }
        try owner.add(MainFileCurrentnessItem(value: "unchanged"))
        let path = try openedPath(file)
        let before = try owner.auditReadFence()
        try owner.requireMainFileUnmoved(expectedPath: path)
        let after = try owner.auditReadFence()
        #expect(after == before)
        owner.close()
        #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: path) }
    }
    @Test func renamedPrimaryFailsWithoutChangingLogicalAdmissionContract() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "main.sqlite"), retired = root.appending(path: "retired.sqlite")
        let owner = try Lattice(MainFileCurrentnessItem.self, configuration: .init(fileURL: file))
        defer { owner.close() }
        try owner.add(MainFileCurrentnessItem(value: "unchanged"))
        let path = try openedPath(file)
        try owner.requireMainFileUnmoved(expectedPath: path)
        try FileManager.default.moveItem(at: file, to: retired)
        #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: path) }
        // A different caller-supplied pathname cannot rewrite SQLite's captured original name.
        let retiredPath = try openedPath(retired)
        #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: retiredPath) }
    }
    @Test func memoryAndMalformedExpectedPathsRefuse() throws {
        let owner = try Lattice(MainFileCurrentnessItem.self, configuration: .init(storage: .memory(named: "currentness-\(UUID())")))
        defer { owner.close() }
        let unopenedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-not-open.sqlite").path
        for path in ["", "bad\0path", String(repeating: "x", count: 4097), unopenedPath] {
            #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: path) }
        }
    }
}
