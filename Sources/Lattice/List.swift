import Foundation
import SQLite3
import Combine
import LatticeSwiftCppBridge

public protocol PersistableUnkeyedCollection {
    associatedtype Element: SchemaProperty
}

public protocol element_proxy {
    associatedtype RefType
    
    mutating func assign(_ type: RefType!)
    var objectRef: RefType? { get }
}

public protocol CxxLinkListRef {
    associatedtype RefType
    associatedtype ElementProxy: element_proxy where RefType == ElementProxy.RefType
    
    static func new() -> Self
    subscript(position: Int) -> ElementProxy { get }
    func size() -> Int
    mutating func pushBack(_ refType: RefType!)
    func erase(_ position: Int)
    func findIndex(_ refType: RefType) -> lattice.optional_size_t
    func findWhere(_ query: std.string) -> lattice.vec_size_t
}

public protocol LinkListable: SchemaProperty {
    associatedtype Ref: CxxLinkListRef
    
    static func getLinkListField(from object: inout CxxDynamicObjectRef, named name: String) -> Ref
    var asRefType: Ref.RefType { get }
    
    init(_ refType: Ref.RefType)
}

extension lattice.link_list.element_proxy: element_proxy {
}
extension lattice.geo_bounds_list.element_proxy: element_proxy {
}

extension lattice.geo_bounds_list_ref: CxxLinkListRef {
    public static func new() -> Self {
        create()
    }
}

extension lattice.link_list_ref : CxxLinkListRef {
    public static func new() -> Self {
        create()
    }
}

public struct List<Element>: MutableCollection, BidirectionalCollection, SchemaProperty, ListProperty,
                             PersistableUnkeyedCollection, RandomAccessCollection, CxxManaged where Element: LinkListable {
    
    private var linkListRef: Element.Ref!
    
    public typealias CxxManagedSpecialization = lattice.ManagedLinkList

    public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> List<Element> {
        // TODO: Implement proper conversion from C++ managed link list
        return List<Element>()
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    public func toCxxValue() -> CxxManagedSpecialization.SwiftType {
        // TODO: Implement proper conversion to C++ managed link list
        return CxxManagedSpecialization.SwiftType.init()
    }
    public static func getField(from object: inout CxxDynamicObjectRef, named name: String) -> List<Element> {
        let listRef = Element.getLinkListField(from: &object, named: name)
        return List(linkListRef: listRef)
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef, named name: String, _ value: List<Element>) {
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
    
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
    
    public typealias DefaultValue = Array<Element>
    
    public static var defaultValue: List<Element> {
        List()
    }
    
    public init() {
//        self.linkListRef = Element.Ref.create().pointee
    }

    init(linkListRef: Element.Ref) {
        self.linkListRef = linkListRef
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
    
    public subscript(position: Int) -> Element {
        get {
            let proxy = linkListRef[position]
            return Element(proxy.objectRef!)
        } set {
            var proxy = linkListRef[position]
            proxy.assign(newValue.asRefType)
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
    
    public mutating func append(_ newElement: Element) {
        linkListRef.pushBack(newElement.asRefType)
    }

    public mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
        newElements.forEach { newElement in
            linkListRef.pushBack(newElement.asRefType)
        }
    }
    
    public func remove(_ element: Element) {
        let indexOpt = linkListRef.findIndex(element.asRefType)
        guard indexOpt.hasValue else { return }
        linkListRef.erase(Int(indexOpt.pointee))
    }
    
    public mutating func remove(at position: Int) -> Element {
        var element = linkListRef[position]
        linkListRef.erase(position)
        return Element(element.objectRef!)
    }
    
    public func removeAll() {
    }
    
    public func first(where predicate: Predicate<Element>) -> Element? {
        var proxy = linkListRef[0]
        return Element(proxy.objectRef!)
    }

    public func remove(where predicate: Predicate<Element>) {
        let query = predicate(Query<Element>()).predicate
        let indices = linkListRef.findWhere(std.string(query))
        print(indices.count)
        for i in 0..<indices.count {
            let idx = indices[i]
            linkListRef.erase(Int(idx) - i)
        }
    }
    
    public func snapshot() -> [Element] {
        fatalError()
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> any Results<Element> {
        fatalError()
    }
}

extension List: LinkProperty where Element: Model {
    public typealias ModelType = Element
    
    public static var modelType: any Model.Type {
        Element.self
    }
}

extension List: GeoboundsProperty where Element: GeoboundsProperty {
    public static func _trace<V>(keyPath: KeyPath<List<Element>, V>) -> String {
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
