import Foundation
import Lattice
import Testing

@Suite("Property Tests") class PropertyTests {
    
    @Test func test_AnyProperty() async throws {
        try print(String(data: JSONEncoder().encode(AnyProperty.date(.now)), encoding: .utf8)!)
    }
}

@Model class ModelWithPrivateSet {
    var publicVar: String
    public private(set) var restrictedVar: String = "hi"
    
    init(publicVar: String, restrictedVar: String) {
        self.publicVar = publicVar
        self.restrictedVar = restrictedVar
    }
}

@Test func test_PrivateSet() throws {
    let path = "\(String.random(length: 32)).sqlite"
    let lattice = try testLattice(path: path, ModelWithPrivateSet.self)
    defer {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
    }

    let obj = ModelWithPrivateSet(publicVar: "public", restrictedVar: "restricted")
    lattice.add(obj)

    let results = lattice.objects(ModelWithPrivateSet.self)
    print("Count:", results.count)
    guard let retrieved = results.first else {
        Issue.record("No objects found")
        return
    }
    #expect(retrieved.publicVar == "public")
    #expect(retrieved.restrictedVar == "restricted")
}
