import Foundation
import Testing
import LatticeTestSupport
@testable import Lattice

@Model final class MainFileCurrentnessItem {
    var value: String
    init(value: String = "unchanged") { self.value = value }
}

@Suite("Exact primary main-file currentness", .serialized)
struct MainFileCurrentnessTests {
    private func directory() throws -> URL {
        let value = LatticeTestScratch.directory.appending(path: "main-currentness-swift-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value.resolvingSymlinksInPath()
    }
    @Test func existingFileChecksAndClosedHandleRefuses() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "main.sqlite")
        let owner = try Lattice(MainFileCurrentnessItem.self, configuration: .init(fileURL: file))
        defer { owner.close() }
        try owner.add(MainFileCurrentnessItem())
        let before = try owner.auditReadFence()
        try owner.requireMainFileUnmoved(expectedPath: file.path)
        let after = try owner.auditReadFence()
        #expect(after == before)
        owner.close()
        #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: file.path) }
    }
    @Test func renamedPrimaryFailsWithoutChangingLogicalAdmissionContract() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "main.sqlite"), retired = root.appending(path: "retired.sqlite")
        let owner = try Lattice(MainFileCurrentnessItem.self, configuration: .init(fileURL: file))
        defer { owner.close() }
        try owner.add(MainFileCurrentnessItem())
        try owner.requireMainFileUnmoved(expectedPath: file.path)
        try FileManager.default.moveItem(at: file, to: retired)
        #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: file.path) }
        // A different caller-supplied pathname cannot rewrite SQLite's captured original name.
        #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: retired.path) }
    }
    @Test func memoryAndMalformedExpectedPathsRefuse() throws {
        let owner = try Lattice(MainFileCurrentnessItem.self, configuration: .init(storage: .memory(named: "currentness-\(UUID())")))
        defer { owner.close() }
        for path in ["", "bad\0path", String(repeating: "x", count: 4097), "/Users/jason/localdev/not-open.sqlite"] {
            #expect(throws: (any Error).self) { try owner.requireMainFileUnmoved(expectedPath: path) }
        }
    }
}
