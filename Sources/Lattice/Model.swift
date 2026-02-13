import Foundation
import SQLite3
#if canImport(Combine)
@_exported import Combine
#endif
@_exported import LatticeSwiftCppBridge
import LatticeSwiftCppBridge
import LatticeSwiftModule
import os.lock

// MARK: - Cross-Instance Observation Registry

/// Tracks all live Model instances by (tableName, primaryKey) to enable cross-instance observation.
/// When one instance modifies a row, all other instances representing that row are notified.
final class ModelInstanceRegistry: @unchecked Sendable {
    static let shared = ModelInstanceRegistry()

    private struct InstanceKey: Hashable {
        let tableName: String
        let primaryKey: Int64
    }

    private struct WeakModelRef: @unchecked Sendable {
        weak var instance: (any Model)?
        let objectIdentifier: ObjectIdentifier

        init(_ model: any Model) {
            self.instance = model
            self.objectIdentifier = ObjectIdentifier(model)
        }
    }

    private var instances: [InstanceKey: [WeakModelRef]] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register a model instance for cross-instance observation
    func register(_ model: any Model, tableName: String) {
        guard let primaryKey = model.primaryKey else { return }
        let key = InstanceKey(tableName: tableName, primaryKey: primaryKey)
        let ref = WeakModelRef(model)
        let objectId = ObjectIdentifier(model)

        lock.lock()
        defer { lock.unlock() }

        var refs = instances[key, default: []]
        if !refs.contains(where: { $0.objectIdentifier == objectId }) {
            refs.append(ref)
        }
        refs.removeAll { $0.instance == nil }
        instances[key] = refs
    }

    /// Deregister a model instance
    func deregister(_ model: any Model, tableName: String) {
        guard let primaryKey = model.primaryKey else { return }
        let key = InstanceKey(tableName: tableName, primaryKey: primaryKey)
        let objectId = ObjectIdentifier(model)

        lock.lock()
        defer { lock.unlock() }

        instances[key]?.removeAll { $0.objectIdentifier == objectId || $0.instance == nil }
        if instances[key]?.isEmpty == true {
            instances.removeValue(forKey: key)
        }
    }

    /// Notify all instances of a row change, except the one that initiated it (if provided)
    func notifyChange(tableName: String, primaryKey: Int64, propertyName: String, excludingInstanceId: ObjectIdentifier? = nil) {
        let key = InstanceKey(tableName: tableName, primaryKey: primaryKey)

        lock.lock()
        let refs = instances[key] ?? []
        lock.unlock()

        for ref in refs {
            guard let model = ref.instance else { continue }
            if let excludeId = excludingInstanceId, ref.objectIdentifier == excludeId {
                continue
            }
            // Trigger both Combine (ObservableObject) and Observation (@Observable) systems
            model._objectWillChange_send()
            model._triggerObservers_send(keyPath: propertyName)
        }
    }
}

public enum _ModelStorage {
    case unmanaged(lattice.swift_dynamic_object)
    case managed(lattice.ManagedModel)
}

public typealias CxxLatticeObject = lattice.swift_dynamic_object
public typealias CxxManagedLatticeObject = lattice.ManagedModel
public typealias CxxManagedModel = lattice.ManagedModel
public typealias CxxManagedLink = lattice.ManagedLink
public typealias CxxManagedInt = lattice.ManagedInt
public typealias CxxDynamicObject = lattice.dynamic_object
public typealias CxxDynamicObjectRef = lattice.dynamic_object_ref


public protocol Model: AnyObject, Observable, ObservableObject, Hashable, Identifiable, SchemaProperty, CxxManaged, LatticeIsolated, LinkListable {
    init(isolation: isolated (any Actor)?)
//    var lattice: Lattice? { get set }
    static var entityName: String { get }
    static var properties: [(String, any SchemaProperty.Type)] { get }
    var primaryKey: Int64? { get set }
    var __globalId: UUID? { get }  // Unique identifier for sync across clients
    
    var _$observationRegistrar: Observation.ObservationRegistrar { get }
    func _objectWillChange_send()
    func _triggerObservers_send(keyPath: String)
    var _lastKeyPathUsed: String? { get set }
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String
    static var constraints: [Constraint] { get }
    var _objectWillChange: Combine.ObservableObjectPublisher { get }
    var _dynamicObject: ModelStorage { get set }
}

extension Model {
    package init(isolation: isolated (any Actor)? = #isolation,
                 dynamicObject: CxxDynamicObjectRef) {
        self.init(isolation: isolation)
        self._dynamicObject._ref = dynamicObject
        // Register for cross-instance observation if this object has a primaryKey
        if self.primaryKey != nil {
            ModelInstanceRegistry.shared.register(self, tableName: Self.entityName)
        }
    }
    
    public init(_ refType: CxxDynamicObjectRef) {
        self.init(dynamicObject: refType)
    }
    public static func _makeLinkList(from storage: inout ModelStorage, named name: String) -> ModelLinkListRef<Self> {
        ModelLinkListRef(_ref: storage._ref.getLinkList(named: std.string(name)))
    }
    
    public var asRefType: CxxDynamicObjectRef { self._dynamicObject._ref }
    
    public static var defaultValue: Self {
        .init(isolation: #isolation)
    }
    public static var sqlType: String { "BIGINT" }
    public static var anyPropertyKind: AnyProperty.Kind { .int }

    public var lattice: Lattice? {
        _dynamicObject._ref.lattice.map { Lattice.init(ref: $0) }
    }

    /// Called after a property mutation to notify other instances representing the same row
    public func _notifyOtherInstances(propertyName: String) {
        guard let primaryKey else { return }
        ModelInstanceRegistry.shared.notifyChange(
            tableName: Self.entityName,
            primaryKey: primaryKey,
            propertyName: propertyName,
            excludingInstanceId: ObjectIdentifier(self)
        )
    }

    /// Called from deinit to deregister from cross-instance observation
    public func _deregisterFromInstanceRegistry() {
        ModelInstanceRegistry.shared.deregister(self, tableName: Self.entityName)
    }

    public static func getField(from storage: inout ModelStorage, named name: String) -> Self {
        let model = Self(isolation: #isolation)
        model._dynamicObject._ref = storage._ref.getObject(named: std.string(name))
        return model
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        storage._ref.setObject(named: std.string(name), value._dynamicObject._ref)
    }

    public typealias ObservableObjectPublisher = AnyPublisher<Void, Never>
    
    // 3️⃣ override the protocol's publisher
    public var objectWillChange: Combine.ObservableObjectPublisher {
        _objectWillChange
    }
    
    public var id: some Hashable {
        if let primaryKey {
            AnyHashable(primaryKey)
        } else {
            AnyHashable(ObjectIdentifier(self))
        }
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(primaryKey)
        hasher.combine(ObjectIdentifier(self))
    }
    
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        if lhs.primaryKey != nil {
            lhs.primaryKey == rhs.primaryKey
        } else {
            lhs === rhs
        }
    }
    typealias SwiftSchema = lattice.SwiftSchema
    
    internal static func cxxPropertyDescriptor() -> lattice.SwiftSchema {
        var schema = SwiftSchema()
        // Filter out id and globalId - these are auto-added by C++
        let filteredProperties = properties.filter { $0.0 != "id" && $0.0 != "globalId" }

        let primitiveProperties: [(String, any PrimitiveProperty.Type)] = filteredProperties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let linkProperties: [(String, any LinkProperty.Type)] = filteredProperties.compactMap {
            if let primitiveType = $0.1 as? (any LinkProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let geoProperties: [(String, any GeoboundsProperty.Type)] = filteredProperties.compactMap {
            if let geotype = $0.1 as? (any GeoboundsProperty.Type) {
                return ($0.0, geotype)
            }
            return nil
        }
        
        for (name, property) in geoProperties {
            // Check if this is a geo_bounds list (List<CLLocationCoordinate2D>, etc.)
            let isGeoBoundsList = property is (any ListProperty.Type)
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: isGeoBoundsList ? .list : .primitive,
                                             target_table: .init(),
                                             link_table: .init(),
                                             nullable: property is (any OptionalProtocol.Type),
                                             is_vector: false, is_geo_bounds: true)
        }
        
        for (name, property) in primitiveProperties {
            // Map Swift property kind to C++ column_type
            let columnType: lattice.column_type = switch property.anyPropertyKind {
            case .int, .int64: .integer
            case .float, .double, .date: .real
            case .data: .blob
            case .string, .null: .text
            }
            // Check if this is a Vector type for automatic vec0 indexing
            let isVector = property is Vector<Float>.Type || property is Vector<Double>.Type
            schema[std.string(name)] = .init(name: std.string(name), type: columnType, kind: .primitive,
                                             target_table: .init(), link_table: .init(),
                                             nullable: property is (any OptionalProtocol.Type),
                                             is_vector: isVector, is_geo_bounds: false)
        }

        for (name, property) in linkProperties {
            let isVector = property is (any ListProperty.Type)
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: isVector ? .list : .link,
                                             target_table: std.string(property.modelType.entityName),
                                             link_table: .init(Self.entityName),
                                             nullable: true, is_vector: isVector, is_geo_bounds: false)
        }

        return schema
    }
    
    // Default CxxManaged stubs for Model types (so macros don't need to generate them)
    public typealias CxxManagedSpecialization = CxxManagedModel

    public static func fromCxxValue(_ value: CxxManagedModel.SwiftType) -> Self {
        fatalError()
    }

    public static func getManaged(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedModel {
        fatalError()
    }

    public static func getManagedOptional(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedModel.OptionalType {
        object.get_managed_field(name)
    }

    public static var defaultCxxLatticeObject: CxxDynamicObject {
        CxxDynamicObject(CxxLatticeObject(std.string(entityName), cxxPropertyDescriptor()))
    }
}

public func _defaultCxxLatticeObject<M>(_ model: M.Type) -> CxxDynamicObject where M: Model {
    CxxDynamicObject(CxxLatticeObject(std.string(M.entityName), M.cxxPropertyDescriptor()))
}

extension Model {
    public var debugDescription: String {
        String(_dynamicObject._ref.debug_description())
    }
}

func _name<T>(for keyPath: PartialKeyPath<T>) -> String where T: Model {
    let t = T(isolation: #isolation)
    _ = t[keyPath: keyPath]
    return t._lastKeyPathUsed ?? "id"
}

@attached(member, names: arbitrary)
@attached(extension, conformances: Model, names: arbitrary)
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "LatticeMacros",
                                      type: "ModelMacro")

@attached(extension, conformances: LatticeEnum, names: arbitrary)
public macro LatticeEnum() = #externalMacro(module: "LatticeMacros",
                                            type: "EnumMacro")

@attached(member, conformances: EmbeddedModel, names: arbitrary)
public macro EmbeddedModel() = #externalMacro(module: "LatticeMacros",
                                              type: "EmbeddedModelMacro")

@attached(member, names: arbitrary)
@attached(extension, conformances: Codable, names: arbitrary)
public macro Codable() = #externalMacro(module: "LatticeMacros",
                                        type: "CodableMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "LatticeMacros",
                                      type: "TransientMacro")


@attached(accessor, names: arbitrary)
public macro Property(name mappedTo: String? = nil) = #externalMacro(module: "LatticeMacros",
                                                                     type: "PropertyMacro")


@attached(peer)
public macro Unique<T>(compoundedWith: PartialKeyPath<T>...,
                       allowsUpsert: Bool = false) = #externalMacro(module: "LatticeMacros",
                                                           type: "UniqueMacro")

@attached(peer)
public macro Unique(allowsUpsert: Bool = false) = #externalMacro(module: "LatticeMacros",
                                                                 type: "UniqueMacro")

// MARK: Constraints
public struct Constraint {
    public var columns: [String]
    public var allowsUpsert: Bool
    public init(columns: [String], allowsUpsert: Bool = false) {
        self.columns = columns
        self.allowsUpsert = allowsUpsert
    }
}

public typealias LatticeModel = Model
extension Lattice {
    public typealias Model = LatticeModel
}
