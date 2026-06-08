import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule
import CxxStdlib

// The backend protocols expose a `lattice` property, which shadows the C++
// `lattice` namespace inside the conformers. Alias the C++ types we need so we
// never have to write `lattice.X` in a method body.
private typealias CxxByteVector = lattice.ByteVector

extension LatticeBackend {
    /// The underlying C++ `swift_lattice_ref`, when this is the C++ backend
    /// (nil on the future C backend). Used by the still-C++-only paths (the
    /// cross-process object-observer registration, `attach`, etc.) that have no
    /// neutral surface yet.
    var asCxxLatticeRef: lattice.swift_lattice_ref? {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
            return (self as? CxxBackend)?.ref
        }
        return nil
    }
}

extension ObjectBackend {
    /// The underlying C++ `dynamic_object_ref`, when this is the C++ backend.
    /// Used by the deferred (geo/union/managed) accessors that stay C++-only.
    var asCxxObjectRef: CxxDynamicObjectRef? {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
            return (self as? CxxObjectBackend)?.ref
        }
        return nil
    }
}

// Phase 2 — the C++ conformers of the backend protocols. These wrap the existing
// SWIFT_SHARED_REFERENCE foreign-reference types and translate the neutral
// (Swift-native) protocol surface to/from std.string / lattice.* at the boundary.
// Gated @available(iOS 16.4,*) because the foreign-reference types are iOS 16.4+;
// iOS 15 gets the pure-C `CBackend` (Phase 3). `final class` + `@inlinable`
// forwarding keeps the modern hot path close to direct dispatch.
//
// NOTE: still a work in progress — `CxxBackend` (the LatticeBackend conformer)
// is a skeleton; the 38 db ops are filled in incrementally. The object/list
// conformers are complete.

// MARK: - CxxObjectBackend (wraps dynamic_object_ref) — the hot path

@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
final class CxxObjectBackend: ObjectBackend, @unchecked Sendable {
    // `var` so the (mutating, on the value-type ref) C++ setters can run inside
    // the protocol's non-mutating (class-bound) setters.
    var ref: CxxDynamicObjectRef

    @inlinable init(_ ref: CxxDynamicObjectRef) { self.ref = ref }

    var tableName: String { String(ref.getTableName()) }
    var lattice: (any LatticeBackend)? { ref.lattice.map { CxxBackend($0) } }

    @inlinable func hasValue(named name: String) -> Bool { ref.hasValue(named: std.string(name)) }
    @inlinable func setNull(named name: String) { ref.setNil(named: std.string(name)) }

    @inlinable func getInt(named name: String) -> Int64 { Int64(ref.getInt(named: std.string(name))) }
    @inlinable func getDouble(named name: String) -> Double { ref.getDouble(named: std.string(name)) }
    @inlinable func getFloat(named name: String) -> Float { ref.getFloat(named: std.string(name)) }
    @inlinable func getBool(named name: String) -> Bool { ref.getBool(named: std.string(name)) }
    @inlinable func getString(named name: String) -> String { String(ref.getString(named: std.string(name))) }
    func getData(named name: String) -> Data {
        Data(ref.getData(named: std.string(name)))
    }

    @inlinable func setInt(named name: String, _ value: Int64) { ref.setInt(named: std.string(name), value) }
    @inlinable func setDouble(named name: String, _ value: Double) { ref.setDouble(named: std.string(name), value) }
    @inlinable func setFloat(named name: String, _ value: Float) { ref.setFloat(named: std.string(name), value) }
    @inlinable func setBool(named name: String, _ value: Bool) { ref.setBool(named: std.string(name), value) }
    @inlinable func setString(named name: String, _ value: String) { ref.setString(named: std.string(name), std.string(value)) }
    func setData(named name: String, _ value: Data) {
        ref.setData(named: std.string(name), value.reduce(into: CxxByteVector()) { $0.push_back($1) })
    }

    func getObject(named name: String) -> any ObjectBackend {
        CxxObjectBackend(ref.getObject(named: std.string(name)))
    }
    func setObject(named name: String, _ value: any ObjectBackend) {
        guard let cxx = value as? CxxObjectBackend else {
            preconditionFailure("CxxObjectBackend.setObject requires a CxxObjectBackend peer")
        }
        ref.setObject(named: std.string(name), cxx.ref)
    }

    func getLinkList(named name: String) -> any ObjectListBackend {
        CxxObjectListBackend(ref.getLinkList(named: std.string(name)))
    }

    func debugDescription() -> String { String(ref.debug_description()) }
}

// MARK: - CxxObjectListBackend (wraps link_list_ref)

@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
final class CxxObjectListBackend: ObjectListBackend, @unchecked Sendable {
    var ref: lattice.link_list_ref

    @inlinable init(_ ref: lattice.link_list_ref) { self.ref = ref }

    var size: Int { ref.size() }
    var linkTableName: String { String(ref.linkTableName) }
    var lattice: (any LatticeBackend)? { ref.lattice.map { CxxBackend($0) } }

    func object(at position: Int) -> (any ObjectBackend)? {
        let proxy = ref[position]
        guard let objRef = proxy.objectRef else { return nil }
        return CxxObjectBackend(objRef)
    }
    func setObject(at position: Int, _ element: any ObjectBackend) {
        guard let cxx = element as? CxxObjectBackend else { preconditionFailure() }
        var proxy = ref[position]
        proxy.assign(cxx.ref)
    }
    func pushBack(_ element: any ObjectBackend) {
        guard let cxx = element as? CxxObjectBackend else { preconditionFailure() }
        ref.pushBack(cxx.ref)
    }
    func erase(at position: Int) { ref.erase(position) }
    func clear() { ref.clear() }
    func findIndex(of element: any ObjectBackend) -> Int? {
        guard let cxx = element as? CxxObjectBackend else { return nil }
        let opt = ref.findIndex(cxx.ref)
        return opt.hasValue ? Int(opt.pointee) : nil
    }
    func findWhere(_ predicate: SQLPredicate) -> [Int] {
        let results = ref.findWhere(std.string(predicate))
        return (0..<results.count).map { Int(results[$0]) }
    }
}

// MARK: - CxxBackend (wraps swift_lattice_ref) — SKELETON, filled in incrementally

@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
final class CxxBackend: LatticeBackend, @unchecked Sendable {
    let ref: lattice.swift_lattice_ref
    @inlinable var l: lattice.swift_lattice { ref.get() }

    @inlinable init(_ ref: lattice.swift_lattice_ref) { self.ref = ref }

    var identityHash: Int64 { Int64(ref.hash_value()) }
    var path: String { String(ref.path()) }

    // Neutral → C++ helpers
    @inline(__always) private func optStr(_ s: String?) -> lattice.OptionalString {
        s.map { lattice.string_to_optional(std.string($0)) } ?? .init()
    }
    @inline(__always) private func optInt(_ i: Int64?) -> lattice.OptionalInt64 {
        i.map { lattice.int64_to_optional($0) } ?? .init()
    }
    func add(_ object: any ObjectBackend) throws {
        guard let cxx = object as? CxxObjectBackend else { preconditionFailure("CxxBackend requires CxxObjectBackend") }
        var err = lattice.cxx_error()
        l.add(cxx.ref, &err)
        if !err.msg.empty() { throw Lattice.Error.databaseError(String(err.msg)) }
    }
    func addPreservingGlobalId(_ object: any ObjectBackend, globalId: UUID) {
        guard let cxx = object as? CxxObjectBackend else { preconditionFailure() }
        l.add_preserving_global_id(cxx.ref, std.string(globalId.uuidString))
    }
    func addBulk(_ objects: [any ObjectBackend]) {
        var vec = lattice.DynamicObjectRefPtrVector()
        for o in objects {
            guard let cxx = o as? CxxObjectBackend else { preconditionFailure() }
            lattice.push_dynamic_object_ref(&vec, cxx.ref)
        }
        l.add_bulk(&vec)
    }
    func remove(_ object: any ObjectBackend) -> Bool {
        guard let cxx = object as? CxxObjectBackend else { preconditionFailure() }
        return l.remove(cxx.ref)
    }
    func object(primaryKey: Int64, table: String) -> (any ObjectBackend)? {
        let o = l.object(primaryKey, std.string(table))
        return o.hasValue ? CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(o.pointee).make_shared())) : nil
    }
    func objectByGlobalId(_ globalId: String, table: String) -> (any ObjectBackend)? {
        guard let o = l.object_by_global_id(std.string(globalId), std.string(table)).value else { return nil }
        return CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(o.pointee).make_shared()))
    }
    func objects(table: String, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?, distinctBy: String?) -> [any ObjectBackend] {
        let res = l.objects(std.string(table), optStr(whereClause), optStr(orderBy), optInt(limit), optInt(offset), optStr(groupBy), optStr(distinctBy))
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }
    func unionObjects(tables: [String], where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?) -> [any ObjectBackend] {
        let tableVec = tables.reduce(into: lattice.StringVector()) { $0.push_back(std.string($1)) }
        let res = l.union_objects(tableVec, optStr(whereClause), optStr(orderBy), optInt(limit), optInt(offset))
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }
    func count(table: String, where whereClause: String?, groupBy: String?, distinctBy: String?) -> Int64 {
        Int64(l.count(std.string(table), optStr(whereClause), optStr(groupBy), optStr(distinctBy)))
    }
    func deleteWhere(table: String, where whereClause: String?) -> Bool {
        l.delete_where(std.string(table), optStr(whereClause))
    }

    // Maintenance
    func trainUntrainedVec0Tables() { l.trainUntrainedVec0Tables() }
    func waitForVec0Training() { l.waitForVec0Training() }
    func vacuumVec0(table: String, column: String) -> Int64 { Int64(l.vacuum_vec0(std.string(table), std.string(column))) }
    func vacuum() { l.vacuum() }
    func safeCompactAuditLog(staleThresholdSeconds: Int64) -> Int64 { Int64(l.safe_compact_audit_log(staleThresholdSeconds)) }
    func forceCompactAuditLog() -> Int64 { Int64(l.force_compact_audit_log()) }
    func backdateReplicationSlots(seconds: Int64) { l.backdate_replication_slots(seconds) }
    func checkpoint() { l.checkpoint() }
    func beginTransaction() { l.begin_transaction() }
    func commit() { l.commit() }
    func close() { l.close() }

    // Sync status
    func isSyncAgent() -> Bool { l.is_sync_agent() }
    func isSyncConnected() -> Bool { l.is_sync_connected() }
    func clearSyncFilter() { l.clear_sync_filter() }

    // ---- Remaining (next Phase-2 sub-tasks): constraint translation + C trampolines ----
    private func TODO(_ what: String) -> Never { fatalError("CxxBackend.\(what) not yet implemented") }
    func objectsWithinBBox(table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?) -> [any ObjectBackend] { TODO("objectsWithinBBox") }
    func countWithinBBox(table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?) -> Int64 { TODO("countWithinBBox") }
    func combinedNearestQuery(table: String, bounds: [BoundsConstraintParam], vectors: [VectorConstraintParam], geos: [GeoConstraintParam], texts: [TextConstraintParam], where whereClause: String?, sort: SortDescriptorParam, limit: Int64, groupBy: String?, distinctBy: String?) -> [NearestRow] { TODO("combinedNearestQuery") }
    func combinedNearestQueryCount(table: String, bounds: [BoundsConstraintParam], vectors: [VectorConstraintParam], geos: [GeoConstraintParam], texts: [TextConstraintParam], where whereClause: String?, sort: SortDescriptorParam, limit: Int64, groupBy: String?, distinctBy: String?) -> Int64 { TODO("combinedNearestQueryCount") }
    func attach(_ other: any LatticeBackend) { TODO("attach") }
    func receiveSyncData(_ data: Data) -> [String] { TODO("receiveSyncData") }
    func lastReceiveError() -> String? { TODO("lastReceiveError") }
    func updateSyncFilter(_ filter: [SyncFilterParam]) { TODO("updateSyncFilter") }
    func addTableObserver(table: String, _ callback: @escaping @Sendable ([TableChangeEvent]) -> Void) -> UInt64 { TODO("addTableObserver") }
    func removeTableObserver(table: String, observerId: UInt64) { TODO("removeTableObserver") }
    func setOnSyncProgress(_ callback: (@Sendable (Int64, Int64, Int64, Int64) -> Void)?) { TODO("setOnSyncProgress") }
    func setOnSyncError(_ callback: (@Sendable (String) -> Void)?) { TODO("setOnSyncError") }
    func setOnSyncStateChange(_ callback: (@Sendable (Bool) -> Void)?) { TODO("setOnSyncStateChange") }
    func setOnXprocIdle(_ callback: (@Sendable () -> Void)?) { TODO("setOnXprocIdle") }
}
