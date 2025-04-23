import Foundation
import Testing
import SwiftUICore
import Lattice
import Observation

@Suite("Results Tests") class ResultsTests {
    deinit {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "lattice.sqlite")))
    }
    
    init() throws {
        Lattice.defaultConfiguration.fileURL = FileManager.default.temporaryDirectory.appending(path: "lattice.sqlite")
    }
    
    @Test func testQuery_In() async throws {
        let lattice = try Lattice(for: [Person.self, Dog.self])
        let person = Person()
        person.age = 10
        lattice.add(person)
        #expect(lattice.objects(Person.self).where {
            $0.age.in([5, 10, 15])
        }.count == 1)
        #expect(lattice.objects(Person.self).where {
            $0.age.in([5, 15, 20])
        }.count == 0)
        
        let globalId = person.__globalId
        #expect(lattice.objects(Person.self).where {
            $0.__globalId.in([UUID(), UUID(), globalId])
        }.count == 1)
    }
}
