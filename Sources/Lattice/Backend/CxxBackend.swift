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

    // Spatial (R*Tree)
    func objectsWithinBBox(table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?) -> [any ObjectBackend] {
        let res = l.objectsWithinBBox(table: std.string(table), geoColumn: std.string(geoColumn), minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, where: optStr(whereClause), orderBy: optStr(orderBy), limit: optInt(limit), offset: optInt(offset), groupBy: optStr(groupBy))
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }
    func countWithinBBox(table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?) -> Int64 {
        Int64(l.countWithinBBox(table: std.string(table), geoColumn: std.string(geoColumn), minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, where: optStr(whereClause)))
    }

    // Composite proximity — translate the neutral *Param structs to C++ constraint vectors.
    private func buildNearestCxx(_ bounds: [BoundsConstraintParam], _ vectors: [VectorConstraintParam], _ geos: [GeoConstraintParam], _ texts: [TextConstraintParam], _ sort: SortDescriptorParam) -> (lattice.BoundsConstraintVector, lattice.VectorConstraintVector, lattice.GeoConstraintVector, lattice.TextConstraintVector, lattice.sort_descriptor) {
        var cb = lattice.BoundsConstraintVector()
        for b in bounds { var x = lattice.bounds_constraint(); x.column = std.string(b.column); x.min_lat = b.minLat; x.max_lat = b.maxLat; x.min_lon = b.minLon; x.max_lon = b.maxLon; cb.push_back(x) }
        var cv = lattice.VectorConstraintVector()
        for v in vectors { var x = lattice.vector_constraint(); x.column = std.string(v.column); var bv = CxxByteVector(); for byte in v.queryVector { bv.push_back(byte) }; x.query_vector = bv; x.k = v.k; x.metric = v.metric; cv.push_back(x) }
        var cg = lattice.GeoConstraintVector()
        for g in geos { var x = lattice.geo_constraint(); x.column = std.string(g.column); x.center_lat = g.centerLat; x.center_lon = g.centerLon; x.radius_meters = g.radiusMeters; cg.push_back(x) }
        var ct = lattice.TextConstraintVector()
        for t in texts { var x = lattice.text_constraint(); x.column = std.string(t.column); x.search_text = std.string(t.searchText); x.limit = t.limit; ct.push_back(x) }
        var cs = lattice.sort_descriptor()
        switch sort.kind {
        case .geoDistance: cs.type = .geo_distance
        case .vectorDistance: cs.type = .vector_distance
        case .property: cs.type = .property
        case .textRank: cs.type = .text_rank
        case .none: break
        }
        cs.column = std.string(sort.column)
        cs.ascending = sort.ascending
        return (cb, cv, cg, ct, cs)
    }
    func combinedNearestQuery(table: String, bounds: [BoundsConstraintParam], vectors: [VectorConstraintParam], geos: [GeoConstraintParam], texts: [TextConstraintParam], where whereClause: String?, sort: SortDescriptorParam, limit: Int64, groupBy: String?, distinctBy: String?) -> [NearestRow] {
        let (cb, cv, cg, ct, cs) = buildNearestCxx(bounds, vectors, geos, texts, sort)
        let res = l.combinedNearestQuery(table: std.string(table), bounds: cb, vectors: cv, geos: cg, texts: ct, where: optStr(whereClause), sort: cs, limit: limit, groupBy: optStr(groupBy), distinctBy: optStr(distinctBy))
        var out: [NearestRow] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() {
            let r = res[i]
            let obj = CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(r.object).make_shared()))
            var d: [DistanceEntry] = []
            for j in 0..<r.distances.size() { let e = r.distances[j]; d.append(DistanceEntry(column: String(e.column), distance: e.distance)) }
            out.append(NearestRow(object: obj, distances: d))
        }
        return out
    }
    func combinedNearestQueryCount(table: String, bounds: [BoundsConstraintParam], vectors: [VectorConstraintParam], geos: [GeoConstraintParam], texts: [TextConstraintParam], where whereClause: String?, sort: SortDescriptorParam, limit: Int64, groupBy: String?, distinctBy: String?) -> Int64 {
        let (cb, cv, cg, ct, cs) = buildNearestCxx(bounds, vectors, geos, texts, sort)
        return Int64(l.combinedNearestQueryCount(table: std.string(table), bounds: cb, vectors: cv, geos: cg, texts: ct, where: optStr(whereClause), sort: cs, limit: limit, groupBy: optStr(groupBy), distinctBy: optStr(distinctBy)))
    }

    // Attach another lattice's underlying handle (cloud-relay / multi-db).
    func attach(_ other: any LatticeBackend) {
        guard let otherRef = other.asCxxLatticeRef else {
            fatalError("CxxBackend.attach requires a C++ backend on both sides")
        }
        l.attach(otherRef.get())
    }

    // Sync data ingestion — returns the affected globalId strings; the caller
    // parses them into UUIDs and checks `lastReceiveError()`.
    func receiveSyncData(_ data: Data) -> [String] {
        l.receive_sync_data(data.toCxxValue()).map { String($0) }
    }
    func lastReceiveError() -> String? {
        let e = l.last_receive_error()
        return e.__convertToBool() ? String(e.pointee) : nil
    }

    // Sync filter — translate the neutral [SyncFilterParam] to the C++ vector.
    func updateSyncFilter(_ filter: [SyncFilterParam]) {
        var entries = lattice.SyncFilterVector()
        for f in filter {
            var entry = lattice.sync_filter_entry()
            entry.table_name = std.string(f.tableName)
            if let whereClause = f.whereClause {
                entry.where_clause = lattice.string_to_optional(std.string(whereClause))
            }
            entries.push_back(entry)
        }
        l.update_sync_filter(entries)
    }

    func removeTableObserver(table: String, observerId: UInt64) {
        l.remove_table_observer(std.string(table), observerId)
    }

    func pendingSyncEntryCount() -> Int64 { Int64(l.pending_sync_entry_count()) }

    // ---- C trampolines: observer / sync callbacks ----
    // Each registers a retained boxed Swift closure as the C++ `void* ctx`, a
    // @convention(c) thunk that unpacks it, and a destroy thunk that releases it.
    // Passing nil clears the handler (mirrors the C++ nullptr branch).

    func addTableObserver(table: String, _ callback: @escaping @Sendable ([TableChangeEvent]) -> Void) -> UInt64 {
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        return l.add_table_observer(
            std.string(table),
            ptr,
            { ctx, ops, rowIds, gids, count in
                guard let ctx, count > 0, let ops, let rowIds, let gids else { return }
                let box = Unmanaged<_CxxClosureBox<@Sendable ([TableChangeEvent]) -> Void>>.fromOpaque(ctx).takeUnretainedValue()
                var events: [TableChangeEvent] = []
                events.reserveCapacity(count)
                for i in 0..<count {
                    let op = ops[i].map { String(cString: $0) } ?? ""
                    let gid = gids[i].map { String(cString: $0) } ?? ""
                    events.append(TableChangeEvent(operation: op, rowId: rowIds[i], globalRowId: gid))
                }
                box.fn(events)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable ([TableChangeEvent]) -> Void>>.fromOpaque(ctx).release()
            }
        )
    }

    func setOnSyncProgress(_ callback: (@Sendable (Int64, Int64, Int64, Int64) -> Void)?) {
        guard let callback else { l.set_on_sync_progress(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        l.set_on_sync_progress(
            ptr,
            { ctx, pending, total, acked, received in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable (Int64, Int64, Int64, Int64) -> Void>>.fromOpaque(ctx).takeUnretainedValue()
                    .fn(Int64(pending), Int64(total), Int64(acked), Int64(received))
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable (Int64, Int64, Int64, Int64) -> Void>>.fromOpaque(ctx).release()
            }
        )
    }

    func setOnSyncError(_ callback: (@Sendable (String) -> Void)?) {
        guard let callback else { l.set_on_sync_error(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        l.set_on_sync_error(
            ptr,
            { ctx, errorPtr, len in
                guard let ctx, let errorPtr else { return }
                let error = String(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: errorPtr),
                    length: Int(len),
                    encoding: .utf8,
                    freeWhenDone: false
                ) ?? "unknown error"
                Unmanaged<_CxxClosureBox<@Sendable (String) -> Void>>.fromOpaque(ctx).takeUnretainedValue().fn(error)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable (String) -> Void>>.fromOpaque(ctx).release()
            }
        )
    }

    func setOnSyncStateChange(_ callback: (@Sendable (Bool) -> Void)?) {
        guard let callback else { l.set_on_sync_state_change(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        l.set_on_sync_state_change(
            ptr,
            { ctx, connected in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable (Bool) -> Void>>.fromOpaque(ctx).takeUnretainedValue().fn(connected)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable (Bool) -> Void>>.fromOpaque(ctx).release()
            }
        )
    }

    func setOnXprocIdle(_ callback: (@Sendable () -> Void)?) {
        guard let callback else { l.set_on_xproc_idle(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        l.set_on_xproc_idle(
            ptr,
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable () -> Void>>.fromOpaque(ctx).takeUnretainedValue().fn()
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable () -> Void>>.fromOpaque(ctx).release()
            }
        )
    }
}

/// Retained box holding a Swift closure across the C `void* ctx` boundary.
/// `@unchecked Sendable`: the wrapped closure is itself `@Sendable`; the box is
/// just transport.
@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
private final class _CxxClosureBox<F>: @unchecked Sendable {
    let fn: F
    init(_ fn: F) { self.fn = fn }
}
