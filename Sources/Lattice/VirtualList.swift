import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge
import LatticeSwiftModule

// MARK: - ModelTypeRegistry

/// Global registry mapping entity names to Model types.
/// Populated during Lattice initialization; used by VirtualList for type resolution.
public final class ModelTypeRegistry: @unchecked Sendable {
    public static let shared = ModelTypeRegistry()
    private var types: [String: any Model.Type] = [:]
    private let lock = NSLock()

    public func register(_ type: any Model.Type) {
        lock.lock()
        defer { lock.unlock() }
        types[type.entityName] = type
    }

    public func resolve(_ entityName: String) -> (any Model.Type)? {
        lock.lock()
        defer { lock.unlock() }
        return types[entityName]
    }
}

// MARK: - VirtualList

public struct VirtualList<Element>: MutableCollection, BidirectionalCollection,
                                     RandomAccessCollection, SchemaProperty,
                                     VirtualListProperty, CxxManaged {

    var linkListRef: any ObjectListBackend

    public typealias CxxManagedSpecialization = lattice.ManagedLinkList

    public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> VirtualList<Element> {
        return VirtualList<Element>()
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    public func toCxxValue() -> CxxManagedSpecialization.SwiftType {
        return CxxManagedSpecialization.SwiftType.init()
    }

    public static func getField(from storage: borrowing ModelStorage, named name: String) -> VirtualList<Element> {
        return VirtualList(linkListRef: storage._ref.getLinkList(named: name))
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: VirtualList<Element>) {
        // Virtual lists use link tables, nothing to set inline
    }

    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        fatalError()
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        // Virtual lists aren't stored inline - they use link tables
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }

    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }

    public static var defaultValue: VirtualList<Element> {
        VirtualList()
    }

    public init() {
        self.linkListRef = BackendFactory.makeEmptyObjectList()
    }

    init(linkListRef: any ObjectListBackend) {
        self.linkListRef = linkListRef
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        linkListRef.size
    }

    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }

    public subscript(position: Int) -> Element {
        get {
            let ref = linkListRef.object(at: position)!
            let tableName = ref.tableName
            guard let modelType = ModelTypeRegistry.shared.resolve(tableName) else {
                fatalError("Unknown model type for table: \(tableName). Ensure all conforming types are registered with Lattice.")
            }
            let object = modelType.init(ref)
            return object as! Element
        }
        set {
            guard let model = newValue as? any Model else { return }
            linkListRef.setObject(at: position, model._dynamicObject._ref)
        }
    }

    public mutating func append(_ element: Element) {
        guard let model = element as? any Model else { return }
        linkListRef.pushBack(model._dynamicObject._ref)
    }

    public mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        for element in elements {
            append(element)
        }
    }

    public func remove(_ element: Element) {
        guard let model = element as? any Model else { return }
        guard let idx = linkListRef.findIndex(of: model._dynamicObject._ref) else { return }
        linkListRef.erase(at: idx)
    }

    public mutating func remove(at position: Int) -> Element {
        let element = self[position]
        linkListRef.erase(at: position)
        return element
    }

    public func removeAll() {
        linkListRef.clear()
    }

    #if canImport(Combine)
    /// Observe structural changes (add/remove/reorder) on this list's link table.
    /// Does NOT fire for child property changes — only link table mutations.
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        let linkTableName = String(linkListRef.linkTableName)
        guard !linkTableName.isEmpty, let latticeRef = linkListRef.lattice else {
            return AnyCancellable {}
        }
        return Lattice.observeLinkTable(linkTableName, backend: latticeRef, block: observer)
    }
    #endif
}
