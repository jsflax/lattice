import Testing
import SwiftUICore
import Lattice
import Observation

@Model final class Person {
    var name: String
    var age: Int
    
    var friend: Person?
    var dog: Dog?
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
    var bar: Embedded
}

@Model final class AllTypesObject {
    var data: Data
}


@Model class Parent {
    var name: String
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

@Suite("Lattice Tests") class LatticeTests {
    deinit {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "lattice.sqlite")))
    }
    
    init() throws {
        Lattice.defaultConfiguration.fileURL = FileManager.default.temporaryDirectory.appending(path: "lattice.sqlite")
    }
    
    private func removeDB() {
        
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
    
//    @Test func testLattice_Objects() async throws {
//        let lattice = try Lattice(Person.self)
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
//        let lattice = try Lattice(Person.self)
//        let task = Task.detached {
//            let lattice2 = try Lattice(Person.self)
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
        
//        persons = persons.where {
//            $0.age.in(25...30)
//        }
//        
//        #expect(persons.count == 2)
    }
    
    @Test func testNameForKeyPath() async throws {
        let keyPath: KeyPath<Person, String> = \Person.name
        #expect(Person._nameForKeyPath(keyPath) == "name")
        #expect(Person._nameForKeyPath(\Person.age) == "age")
    }
    
    @Test func testLattice_ObservableRegistrar() async throws {
        Task {
            let lattice = try Lattice(Person.self)
            let person = Person()
            lattice.add(person)
            await #expect(lattice.dbPtr.observationRegistrar.count == 2)
            await #expect(lattice.dbPtr.observationRegistrar[Person.entityName]?.count == 1)
        }
//        await #expect(lattice.dbPtr.observationRegistrar.count == 2) // Person table stays
//        await #expect(lattice.dbPtr.observationRegistrar[Person.entityName]?.count == 0) // Person object is reaped
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
    
    @Test func testResults_Observe() async throws {
        let lattice = try Lattice(Person.self, Dog.self)
        
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
                .where({ [name = person.name] in
                    $0.name == name
                })
                .observe(block)
            let cancellable2 = lattice.objects(Person.self)
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
        try await Task.sleep(for: .milliseconds(10))
        #expect(insertHitCount == 2)
        
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            let cancellable = lattice.objects(Person.self)
                .where({ [name = person.name] in
                    $0.name == name
                })
                .observe(block)
            let cancellable2 = lattice.objects(Person.self)
                .where({ [name = person.name] in
                    $0.name != name
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
        try autoreleasepool {
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
        let lattice = try Lattice(ModelWithNonNullEmbeddedModelObject.self)
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
        let lattice = try Lattice(AllTypesObject.self)
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
            let lattice = try Lattice(MigrationV1.Person.self)
            lattice.add(personv1)
        }
        try autoreleasepool {
            let person = MigrationV2.Person()
            let lattice = try Lattice(MigrationV2.Person.self)
            lattice.add(person)
            #expect(person.city == "")
            person.city = "New York"
            #expect(person.city == "New York")
        }
        try autoreleasepool {
            let person = MigrationV3.Person()
            let lattice = try Lattice(MigrationV3.Person.self)
            lattice.add(person)
            person.contacts["email"] = "john@example.com"
            #expect(person.contacts["email"] == "john@example.com")
        }
    }
    
    @Test func test_Link() async throws {
        let lattice = try Lattice(Person.self, Dog.self)
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
        let lattice = try Lattice(Person.self, Dog.self)
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
        let lattice = try Lattice(Parent.self, Child.self)
        let parent = Parent()
        let children = [Child(), Child(), Child()]
        for child in children {
            child.parent = parent
            lattice.add(child)
        }
        lattice.add(parent)
        
        #expect(parent.children.count == 3)
    }
    
    @Test func test_BulkInsert() async throws {
        let people = (0..<1000).map { _ in Person() }
        var age = 0
        people.forEach {
            $0.age = age;
            age += 1
        }
        let lattice = try Lattice(Person.self, Dog.self)
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
        let lattice1 = try Lattice(Person.self, Dog.self, ModelWithEmbeddedModelObject.self,
                                   configuration: .init(fileURL: lattice1URL))
        let lattice2 = try Lattice(Person.self, Dog.self, ModelWithEmbeddedModelObject.self,
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
        let lattice = try Lattice(ModelWithConstraints.self)
        
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
    
    @Test func testLatticeCache() async throws {
        try autoreleasepool {
            var lattice1: Lattice? = try Lattice(Dog.self)
            #expect(Lattice.latticeIsolationRegistrar.count == 1)
            lattice1?.add(Dog())
            var lattice2: Lattice? = try Lattice(Dog.self)
            #expect(Lattice.latticeIsolationRegistrar.count == 1)
            lattice1 = nil
            #expect(Lattice.latticeIsolationRegistrar.count == 1)
            lattice2?.add(Dog())
            lattice2 = nil
            #expect(Lattice.latticeIsolationRegistrar.count == 0)
        }
        try await Task { @MainActor in
            var lattice1: Lattice? = try Lattice(Dog.self)
            #expect(Lattice.latticeIsolationRegistrar.count == 1)
            lattice1?.add(Dog())
            var lattice2: Lattice? = try Lattice(Dog.self)
            #expect(Lattice.latticeIsolationRegistrar.count == 1)
            lattice1 = nil
            #expect(Lattice.latticeIsolationRegistrar.count == 1)
            lattice2?.add(Dog())
            lattice2 = nil
            #expect(Lattice.latticeIsolationRegistrar.count == 0)
        }.value
    }
    
    
}
