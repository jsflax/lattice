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


extension Lattice {
    func objects<each M: Model, V>(_ models: repeat (each M).Type,
                                   as virtualModel: V.Type) -> VirtualResults<repeat each M, V> {
        for type in repeat (each M).self {
            guard type.init(isolation: #isolation) is V else {
                preconditionFailure("Type mismatch: \(type) is not \(V.self)")
            }
        }
        return VirtualResults(self)
    }
    
//    func objects<V>(_ virtualModel: V.Type) -> VirtualResults<repeat each M, V> {
//        self.modelTypes.filter({ $0.init(isolation: #isolation) is V })
//    }
}

public struct VirtualResults<each M: Model, Element> {
    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<Element>?
    
    init(_ lattice: Lattice, whereStatement: Query<Bool>? = nil, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
    }

    init(_ lattice: Lattice, whereStatement: Predicate<Element>, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement(Query())
        self.sortStatement = sortStatement
    }
    
    private func constructVirtualQuery<T>(_ t: T.Type) -> _VirtualQuery<T, Element> {
        _VirtualQuery<T, Element>()
    }
    
    public func `where`(_ query: @escaping (any VirtualQuery<Element>) -> Query<Bool>) -> Self {
        let types = (repeat (each M).self)
        for t in repeat each types {
            return Self(_lattice, whereStatement: query(constructVirtualQuery(t)))
        }
        fatalError()
    }
}

@dynamicMemberLookup
public protocol VirtualQuery<VT> {
    associatedtype VT
    subscript<V>(dynamicMember member: KeyPath<VT, V>) -> Query<V> { get }
}

@dynamicMemberLookup
public struct _VirtualQuery<T: Model, VT> : VirtualQuery {
    init() {}
    
    public subscript<V>(dynamicMember member: KeyPath<VT, V>) -> Query<V> {
        let query = Query<T>()
        let inst = T(isolation: #isolation)
        guard let virtualInst = inst as? VT else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: member]
        let keyPath = inst._lastKeyPathUsed ?? "id"
        return query.virtualMember(keyPath, withType: V.self)
    }
}

package func testUnion() throws {
    let lattice = try Lattice(Restaurant.self, Museum.self)
    let results = lattice.objects(Restaurant.self, Museum.self, as: POI.self).where {
        $0.name.isEmpty
    }
}
