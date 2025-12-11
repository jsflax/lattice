import Foundation
import SQLite3
#if canImport(Combine)
@_exported import Combine
#endif
import LatticeSwiftCppBridge

public enum _ModelStorage {
    case unmanaged(lattice.swift_dynamic_object)
    case managed(lattice.ManagedModel)
}

public typealias CxxLatticeObject = lattice.swift_dynamic_object
public typealias CxxManagedLatticeObject = lattice.ManagedModel

public protocol Model: AnyObject, Observable, ObservableObject, Hashable, Identifiable, SchemaProperty, SendableMetatype, CxxManaged {
    init(isolation: isolated (any Actor)?)
    var lattice: Lattice? { get set }
    static var entityName: String { get }
    static var properties: [(String, any SchemaProperty.Type)] { get }
    var primaryKey: Int64? { get set }
    var __globalId: UUID { get }  // Unique identifier for sync across clients
    func _assign(lattice: Lattice?)
    func _encode(statement: OpaquePointer?)
    func _didEncode()

    var _$observationRegistrar: Observation.ObservationRegistrar { get }
    func _objectWillChange_send()
    func _triggerObservers_send(keyPath: String)
    var _lastKeyPathUsed: String? { get set }
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String
    static var constraints: [Constraint] { get }
    var _objectWillChange: Combine.ObservableObjectPublisher { get }
    var _storage: _ModelStorage { get set }
}

extension Model {
    public static var defaultValue: Self {
        .init(isolation: #isolation)
    }
    public static var sqlType: String { "BIGINT" }
    public static var anyPropertyKind: AnyProperty.Kind { .int }

    // CxxManaged conformance
    public func toCxxValue() -> lattice.ManagedModel? {
        if case let .managed(cxxObject) = _storage {
            return cxxObject
        }
        return nil
    }

    public static func fromCxxValue(_ value: lattice.ManagedModel?) -> Self {
        let object = Self(isolation: #isolation)
        if let value {
            object._storage = .managed(value)
        }
        return object
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Self {
        // Models aren't stored inline in dynamic objects - return a new unmanaged instance
        let model = Self(isolation: #isolation)
        return model
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        // Models aren't stored inline in dynamic objects
        // Links are handled separately via link tables
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
                                             target_table: .init(), link_table: .init(), nullable: false,
                                             is_vector: isVector)
        }

        for (name, property) in linkProperties {
            schema[std.string(name)] = .init(name: std.string(name), type: .integer, kind: .link,
                                             target_table: std.string(property.modelType.entityName),
                                             link_table: .init(Self.entityName),
                                             nullable: true, is_vector: false)
        }


        return schema
    }
    
    public static var defaultCxxLatticeObject: CxxLatticeObject {
        CxxLatticeObject(std.string(entityName), cxxPropertyDescriptor())
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

@attached(member, names: arbitrary)
@attached(extension, conformances: Codable, names: arbitrary)
public macro Codable() = #externalMacro(module: "LatticeMacros",
                                        type: "CodableMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "LatticeMacros",
                                      type: "TransientMacro")


//@attached(accessor, names: arbitrary)
//public macro Property(name mappedTo: String? = nil) = #externalMacro(module: "LatticeMacros",
//                                                                     type: "PropertyMacro")


@attached(peer)
public macro Unique<T>(compoundedWith: PartialKeyPath<T>...,
                       allowsUpsert: Bool = false) = #externalMacro(module: "LatticeMacros",
                                                           type: "UniqueMacro")

@attached(peer)
public macro Unique() = #externalMacro(module: "LatticeMacros",
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
