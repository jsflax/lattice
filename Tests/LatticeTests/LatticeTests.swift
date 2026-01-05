import Testing
import Foundation
//import SwiftUI
import Lattice
import Observation
#if canImport(CoreLocation)
import CoreLocation
#endif

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
    // MARK: - String
    var string: String
    var stringOpt: String?
    var stringArray: [String]
    var stringArrayOpt: [String]?

    // MARK: - UUID
    var uuid: UUID
    var uuidOpt: UUID?

    // MARK: - URL
    var url: URL
    var urlOpt: URL?

    // MARK: - Bool
    var bool: Bool
    var boolOpt: Bool?

    // MARK: - Int64 (primary integer type with CxxManaged support)
    var int64: Int64
    var int64Opt: Int64?

    // MARK: - Float
    var float: Float
    var floatOpt: Float?

    // MARK: - Double
    var double: Double
    var doubleOpt: Double?

    // MARK: - Date
    var date: Date
    var dateOpt: Date?

    // MARK: - Data
    var data: Data
    var dataOpt: Data?

    // MARK: - Dictionary
    var dict: [String: String]
    var dictOpt: [String: String]?

    // MARK: - Embedded
    var embedded: Embedded
    var embeddedOpt: Embedded?
    var embeddedArray: [Embedded]
    var embeddedArrayOpt: [Embedded]?

#if canImport(CoreLocation)
    var customType: CLLocationCoordinate2D
    var customTypeOpt: CLLocationCoordinate2D?
    var customTypeArray: List<CLLocationCoordinate2D>
#endif
}


@Model class Grandparent {
    var name: String
}

@Model class Parent {
    var name: String
    var grandparent: Grandparent?
    @Relation(link: \Child.parent)
    var children: any Results<Child>
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

class BaseTest {
    deinit {
        paths.forEach { try? Lattice.delete(for: .init(fileURL: $0)) }
    }
    
    private var paths: [URL] = []
    
    func testLattice<each M: Model>(isolation: isolated (any Actor)? = #isolation,
                                    path: String? = nil,
                                    _ types: repeat (each M).Type,
                                    migration: [Int: Migration]? = nil) throws -> Lattice {
        let path = FileManager.default.temporaryDirectory.appending(path: path ?? "\(String.random(length: 32)).sqlite")
        paths.append(path)
        print("Lattice path: \(path)")
        return try Lattice(repeat each types, configuration: .init(fileURL: path), migration: migration)
    }
}

@Suite("Lattice Tests")
class LatticeTests: BaseTest {
    private let path: String = "\(String.random(length: 32)).sqlite"
    
//    init() throws {
//        print("Lattice path: \(FileManager.default.temporaryDirectory.appending(path: path))")
//    }
    
    private func removeDB() {
        
    }
    
    @Test func test_SimpleExample() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        let manager = try testLattice(path: path, Person.self)
        let person = Person()
        person.name = "John"
        person.age = 30
        #expect(person.age == 30)
        manager.add(person)
        
        person.age = 31
        #expect(person.age == 31)
        print(person.age)
    }
    
    @Test func test_AllTypes() async throws {
        let lattice = try testLattice(AllTypesObject.self)

        // Test values
        let testUUID = UUID()
        let testURL = URL(string: "https://example.com/path")!
        let testDate = Date(timeIntervalSince1970: 1700000000)
        let testData = Data([0x01, 0x02, 0x03, 0xAB, 0xCD])
        let emptyData = Data()

        let obj = AllTypesObject()

        // MARK: - Set all values
        // String
        obj.string = "Hello World"
        obj.stringOpt = "Optional String"
        obj.stringArray = ["one", "two", "three"]
        obj.stringArrayOpt = ["opt1", "opt2"]

        // UUID
        obj.uuid = testUUID
        obj.uuidOpt = UUID()

        // URL
        obj.url = testURL
        obj.urlOpt = URL(string: "https://optional.com")!

        // Bool
        obj.bool = true
        obj.boolOpt = false

        // Int64
        obj.int64 = 9223372036854775807
        obj.int64Opt = -9223372036854775808

        // Float
        obj.float = 3.14159
        obj.floatOpt = -2.71828

        // Double
        obj.double = 3.141592653589793
        obj.doubleOpt = -2.718281828459045

        // Date
        obj.date = testDate
        obj.dateOpt = Date(timeIntervalSince1970: 0)

        // Data
        obj.data = testData
        obj.dataOpt = emptyData

        // Dictionary
        obj.dict = ["key1": "value1", "key2": "value2"]
        obj.dictOpt = ["optKey": "optValue"]

        // Embedded
        obj.embedded = Embedded(bar: "embedded value")
        obj.embeddedOpt = Embedded(bar: "optional embedded")
        obj.embeddedArray = [Embedded(bar: "arr1"), Embedded(bar: "arr2")]
        obj.embeddedArrayOpt = [Embedded(bar: "optArr1")]

        // MARK: - Persist
        lattice.add(obj)

        // MARK: - Retrieve and verify
        let results = lattice.objects(AllTypesObject.self)
        #expect(results.count == 1)

        guard let retrieved = results.first else {
            Issue.record("No object retrieved")
            return
        }

        // String
        #expect(retrieved.string == "Hello World")
        #expect(retrieved.stringOpt == "Optional String")
        #expect(retrieved.stringArray == ["one", "two", "three"])
        #expect(retrieved.stringArrayOpt == ["opt1", "opt2"])

        // UUID
        #expect(retrieved.uuid == testUUID)
        #expect(retrieved.uuidOpt != nil)

        // URL
        #expect(retrieved.url == testURL)
        #expect(retrieved.urlOpt == URL(string: "https://optional.com")!)

        // Bool
        #expect(retrieved.bool == true)
        #expect(retrieved.boolOpt == false)

        // Int64
        #expect(retrieved.int64 == 9223372036854775807)
        #expect(retrieved.int64Opt == -9223372036854775808)

        // Float (use approximate comparison due to floating point)
        #expect(Swift.abs(retrieved.float - 3.14159) < 0.0001)
        #expect(retrieved.floatOpt != nil)
        #expect(Swift.abs(retrieved.floatOpt! - (-2.71828)) < 0.0001)

        // Double
        #expect(Swift.abs(retrieved.double - 3.141592653589793) < 0.0000001)
        #expect(retrieved.doubleOpt != nil)
        #expect(Swift.abs(retrieved.doubleOpt! - (-2.718281828459045)) < 0.0000001)

        // Date
        #expect(retrieved.date == testDate)
        #expect(retrieved.dateOpt == Date(timeIntervalSince1970: 0))

        // Data
        #expect(retrieved.data == testData)
        #expect(retrieved.dataOpt == emptyData)

        // Dictionary
        #expect(retrieved.dict == ["key1": "value1", "key2": "value2"])
        #expect(retrieved.dictOpt == ["optKey": "optValue"])

        // Embedded
        #expect(retrieved.embedded.bar == "embedded value")
        #expect(retrieved.embeddedOpt?.bar == "optional embedded")
        #expect(retrieved.embeddedArray.count == 2)
        #expect(retrieved.embeddedArray[0].bar == "arr1")
        #expect(retrieved.embeddedArrayOpt?.count == 1)

        // MARK: - Test nil optionals
        let obj2 = AllTypesObject()
        obj2.string = "test"
        obj2.uuid = UUID()
        obj2.url = URL(string: "https://test.com")!
        obj2.bool = false
        obj2.int64 = 0
        obj2.float = 0
        obj2.double = 0
        obj2.date = Date()
        obj2.data = Data()
        obj2.dict = [:]
        obj2.embedded = Embedded(bar: "")
        // Leave all optionals as nil

        lattice.add(obj2)

        let results2 = lattice.objects(AllTypesObject.self)
        #expect(results2.count == 2)

        // Find the one with nil optionals
        let nilObj = results2.first { $0.stringOpt == nil }
        #expect(nilObj != nil)
        #expect(nilObj?.uuidOpt == nil)
        #expect(nilObj?.urlOpt == nil)
        #expect(nilObj?.boolOpt == nil)
        #expect(nilObj?.int64Opt == nil)
        #expect(nilObj?.floatOpt == nil)
        #expect(nilObj?.doubleOpt == nil)
        #expect(nilObj?.dateOpt == nil)
        #expect(nilObj?.dataOpt == nil)
        #expect(nilObj?.dictOpt == nil)
        #expect(nilObj?.embeddedOpt == nil)
        #expect(nilObj?.stringArrayOpt == nil)
        #expect(nilObj?.embeddedArrayOpt == nil)
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
    
//    @Test func testLattice_ObservableRegistrar() async throws {
//        let lattice = try testLattice(path: path, Person.self)
//        let person = Person()
//        lattice.add(person)
//        person.dog = .init()
//        person.dog?.name = "Spot"
//        // Person and Dog should have observers registered
//        // (AuditLog may also have observers from audit logging - that's expected implementation detail)
//        #expect(lattice.dbPtr.observationRegistrar[Person.entityName] != nil, "Person should have observers")
//        #expect(lattice.dbPtr.observationRegistrar[Dog.entityName] != nil, "Dog should have observers")
//        #expect(lattice.dbPtr.observationRegistrar[Person.entityName]?.count == 1, "Person should have exactly 1 observer")
//    }
    
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
        let block = { (change: CollectionChange) -> Void in
            switch change {
            case .insert(let id):
                let found = lattice.object(Person.self, primaryKey: id)
                #expect(found?.name == person.name)
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
                #expect(lattice.delete(person))
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
    
    @Test
    func test_AuditLogObserve_inMemory() async throws {
        let lattice = try Lattice(Person.self, Dog.self, configuration: .init(isStoredInMemoryOnly: true))

        var insertHitCount = 0
        var deleteHitCount = 0

        let person = Person()
        person.name = "Test"
        var checkedContinuation: CheckedContinuation<Void, Never>?
        let block = { (changes: [AuditLog]) -> Void in
            for change in changes {
                switch change.operation {
                case .insert:
                    let found = lattice.object(Person.self, primaryKey: change.rowId)
                    #expect(found?.name == person.name)
                    insertHitCount += 1
                case .delete:
                    deleteHitCount += 1
                default: break
                }
            }
            checkedContinuation?.resume()
        }
        var cancellable: AnyCancellable?
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            cancellable = lattice.observe(block)
            autoreleasepool {
                lattice.add(person)
            }
        }
        cancellable?.cancel()
        #expect(insertHitCount == 1)
        #expect(deleteHitCount == 0)
    }
    
    @Test
    func test_AuditLogObserve() async throws {
        let lattice = try testLattice(path: path, Person.self, Dog.self)

        var insertHitCount = 0
        var deleteHitCount = 0

        let person = Person()
        person.name = "Test"
        var checkedContinuation: CheckedContinuation<Void, Never>?
        let block = { (changes: [AuditLog]) -> Void in
            for change in changes {
                switch change.operation {
                case .insert:
                    let found = lattice.object(Person.self, primaryKey: change.rowId)
                    #expect(found?.name == person.name)
                    insertHitCount += 1
                case .delete:
                    deleteHitCount += 1
                default: break
                }
            }
            checkedContinuation?.resume()
        }
        var cancellable: AnyCancellable?
        await withCheckedContinuation { continuation in
            checkedContinuation = continuation
            cancellable = lattice.observe(block)
            autoreleasepool {
                lattice.add(person)
            }
        }
        cancellable?.cancel()
        #expect(insertHitCount == 1)
        #expect(deleteHitCount == 0)
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
        let query = p(Query<Person>())
        print(query.convertKeyPathsToEmbedded(rootPath: "root").predicate)
    }
    
    @Test func test_Data() async throws {
        let lattice = try testLattice(AllTypesObject.self)
        let object = AllTypesObject()
        // Set required fields
        object.string = "test"
        object.uuid = UUID()
        object.url = URL(string: "https://test.com")!
        object.bool = false
        object.int64 = 0
        object.float = 0
        object.double = 0
        object.date = Date()
        object.dict = [:]
        object.embedded = Embedded(bar: "")
        // Test Data
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
        #expect(person.dog == nil)
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
    
//    @Test func test_AuditLog_ApplyInstructions() async throws {
//        let lattice1URL = FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite")
//        let lattice2URL = FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite")
//        defer {
//            try? Lattice.delete(for: .init(fileURL: lattice1URL))
//            try? Lattice.delete(for: .init(fileURL: lattice2URL))
//        }
//        let lattice1 = try Lattice(for: [Person.self, Dog.self, ModelWithEmbeddedModelObject.self],
//                                   configuration: .init(fileURL: lattice1URL))
//        let lattice2 = try Lattice(for: [Person.self, Dog.self, ModelWithEmbeddedModelObject.self],
//                                   configuration: .init(fileURL: lattice2URL))
//        
//        let person = Person()
//        person.name = "Jay"
//        person.age = 25
//        lattice1.add(person)
//        
//        #expect(lattice1.objects(Person.self).count == 1)
//        #expect(lattice2.objects(Person.self).count == 0)
//        
//        #expect(lattice1.object(Person.self, primaryKey: person.primaryKey!)?.name == "Jay")
//        #expect(lattice1.object(Person.self, primaryKey: person.primaryKey!)?.age == 25)
//        
//        let entry1 = lattice1.objects(AuditLog.self).first
//        lattice2.applyInstructions(from: lattice1.objects(AuditLog.self).snapshot())
//        let entry2 = lattice2.objects(AuditLog.self).first
//        try #require(entry1?.__globalId == entry2?.__globalId)
//        
//        #expect(lattice1.objects(Person.self).count == 1)
//        #expect(lattice2.objects(Person.self).count == 1)
//        
//        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.name == "Jay")
//        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.age == 25)
//        
//        person.age = 30
//        
//        lattice2.applyInstructions(from: lattice1.objects(AuditLog.self).snapshot())
//        
//        #expect(lattice1.objects(Person.self).count == 1)
//        #expect(lattice2.objects(Person.self).count == 1)
//        
//        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.name == "Jay")
//        #expect(lattice2.object(Person.self, primaryKey: person.primaryKey!)?.age == 30)
//        
//        // test embedded object
//        
//        let model = ModelWithEmbeddedModelObject()
//        model.bar = .init(bar: "baz")
//        
//        lattice1.add(model)
//        
//        #expect(lattice1.objects(ModelWithEmbeddedModelObject.self).count == 1)
//        #expect(lattice2.objects(ModelWithEmbeddedModelObject.self).count == 0)
//        
//        #expect(lattice1.object(ModelWithEmbeddedModelObject.self,
//                                primaryKey: model.primaryKey!)?.bar?.bar == "baz")
////        try await Task.sleep(for: .seconds(1))
//        lattice2.applyInstructions(from: lattice1.objects(AuditLog.self).snapshot())
//        
//        #expect(lattice1.objects(ModelWithEmbeddedModelObject.self).count == 1)
//        #expect(lattice2.objects(ModelWithEmbeddedModelObject.self).count == 1)
//        
//        #expect(lattice2.object(ModelWithEmbeddedModelObject.self,
//                                primaryKey: model.primaryKey!)?.bar?.bar == "baz")
//    }
    
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

    @Test func test_StringIsEmptyQuery() async throws {
        let lattice = try testLattice(AllTypesObject.self)

        // Create object with empty string
        let objEmpty = AllTypesObject()
        objEmpty.string = ""
        objEmpty.uuid = UUID()
        objEmpty.url = URL(string: "https://test.com")!
        objEmpty.bool = false
        objEmpty.int64 = 0
        objEmpty.float = 0
        objEmpty.double = 0
        objEmpty.date = Date()
        objEmpty.data = Data()
        objEmpty.dict = [:]
        objEmpty.embedded = Embedded(bar: "")

        // Create object with non-empty string
        let objFilled = AllTypesObject()
        objFilled.string = "hello"
        objFilled.uuid = UUID()
        objFilled.url = URL(string: "https://test.com")!
        objFilled.bool = false
        objFilled.int64 = 0
        objFilled.float = 0
        objFilled.double = 0
        objFilled.date = Date()
        objFilled.data = Data()
        objFilled.dict = [:]
        objFilled.embedded = Embedded(bar: "")

        lattice.add(objEmpty)
        lattice.add(objFilled)

        // Test isEmpty on non-optional string
        let emptyResults = lattice.objects(AllTypesObject.self).where {
            $0.string.isEmpty
        }
        #expect(emptyResults.count == 1)
        #expect(emptyResults.first?.string == "")

        // Test !isEmpty
        let nonEmptyResults = lattice.objects(AllTypesObject.self).where {
            !$0.string.isEmpty
        }
        #expect(nonEmptyResults.count == 1)
        #expect(nonEmptyResults.first?.string == "hello")
    }

    @Test func test_NullQuery() async throws {
        let lattice = try testLattice(AllTypesObject.self)

        // Create object with nil optional string
        let objWithNull = AllTypesObject()
        objWithNull.string = "hasNull"
        objWithNull.stringOpt = nil
        objWithNull.uuid = UUID()
        objWithNull.url = URL(string: "https://test.com")!
        objWithNull.bool = false
        objWithNull.int64 = 0
        objWithNull.float = 0
        objWithNull.double = 0
        objWithNull.date = Date()
        objWithNull.data = Data()
        objWithNull.dict = [:]
        objWithNull.embedded = Embedded(bar: "")

        // Create object with non-nil optional string
        let objWithValue = AllTypesObject()
        objWithValue.string = "hasValue"
        objWithValue.stringOpt = "I have a value"
        objWithValue.uuid = UUID()
        objWithValue.url = URL(string: "https://test.com")!
        objWithValue.bool = false
        objWithValue.int64 = 0
        objWithValue.float = 0
        objWithValue.double = 0
        objWithValue.date = Date()
        objWithValue.data = Data()
        objWithValue.dict = [:]
        objWithValue.embedded = Embedded(bar: "")

        lattice.add(objWithNull)
        lattice.add(objWithValue)

        // Test querying for null (IS NULL)
        let nullResults = lattice.objects(AllTypesObject.self).where {
            $0.stringOpt == nil
        }
        #expect(nullResults.count == 1)
        #expect(nullResults.first?.string == "hasNull")

        // Test querying for not null (IS NOT NULL)
        let notNullResults = lattice.objects(AllTypesObject.self).where {
            $0.stringOpt != nil
        }
        #expect(notNullResults.count == 1)
        #expect(notNullResults.first?.string == "hasValue")
    }

    @Test func test_ArrayIsEmptyQuery() async throws {
        let lattice = try testLattice(AllTypesObject.self)

        // Create object with empty array
        let objEmpty = AllTypesObject()
        objEmpty.string = "empty"
        objEmpty.stringArray = []
        objEmpty.uuid = UUID()
        objEmpty.url = URL(string: "https://test.com")!
        objEmpty.bool = false
        objEmpty.int64 = 0
        objEmpty.float = 0
        objEmpty.double = 0
        objEmpty.date = Date()
        objEmpty.data = Data()
        objEmpty.dict = [:]
        objEmpty.embedded = Embedded(bar: "")

        // Create object with non-empty array
        let objFilled = AllTypesObject()
        objFilled.string = "filled"
        objFilled.stringArray = ["one", "two", "three"]
        objFilled.uuid = UUID()
        objFilled.url = URL(string: "https://test.com")!
        objFilled.bool = false
        objFilled.int64 = 0
        objFilled.float = 0
        objFilled.double = 0
        objFilled.date = Date()
        objFilled.data = Data()
        objFilled.dict = [:]
        objFilled.embedded = Embedded(bar: "")

        lattice.add(objEmpty)
        lattice.add(objFilled)

        // Test isEmpty query
        let emptyResults = lattice.objects(AllTypesObject.self).where {
            $0.stringArray.isEmpty
        }
        #expect(emptyResults.count == 1)
        #expect(emptyResults.first?.string == "empty")

        // Test !isEmpty query (non-empty arrays)
        let nonEmptyResults = lattice.objects(AllTypesObject.self).where {
            !$0.stringArray.isEmpty
        }
        #expect(nonEmptyResults.count == 1)
        #expect(nonEmptyResults.first?.string == "filled")

        // Test count query
        let countResults = lattice.objects(AllTypesObject.self).where {
            $0.stringArray.count == 3
        }
        #expect(countResults.count == 1)
        #expect(countResults.first?.string == "filled")

        // Test count > 0 (alternative to !isEmpty)
        let countGreaterThanZero = lattice.objects(AllTypesObject.self).where {
            $0.stringArray.count > 0
        }
        #expect(countGreaterThanZero.count == 1)
        #expect(countGreaterThanZero.first?.string == "filled")
    }
    @Test func test_QueryByGlobalId() async throws {
        let lattice = try testLattice(Person.self)

        // Create and add some objects
        let person1 = Person()
        person1.name = "Alice"
        person1.age = 30

        let person2 = Person()
        person2.name = "Bob"
        person2.age = 25

        lattice.add(person1)
        lattice.add(person2)

        // Get the globalId of person1
        let globalId = person1.__globalId
        #expect(globalId != nil, "globalId should be set after adding to lattice")

        // Query by globalId
        let results = lattice.objects(Person.self).where {
            $0.__globalId == globalId
        }

        #expect(results.count == 1)
        #expect(results.first?.name == "Alice")
        #expect(results.first?.__globalId == globalId)
    }

    protocol POI: VirtualModel {
        var name: String { get }
        var country: String { get }
    }
    
    @Model class Restaurant: POI {
        var name: String
        var country: String
        
        init(name: String, country: String) {
            self.name = name
            self.country = country
        }
    }
    
    @Model class Museum: POI {
        var name: String
        var country: String
        var exhibitCount: Int

        init(name: String, country: String, exhibitCount: Int = 0) {
            self.name = name
            self.country = country
            self.exhibitCount = exhibitCount
        }
    }
    
    @Test func test_Attach() {
        var lattice1 = try! testLattice(Restaurant.self, Person.self)
        let lattice2 = try! testLattice(Museum.self)

        let museum = Museum(name: "The Louvre", country: "France")
        let restaurant = Restaurant(name: "Le Bernardin", country: "United States")

        lattice1.add(restaurant)
        lattice2.add(museum)

        lattice1.attach(lattice: lattice2)

        #expect(lattice1.objects(Museum.self).count == 1)
        #expect(lattice1.objects(Restaurant.self).count == 1)

        #expect(lattice1.objects(POI.self).count == 2)

        var results = lattice1.objects(POI.self)
        results = results.where {
            $0.country == "France"
        }
        #expect(results.count == 1)
        guard let hydratedMuseum = results.first as? Museum else {
            return #expect(Bool(false), "Should have been a museum")
        }
        #expect(museum == hydratedMuseum)
    }

    // MARK: - Group By Tests

    @Model final class Listing {
        var title: String
        var destination: String
        var price: Int

        convenience init(title: String, destination: String, price: Int) {
            self.init()
            self.title = title
            self.destination = destination
            self.price = price
        }
    }

    @Test func test_GroupBy_Basic() async throws {
        let lattice = try testLattice(Listing.self)

        // Add listings with duplicate destinations
        lattice.add(Listing(title: "Beach House", destination: "Hawaii", price: 200))
        lattice.add(Listing(title: "Mountain Cabin", destination: "Colorado", price: 150))
        lattice.add(Listing(title: "Surf Shack", destination: "Hawaii", price: 100))
        lattice.add(Listing(title: "Ski Lodge", destination: "Colorado", price: 300))
        lattice.add(Listing(title: "City Loft", destination: "New York", price: 250))

        // Without group by - should get all 5
        let allListings = lattice.objects(Listing.self).snapshot()
        #expect(allListings.count == 5)

        // With group by destination - should get 3 unique destinations
        let grouped = lattice.objects(Listing.self).group(by: \.destination).snapshot()
        #expect(grouped.count == 3)

        // Verify we got one from each destination
        let destinations = Set(grouped.map { $0.destination })
        #expect(destinations == Set(["Hawaii", "Colorado", "New York"]))
    }

    @Test func test_GroupBy_Count() async throws {
        let lattice = try testLattice(Listing.self)

        lattice.add(Listing(title: "A", destination: "Hawaii", price: 100))
        lattice.add(Listing(title: "B", destination: "Hawaii", price: 200))
        lattice.add(Listing(title: "C", destination: "Colorado", price: 150))
        lattice.add(Listing(title: "D", destination: "Colorado", price: 250))
        lattice.add(Listing(title: "E", destination: "Colorado", price: 350))

        // Count without group by
        #expect(lattice.objects(Listing.self).count == 5)

        // Count with group by - should be COUNT(DISTINCT destination) = 2
        #expect(lattice.objects(Listing.self).group(by: \.destination).count == 2)
    }

    @Test func test_GroupBy_WithWhere() async throws {
        let lattice = try testLattice(Listing.self)

        lattice.add(Listing(title: "Cheap Hawaii", destination: "Hawaii", price: 50))
        lattice.add(Listing(title: "Expensive Hawaii", destination: "Hawaii", price: 500))
        lattice.add(Listing(title: "Cheap Colorado", destination: "Colorado", price: 75))
        lattice.add(Listing(title: "Expensive Colorado", destination: "Colorado", price: 400))
        lattice.add(Listing(title: "Mid New York", destination: "New York", price: 200))

        // Filter to expensive listings (price > 100), then group by destination
        let expensiveGrouped = lattice.objects(Listing.self)
            .where { $0.price > 100 }
            .group(by: \.destination)
            .snapshot()

        // Should get 3 destinations (Hawaii, Colorado, New York all have listings > 100)
        #expect(expensiveGrouped.count == 3)

        // Filter to cheap listings (price < 100), then group by destination
        let cheapGrouped = lattice.objects(Listing.self)
            .where { $0.price < 100 }
            .group(by: \.destination)
            .snapshot()

        // Only Hawaii and Colorado have cheap listings
        #expect(cheapGrouped.count == 2)
    }

    @Test func test_GroupBy_WithSort() async throws {
        let lattice = try testLattice(Listing.self)

        lattice.add(Listing(title: "Z Hawaii", destination: "Hawaii", price: 100))
        lattice.add(Listing(title: "A Colorado", destination: "Colorado", price: 200))
        lattice.add(Listing(title: "M New York", destination: "New York", price: 150))

        // Group by destination, sorted by title ascending
        let sorted = lattice.objects(Listing.self)
            .group(by: \.destination)
            .sortedBy(.init(\.title, order: .forward))
            .snapshot()

        #expect(sorted.count == 3)
        // Should be sorted: A Colorado, M New York, Z Hawaii
        #expect(sorted[0].title == "A Colorado")
        #expect(sorted[1].title == "M New York")
        #expect(sorted[2].title == "Z Hawaii")
    }

    @Test func test_GroupBy_EmptyResults() async throws {
        let lattice = try testLattice(Listing.self)

        // No data - group by should return empty
        let grouped = lattice.objects(Listing.self).group(by: \.destination).snapshot()
        #expect(grouped.isEmpty)
        #expect(lattice.objects(Listing.self).group(by: \.destination).count == 0)
    }

    @Test func test_GroupBy_AllSameValue() async throws {
        let lattice = try testLattice(Listing.self)

        // All listings have the same destination
        lattice.add(Listing(title: "A", destination: "Hawaii", price: 100))
        lattice.add(Listing(title: "B", destination: "Hawaii", price: 200))
        lattice.add(Listing(title: "C", destination: "Hawaii", price: 300))

        let grouped = lattice.objects(Listing.self).group(by: \.destination).snapshot()
        #expect(grouped.count == 1)
        #expect(grouped.first?.destination == "Hawaii")
    }

    @Test func test_GroupBy_AllUniqueValues() async throws {
        let lattice = try testLattice(Listing.self)

        // All listings have unique destinations
        lattice.add(Listing(title: "A", destination: "Hawaii", price: 100))
        lattice.add(Listing(title: "B", destination: "Colorado", price: 200))
        lattice.add(Listing(title: "C", destination: "New York", price: 300))

        let grouped = lattice.objects(Listing.self).group(by: \.destination).snapshot()
        #expect(grouped.count == 3) // Same as ungrouped
    }

    @Test func test_GroupBy_Chaining() async throws {
        let lattice = try testLattice(Listing.self)

        lattice.add(Listing(title: "A", destination: "Hawaii", price: 50))
        lattice.add(Listing(title: "B", destination: "Hawaii", price: 150))
        lattice.add(Listing(title: "C", destination: "Colorado", price: 200))
        lattice.add(Listing(title: "D", destination: "Colorado", price: 250))
        lattice.add(Listing(title: "E", destination: "New York", price: 300))

        // Chain: where -> group -> sort
        let result = lattice.objects(Listing.self)
            .where { $0.price > 100 }
            .group(by: \.destination)
            .sortedBy(.init(\.destination, order: .forward))
            .snapshot()

        #expect(result.count == 3)
        #expect(result[0].destination == "Colorado")
        #expect(result[1].destination == "Hawaii")
        #expect(result[2].destination == "New York")
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


