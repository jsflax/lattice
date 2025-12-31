import Foundation
import SQLite3
#if canImport(Combine)
@_exported import Combine
#endif
import LatticeSwiftCppBridge
import LatticeSwiftModule

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

public protocol Model: AnyObject, Observable, ObservableObject, Hashable, Identifiable, SchemaProperty, SendableMetatype, CxxManaged, LatticeIsolated {
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
    var _dynamicObject: CxxDynamicObjectRef { get set }
}

extension Model {
    package init(isolation: isolated (any Actor)? = #isolation,
                 dynamicObject: CxxDynamicObjectRef) {
        self.init(isolation: isolation)
        self._dynamicObject = dynamicObject
    }
    
    public static var defaultValue: Self {
        .init(isolation: #isolation)
    }
    public static var sqlType: String { "BIGINT" }
    public static var anyPropertyKind: AnyProperty.Kind { .int }

    public var lattice: Lattice? {
        _dynamicObject.lattice.map { Lattice.init(ref: $0) }
    }

    public static func getField(from object: inout CxxDynamicObjectRef, named name: String) -> Self {
        let model = Self(isolation: #isolation)
        model._dynamicObject = object.getObject(named: std.string(name))
        return model
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef, named name: String, _ value: Self) {
        object.setObject(named: std.string(name), value._dynamicObject)
    }

    public typealias ObservableObjectPublisher = AnyPublisher<Void, Never>
    
    // 3️⃣ override the protocol’s publisher
    public var objectWillChange: Publishers.HandleEvents<Combine.ObservableObjectPublisher> {
        // each new subscriber bumps the count…
        _objectWillChange
            .handleEvents(
                receiveSubscription: { [weak self] _ in
                    self.map {
                        $0.lattice?.beginObserving($0)
                    }
                },
                receiveCancel: { [weak self] in
                    self.map {
                        $0.lattice?.finishObserving($0)
                    }
                }
            )
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
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: .primitive, target_table: .init(),
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
    
    public static var defaultCxxLatticeObject: CxxDynamicObject {
        CxxDynamicObject(CxxLatticeObject(std.string(entityName), cxxPropertyDescriptor()))
    }
}

public func _defaultCxxLatticeObject<M>(_ model: M.Type) -> CxxDynamicObject where M: Model {
    CxxDynamicObject(CxxLatticeObject(std.string(M.entityName), M.cxxPropertyDescriptor()))
}

extension Model {
    public var debugDescription: String {
        String(_dynamicObject.debug_description())
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
