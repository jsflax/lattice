import Foundation
import SQLite3
import Combine
import LatticeSwiftCppBridge

public protocol PersistableUnkeyedCollection {
    associatedtype Element: SchemaProperty
}

typealias LinkListRef = lattice.link_list_ref

public struct List<T>: MutableCollection, BidirectionalCollection, SchemaProperty, ListProperty,
                       PersistableUnkeyedCollection, LinkProperty, RandomAccessCollection, CxxManaged where T: Model {
    private var linkListRef: LinkListRef!
    
    public typealias CxxManagedSpecialization = lattice.ManagedLinkList

    public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> List<T> {
        // TODO: Implement proper conversion from C++ managed link list
        return List<T>()
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    public func toCxxValue() -> CxxManagedSpecialization.SwiftType {
        // TODO: Implement proper conversion to C++ managed link list
        return CxxManagedSpecialization.SwiftType.init()
    }
    public static func getField(from object: inout CxxDynamicObjectRef, named name: String) -> List<T> {
        let listRef = object.getLinkList(named: std.string(name))
        return List(linkListRef: listRef!)
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef, named name: String, _ value: List<T>) {
//        fatalError()
    }
 
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        fatalError()
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        // Lists aren't stored inline - they use link tables
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public typealias ModelType = T
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
    public static var modelType: any Model.Type {
        T.self
    }
    
    public typealias DefaultValue = Array<T>
    
    public static var defaultValue: List<T> {
        List()
    }
    
    public init() {
        self.linkListRef = LinkListRef.create()
    }

    init(linkListRef: LinkListRef) {
        self.linkListRef = linkListRef
    }
    
    public static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> List<T> {
        fatalError()
    }
    
    public static func _set(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: List<T>) {
        
    }
    
    public var startIndex: Int = 0

    
    public func index(after i: Int) -> Int {
        i + 1
    }
    public func index(before i: Int) -> Int {
        i - 1
    }
    
    public enum CollectionChange {
        case insert(Int64)
        case delete(Int64)
    }
    
    public var endIndex: Int {
        linkListRef.size()
    }
    
    public subscript(position: Int) -> T {
        get {
            let proxy = linkListRef[position]
            return T(dynamicObject: CxxDynamicObjectRef.wrap(proxy.object))
        } set {
            var proxy = linkListRef[position]
            proxy.assign(newValue._dynamicObject)
        }
    }
//    
//    public subscript(safe: Int) -> T? {
//        get {
//            switch storage {
//            case .unmanaged(let unmanaged): unmanaged.storage[safe]
//            case .managed(let managed): managed[safe]
//            }
//        } set {
//            switch storage {
//            case .unmanaged(let unmanaged):
//                unmanaged.storage[safe] = newValue
//            case .managed(let managed):
//                managed[safe] = newValue
//            }
//        }
//    }
    
    public mutating func append(_ newElement: T) {
        linkListRef.push_back(newElement._dynamicObject)
    }

    public mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == T {
        newElements.forEach { newElement in
            linkListRef.push_back(newElement._dynamicObject)
        }
    }
    
    public func remove(_ element: Element) {
        let indexOpt = linkListRef.find_index(element._dynamicObject)
        guard indexOpt.hasValue else { return }
        linkListRef.erase(Int(indexOpt.pointee))
    }
    
    public mutating func remove(at position: Int) -> T {
        var element = linkListRef[position]
        linkListRef.erase(position)
        return T(dynamicObject: CxxDynamicObjectRef.wrap(element.object))
    }
    
    public func removeAll() {
    }
    
    public func first(where predicate: Predicate<Element>) -> Element? {
        var proxy = linkListRef[0]
        return T(dynamicObject: CxxDynamicObjectRef.wrap(proxy.object))
    }

    public func remove(where predicate: Predicate<Element>) {
        let query = predicate(Query<List<T>.Element>()).predicate
        let indices = linkListRef.findWhere(predicate: std.string(query))
        print(indices.count)
        for i in 0..<indices.count {
            let idx = indices[i]
            linkListRef.erase(Int(idx) - i)
        }
    }
    
    public func snapshot() -> [Element] {
        fatalError()
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Results<Element> {
        fatalError()
    }
}

extension List {
    public static func +(lhs: List, rhs: List) -> Array<Element> {
        lhs.map { $0 } + rhs.map { $0 }
    }
}

// MARK: Codable Support
extension List: Codable where Element: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let count = container.count else {
//            self.linkList = LinkList()
            fatalError()
            return
        }
        
//        self.linkList = .init()
        try (0..<(container.count ?? 0)).forEach { _ in
//            var o = try container.decode(Element.self)._dynamicObject
//            self.linkList.push_back(&o)
        }
        fatalError()
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: self.map(\.self))
    }
}


public typealias LatticeList = List

extension Lattice {
    public typealias List = LatticeList
}
