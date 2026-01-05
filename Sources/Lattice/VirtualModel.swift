import Foundation
import LatticeSwiftCppBridge


public protocol VirtualModel {
}


protocol POI: VirtualModel {
    var name: String { get }
    var description: String { get }
    var embedding: FloatVector { get }
}

protocol Test {
}

extension Test {
    var schema: lattice.SwiftSchema {
        return .init()
    }
}

@Model
class Restaurant: POI, Test {
    var name: String
    
    var description: String
    
    var embedding: FloatVector
}

@Model
class Museum: POI {
    var name: String
    
    var description: String
    
    var embedding: FloatVector
}



internal protocol _QueryProtocol {
    
}

@dynamicMemberLookup
public protocol _Query<T> {
    init()
    associatedtype T
//    subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> { get }
//    subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where Self.T: Model { get }
}

extension _Query {
    // Specialized subscript for optional Model links - must come before generic subscripts
    public subscript<V: Model>(dynamicMember member: KeyPath<T, V?>) -> Query<V> where T: Model {
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        } else if let self = self as? any VirtualQuery<T> {
            // VirtualQuery doesn't support link queries yet
            fatalError("VirtualQuery link queries not implemented")
        }
        else {
            fatalError()
        }
    }

    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where T: Model {
        // not the best hack to get around witness tables
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        } else if let self = self as? any VirtualQuery<T> {
            return self[dynamicMember: member]
        }
        else {
            fatalError()
        }
    }
    
    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where T: GeoboundsProperty {
        // not the best hack to get around witness tables
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        } else if let self = self as? any VirtualQuery<T> {
            return self[dynamicMember: member]
        }
        else {
            fatalError()
        }
    }

    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> {
        // not the best hack to get around witness tables
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        } else if let self = self as? any VirtualQuery<T> {
            return self[dynamicMember: member]
        }
        else {
            fatalError()
        }
    }
}

extension Query: _Query {
    public init() {
        self.init(isPrimitive: false)
    }
}

@dynamicMemberLookup
public protocol VirtualQuery<VT>: _Query {
    associatedtype VT
    subscript<V>(dynamicMember member: KeyPath<VT, V>) -> Query<V> { get }
}

@dynamicMemberLookup
public struct _VirtualQuery<each M: Model, VT> : VirtualQuery {
    public typealias T = VT
    public init() {}
    
    private func query<T>(_ type: T.Type) -> Query<T>{
        Query<T>()
    }
    private func query<V>(member: KeyPath<VT, V>) -> Query<V> {
        for t in repeat (each M).self {
            let query = query(t)
            let inst = t.init(isolation: #isolation)
            guard let virtualInst = inst as? VT else {
                preconditionFailure()
            }
            _ = virtualInst[keyPath: member]
            let keyPath = inst._lastKeyPathUsed ?? "id"
            return query.virtualMember(keyPath, withType: V.self)
        }
        fatalError()
    }
    
    public subscript<V>(dynamicMember member: KeyPath<VT, V>) -> Query<V> {
        query(member: member)
    }
}

protocol _Results<Element> {
    associatedtype Element
//    associatedtype Q: _Query
    
    func `where`(_ query: (any _Query<Element>) -> some _Query<Bool>)
}
struct TResults<Element>: _Results {
    func `where`(_ query: (any _Query<Element>) -> some _Query<Bool>) {
        query(Query())
    }
}

@attached(extension, names: arbitrary)
public macro VirtualModel() = #externalMacro(module: "LatticeMacros",
                                             type: "VirtualModelMacro")
