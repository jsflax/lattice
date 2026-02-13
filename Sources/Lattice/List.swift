import Foundation
import SQLite3
import Combine
import LatticeSwiftCppBridge

public protocol PersistableUnkeyedCollection {
    associatedtype Element: SchemaProperty
}

// MARK: - LinkListRef Protocol (Pure Swift - no C++ types exposed)

public protocol LinkListRef<Element> {
    associatedtype Element

    static func new() -> Self
    func get(at position: Int) -> Element
    mutating func set(at position: Int, _ element: Element)
    func count() -> Int
    mutating func append(_ element: Element)
    func remove(at position: Int)
    func removeAll()
    func indexOf(_ element: Element) -> Int?
    func indicesWhere(_ query: String) -> [Int]
}

public protocol LinkListable: SchemaProperty {
    associatedtype ListRef: LinkListRef

    static func _makeLinkList(from storage: inout ModelStorage, named name: String) -> ListRef
}

// MARK: - ModelLinkListRef (wraps C++ link_list_ref)

public struct ModelLinkListRef<T: Model>: @unchecked Sendable, LinkListRef {
    var _ref: lattice.link_list_ref

    init(_ref: lattice.link_list_ref) {
        self._ref = _ref
    }

    public static func new() -> Self {
        Self(_ref: .create())
    }

    public func get(at position: Int) -> T {
        let proxy = _ref[position]
        return T(proxy.objectRef!)
    }

    public mutating func set(at position: Int, _ element: T) {
        var proxy = _ref[position]
        proxy.assign(element._dynamicObject._ref)
    }

    public func count() -> Int {
        _ref.size()
    }

    public mutating func append(_ element: T) {
        _ref.pushBack(element._dynamicObject._ref)
    }

    public func remove(at position: Int) {
        _ref.erase(position)
    }

    public func removeAll() {
        _ref.clear()
    }

    public func indexOf(_ element: T) -> Int? {
        let opt = _ref.findIndex(element._dynamicObject._ref)
        return opt.hasValue ? Int(opt.pointee) : nil
    }

    public func indicesWhere(_ query: String) -> [Int] {
        let results = _ref.findWhere(std.string(query))
        return (0..<results.count).map { Int(results[$0]) }
    }
}

public struct List<Element>: MutableCollection, BidirectionalCollection, SchemaProperty, ListProperty,
                             PersistableUnkeyedCollection, RandomAccessCollection, CxxManaged where Element: LinkListable, Element.ListRef.Element == Element {
    
    private var linkListRef: Element.ListRef
    
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
    public static func getField(from storage: inout ModelStorage, named name: String) -> List<Element> {
        let listRef = Element._makeLinkList(from: &storage, named: name)
        return List(linkListRef: listRef)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: List<Element>) {
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
        self.linkListRef = Element.ListRef.new()
    }

    init(linkListRef: Element.ListRef) {
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
        linkListRef.count()
    }

    public subscript(position: Int) -> Element {
        get {
            linkListRef.get(at: position)
        } set {
            linkListRef.set(at: position, newValue)
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
        linkListRef.append(newElement)
    }

    public mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
        newElements.forEach { newElement in
            linkListRef.append(newElement)
        }
    }

    public func remove(_ element: Element) {
        guard let index = linkListRef.indexOf(element) else { return }
        linkListRef.remove(at: index)
    }

    public mutating func remove(at position: Int) -> Element {
        let element = linkListRef.get(at: position)
        linkListRef.remove(at: position)
        return element
    }

    public func removeAll() {
        linkListRef.removeAll()
    }

    public func first(where predicate: Predicate<Element>) -> Element? {
        linkListRef.get(at: 0)
    }

    public func remove(where predicate: Predicate<Element>) {
        let query = predicate(Query<Element>()).predicate
        let indices = linkListRef.indicesWhere(query)
        for i in 0..<indices.count {
            let idx = indices[i]
            linkListRef.remove(at: idx - i)
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
