import Foundation
import Testing
import SwiftUI
import Lattice
import Observation

@Suite("Results Tests")
class ResultsTests: BaseTest {
    @Test func testQuery_In() async throws {
        let lattice = try testLattice(Person.self, Dog.self)
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
    
    @Test func testCursor() async throws {
        let lattice = try testLattice(SequenceSyncObject.self)
        let objects = (0..<100_000).map { _ in SequenceSyncObject() }
        lattice.transaction {
            lattice.add(contentsOf: objects)
        }

        let results = lattice.objects(SequenceSyncObject.self)

        // Test 1: Slice iteration (batched - 1 query for the range)
        var duration = Test.Clock().measure {
            for result in results[0..<1000] {
                _ = result.open
            }
        }
        print("Slice iteration (1000 items): \(duration)")

        // Test 2: Cursor iteration (batched - queries of 100)
        let cursor = Results<SequenceSyncObject>.Cursor(results)
        duration = Test.Clock().measure {
            var idx = 0
            while idx < 1000, let result = cursor.next()  {
                _ = result.open
                idx += 1
            }
        }
        print("Cursor iteration (1000 items): \(duration)")

        // Test 3: Full results iteration via for-in (uses Cursor)
        duration = Test.Clock().measure {
            var count = 0
            for result in results {
                _ = result.open
                count += 1
                if count >= 1000 { break }
            }
        }
        print("For-in iteration (1000 items): \(duration)")
    }
    
    @Test func test_WriteWhileIterating() async throws {
        let lattice = try testLattice(SequenceSyncObject.self)
        let objects = (0..<1000).map { _ in SequenceSyncObject() }
        lattice.transaction {
            lattice.add(contentsOf: objects)
        }
        
        func doWork(isolation: isolated (any Actor)? = #isolation) throws {
            let lattice = try Lattice(for: [SequenceSyncObject.self])
            let results = lattice.objects(SequenceSyncObject.self)
            lattice.transaction {
                for object in results {
                    
                    object.low = 5000
                }
            }
        }
        
        Task { @TestActor in
            try doWork()
        }
        Task { @TestActor in
            try doWork()
        }
        let results = lattice.objects(SequenceSyncObject.self)
        for object in results {
            lattice.transaction {
                object.high = 5000
            }
        }
    }
    
    @Test
    func test_ResultsSendableReference() async throws {
        let lattice = try testLattice(Person.self, Dog.self)
        let person = Person()
        person.age = 10
        lattice.add(person)
        
        let person2 = Person()
        person2.age = 20
        lattice.add(person2)
        
        let results = lattice.objects(Person.self).where {
            $0.age.in([5, 10, 15])
        }
        #expect(results.count == 1)
        let ref = results.sendableReference
        let configuration = lattice.configuration
        try await Task { [ref] in
            let results = try ref.resolve(on: Lattice(Person.self, Dog.self, configuration: configuration))
            #expect(results.count == 1)
        }.value
        
        #expect(lattice.objects(Person.self).count == 2)
    }
}

@globalActor struct TestActor {
    actor ActorType {}
    static let shared = ActorType()
}
