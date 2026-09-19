import Foundation
import Testing
@testable import Lattice

private final class ConstructionEvents: @unchecked Sendable {
    static let shared = ConstructionEvents()
    private let lock = NSLock()
    private var events: [String] = []

    func record<T>(_ name: String, _ value: T) -> T {
        lock.lock()
        events.append(name)
        lock.unlock()
        return value
    }

    func take() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let result = events
        events.removeAll()
        return result
    }
}

@Model private final class ConstructionDefaultItem {
    var rank: Int = ConstructionEvents.shared.record("rank", 7)
    var title: String = ConstructionEvents.shared.record("title", "default")
    var body: String = ConstructionEvents.shared.record("body", "body")
    var accessCount: Int = ConstructionEvents.shared.record("accessCount", 2)
    var lastAccessed: Date = ConstructionEvents.shared.record("lastAccessed", Date(timeIntervalSince1970: 5))
    var pinned: Bool = ConstructionEvents.shared.record("pinned", true)
}

// A manual conformer exercises the required initializer, including reading and
// mutating defaults before Model.init(dynamicObject:) replaces its storage.
#if canImport(Combine)
private typealias ConstructionPublisher = Combine.ObservableObjectPublisher
#else
private typealias ConstructionPublisher = ObservableObjectPublisher
#endif

private final class ConstructionCustomItem: Model {
    static var entityName: String { "ConstructionCustomItem" }
    static var properties: [(String, any SchemaProperty.Type)] {
        let properties: [(String, any SchemaProperty.Type)] = [("rank", Int.self)]
        return ConstructionEvents.shared.record("schema", properties)
    }
    static var constraints: [Constraint] { [] }
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String { "rank" }
    var _dynamicObject: ModelStorage
    var _lastKeyPathUsed: String?
    var _instanceObservers: [_ModelObserver] = []
    let _objectWillChange = ConstructionPublisher()
    private var registrar: Any?
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    var _$observationRegistrar: Observation.ObservationRegistrar {
        registrar as! Observation.ObservationRegistrar
    }
    func _objectWillChange_send() { _objectWillChange.send() }
    func _triggerObservers_send(keyPath: String) {}
    var primaryKey: Int64? {
        get { Int64?.getField(from: _dynamicObject, named: "id") }
        set { Int64?.setField(on: &_dynamicObject, named: "id", newValue) }
    }
    var globalId: UUID? { UUID?.getField(from: _dynamicObject, named: "globalId") }
    var rank: Int {
        get { Int.getField(from: _dynamicObject, named: "rank") }
        set { Int.setField(on: &_dynamicObject, named: "rank", newValue) }
    }
    init(isolation: isolated (any Actor)? = #isolation) {
        _dynamicObject = ModelStorage._default(Self.self)
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
            registrar = Observation.ObservationRegistrar()
        }
        _ = ConstructionEvents.shared.record("custom-init-default-\(rank)", 0)
        rank = 13
    }
    deinit { _deregisterFromInstanceRegistry() }
}

@Suite("Unmanaged construction semantics", .serialized)
struct UnmanagedConstructionTests {
    private let defaultEvents = ["rank", "title", "body", "accessCount", "lastAccessed", "pinned"]

    @Test func freshModelsEvaluateEveryDefaultOnceAndKeepIndependentStorage() {
        _ = ConstructionEvents.shared.take()
        let first = ConstructionDefaultItem()
        let second = ConstructionDefaultItem()
        #expect(ConstructionEvents.shared.take() == defaultEvents + defaultEvents)
        #expect(first.rank == 7 && second.rank == 7)
        first.rank = 99
        first.title = "changed"
        #expect(second.rank == 7 && second.title == "default")
        #expect(second.body == "body" && second.accessCount == 2)
        #expect(second.lastAccessed == Date(timeIntervalSince1970: 5) && second.pinned)
        #expect(!first.isManaged && !second.isManaged)
    }

    @Test func hydrationRunsDefaultsAndPreservesSixLiveGetters() throws {
        let db = try Lattice(ConstructionDefaultItem.self, configuration: .init(storage: .memory()))
        defer { db.close() }
        var id: Int64 = 0
        do {
            let seed = ConstructionDefaultItem()
            seed.rank = 21
            seed.title = "stored"
            seed.body = "stored body"
            seed.accessCount = 22
            seed.lastAccessed = Date(timeIntervalSince1970: 23)
            seed.pinned = false
            try db.add(seed)
            id = try #require(seed.primaryKey)
        }
        let row = try #require(db.backend.objects(
            table: ConstructionDefaultItem.entityName, where: nil, orderBy: nil,
            limit: 1, offset: nil, groupBy: nil, distinctBy: nil).first)
        try #require(row._queryRowValue(named: "rank") == .int64(21))
        _ = ConstructionEvents.shared.take()
        var model: ConstructionDefaultItem? = ConstructionDefaultItem(dynamicObject: row)
        #expect(ConstructionEvents.shared.take() == defaultEvents)
        #expect(model?.rank == 21 && model?.title == "stored" && model?.body == "stored body")
        #expect(model?.accessCount == 22 && model?.lastAccessed == Date(timeIntervalSince1970: 23))
        #expect(model?.pinned == false)
        #expect(row._queryRowValue(named: "rank") == nil)
        #expect(model?.isMaterialized == false)

        row.setInt(named: "rank", 31)
        row.setString(named: "title", "live")
        row.setString(named: "body", "live body")
        row.setInt(named: "accessCount", 32)
        row.setDouble(named: "lastAccessed", 33)
        row.setBool(named: "pinned", true)
        #expect(model?.rank == 31 && model?.title == "live" && model?.body == "live body")
        #expect(model?.accessCount == 32 && model?.lastAccessed == Date(timeIntervalSince1970: 33))
        #expect(model?.pinned == true)

        // Registration keeps identity available without retaining the model.
        let path = db.backend.path
        #expect(ModelInstanceRegistry.shared._liveInstanceCount(
            databasePath: path, tableName: ConstructionDefaultItem.entityName, primaryKey: id) == 1)
        weak var weakModel = model
        model = nil
        #expect(weakModel == nil)
        #expect(ModelInstanceRegistry.shared._liveInstanceCount(
            databasePath: path, tableName: ConstructionDefaultItem.entityName, primaryKey: id) == 0)
    }

    @Test func hydrationCallsCustomRequiredInitializerBeforeReplacingStorage() throws {
        let db = try Lattice(ConstructionCustomItem.self, configuration: .init(storage: .memory()))
        defer { db.close() }
        let seed = ConstructionCustomItem()
        seed.rank = 42
        try db.add(seed)
        let id = try #require(seed.primaryKey)
        let row = try #require(db.backend.object(primaryKey: id, table: ConstructionCustomItem.entityName))
        _ = ConstructionEvents.shared.take()
        let model = ConstructionCustomItem(dynamicObject: row)
        #expect(ConstructionEvents.shared.take() == ["schema", "custom-init-default-0"])
        #expect(model.rank == 42, "Initializer mutation must precede the managed storage swap")
        #expect(row.getInt(named: "rank") == 42, "Defaults must never be written into the fetched row")
        #expect(model.primaryKey == id)
        #expect(!model.isMaterialized)
    }
}
