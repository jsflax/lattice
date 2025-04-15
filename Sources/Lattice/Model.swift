import Foundation

public protocol Model: AnyObject, Observable, ObservableObject, Hashable, Identifiable {
    init()
    var lattice: Lattice? { get set }
    static var entityName: String { get }
    static var properties: [(String, any Property.Type)] { get }
    var primaryKey: Int64? { get set }
    func _assign(lattice: Lattice?, statement: OpaquePointer?)
    func _encode(statement: OpaquePointer?)
    var _$observationRegistrar: Observation.ObservationRegistrar { get }
    func _objectWillChange_send()
    func _triggerObservers_send(keyPath: String)
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String
}

extension Model {
    public var id: ObjectIdentifier {
        ObjectIdentifier(self)
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

func _name<T, V>(for keyPath: KeyPath<T, V>) -> String where T: Model {
    T._nameForKeyPath(keyPath)
}

@attached(member, names: arbitrary)
@attached(extension, conformances: Model, names: arbitrary)
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "LatticeMacros",
                                      type: "ModelMacro")


@attached(peer)
public macro Transient() = #externalMacro(module: "LatticeMacros",
                                      type: "TransientMacro")
