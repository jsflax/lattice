import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

// MARK: - DynamicObject
//
// The public, schema-driven, type-erased object returned by the dynamic query
// API (`Lattice.dynamicObjects(_:)`). It wraps a type-erased `ObjectBackend`
// row from a database opened WITHOUT compile-time `@Model` types, and resolves
// each property by the runtime schema (see `Lattice.dynamicSchema`).
//
// Access is Realm-style: `@dynamicMemberLookup` (and a String subscript for
// non-identifier names) returns `Any?`, which the caller casts:
//
//     let row  = lattice.dynamicObjects("Person").first!
//     let name = row.name as? String                 // scalar (native value)
//     let dog  = row.dog  as? DynamicObject           // to-one link
//     let tags = row.tags as? List<DynamicObject>     // to-many
//
// Scalars come back as their native storage type (Int64 / Double / String /
// Data). Date/Bool/UUID are stored as those primitives (Double/Int64/String)
// and surface as such — the dynamic API is intentionally low-level ("unsafe").
@dynamicMemberLookup
public final class DynamicObject: @unchecked Sendable {
    /// The type-erased backing row.
    public let backend: any ObjectBackend

    /// Column schema for this object's table. Resolved lazily from the backend's
    /// lattice the first time it's needed (or injected by `DynamicResults` to
    /// avoid a per-object lookup).
    private var _properties: [PropertyInfo]?

    init(backend: any ObjectBackend, schema: [PropertyInfo]? = nil) {
        self.backend = backend
        self._properties = schema
    }

    /// The model table this row belongs to.
    public var tableName: String { backend.tableName }

    /// The row's global sync id (UUID string), if present.
    public var globalId: String? {
        backend.hasValue(named: "globalId") ? backend.getString(named: "globalId") : nil
    }

    /// The row's local primary key, if present.
    public var primaryKey: Int64? {
        backend.hasValue(named: "id") ? backend.getInt(named: "id") : nil
    }

    /// Column descriptors for this object's table.
    public var properties: [PropertyInfo] {
        if let p = _properties { return p }
        let provider = backend.lattice as? any DynamicSchemaProviding
        let p = provider?.dynamicProperties(table: backend.tableName) ?? []
        _properties = p
        return p
    }

    public subscript(dynamicMember name: String) -> Any? { self[name] }

    public subscript(_ name: String) -> Any? {
        guard let prop = properties.first(where: { $0.name == name }) else { return nil }
        switch prop.kind {
        case .primitive:
            guard backend.hasValue(named: name) else { return nil }
            switch prop.columnType {
            case .integer: return backend.getInt(named: name)
            case .real:    return backend.getDouble(named: name)
            case .text:    return backend.getString(named: name)
            case .blob:    return backend.getData(named: name)
            }
        case .link, .virtualLink:
            let linked = backend.getObject(named: name)
            return linked.hasLattice ? DynamicObject(backend: linked) : nil
        case .list, .virtualList:
            let listBackend = backend.getLinkList(named: name)
            return List<DynamicObject>(linkListRef: DynamicLinkListRef(_ref: listBackend))
        case .unionType:
            // Stored as the union row's globalId (TEXT). Rich case/payload
            // decoding lives in the MCP serializer (which has the union schema);
            // here we surface the raw reference.
            guard backend.hasValue(named: name) else { return nil }
            return backend.getString(named: name)
        }
    }
}

// MARK: - LinkListable conformance (enables List<DynamicObject> for to-many)

extension DynamicObject: LinkListable {
    public static var anyPropertyKind: AnyProperty.Kind { .string }

    /// Never read on the dynamic query path: a `List<DynamicObject>` is only ever
    /// produced from an existing link list (`init(linkListRef:)`), and
    /// `List()`/`new()` uses `DynamicLinkListRef.new()`, not this. A
    /// `Property<DynamicObject>` model field doesn't exist.
    public static var defaultValue: DynamicObject {
        fatalError("DynamicObject has no default value; it is only produced by a dynamic query")
    }

    public static func _makeLinkList(from storage: borrowing ModelStorage, named name: String) -> DynamicLinkListRef {
        DynamicLinkListRef(_ref: storage._ref.getLinkList(named: name))
    }
}

// MARK: - DynamicLinkListRef (wraps an ObjectListBackend, hydrates DynamicObjects)

public struct DynamicLinkListRef: LinkListRef, @unchecked Sendable {
    public typealias Element = DynamicObject

    var _ref: any ObjectListBackend

    init(_ref: any ObjectListBackend) { self._ref = _ref }

    public static func new() -> Self { Self(_ref: CxxObjectListBackend(.create())) }

    public func get(at position: Int) -> DynamicObject {
        DynamicObject(backend: _ref.object(at: position)!)
    }
    public func tryGet(at position: Int) -> DynamicObject? {
        _ref.object(at: position).map { DynamicObject(backend: $0) }
    }
    public mutating func set(at position: Int, _ element: DynamicObject) {
        _ref.setObject(at: position, element.backend)
    }
    public func count() -> Int { _ref.size }
    public mutating func append(_ element: DynamicObject) {
        _ref.pushBack(element.backend)
    }
    public func remove(at position: Int) { _ref.erase(at: position) }
    public func removeAll() { _ref.clear() }
    public func indexOf(_ element: DynamicObject) -> Int? {
        _ref.findIndex(of: element.backend)
    }
    public func indicesWhere(_ query: String) -> [Int] { _ref.findWhere(query) }
    public func indices(matching predicate: String?,
                        orderedBy column: String?,
                        ascending: Bool) -> [Int] {
        _ref.findIndices(matching: predicate, orderedBy: column, ascending: ascending)
    }
    public var linkTableName: String { _ref.linkTableName }
    public var latticeBackend: (any LatticeBackend)? { _ref.lattice }
}
