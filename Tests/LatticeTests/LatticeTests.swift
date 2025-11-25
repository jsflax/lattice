import Testing
import Foundation
//import SwiftUI
import Lattice
import Observation


fileprivate let base64 = Array<UInt8>(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
)
/// Generate a random string of base64 filename safe characters.
///
/// - Parameters:
///   - length: The number of characters in the returned string.
/// - Returns: A random string of length `length`.
fileprivate func createRandomString(length: Int) -> String {
  return String(
    decoding: (0..<length).map{
      _ in base64[Int.random(in: 0..<64)]
    },
    as: UTF8.self
  )
}

extension String {
    static func random(length: Int) -> String {
        createRandomString(length: length)
    }
}

@Model final class Person {
    var name: String
    var age: Int
    
    var friend: Person?
    var dog: Dog?
}

@Model final class PersonWithDogs {
    var name: String
    var age: Int
    
    var dogs: List<Dog>
}

@Model class Dog {
    var name: String
    var puppies: List<Dog>
}

struct Embedded: EmbeddedModel {
    var bar: String = ""
}

@Model class ModelWithEmbeddedModelObject {
    var foo: String
    var bar: Embedded?
}

@Model class ModelWithNonNullEmbeddedModelObject {
    var foo: String
    var bar: Embedded = Embedded(bar: "hey")
}

@Model final class AllTypesObject {
    var data: Data
}


@Model class Grandparent {
    var name: String
}

@Model class Parent {
    var name: String
    var grandparent: Grandparent?
    @Relation(link: \Child.parent)
    var children: Results<Child>
}

@Model class ModelWithConstraints {
    @Unique()
    var name: String
    
    @Unique(compoundedWith: \Self.date, \.email, allowsUpsert: true)
    var age: Int
    var date: Date
    var email: String
}

//@Model class ParentWithChildren {
//    var name: String
//    @Relation(link: \Child.parent)
//    var children: Results<Child>
//}

@Model class Child {
    var name: String
    var parent: Parent?
}


func testLattice(isolation: isolated (any Actor)? = #isolation,
                 path: String,
                 _ types: any Model.Type...) throws -> Lattice {
    try Lattice(for: types, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
}

@Suite("Lattice Tests") class LatticeTests {
    private let path: String = "\(String.random(length: 32)).sqlite"
    
    deinit {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
    }
    
    init() throws {
        print("Lattice path: \(FileManager.default.temporaryDirectory.appending(path: path))")
//        Lattice.defaultConfiguration.fileURL = FileManager.default.temporaryDirectory.appending(path: path)
    }
    
    private func removeDB() {
        
    }
    
    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        let manager = try testLattice(path: path, Person.self)
        let person = Person()
        person.name = "John"
        person.age = 30
        manager.add(person)
        
        person.age = 31
        print(person)
    }
    
//    @Test func testLattice_Objects() async throws {
//        let lattice = try testLattice(path: path, Person.self)
//        let persons = lattice.objects(Person.self)
//        
//        let person = persons[0]
//        print(person.age)
//        //    @Sendable func track() {
//        //        withObservationTracking {
//        //            print("Tracking age: \(person.age)")
//        //        } onChange: {
//        //            print("Change")
//        //            print(person.age)
//        //            track()
//        //        }
//        //    }
//        //    track()
//        person.age += 1
//        //    print(lattice.object(Person.self, primaryKey: 2)?.age)
//    }
    
    
//    @Test func testLattice_Objects_MultipleConnections() async throws {
//        let lattice = try testLattice(path: path, Person.self)
//        let task = Task.detached {
//            let lattice2 = try testLattice(path: path, Person.self)
//            try await Task.sleep(for: .seconds(10))
//        }
//        let persons = lattice.objects(Person.self)
//        
//        let person = persons[0]
//        print(person.age)
//        //    @Sendable func track() {
//        //        withObservationTracking {
//        //            print("Tracking age: \(person.age)")
//        //        } onChange: {
//        //            print("Change")
//        //            print(person.age)
//        //            track()
//        //        }
//        //    }
//        //    track()
//        //
//        person.age += 1
//        try await task.value
//        //    print(lattice.object(Person.self, primaryKey: 2)?.age)
//    }
//    
    @Test func testLattice_ResultsQuery() async throws {
        let lattice = try testLattice(path: path, Person.self)
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
        let lattice = try testLattice(path: path, Person.self)
        let persons = lattice.objects(Person.self)
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
    }
    
    @Test func testNameForKeyPath() async throws {
        let keyPath: KeyPath<Person, String> = \Person.name
        #expect(Person._nameForKeyPath(keyPath) == "name")
        #expect(Person._nameForKeyPath(\Person.age) == "age")
    }
    
    @Test func testLattice_ObservableRegistrar() async throws {
        let path = self.path
        Task {
            let lattice = try Lattice(for: [Person.self], configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
            let person = Person()
            lattice.add(person)
            person.dog = .init()
            person.dog?.name = "Spot"
            #expect(lattice.dbPtr.observationRegistrar.count == 2)
            #expect(lattice.dbPtr.observationRegistrar[Person.entityName]?.count == 1)
        }
    }
    
    public class AtomicInteger: @unchecked Sendable {

        private let lock = DispatchSemaphore(value: 1)
        private var value = 0

        // You need to lock on the value when reading it too since
        // there are no volatile variables in Swift as of today.
        public func get() -> Int {

            lock.wait()
            defer { lock.signal() }
            return value
        }

        public func set(_ newValue: Int) {

            lock.wait()
            defer { lock.signal() }
            value = newValue
        }

        public func incrementAndGet() -> Int {

            lock.wait()
            defer { lock.signal() }
            value += 1
            return value
        }
        
        public static func +=(lhs: AtomicInteger, rhs: Int) {
            lhs.set(lhs.get() + rhs)
        }
        
        public static func ==(lhs: AtomicInteger, rhs: Int) -> Bool {
            lhs.get() == rhs
        }
    }
    class Unsafe<T>: @unchecked Sendable {
        var value: T?
        init(_ value: T? = nil) {
            self.value = value
        }
    }
    
    @Test(.timeLimit(.minutes(1))) func testResults_Observe() async throws {
        let lattice = try testLattice(path: path, Person.self, Dog.self)

        var insertHitCount = 0
        var deleteHitCount = 0

        let person = Person()
        person.name = "Test"
        var checkedContinuation: CheckedContinuation<Void, Never>?
        let block = { (change: Results<Person>.CollectionChange) -> Void in
            switch change {
            case .insert(let id):
                #expect(lattice.object(Person.self, primaryKey: id)?.name == person.name)
                insertHitCount += 1
            case .delete(_):
                deleteHitCount += 1
            }
            checkedContinuation?.resume()
        }
        var cancellable: AnyCancellable?
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            cancellable = lattice.objects(Person.self).observe(block)
            autoreleasepool {
                lattice.add(person)
            }
        }
        cancellable?.cancel()
        #expect(insertHitCount == 1)
        #expect(deleteHitCount == 0)
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            cancellable = lattice.objects(Person.self).observe(block)
            autoreleasepool {
                _ = lattice.delete(person)
            }
        }
        cancellable?.cancel()
        #expect(insertHitCount == 1)
        #expect(deleteHitCount == 1)
        person.age = 100
        person.name = "Test_Name"
        var cancellable2: AnyCancellable?
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            cancellable = lattice.objects(Person.self)
                .where({ [name = person.name] in
                    $0.name == name
                })
                .observe(block)
            cancellable2 = lattice.objects(Person.self)
                .where({ [name = person.name] in
                    $0.name != name
                })
                .observe { change in
                    insertHitCount += 1
                }
            autoreleasepool {
                lattice.add(person)
            }
        }
        cancellable?.cancel()
        cancellable2?.cancel()
        try await Task.sleep(for: .milliseconds(10))
        #expect(insertHitCount == 2)

        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            cancellable = lattice.objects(Person.self)
                .where({ [name = person.name] in
                    $0.name == name
                })
                .observe(block)
            cancellable2 = lattice.objects(Person.self)
                .where({ [name = person.name] in
                    $0.name != name
                })
                .observe { change in
                    deleteHitCount += 1
                }
            _ = autoreleasepool {
                lattice.delete(person)
            }
        }
        cancellable?.cancel()
        cancellable2?.cancel()
        try await Task.sleep(for: .milliseconds(10))
        #expect(deleteHitCount == 2)
    }
    
    @Test func test_Embedded() async throws {
        try autoreleasepool {
            let lattice = try testLattice(path: path, ModelWithEmbeddedModelObject.self)
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
        let lattice = try testLattice(path: path, ModelWithNonNullEmbeddedModelObject.self)
        let object = ModelWithNonNullEmbeddedModelObject()
        object.bar = .init(bar: "hi")
        lattice.add(object)
        let objects = lattice.objects(ModelWithNonNullEmbeddedModelObject.self).where {
            $0.bar.bar == "hi"
        }
        #expect(objects.count > 0)
        for object in objects {
            #expect(object.bar.bar == "hi")
        }
    }
    
    @Test func test_ConvertQueryToEmbedded() async throws {
        let p: LatticePredicate<Person> = {
            $0.name == "John"
        }
        var query = p(Query<Person>())
        print(query.convertKeyPathsToEmbedded(rootPath: "root").predicate)
    }
    
    @Test func test_Data() async throws {
        let lattice = try testLattice(path: path, AllTypesObject.self)
        let object = AllTypesObject()
        object.data = Data([1, 2, 3])
        lattice.add(object)
        #expect(lattice.objects(AllTypesObject.self).first?.data == Data([1, 2, 3]))
    }
    
    class MigrationV1 {
        @Model class Person {
            var name: String
            var otherPerson: Person?
        }
    }
    class MigrationV2 {
        @Model class Person {
            var name: String
            var age: Int
            var city: String
        }
    }
    class MigrationV3 {
        @Model class Person {
            var name: String
            var age: Int
            var contacts: [String: String]
        }
    }
    @Test func test_Migration() async throws {
        try autoreleasepool {
            let personv1 = MigrationV1.Person()
            let lattice = try testLattice(path: path, MigrationV1.Person.self)
            lattice.add(personv1)
        }
        try autoreleasepool {
            let person = MigrationV2.Person()
            let lattice = try testLattice(path: path, MigrationV2.Person.self)
            lattice.add(person)
            #expect(person.city == "")
            person.city = "New York"
            #expect(person.city == "New York")
        }
        try autoreleasepool {
            let person = MigrationV3.Person()
            let lattice = try testLattice(path: path, MigrationV3.Person.self)
            lattice.add(person)
            person.contacts["email"] = "john@example.com"
            #expect(person.contacts["email"] == "john@example.com")
        }
    }
    
    @Test func test_Link() async throws {
        let lattice = try testLattice(path: path, Person.self, Dog.self)
        // add person with no link
        let person = Person()
        lattice.add(person)
        #expect(person.dog == nil)
        
        // add link to live object
        let dog = Dog()
        dog.name = "max"
        #expect(dog.name == "max")
        person.dog = dog
        #expect(person.dog?.name == "max")
        
        let person2 = Person()
        // add managed dog
        person2.dog = dog
        person2.dog?.name = "max"
        // check if first persons dog received the update
        #expect(person.dog?.name == "max")
        #expect(person2.dog?.name == "max")
        #expect(person.dog?.primaryKey == person2.dog?.primaryKey)
        
        lattice.add(person2)
        
        #expect(person2.dog?.name == "max")
        
        person.dog = nil
        #expect(person.dog == nil)
    }
    
    @Test func test_LinkList() async throws {
        let lattice = try testLattice(path: path, Person.self, Dog.self)
        let dog = Dog()
        let fido = Dog()
        fido.name = "fido"
        let spot = Dog()
        spot.name = "spot"
        let bella = Dog()
        bella.name = "bella"
        dog.puppies.append(contentsOf: [fido, spot, bella])
        lattice.add(dog)
        #expect(dog.puppies.count == 3)
        #expect(dog.puppies[0].name == "fido")
        #expect(dog.puppies[1].name == "spot")
        #expect(dog.puppies[2].name == "bella")
        
        dog.puppies.remove(spot)
        
        #expect(dog.puppies[0].name == "fido")
        #expect(dog.puppies[1].name == "bella")
        
        #expect(dog.puppies.count == 2)
        
        var hits = 0
        for puppy in dog.puppies {
            #expect(puppy.name != "spot")
            hits += 1
        }
        #expect(hits == 2)
        
        #expect(dog.puppies.first(where: {
            $0.name == "bella"
        })?.name == "bella")
        
        dog.puppies.remove {
            $0.name == "bella" || $0.name == "fido"
        }
        // dog.puppies.removeAll()
        
        #expect(dog.puppies.count == 0)
    }
    
    @Test func test_Relation() async throws {
        let lattice = try testLattice(path: path, Parent.self, Child.self)
        let parent = Parent()
        let children = [Child(), Child(), Child()]
        for child in children {
            child.parent = parent
            lattice.add(child)
        }

        #expect(parent.children.count == 3)
    }

    @Test func test_LinkQuery() async throws {
        let lattice = try testLattice(path: path, Parent.self, Child.self)
        let parent1 = Parent()
        let parent2 = Parent()
        lattice.add(parent1)
        lattice.add(parent2)

        let child1 = Child()
        child1.parent = parent1
        let child2 = Child()
        child2.parent = parent1
        let child3 = Child()
        child3.parent = parent2

        lattice.add(contentsOf: [child1, child2, child3])

        // Test querying by link's primary key
        let parent1PK = parent1.primaryKey!
        let childrenOfParent1 = lattice.objects(Child.self).where {
            $0.parent.primaryKey == parent1PK
        }

        #expect(childrenOfParent1.count == 2)
    }

    @Test func test_NestedLinkQuery() async throws {
        let lattice = try testLattice(path: path, Parent.self, Child.self)

        // Create parents with different names
        let parent1 = Parent()
        parent1.name = "Alice"
        let parent2 = Parent()
        parent2.name = "Bob"
        lattice.add(parent1)
        lattice.add(parent2)

        // Create children linked to parents
        let child1 = Child()
        child1.name = "Child1"
        child1.parent = parent1
        let child2 = Child()
        child2.name = "Child2"
        child2.parent = parent1
        let child3 = Child()
        child3.name = "Child3"
        child3.parent = parent2

        lattice.add(contentsOf: [child1, child2, child3])

        // Test querying by link's property (not just primaryKey)
        let childrenOfAlice = lattice.objects(Child.self).where {
            $0.parent.name == "Alice"
        }

        #expect(childrenOfAlice.count == 2)
        #expect(childrenOfAlice.contains(where: { $0.name == "Child1" }))
        #expect(childrenOfAlice.contains(where: { $0.name == "Child2" }))
    }

    @Test func test_DeeplyNestedLinkQuery() async throws {
        let lattice = try testLattice(path: path, Grandparent.self, Parent.self, Child.self)

        // Create grandparents
        let grandparent1 = Grandparent()
        grandparent1.name = "GrandpaSmith"
        let grandparent2 = Grandparent()
        grandparent2.name = "GrandpaJones"
        lattice.add(grandparent1)
        lattice.add(grandparent2)

        // Create parents linked to grandparents
        let parent1 = Parent()
        parent1.name = "Alice"
        parent1.grandparent = grandparent1
        let parent2 = Parent()
        parent2.name = "Bob"
        parent2.grandparent = grandparent2
        let parent3 = Parent()
        parent3.name = "Charlie"
        parent3.grandparent = grandparent1
        lattice.add(contentsOf: [parent1, parent2, parent3])

        // Create children linked to parents
        let child1 = Child()
        child1.name = "Child1"
        child1.parent = parent1
        let child2 = Child()
        child2.name = "Child2"
        child2.parent = parent2
        let child3 = Child()
        child3.name = "Child3"
        child3.parent = parent3
        lattice.add(contentsOf: [child1, child2, child3])

        // Test querying through multiple levels: child -> parent -> grandparent
        let smithGrandchildren = lattice.objects(Child.self).where {
            $0.parent.grandparent.name == "GrandpaSmith"
        }

        #expect(smithGrandchildren.count == 2)
        #expect(smithGrandchildren.contains(where: { $0.name == "Child1" }))
        #expect(smithGrandchildren.contains(where: { $0.name == "Child3" }))
    }

    @Test func test_BulkInsert() async throws {
        let people = (0..<1000).map { _ in Person() }
        var age = 0
        people.forEach {
            $0.age = age;
            age += 1
        }
        let lattice = try testLattice(path: path, Person.self, Dog.self)
        lattice.add(contentsOf: people)
        #expect(lattice.objects(Person.self).count == 1000)
        age = 0
        lattice.objects(Person.self).sortedBy(.init(\.age, order: .forward)).forEach {
            #expect($0.age == age)
            age += 1
        }
    }
    
    @Test func test_AuditLog_ApplyInstructions() async throws {
        let lattice1URL = FileManager.default.temporaryDirectory.appending(path: "lattice_1.sqlite")
        let lattice2URL = FileManager.default.temporaryDirectory.appending(path: "lattice_2.sqlite")
        defer {
            try? Lattice.delete(for: .init(fileURL: lattice1URL))
            try? Lattice.delete(for: .init(fileURL: lattice2URL))
        }
        let lattice1 = try Lattice(for: [Person.self, Dog.self, ModelWithEmbeddedModelObject.self],
                                   configuration: .init(fileURL: lattice1URL))
        let lattice2 = try Lattice(for: [Person.self, Dog.self, ModelWithEmbeddedModelObject.self],
                                   configuration: .init(fileURL: lattice2URL))
        
        let person = Person()
        person.name = "Jay"
        person.age = 25
        lattice1.add(person)
        
        #expect(lattice1.objects(Person.self).count == 1)
        #expect(lattice2.objects(Person.self).count == 0)
        
        #expect(lattice1.object(Person.self, primaryKey: person.primaryKey!)?.name == "Jay")
        #expect(lattice1.object(Person.self, primaryKey: person.primaryKey!)?.age == 25)
        
        let entry1 = lattice1.objects(AuditLog.self).first
        lattice2.applyInstructions(from: lattice1.objects(AuditLog.self).snapshot())
        let entry2 = lattice2.objects(AuditLog.self).first
        try #require(entry1?.__globalId == entry2?.__globalId)
        
        #expect(lattice1.objects(Person.self).count == 1)
        #expect(lattice2.objects(Person.self).count == 1)
        
        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.name == "Jay")
        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.age == 25)
        
        person.age = 30
        
        lattice2.applyInstructions(from: lattice1.objects(AuditLog.self).snapshot())
        
        #expect(lattice1.objects(Person.self).count == 1)
        #expect(lattice2.objects(Person.self).count == 1)
        
        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.name == "Jay")
        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.age == 30)
        
        // test embedded object
        
        let model = ModelWithEmbeddedModelObject()
        model.bar = .init(bar: "baz")
        
        lattice1.add(model)
        
        #expect(lattice1.objects(ModelWithEmbeddedModelObject.self).count == 1)
        #expect(lattice2.objects(ModelWithEmbeddedModelObject.self).count == 0)
        
        #expect(lattice1.object(ModelWithEmbeddedModelObject.self,
                                primaryKey: model.primaryKey!)?.bar?.bar == "baz")
//        try await Task.sleep(for: .seconds(1))
        lattice2.applyInstructions(from: lattice1.objects(AuditLog.self).snapshot())
        
        #expect(lattice1.objects(ModelWithEmbeddedModelObject.self).count == 1)
        #expect(lattice2.objects(ModelWithEmbeddedModelObject.self).count == 1)
        
        #expect(lattice2.object(ModelWithEmbeddedModelObject.self,
                                primaryKey: model.primaryKey!)?.bar?.bar == "baz")
    }
    
    @Test func testConstraints() async throws {
        var model = ModelWithConstraints()
        let lattice = try testLattice(path: path, ModelWithConstraints.self)
        
        let date = Date()
        model.name = "Jim"
        model.age = 40
        model.date = date
        model.email = "invalid"
        
        lattice.add(model)
        let globalId = model.__globalId
        
        #expect(lattice.objects(ModelWithConstraints.self).count == 1)
        
        model = ModelWithConstraints()
        model.name = "Bob"
        model.age = 40
        model.date = date
        model.email = "invalid"
        
        lattice.add(model)
        
        #expect(lattice.objects(ModelWithConstraints.self).count == 1)
        #expect(lattice.objects(ModelWithConstraints.self).first?.name == "Bob")
        #expect(lattice.objects(ModelWithConstraints.self).first?.__globalId == globalId)
        
        let modelsToAdd = [ModelWithConstraints(), ModelWithConstraints(), ModelWithConstraints()]
        modelsToAdd.enumerated().forEach { (idx, model) in
            model.name = idx == 0 ? "Bill" : idx == 1 ? "John" : idx == 2 ? "Mary" : "Unknown"
            model.age = 40
            model.date = date
            model.email = "invalid"
        }
        lattice.add(contentsOf: modelsToAdd)
        
        #expect(lattice.objects(ModelWithConstraints.self).count == 1)
        #expect(lattice.objects(ModelWithConstraints.self).first?.name == "Mary")
        #expect(lattice.objects(ModelWithConstraints.self).first?.__globalId == globalId)
    }
    
    @Test func testNestedSchemaDiscoveryForList() throws {
        let lattice = try testLattice(path: path, PersonWithDogs.self)
        let person = PersonWithDogs()
        lattice.add(person)
        person.dogs.append(Dog())
    }
    // TODO: Re-enable if we figure out publishEvents race for strong ref
//    @Test func testLatticeCache() async throws {
//        let uniquePath = "\(String.random(length: 32)).sqlite"
//        defer {
//            try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: uniquePath)))
//        }
//        try autoreleasepool {
//            var lattice1: Lattice? = try testLattice(path: uniquePath, Dog.self)
//            #expect(Lattice.latticeIsolationRegistrar.count == 1)
//            lattice1?.add(Dog())
//            var lattice2: Lattice? = try testLattice(path: uniquePath, Dog.self)
//            #expect(Lattice.latticeIsolationRegistrar.count == 1)
//            lattice1 = nil
//            #expect(Lattice.latticeIsolationRegistrar.count == 1)
//            lattice2?.add(Dog())
//            lattice2 = nil
//        }
//        // Give ARC time to clean up
//        try await Task.sleep(for: .milliseconds(10))
//        #expect(Lattice.latticeIsolationRegistrar.count == 0)
//        try await Task { @MainActor [uniquePath] in
//            var lattice1: Lattice? = try testLattice(path: uniquePath, Dog.self)
//            #expect(Lattice.latticeIsolationRegistrar.count == 1)
//            lattice1?.add(Dog())
//            var lattice2: Lattice? = try testLattice(path: uniquePath, Dog.self)
//            #expect(Lattice.latticeIsolationRegistrar.count == 1)
//            lattice1 = nil
//            #expect(Lattice.latticeIsolationRegistrar.count == 1)
//            lattice2?.add(Dog())
//            lattice2 = nil
//            // Give ARC time to clean up
//            try await Task.sleep(for: .milliseconds(10))
//            #expect(Lattice.latticeIsolationRegistrar.count == 0)
//        }.value
//    }
    
    
}
