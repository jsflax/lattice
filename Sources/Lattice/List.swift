import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge

public protocol PersistableUnkeyedCollection {
    associatedtype Element: SchemaProperty
}

// MARK: - LinkListRef Protocol (Pure Swift - no C++ types exposed)

public protocol LinkListRef<Element> {
    associatedtype Element

    static func new() -> Self
    func get(at position: Int) -> Element
    /// Nil-guarded variant of `get(at:)`: returns nil when the backing slot is
    /// null (e.g. a row was cascade-removed concurrently) instead of trapping.
    /// Used by `@Detached` materialization. Default falls back to `get(at:)`.
    func tryGet(at position: Int) -> Element?
    mutating func set(at position: Int, _ element: Element)
    func count() -> Int
    mutating func append(_ element: Element)
    func remove(at position: Int)
    func removeAll()
    func indexOf(_ element: Element) -> Int?
    func indicesWhere(_ query: String) -> [Int]

    var linkTableName: String { get }
    /// The owning db handle as a neutral backend (nil when unmanaged). Replaces
    /// the former `lattice.swift_lattice_ref?` so the protocol carries no
    /// foreign-reference type into the iOS-15 floor.
    var latticeBackend: (any LatticeBackend)? { get }
}

extension LinkListRef {
    /// Default: force-hydrate via `get(at:)`. Backends with a nullable slot
    /// (e.g. `ModelLinkListRef`) override this to return nil instead of trapping.
    public func tryGet(at position: Int) -> Element? { get(at: position) }
}

public protocol LinkListable: SchemaProperty {
    associatedtype ListRef: LinkListRef

    static func _makeLinkList(from storage: borrowing ModelStorage, named name: String) -> ListRef
}

// MARK: - ModelLinkListRef (wraps C++ link_list_ref)

public struct ModelLinkListRef<T: Model>: @unchecked Sendable, LinkListRef {
    var _ref: any ObjectListBackend

    init(_ref: any ObjectListBackend) {
        self._ref = _ref
    }

    public static func new() -> Self {
        Self(_ref: CxxObjectListBackend(.create()))
    }

    public func get(at position: Int) -> T {
        T(_ref.object(at: position)!)
    }

    public func tryGet(at position: Int) -> T? {
        _ref.object(at: position).map { T($0) }
    }

    public mutating func set(at position: Int, _ element: T) {
        _ref.setObject(at: position, element._dynamicObject._ref)
    }

    public func count() -> Int {
        _ref.size
    }

    public mutating func append(_ element: T) {
        _ref.pushBack(element._dynamicObject._ref)
    }

    public func remove(at position: Int) {
        _ref.erase(at: position)
    }

    public func removeAll() {
        _ref.clear()
    }

    public func indexOf(_ element: T) -> Int? {
        _ref.findIndex(of: element._dynamicObject._ref)
    }

    public func indicesWhere(_ query: String) -> [Int] {
        _ref.findWhere(query)
    }

    /// List positions matching `predicate` (nil = all), ordered by a target
    /// column (nil = list order). Positions only — no rows are hydrated.
    public func indices(matching predicate: String?,
                        orderedBy column: String?,
                        ascending: Bool) -> [Int] {
        _ref.findIndices(matching: predicate, orderedBy: column, ascending: ascending)
    }

    public var linkTableName: String {
        _ref.linkTableName
    }

    public var latticeBackend: (any LatticeBackend)? {
        _ref.lattice
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
    public static func getField(from storage: borrowing ModelStorage, named name: String) -> List<Element> {
        let listRef = Element._makeLinkList(from: storage, named: name)
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
        let query = predicate(Query<Element>()).predicate
        guard let idx = linkListRef.indicesWhere(query).first else { return nil }
        return linkListRef.get(at: idx)
    }

    public func remove(where predicate: Predicate<Element>) {
        let query = predicate(Query<Element>()).predicate
        let indices = linkListRef.indicesWhere(query)
        for i in 0..<indices.count {
            let idx = indices[i]
            linkListRef.remove(at: idx - i)
        }
    }

    /// Materialize elements into a stable buffer. Prefer iterating the list
    /// (or a `where`/`sortedBy` slice) directly — elements hydrate lazily
    /// there. Use this when you need a stable buffer, e.g. deleting elements
    /// while iterating (deletion cascade-removes rows from the live list).
    ///
    /// `limit`/`offset` mirror `Results.snapshot(limit:offset:)` and bound
    /// hydration to the requested window (list positions, post-`offset`).
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        let count = linkListRef.count()
        let start = Swift.min(Swift.max(Int(offset ?? 0), 0), count)
        let end = limit.map { Swift.min(start + Swift.max(Int($0), 0), count) } ?? count
        return (start..<end).map { linkListRef.get(at: $0) }
    }

    #if canImport(Combine)
    /// Observe structural changes (add/remove/reorder) on this list's link table.
    /// Does NOT fire for child property changes — only link table mutations.
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        let linkTableName = linkListRef.linkTableName
        guard !linkTableName.isEmpty, let latticeBackend = linkListRef.latticeBackend else {
            return AnyCancellable {}
        }
        return Lattice.observeLinkTable(linkTableName, backend: latticeBackend, block: observer)
    }
    #endif
}

extension List: LinkProperty where Element: Model {
    public typealias ModelType = Element

    public static var modelType: any Model.Type {
        Element.self
    }
}

extension List {
    /// Nil-guarded materialization for `@Detached`: walks positions skipping any
    /// whose backend slot is null (a concurrent cascade-delete can shrink the
    /// link table between `count()` and access), instead of trapping the way
    /// `subscript`/`snapshot()` do via force-unwrap. Must be called on the
    /// model's owning isolation (same thread-confinement contract as any read).
    func _detachedElements() -> [Element] {
        let n = linkListRef.count()
        var out: [Element] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            if let e = linkListRef.tryGet(at: i) { out.append(e) }
        }
        return out
    }
}

// MARK: - Lazy query views

/// A lazy, SQL-backed view over a managed `List` — what `List.where(_:)` and
/// `List.sortedBy(_:)` return. Membership and order come from ONE SQL query
/// over the link table joined to the target table (positions only — no row
/// data); elements hydrate one at a time on access, preserving Lattice's
/// lazy-loading model. Views compose: `list.where { … }.sortedBy(…)` runs a
/// single combined query.
///
/// Positions are fixed when the view is created. If you mutate the underlying
/// list while iterating — e.g. deleting elements, which cascade-removes them
/// from the list — materialize first with `snapshot()`.
public struct ListSlice<Element>: RandomAccessCollection
    where Element: Model, Element.ListRef == ModelLinkListRef<Element> {

    private let listRef: ModelLinkListRef<Element>
    private let predicate: String?
    private let sort: (column: String, ascending: Bool)?
    private let positions: [Int]

    init(listRef: ModelLinkListRef<Element>,
         predicate: String?,
         sort: (column: String, ascending: Bool)?) {
        self.listRef = listRef
        self.predicate = predicate
        self.sort = sort
        self.positions = listRef.indices(matching: predicate,
                                         orderedBy: sort?.column,
                                         ascending: sort?.ascending ?? true)
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { positions.count }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }

    /// Hydrates only the accessed element.
    public subscript(position: Int) -> Element {
        listRef.get(at: positions[position])
    }

    /// Narrow the view with an additional predicate (combined into one query).
    public func `where`(_ predicate: Predicate<Element>) -> ListSlice<Element> {
        let query = predicate(Query<Element>()).predicate
        let combined = self.predicate.map { "(\($0)) AND (\(query))" } ?? query
        return ListSlice(listRef: listRef, predicate: combined, sort: sort)
    }

    /// Re-sort the view (replaces any existing sort; one combined query).
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> ListSlice<Element> {
        ListSlice(listRef: listRef, predicate: predicate,
                  sort: ListSlice.sortColumn(for: sortDescriptor))
    }

    /// Materialize the view's elements (e.g. before mutating the list).
    ///
    /// `limit`/`offset` mirror `Results.snapshot(limit:offset:)` and bound
    /// hydration to the requested window. Note: the view's position query ran
    /// (unbounded) at view creation — the bound here saves row hydration,
    /// which is the dominant cost.
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        let start = Swift.min(Swift.max(Int(offset ?? 0), 0), positions.count)
        let end = limit.map { Swift.min(start + Swift.max(Int($0), 0), positions.count) } ?? positions.count
        return (start..<end).map { listRef.get(at: positions[$0]) }
    }

    static func sortColumn(for descriptor: SortDescriptor<Element>) -> (column: String, ascending: Bool)? {
        guard let keyPath = descriptor.keyPath else { return nil }
        return (_name(for: keyPath), descriptor.order == .forward)
    }
}

extension List where Element: Model, Element.ListRef == ModelLinkListRef<Element> {
    /// Lazy filtered view — the predicate runs in SQL against the link-table
    /// join; elements hydrate on access.
    public func `where`(_ predicate: Predicate<Element>) -> ListSlice<Element> {
        let query = predicate(Query<Element>()).predicate
        return ListSlice(listRef: linkListRef, predicate: query, sort: nil)
    }

    /// Lazy sorted view — ordering runs in SQL against the link-table join;
    /// elements hydrate on access (`.first` hydrates exactly one).
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> ListSlice<Element> {
        ListSlice(listRef: linkListRef,
                  predicate: nil,
                  sort: ListSlice.sortColumn(for: sortDescriptor))
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
