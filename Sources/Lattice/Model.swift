import Foundation
import SQLite3
#if canImport(Combine)
@_exported import Combine
#endif

public protocol Model: AnyObject, Observable, ObservableObject, Hashable, Identifiable, Property, SendableMetatype {
    init(isolation: isolated (any Actor)?)
    var lattice: Lattice? { get set }
    static var entityName: String { get }
    static var properties: [(String, any Property.Type)] { get }
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
}

extension Model {
    
    public static var sqlType: String { "BIGINT" }
    public static var anyPropertyKind: AnyProperty.Kind { .int }
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


@attached(accessor, names: arbitrary)
public macro Property(name mappedTo: String? = nil) = #externalMacro(module: "LatticeMacros",
                                                                     type: "PropertyMacro")


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
