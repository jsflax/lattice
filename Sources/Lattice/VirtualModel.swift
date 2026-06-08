import Foundation
import LatticeSwiftCppBridge


public protocol VirtualModel {
    var primaryKey: Int64? { get }
    var globalId: UUID? { get }
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

enum Blah<T> {
    
}
@dynamicMemberLookup
public protocol _Query<T> {
    init()
    associatedtype T
//    subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> { get }
//    subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where Self.T: Model { get }

    /// Resolve a virtual (polymorphic) member into a column-keyed `Query<V>`.
    /// Default (concrete `Query<T>` and any other non-virtual `_Query`) traps;
    /// `VirtualQuery` conformers override it.
    ///
    /// This requirement replaces the former `self as? any VirtualQuery<T>`
    /// downcast in the dynamicMember subscripts below. A runtime cast to a
    /// *parameterized* existential (`any P<T>`) requires iOS 16; routing through
    /// a base-protocol requirement is plain witness-table dispatch and
    /// back-deploys to iOS 15. (Static `any P<T>` as a type is fine on 15 — only
    /// the `as?`/`is` cast needs 16.)
    func _virtualMember<V>(_ member: KeyPath<T, V>) -> Query<V>
}

extension _Query {
    public func _virtualMember<V>(_ member: KeyPath<T, V>) -> Query<V> {
        fatalError("dynamicMember on a _Query that is neither Query nor VirtualQuery")
    }
}

extension _Query {
    // Specialized subscript for optional Model links - must come before generic subscripts
    public subscript<V: Model>(dynamicMember member: KeyPath<T, V?>) -> Query<V> where T: Model {
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        }
        // VirtualQuery doesn't support link queries yet.
        fatalError("VirtualQuery link queries not implemented")
    }

    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where T: Model {
        // Concrete Query<T> takes the fast path; everything else (VirtualQuery
        // conformers) resolves via the `_virtualMember` witness — no runtime
        // cast to a parameterized existential (which would require iOS 16).
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        }
        return self._virtualMember(member)
    }

    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where T: GeoboundsProperty {
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        }
        return self._virtualMember(member)
    }

    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> {
        if let self = self as? Query<T> {
            return self[dynamicMember: member]
        }
        return self._virtualMember(member)
    }
}

extension Query: _Query {
    public init() {
        self.init(isPrimitive: false)
    }
}

@dynamicMemberLookup
public protocol VirtualQuery<VT>: _Query where Self.T == Self.VT {
    associatedtype VT
    subscript<V>(dynamicMember member: KeyPath<VT, V>) -> Query<V> { get }
}

extension VirtualQuery {
    // Witness for `_Query._virtualMember`. `Self.T == Self.VT` (above) makes the
    // `KeyPath<T, V>` argument interchangeable with the subscript's
    // `KeyPath<VT, V>`, so this forwards to the conformer's own virtual-member
    // subscript — no parameterized-existential cast.
    public func _virtualMember<V>(_ member: KeyPath<T, V>) -> Query<V> {
        self[dynamicMember: member]
    }
}

// Parameter-pack query DSL for polymorphic models. Gated to iOS 17 because of
// the variadic generics; iOS 15 uses `_VirtualQueryCompat` below, which stores
// the model types in an array instead of a pack.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
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

// Non-pack equivalent of `_VirtualQuery` for the iOS 15 path. The model types
// are carried as a runtime array; `query(member:)` only ever needs a
// representative type (the pack version returns on its first iteration), so
// `modelTypes.first` suffices. Must be built via `init(modelTypes:)` from the
// enclosing compat results — the bare `_Query.init()` requirement yields an
// empty query that cannot resolve a key path.
@dynamicMemberLookup
public struct _VirtualQueryCompat<VT>: VirtualQuery {
    public typealias T = VT
    let modelTypes: [any Model.Type]
    public init() { self.modelTypes = [] }
    init(modelTypes: [any Model.Type]) { self.modelTypes = modelTypes }

    private func query<V>(member: KeyPath<VT, V>) -> Query<V> {
        guard let t = modelTypes.first else { fatalError() }
        let inst = t.init(isolation: #isolation)
        guard let virtualInst = inst as? VT else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: member]
        let keyPath = inst._lastKeyPathUsed ?? "id"
        // virtualMember is a fresh Query<V> builder keyed on the column string;
        // the receiver's type parameter is irrelevant, so any Query instance works.
        return Query<VT>().virtualMember(keyPath, withType: V.self)
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
