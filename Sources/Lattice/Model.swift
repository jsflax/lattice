import Foundation
@_exported import Observation
#if canImport(Combine)
@_exported import Combine
#endif
@_exported import LatticeSwiftCppBridge
import LatticeSwiftCppBridge
import LatticeSwiftModule
#if canImport(os)
import os.lock
#endif

// MARK: - Cross-Instance Observation Registry

/// Tracks all live Model instances by (tableName, primaryKey) to enable cross-instance
/// and cross-process observation. Registers C++ object observers so that changes from
/// other processes trigger `_objectWillChange_send()` on hydrated Swift model instances.
final class ModelInstanceRegistry: @unchecked Sendable {
    static let shared = ModelInstanceRegistry()

    private struct InstanceKey: Hashable {
        let databasePath: String
        let tableName: String
        let primaryKey: Int64
    }

    /// Context for the C function pointer object observer callback.
    fileprivate final class _ObjectObserverCtx: @unchecked Sendable {
        let dbPath: String
        let tableName: String
        let primaryKey: Int64
        init(dbPath: String, tableName: String, primaryKey: Int64) {
            self.dbPath = dbPath; self.tableName = tableName; self.primaryKey = primaryKey
        }
    }

    private struct WeakModelRef: @unchecked Sendable {
        weak var instance: (any Model)?
        let objectIdentifier: ObjectIdentifier
        var cxxObserverId: UInt64?
        // Boxed backend handle; deregister recovers the swift_lattice_ref via
        // asCxxLatticeRef (the handle works on every OS — value-converted
        // below the FRT floor).
        var latticeBackend: (any LatticeBackend)?
        init(_ model: any Model) {
            self.instance = model
            self.objectIdentifier = ObjectIdentifier(model)
        }
    }

    private var instances: [InstanceKey: [WeakModelRef]] = [:]
    /// Maps ObjectIdentifier → InstanceKey so deregister can look up the key
    /// without accessing the model's C++ lattice ref (which may be dangling in deinit).
    private var registeredKeys: [ObjectIdentifier: InstanceKey] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register a model instance for cross-instance and cross-process observation
    func register(_ model: any Model, tableName: String) {
        LatticePerf.bump(.registrations)
        guard let primaryKey = model.primaryKey else { return }
        guard let latticeBackend = model._dynamicObject._ref.lattice else { return }
        // Cross-process object observation uses the C++ object-observer API.
        guard let latticeRef = latticeBackend.asCxxLatticeRef else { return }
        let dbPath = String(latticeRef.path())
        let key = InstanceKey(databasePath: dbPath, tableName: tableName, primaryKey: primaryKey)
        var ref = WeakModelRef(model)
        let objectId = ObjectIdentifier(model)

        // Register C++ object observer for cross-process changes.
        // Pack captured state into a context for the C function pointer callback.
        let observerCtx = _ObjectObserverCtx(dbPath: dbPath, tableName: tableName, primaryKey: primaryKey)
        let observerCtxPtr = Unmanaged.passRetained(observerCtx).toOpaque()

        let observerId = latticeRef.add_object_observer(
            std.string(tableName),
            primaryKey,
            observerCtxPtr,
            { (changedFieldNamesCStr, ctxPtr) in
                guard let ctxPtr, let changedFieldNamesCStr else { return }
                let ctx = Unmanaged<_ObjectObserverCtx>.fromOpaque(ctxPtr).takeUnretainedValue()
                // changedFieldsNames is a JSON array like '["age",null,"name"]'
                // null entries are unchanged columns from the trigger's CASE expressions
                let fieldNames = String(cString: changedFieldNamesCStr)
                var names: [String] = []
                if let data = fieldNames.data(using: .utf8),
                   let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    names = array.compactMap { $0 as? String }
                }
                // Empty names means same-process change (flush_changes default) —
                // Swift's _notifyOtherInstances already handles cross-instance notification.
                // Cross-process changes always have field names from AuditLog triggers.
                guard !names.isEmpty else { return }
                for name in names {
                    ModelInstanceRegistry.shared.notifyChange(
                        databasePath: ctx.dbPath,
                        tableName: ctx.tableName,
                        primaryKey: ctx.primaryKey,
                        propertyName: name
                    )
                }
            },
            { ptr in
                guard let ptr else { return }
                Unmanaged<_ObjectObserverCtx>.fromOpaque(ptr).release()
            }
        )
        ref.cxxObserverId = observerId
        ref.latticeBackend = latticeBackend
        lock.lock()
        registeredKeys[objectId] = key
        var refs = instances.removeValue(forKey: key) ?? []
        lock.unlock()

        // Clean up nil weak refs outside the lock (same deadlock avoidance as deregister).
        if !refs.contains(where: { $0.objectIdentifier == objectId }) {
            refs.append(ref)
        }
        refs.removeAll { $0.instance == nil }

        lock.lock()
        // Merge with any refs added concurrently for this key.
        if var existing = instances[key] {
            for r in refs where !existing.contains(where: { $0.objectIdentifier == r.objectIdentifier }) {
                existing.append(r)
            }
            instances[key] = existing
        } else {
            instances[key] = refs
        }
        lock.unlock()
    }

    /// Deregister a model instance and remove its C++ object observer.
    /// Uses the pre-stored InstanceKey to avoid accessing the model's C++ lattice ref,
    /// which may be a dangling pointer during deinit teardown.
    func deregister(_ model: any Model, tableName: String) {
        LatticePerf.bump(.deregistrations)
        let objectId = ObjectIdentifier(model)

        lock.lock()
        guard let key = registeredKeys.removeValue(forKey: objectId) else {
            lock.unlock()
            return
        }

        // Take the entire ref list out while locked. This avoids accessing
        // weak var instance inside the lock — reading a weak var creates a
        // temporary strong ref whose release can trigger Model.deinit →
        // recursive deregister → deadlock on this non-recursive lock.
        let allRefs = instances.removeValue(forKey: key) ?? []
        lock.unlock()

        // Process outside the lock: partition into removed, alive, and nil.
        // Any Model.deinit triggered by temporary strong refs here is safe
        // (lock is not held).
        var removedRefs: [WeakModelRef] = []
        var keptRefs: [WeakModelRef] = []
        for ref in allRefs {
            if ref.objectIdentifier == objectId {
                removedRefs.append(ref)
            } else if ref.instance != nil {
                keptRefs.append(ref)
            }
        }

        // Put back surviving refs, merging with any added concurrently.
        if !keptRefs.isEmpty {
            lock.lock()
            if var existing = instances[key] {
                existing.append(contentsOf: keptRefs)
                instances[key] = existing
            } else {
                instances[key] = keptRefs
            }
            lock.unlock()
        }

        for ref in removedRefs {
            if let observerId = ref.cxxObserverId,
               let latticeBackend = ref.latticeBackend,
               let latticeRef = latticeBackend.asCxxLatticeRef {
                latticeRef.remove_object_observer(std.string(tableName), key.primaryKey, observerId)
            }
        }
    }

    /// Look up the cached database path for a registered model instance.
    /// Returns nil if the model was never registered (e.g. unmanaged objects).
    func databasePath(for model: any Model) -> String? {
        let objectId = ObjectIdentifier(model)
        lock.lock()
        defer { lock.unlock() }
        return registeredKeys[objectId]?.databasePath
    }

    /// Item A §1.6 (Commit 7): the live registered instance for a row, if
    /// any weak ref is still alive. Page refills consult this so a
    /// re-hydrated row is the SAME object identity as the instance a view
    /// already holds — identity stability becomes instance-level, not just
    /// id-level, and observer-registration churn is bounded (A1 risk 3).
    /// Best-effort by contract: nil (no live ref) hydrates fresh as today.
    ///
    /// `backendIdentity` scopes reuse to instances hydrated from the SAME
    /// core handle (`LatticeBackend.identityHash` — the underlying
    /// swift_lattice impl pointer). The registry key is (path, table, pk),
    /// so it also matches instances belonging to OTHER Lattice handles on
    /// the same file — but a managed instance's property writes route
    /// through ITS OWN handle's connection: handing handle B's instance to
    /// a facade on handle A would send A's writes through B's connection,
    /// interleaving with B's transactions (an overlapping BEGIN throws —
    /// pinned by `test_WriteWhileIterating`). Same-handle instances are the
    /// ones whose write routing is already ours.
    ///
    /// The weak refs are resolved OUTSIDE the lock: reading a weak var
    /// creates a temporary strong ref whose release can trigger
    /// Model.deinit → deregister → deadlock on this non-recursive lock
    /// (same discipline as `deregister`).
    func lookup(databasePath: String, tableName: String, primaryKey: Int64,
                backendIdentity: Int64) -> (any Model)? {
        let key = InstanceKey(databasePath: databasePath, tableName: tableName, primaryKey: primaryKey)
        lock.lock()
        let refs = instances[key] ?? []
        lock.unlock()
        for ref in refs where ref.latticeBackend?.identityHash == backendIdentity {
            if let model = ref.instance { return model }
        }
        return nil
    }

    /// Diagnostics (tests): number of LIVE registered instances for one row
    /// key. The Commit-7 churn pin: with page-refill reuse, a row held by a
    /// view and cached in a page is ONE instance, not an accumulating pile
    /// of duplicates. Weak refs resolved outside the lock (see `lookup`).
    func _liveInstanceCount(databasePath: String, tableName: String, primaryKey: Int64) -> Int {
        let key = InstanceKey(databasePath: databasePath, tableName: tableName, primaryKey: primaryKey)
        lock.lock()
        let refs = instances[key] ?? []
        lock.unlock()
        var alive = 0
        for ref in refs where ref.instance != nil {
            alive += 1
        }
        return alive
    }

    /// Notify all instances of a row change, except the one that initiated it (if provided)
    func notifyChange(databasePath: String, tableName: String, primaryKey: Int64, propertyName: String, excludingInstanceId: ObjectIdentifier? = nil) {
        let key = InstanceKey(databasePath: databasePath, tableName: tableName, primaryKey: primaryKey)

        lock.lock()
        let refs = instances[key] ?? []
        lock.unlock()

        for ref in refs {
            guard let model = ref.instance else { continue }
            if let excludeId = excludingInstanceId, ref.objectIdentifier == excludeId {
                continue
            }
            Task {
                // Trigger both Combine (ObservableObject) and Observation (@Observable) systems
                if let isolation = model.lattice?.isolation {
                    await isolation.invoke { _ in
                        ref.instance?._objectWillChange_send()
                        ref.instance?._triggerObservers_send(keyPath: propertyName)
                    }
                } else {
                    ref.instance?._objectWillChange_send()
                    ref.instance?._triggerObservers_send(keyPath: propertyName)
                }
            }
        }
    }
}

public enum _ModelStorage {
    case unmanaged(lattice.swift_dynamic_object)
    case managed(lattice.ManagedModel)
}

public typealias CxxLatticeObject = lattice.swift_dynamic_object
public typealias CxxManagedLatticeObject = lattice.ManagedModel
public typealias CxxManagedModel = lattice.ManagedModel
public typealias CxxManagedLink = lattice.ManagedLink
public typealias CxxManagedInt = lattice.ManagedInt
public typealias CxxDynamicObject = lattice.dynamic_object
public typealias CxxDynamicObjectRef = lattice.dynamic_object_ref


/// A closure-based observer registered on a single Model instance.
public struct _ModelObserver {
    public let id: UUID
    public let propertyName: String?
    public let callback: (String) -> Void

    public init(id: UUID = UUID(), propertyName: String? = nil, callback: @escaping (String) -> Void) {
        self.id = id
        self.propertyName = propertyName
        self.callback = callback
    }
}

// NOTE: `Observable` (iOS 17) is intentionally NOT a refinement here — that
// would force an iOS-17 floor on every model. The @Model macro instead adds
// `Observable` conformance per-model behind `@available(iOS 17, *)`. Below iOS 17
// models still drive SwiftUI via `ObservableObject` (Combine).
public protocol Model: AnyObject, ObservableObject, Hashable, Identifiable, SchemaProperty, CxxManaged, LatticeIsolated, LinkListable, UnionProperty {
    init(isolation: isolated (any Actor)?)
//    var lattice: Lattice? { get set }
    static var entityName: String { get }
    static var properties: [(String, any SchemaProperty.Type)] { get }
    var primaryKey: Int64? { get set }
    var globalId: UUID? { get }
    @available(*, deprecated, renamed: "globalId")
    var __globalId: UUID? { get }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    var _$observationRegistrar: Observation.ObservationRegistrar { get }
    func _objectWillChange_send()
    func _triggerObservers_send(keyPath: String)
    var _lastKeyPathUsed: String? { get set }
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String
    static var constraints: [Constraint] { get }
    static var fullTextProperties: Set<String> { get }
    static var indexedProperties: Set<String> { get }
    #if canImport(Combine)
    var _objectWillChange: Combine.ObservableObjectPublisher { get }
    #else
    var _objectWillChange: ObservableObjectPublisher { get }
    #endif
    var _dynamicObject: ModelStorage { get set }
    var _instanceObservers: [_ModelObserver] { get set }
}

extension Model {
    package init(isolation: isolated (any Actor)? = #isolation,
                 dynamicObject: any ObjectBackend) {
        LatticePerf.bump(.materializations)
        self.init(isolation: isolation)
        self._dynamicObject._ref = dynamicObject
        // Register for cross-instance observation if this object has a primaryKey
        if self.primaryKey != nil {
            ModelInstanceRegistry.shared.register(self, tableName: Self.entityName)
        }
    }
    
    public init(_ refType: any ObjectBackend) {
        self.init(dynamicObject: refType)
    }

    // Boxing overload: query/list hydration produces a C++ dynamic_object_ref
    // (FRT on 16.4+, value type below); this wraps it in a CxxObjectBackend.
    public init(dynamicObject refType: CxxDynamicObjectRef) {
        self.init(dynamicObject: CxxObjectBackend(refType) as any ObjectBackend)
    }
    public static func _makeLinkList(from storage: borrowing ModelStorage, named name: String) -> ModelLinkListRef<Self> {
        ModelLinkListRef(_ref: storage._ref.getLinkList(named: name))
    }
    
    public var asRefType: any ObjectBackend { self._dynamicObject._ref }
    
    public static var defaultValue: Self {
        .init(isolation: #isolation)
    }
    public static var sqlType: String { "BIGINT" }
    public static var anyPropertyKind: AnyProperty.Kind { .int }
    public static var fullTextProperties: Set<String> { [] }
    public static var indexedProperties: Set<String> { [] }

    public var lattice: Lattice? {
        _dynamicObject._ref.lattice?.asCxxLatticeRef.flatMap { Lattice.init(ref: $0) }
    }

    /// Cheap managed-check: true when the object is persisted (has an owning
    /// db). Avoids the box→unbox→cache-lookup round trip of `lattice != nil`.
    public var isManaged: Bool { _dynamicObject._ref.hasLattice }

    /// Fire all instance-level observers whose property filter matches (or have no filter).
    public func _fireObservers(propertyName: String) {
        for observer in _instanceObservers {
            if let filter = observer.propertyName {
                guard filter == propertyName else { continue }
            }
            observer.callback(propertyName)
        }
    }

    /// Observe any property change on this instance. The callback receives the property name.
    /// Returns an `AnyCancellable` that removes the observer when cancelled.
    public func observe(_ block: @escaping (String) -> Void) -> AnyCancellable {
        let observer = _ModelObserver(callback: block)
        let id = observer.id
        _instanceObservers.append(observer)
        return AnyCancellable { [weak self] in
            self?._instanceObservers.removeAll { $0.id == id }
        }
    }

    /// Observe a specific property on this instance. The callback receives the new value.
    /// Returns an `AnyCancellable` that removes the observer when cancelled.
    public func observe<T>(_ keyPath: KeyPath<Self, T>, _ block: @escaping (T) -> Void) -> AnyCancellable {
        let name = _name(for: keyPath)
        let observer = _ModelObserver(propertyName: name) { [weak self] _ in
            guard let self else { return }
            block(self[keyPath: keyPath])
        }
        let id = observer.id
        _instanceObservers.append(observer)
        return AnyCancellable { [weak self] in
            self?._instanceObservers.removeAll { $0.id == id }
        }
    }


    /// Called after a property mutation to notify other instances representing the same row.
    /// Uses the registry's cached database path to avoid accessing the C++ lattice ref,
    /// which may be a dangling raw pointer during teardown.
    ///
    /// `changedColumn` (item A Commit 8, §2.3 v1.1): the mapped SQL column a
    /// plain-property setter just updated — nil for mutations without a
    /// provable single-column UPDATE shape (virtual links, external
    /// callers), which keeps the Layer-1 bump on the conservative
    /// whole-table rule.
    public func _notifyOtherInstances(propertyName: String, changedColumn: String? = nil) {
        _fireObservers(propertyName: propertyName)
        guard let primaryKey else { return }
        guard let dbPath = ModelInstanceRegistry.shared.databasePath(for: self) else { return }
        // Item A §1.3 Layer 1 (Commit 1): a managed-property setter is a
        // settled autocommit write (or part of an explicit transaction that
        // bumps again at commit) — bump the generation epoch synchronously
        // so same-handle predicate/sort-membership changes are
        // read-your-writes exact, not one scheduler hop late. O(1) counter
        // update under a leaf lock; a no-op when the store has no live
        // results. (The synchronous CORE hook that also covers non-Swift
        // writers lands in Commit 3, §2.3.) Commit 8: the setter's column
        // rides along so the Layer-1 double bump classifies identically to
        // the hook's annotated classification — a nil-fields bump here
        // would clobber the skip the hook just preserved.
        GenerationCoordinatorRegistry.noteWrite(path: dbPath, tables: [Self.entityName],
                                                updatedColumns: changedColumn.map { [$0] })
        ModelInstanceRegistry.shared.notifyChange(
            databasePath: dbPath,
            tableName: Self.entityName,
            primaryKey: primaryKey,
            propertyName: propertyName,
            excludingInstanceId: ObjectIdentifier(self)
        )
    }

    /// Register this model if it has a primaryKey and isn't already registered.
    /// Called after `lattice.add()` so that manually-created models get registered.
    public func _registerIfNeeded() {
        guard primaryKey != nil else { return }
        if ModelInstanceRegistry.shared.databasePath(for: self) == nil {
            ModelInstanceRegistry.shared.register(self, tableName: Self.entityName)
        }
    }

    /// Called from deinit to deregister from cross-instance observation
    public func _deregisterFromInstanceRegistry() {
        ModelInstanceRegistry.shared.deregister(self, tableName: Self.entityName)
    }

    public static func getField(from storage: borrowing ModelStorage, named name: String) -> Self {
        let model = Self(isolation: #isolation)
        model._dynamicObject._ref = storage._ref.getObject(named: name)
        return model
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        storage._ref.setObject(named: name, value._dynamicObject._ref)
    }

    #if canImport(Combine)
    public typealias ObservableObjectPublisher = AnyPublisher<Void, Never>

    // 3️⃣ override the protocol's publisher
    public var objectWillChange: Combine.ObservableObjectPublisher {
        _objectWillChange
    }
    #else
    public var objectWillChange: ObservableObjectPublisher {
        _objectWillChange
    }
    #endif
    
    public var id: some Hashable {
        if let primaryKey {
            AnyHashable(primaryKey)
        } else {
            AnyHashable(ObjectIdentifier(self))
        }
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
    typealias SwiftSchema = lattice.SwiftSchema
    
    internal static func cxxPropertyDescriptor() -> lattice.SwiftSchema {
        var schema = SwiftSchema()
        // Filter out id and globalId - these are auto-added by C++
        let filteredProperties = properties.filter { $0.0 != "id" && $0.0 != "globalId" }

        let primitiveProperties: [(String, any PrimitiveProperty.Type)] = filteredProperties.compactMap {
            if let primitiveType = $0.1 as? (any PrimitiveProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let linkProperties: [(String, any LinkProperty.Type)] = filteredProperties.compactMap {
            if let primitiveType = $0.1 as? (any LinkProperty.Type) {
                return ($0.0, primitiveType)
            }
            return nil
        }
        let geoProperties: [(String, any GeoboundsProperty.Type)] = filteredProperties.compactMap {
            if let geotype = $0.1 as? (any GeoboundsProperty.Type) {
                return ($0.0, geotype)
            }
            return nil
        }
        
        for (name, property) in geoProperties {
            // Check if this is a geo_bounds list (List<CLLocationCoordinate2D>, etc.)
            let isGeoBoundsList = property is (any ListProperty.Type)
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: isGeoBoundsList ? .list : .primitive,
                                             target_table: .init(),
                                             link_table: .init(),
                                             nullable: property is (any OptionalProtocol.Type),
                                             is_vector: false, is_geo_bounds: true,
                                             is_full_text: false,
                                             is_indexed: false,
                                             is_unique: false, column_name: .init(),
                                                     is_union: false, union_desc: .init())
        }

        for (name, property) in primitiveProperties {
            // Map Swift property kind to C++ column_type
            let columnType: lattice.column_type = switch property.anyPropertyKind {
            case .int, .int64: .integer
            case .float, .double, .date: .real
            case .data: .blob
            case .string, .null: .text
            }
            // Check if this is a Vector type for automatic vec0 indexing
            let isVector = property is Vector<Float>.Type || property is Vector<Double>.Type
            let isFullText = fullTextProperties.contains(name)
            let isIndexed = indexedProperties.contains(name)
            schema[std.string(name)] = .init(name: std.string(name), type: columnType, kind: .primitive,
                                             target_table: .init(), link_table: .init(),
                                             nullable: property is (any OptionalProtocol.Type),
                                             is_vector: isVector, is_geo_bounds: false,
                                             is_full_text: isFullText,
                                             is_indexed: isIndexed,
                                             is_unique: false,
                                             column_name: .init(),
                                             is_union: false, union_desc: .init())
        }

        for (name, property) in linkProperties {
            let isVector = property is (any ListProperty.Type)
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: isVector ? .list : .link,
                                             target_table: std.string(property.modelType.entityName),
                                             link_table: .init(Self.entityName),
                                             nullable: true, is_vector: isVector, is_geo_bounds: false,
                                             is_full_text: false,
                                             is_indexed: false,
                                             is_unique: false, column_name: .init(),
                                                     is_union: false, union_desc: .init())
        }

        let virtualListProperties: [(String, any VirtualListProperty.Type)] = filteredProperties.compactMap {
            if let vlType = $0.1 as? (any VirtualListProperty.Type) {
                return ($0.0, vlType)
            }
            return nil
        }

        for (name, _) in virtualListProperties {
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: .virtual_list,
                                             target_table: .init(),
                                             link_table: .init(Self.entityName),
                                             nullable: true, is_vector: false, is_geo_bounds: false,
                                             is_full_text: false,
                                             is_indexed: false,
                                             is_unique: false, column_name: .init(),
                                                     is_union: false, union_desc: .init())
        }

        let virtualLinkProperties: [(String, VirtualLinkMarker.Type)] = filteredProperties.compactMap {
            if $0.1 is VirtualLinkMarker.Type {
                return ($0.0, VirtualLinkMarker.self)
            }
            return nil
        }

        for (name, _) in virtualLinkProperties {
            schema[std.string(name)] = .init(name: std.string(name), type: .integer,
                                             kind: .virtual_link,
                                             target_table: .init(),
                                             link_table: .init(Self.entityName),
                                             nullable: true, is_vector: false, is_geo_bounds: false,
                                             is_full_text: false,
                                             is_indexed: false,
                                             is_unique: false, column_name: .init(),
                                                     is_union: false, union_desc: .init())
        }

        // Union properties — detected by LatticeUnion conformance
        let unionProperties: [(String, any LatticeUnion.Type)] = filteredProperties.compactMap {
            if let unionType = $0.1 as? (any LatticeUnion.Type) {
                return ($0.0, unionType)
            }
            return nil
        }

        for (name, property) in unionProperties {
            // Build the C++ union_descriptor from Swift metadata
            var udesc = LatticeSwiftCppBridge.lattice.union_descriptor()
            udesc.union_table_name = std.string(property.unionTableName)
            for caseDesc in property.unionCases {
                var uc = LatticeSwiftCppBridge.lattice.union_case()
                uc.case_name = std.string(caseDesc.name)
                for field in caseDesc.fields {
                    var ucv = LatticeSwiftCppBridge.lattice.union_case_value()
                    ucv.param_name = std.string(field.label)

                    // Determine column type from the field's actual type
                    if let linkType = field.type as? any LinkProperty.Type {
                        ucv.type = .text
                        ucv.is_link = true
                        ucv.link_target = std.string(linkType.modelType.entityName)
                    } else if let primitiveType = field.type as? any PrimitiveProperty.Type {
                        ucv.type = switch primitiveType.anyPropertyKind {
                        case .int, .int64: .integer
                        case .float, .double, .date: .real
                        case .data: .blob
                        case .string, .null: .text
                        }
                        ucv.is_link = false
                    } else {
                        ucv.type = .text
                        ucv.is_link = false
                    }
                    ucv.link_target = ucv.is_link ? ucv.link_target : std.string("")
                    uc.values.push_back(ucv)
                }
                udesc.cases.push_back(uc)
            }

            schema[std.string(name)] = .init(name: std.string(name), type: .text,
                                             kind: .union_type,
                                             target_table: std.string(property.unionTableName),
                                             link_table: .init(),
                                             nullable: true, is_vector: false, is_geo_bounds: false,
                                             is_full_text: false,
                                             is_indexed: false,
                                             is_unique: false, column_name: .init(),
                                             is_union: true, union_desc: udesc)
        }

        return schema
    }
    
    // Default CxxManaged stubs for Model types (so macros don't need to generate them)
    public typealias CxxManagedSpecialization = CxxManagedModel

    public static func fromCxxValue(_ value: CxxManagedModel.SwiftType) -> Self {
        fatalError()
    }

    public static func getManaged(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedModel {
        fatalError()
    }

    public static func getManagedOptional(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedModel.OptionalType {
        object.get_managed_field(name)
    }

    public static var defaultCxxLatticeObject: CxxDynamicObject {
        CxxDynamicObject(CxxLatticeObject(std.string(entityName), cxxPropertyDescriptor()))
    }
}

public func _defaultCxxLatticeObject<M>(_ model: M.Type) -> CxxDynamicObject where M: Model {
    CxxDynamicObject(CxxLatticeObject(std.string(M.entityName), M.cxxPropertyDescriptor()))
}

// MARK: - UnionProperty conformance (links stored as globalId TEXT + link_ref)

extension Model {
    public static func getField(from uv: lattice.union_value, named name: String) -> Self {
        guard let linkRef = _optRef(uv.getLinkRef(std.string(name))) else {
            return Self(isolation: nil)
        }
        let model = Self(isolation: nil)
        model._dynamicObject._ref = CxxObjectBackend(linkRef)
        return model
    }

    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self) {
        let gid = value.globalId?.uuidString.lowercased() ?? ""
        uv.setString(std.string(name), std.string(gid))
        uv.setLinkRef(std.string(name), value._dynamicObject._ref.asCxxObjectRef!)
    }
}

extension Model {
    public var debugDescription: String {
        _dynamicObject._ref.debugDescription()
    }
}

func _name<T>(for keyPath: PartialKeyPath<T>) -> String where T: Model {
    let t = T(isolation: #isolation)
    _ = t[keyPath: keyPath]
    return t._lastKeyPathUsed ?? "id"
}

@attached(member, names: arbitrary)
@attached(extension, conformances: Model, Observable, names: arbitrary)
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "LatticeMacros",
                                      type: "ModelMacro")

@attached(extension, conformances: LatticeEnum, Codable, DetachableLeaf, names: arbitrary)
public macro LatticeEnum() = #externalMacro(module: "LatticeMacros",
                                            type: "EnumMacro")

@attached(extension, conformances: LatticeUnion, Codable, Sendable, Equatable, DetachableLeaf, names: arbitrary)
public macro Union() = #externalMacro(module: "LatticeMacros",
                                      type: "UnionMacro")

@attached(member, conformances: EmbeddedModel, names: arbitrary)
public macro EmbeddedModel() = #externalMacro(module: "LatticeMacros",
                                              type: "EmbeddedModelMacro")

@attached(member, names: arbitrary)
@attached(extension, conformances: Codable, names: arbitrary)
public macro Codable() = #externalMacro(module: "LatticeMacros",
                                        type: "CodableMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "LatticeMacros",
                                      type: "TransientMacro")

@attached(peer)
public macro FullText() = #externalMacro(module: "LatticeMacros",
                                         type: "FullTextMacro")


@attached(accessor, names: arbitrary)
public macro Property(name mappedTo: String? = nil) = #externalMacro(module: "LatticeMacros",
                                                                     type: "PropertyMacro")

@attached(accessor, names: arbitrary)
public macro VirtualLinkProperty(name mappedTo: String? = nil) = #externalMacro(
    module: "LatticeMacros", type: "VirtualLinkPropertyMacro")


@attached(peer)
public macro Unique<T>(compoundedWith: PartialKeyPath<T>...,
                       allowsUpsert: Bool = false) = #externalMacro(module: "LatticeMacros",
                                                           type: "UniqueMacro")

@attached(peer)
public macro Unique(allowsUpsert: Bool = false) = #externalMacro(module: "LatticeMacros",
                                                                 type: "UniqueMacro")

@attached(peer)
public macro Indexed() = #externalMacro(module: "LatticeMacros",
                                        type: "IndexedMacro")

/// Override the JSON key used by `@Codable` for this property.
/// Does not affect the SQLite column name (use `@Property(name:)` for that).
@attached(peer)
public macro CodingKey(_ key: String) = #externalMacro(module: "LatticeMacros",
                                                        type: "CodingKeyMacro")

/// Exclude this property from `@Codable` encoding/decoding.
/// The property is still persisted in Lattice — only JSON serialization is skipped.
@attached(peer)
public macro CodableIgnored() = #externalMacro(module: "LatticeMacros",
                                                type: "CodableIgnoredMacro")

// MARK: Constraints
public struct Constraint {
    public var columns: [String]
    public var allowsUpsert: Bool
    public init(columns: [String], allowsUpsert: Bool = false) {
        self.columns = columns
        self.allowsUpsert = allowsUpsert
    }
}

public typealias LatticeModel = Model
extension Lattice {
    public typealias Model = LatticeModel
}
