import Foundation
import Testing
import Lattice

@Model
final class TestMemory {
    var content: String
    var project: String

    init(content: String = "", project: String = "test") {
        self.content = content
        self.project = project
    }
}

@Suite struct PreserveGlobalIdTests {
    @Test func addWithPreservedGlobalId() throws {
        let latticeA = try Lattice(TestMemory.self, configuration: .init(isStoredInMemoryOnly: true))
        let latticeB = try Lattice(TestMemory.self, configuration: .init(isStoredInMemoryOnly: true))

        // Add to lattice A
        let original = TestMemory(content: "test memory", project: "proj")
        latticeA.add(original)
        let originalGlobalId = original.globalId!

        // Migrate to lattice B preserving globalId
        let copy = TestMemory(content: original.content, project: original.project)
        latticeB.add(copy, preservingGlobalId: originalGlobalId)

        // Verify globalId preserved
        #expect(copy.globalId == originalGlobalId)

        // Verify the object is queryable
        let found = latticeB.objects(TestMemory.self).where { $0.content == "test memory" }.first
        #expect(found != nil)
        #expect(found?.globalId == originalGlobalId)
    }

    @Test func addWithPreservedGlobalId_differentFromGenerated() throws {
        let lattice = try Lattice(TestMemory.self, configuration: .init(isStoredInMemoryOnly: true))

        let specificId = UUID()
        let obj = TestMemory(content: "specific id", project: "test")
        lattice.add(obj, preservingGlobalId: specificId)

        #expect(obj.globalId == specificId)
    }

    @Test func addWithoutPreservedGlobalId_generatesNew() throws {
        let lattice = try Lattice(TestMemory.self, configuration: .init(isStoredInMemoryOnly: true))

        let obj = TestMemory(content: "auto id", project: "test")
        lattice.add(obj)

        #expect(obj.globalId != nil)
    }
}
