import Testing
import SwiftUICore
@testable import Lattice
import Observation

@Model final class Person: @unchecked Sendable {
    var name: String
    var age: Int
}


struct Embedded: EmbeddedModel {
    var bar: String = ""
}

@Model class ModelWithEmbeddedModelObject {
    var foo: String
    var bar: Embedded?
}

@Suite("Lattice Tests") class LatticeTests {
    deinit {
        let lattice = try! Lattice(Person.self, ModelWithEmbeddedModelObject.self)
        lattice.delete(Person.self)
        lattice.delete(ModelWithEmbeddedModelObject.self)
        lattice.deleteHistory()
    }
    
    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        let manager = try Lattice(Person.self)
        let person = Person()
        person.name = "John"
        person.age = 30
        manager.add(person)
        
        person.age = 31
        print(person)
    }
    
    @Test func testLattice_Objects() async throws {
        let lattice = try Lattice(Person.self)
        let persons = lattice.objects(Person.self)
        
        let person = persons[0]
        print(person.age)
        //    @Sendable func track() {
        //        withObservationTracking {
        //            print("Tracking age: \(person.age)")
        //        } onChange: {
        //            print("Change")
        //            print(person.age)
        //            track()
        //        }
        //    }
        //    track()
        person.age += 1
        //    print(lattice.object(Person.self, primaryKey: 2)?.age)
    }
    
    
    @Test func testLattice_Objects_MultipleConnections() async throws {
        let lattice = try Lattice(Person.self)
        let task = Task.detached {
            let lattice2 = try Lattice(Person.self)
            try await Task.sleep(for: .seconds(10))
        }
        let persons = lattice.objects(Person.self)
        
        let person = persons[0]
        print(person.age)
        //    @Sendable func track() {
        //        withObservationTracking {
        //            print("Tracking age: \(person.age)")
        //        } onChange: {
        //            print("Change")
        //            print(person.age)
        //            track()
        //        }
        //    }
        //    track()
        //
        person.age += 1
        try await task.value
        //    print(lattice.object(Person.self, primaryKey: 2)?.age)
    }
    
    @Test func testLattice_ResultsQuery() async throws {
        let lattice = try Lattice(Person.self)
        var persons = lattice.objects(Person.self)
        lattice.delete(Person.self)
        let person1 = Person()
        let person2 = Person()
        let person3 = Person()
        person1.name = "John"
        person1.age = 30
        person2.name = "Jane"
        person2.age = 25
        person3.name = "Tim"
        person3.age = 22
        
        #expect(persons.count == 0)
        
        lattice.add(person1)
        lattice.add(person2)
        lattice.add(person3)
        
        #expect(persons.count == 3)
        
        persons = persons.where {
            $0.name == "John" || $0.name == "Jane"
        }
        
        #expect(persons.count == 2)
    }
    
    @Test func testLattice_ResultsQueryInt() async throws {
        let lattice = try Lattice(Person.self)
        var persons = lattice.objects(Person.self)
        lattice.delete(Person.self)
        let person1 = Person()
        let person2 = Person()
        let person3 = Person()
        person1.name = "John"
        person1.age = 30
        person2.name = "Jane"
        person2.age = 25
        person3.name = "Tim"
        person3.age = 22
        
        #expect(persons.count == 0)
        
        lattice.add(person1)
        lattice.add(person2)
        lattice.add(person3)
        
        #expect(persons.count == 3)
        
        persons = persons.where {
            $0.age.in(25...30)
        }
        
        #expect(persons.count == 2)
    }
    
    @Test func testNameForKeyPath() async throws {
        let keyPath: KeyPath<Person, String> = \Person.name
        #expect(Person._nameForKeyPath(keyPath) == "name")
        #expect(Person._nameForKeyPath(\Person.age) == "age")
    }
    
    @Test func testLattice_ObservableRegistrar() async throws {
        let lattice = try Lattice(Person.self)
        autoreleasepool {
            let person = Person()
            lattice.add(person)
            #expect(Lattice.observationRegistrar.count == 1)
            #expect(Lattice.observationRegistrar[Person.entityName]?.count == 1)
        }
        #expect(Lattice.observationRegistrar.count == 1) // Person table stays
        #expect(Lattice.observationRegistrar[Person.entityName]?.count == 0) // Person object is reaped
    }
    
    @Test func testResults_Observe() async throws {
        let lattice = try Lattice(Person.self)
        
        var insertHitCount = 0
        var deleteHitCount = 0
        
        let person = Person()
        var checkedContinuation: CheckedContinuation<Void, Never>?
        let block = { (change: Results<Person>.CollectionChange) -> Void in
            switch change {
            case .insert(_):
                // TODO: Primary Key is not set yet for the added object
                // TODO: when the observer is hit. This is out of step.
                //            #expect(inserted.primaryKey == person.primaryKey)
                insertHitCount += 1
            case .delete(_):
                deleteHitCount += 1
            }
            checkedContinuation?.resume()
        }
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            let cancellable = lattice.objects(Person.self).observe(block)
            autoreleasepool {
                lattice.add(person)
            }
        }
        #expect(insertHitCount == 1)
        #expect(deleteHitCount == 0)
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            let cancellable = lattice.objects(Person.self).observe(block)
            autoreleasepool {
                _ = lattice.delete(person)
            }
        }
        #expect(insertHitCount == 1)
        #expect(deleteHitCount == 1)
        person.age = 100
        person.name = "Test_Name"
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            let cancellable = lattice.objects(Person.self)
                .where({
                    $0.name == person.name
                })
                .observe(block)
            let cancellable2 = lattice.objects(Person.self)
                .where({
                    $0.name != person.name
                })
                .observe { change in
                    insertHitCount += 1
                }
            autoreleasepool {
                lattice.add(person)
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(insertHitCount == 2)
        
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            let cancellable = lattice.objects(Person.self)
                .where({
                    $0.name == person.name
                })
                .observe(block)
            let cancellable2 = lattice.objects(Person.self)
                .where({
                    $0.name != person.name
                })
                .observe { change in
                    deleteHitCount += 1
                }
            autoreleasepool {
                lattice.delete(person)
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(deleteHitCount == 2)
    }
    
    @Test func test_Embedded() async throws {
        let lattice = try Lattice(ModelWithEmbeddedModelObject.self)
        let object = ModelWithEmbeddedModelObject()
        object.bar = .init(bar: "hi")
        lattice.add(object)
        let objects = lattice.objects(ModelWithEmbeddedModelObject.self).where {
            $0.bar.bar == "hi"
        }
        #expect(objects.count > 0)
        for object in objects {
            #expect(object.bar?.bar == "hi")
        }
    }
    
    @Test func test_ConvertQueryToEmbedded() async throws {
        let p: LatticePredicate<Person> = {
            $0.name == "John"
        }
        var query = p(Query<Person>())
        print(query.convertKeyPathsToEmbedded(rootPath: "root").predicate)
    }
}
