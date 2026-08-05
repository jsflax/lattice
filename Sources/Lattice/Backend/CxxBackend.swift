import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule
import CxxStdlib

// The backend protocols expose a `lattice` property, which shadows the C++
// `lattice` namespace inside the conformers. Alias the C++ types we need so we
// never have to write `lattice.X` in a method body.
private typealias CxxByteVector = lattice.ByteVector

// MARK: - FRT/value import-gap helpers
//
// A C++ `dynamic_object_ref` returned from a factory/getter imports as an
// OPTIONAL foreign-reference class on iOS 16.4+ (the FRT path) but as a
// NON-OPTIONAL value type on iOS 15 (the #if value-type path). These two
// helpers let one shared Swift call site handle both: a non-optional value
// promotes to `.some`, so the same code compiles and behaves correctly on each
// deployment target. `isValid` (always present on both) distinguishes a real
// ref from the empty/absent ref the value path returns instead of null.

/// Unwrap a ref that is guaranteed present (e.g. a fresh `wrap`/`create`).
/// The `isValid` precondition gives the value path the same fail-fast behavior
/// the FRT path gets from `!` on a nil pointer (an invalid value-path ref
/// would otherwise flow on to a null-shared_ptr deref).
@inline(__always) func _requireRef(_ r: CxxDynamicObjectRef?) -> CxxDynamicObjectRef {
    let v = r!
    precondition(v.isValid(), "expected a valid dynamic_object_ref")
    return v
}

/// Geo analog of `_requireRef` (FRT-optional vs value-non-optional gap).
@inline(__always) func _requireGeoRef(_ r: lattice.geo_bounds_ref?) -> lattice.geo_bounds_ref {
    let v = r!
    precondition(v.isValid(), "expected a valid geo_bounds_ref")
    return v
}

/// Normalize a nullable ref to a Swift optional: nil when absent (FRT null) or
/// empty (value-path `isValid()==false`).
@inline(__always) func _optRef(_ r: CxxDynamicObjectRef?) -> CxxDynamicObjectRef? {
    guard let r, r.isValid() else { return nil }
    return r
}

/// Same normalization for the db ref: `swift_lattice_ref` imports as an optional
/// FRT on 16.4+ but as a non-optional value (empty when absent) on iOS 15. A
/// non-optional argument promotes to `.some`, so one call site
/// (`_optLatticeRef(...).map { CxxBackend($0) }`) compiles and behaves on both.
@inline(__always) func _optLatticeRef(_ r: lattice.swift_lattice_ref?) -> lattice.swift_lattice_ref? {
    guard let r, r.isValid() else { return nil }
    return r
}

/// Unwrap a db ref that is guaranteed present (e.g. a fresh `create`). On the FRT
/// path the factory returns an optional reference; on the value path it returns a
/// non-optional value that promotes to `.some`, so `!` is valid on both. The
/// `isValid` precondition restores fail-fast on the value path (where an empty
/// ref would otherwise pass `!` and null-deref later).
@inline(__always) func _requireLatticeRef(_ r: lattice.swift_lattice_ref?) -> lattice.swift_lattice_ref {
    let v = r!
    precondition(v.isValid(), "expected a valid swift_lattice_ref")
    return v
}

extension LatticeBackend {
    /// The underlying C++ `swift_lattice_ref`. Used by the paths that drive the
    /// C++ surface directly (object-observer registration, `attach`, nearest
    /// queries). Available on every OS: below the FRT floor the ref is a
    /// copyable value type over the same shared db.
    var asCxxLatticeRef: lattice.swift_lattice_ref? {
        return (self as? CxxBackend)?.ref
    }

    // Sealed-query error surface, protocol-untouched (cast-based, like
    // asCxxLatticeRef): non-C++ backends report nothing. Concrete
    // implementations live on CxxBackend and shadow these for direct calls.

    /// The last sealed-query failure on the CURRENT THREAD, or nil if the
    /// most recent query call succeeded. Check immediately after the call.
    func lastQueryError() -> String? {
        (self as? CxxBackend)?.lastQueryError()
    }

    /// Register a handler for sealed-query failures (nil clears). No-op on
    /// non-C++ backends.
    func setOnQueryError(_ handler: (@Sendable (String) -> Void)?) {
        (self as? CxxBackend)?.setOnQueryError(handler)
    }
}

extension ObjectBackend {
    /// The underlying C++ `dynamic_object_ref`, when this is the C++ backend.
    /// Used by the deferred (geo/union/managed) accessors that stay C++-only.
    var asCxxObjectRef: CxxDynamicObjectRef? {
        return (self as? CxxObjectBackend)?.ref
    }
}

// The C++ conformers of the backend protocols. They wrap the lattice handle
// types and translate the neutral (Swift-native) protocol surface to/from
// std.string / lattice.* at the boundary. The handles work on every OS: on
// iOS 16.4+/macOS 13.3+ they are foreign-reference classes; below that floor
// they compile as copyable value types over the same shared_ptr-owned state
// (LATTICE_HAS_FRT in LatticeCore), so there is no separate iOS-15 backend.
// `final class` + `@inlinable` forwarding keeps the hot path close to direct
// dispatch.

// MARK: - CxxObjectBackend (wraps dynamic_object_ref) — the hot path

final class CxxObjectBackend: ObjectBackend, @unchecked Sendable {
    let ref: CxxDynamicObjectRef

    @inlinable init(_ ref: CxxDynamicObjectRef) { self.ref = ref }

    var tableName: String { String(ref.getTableName()) }
    var lattice: (any LatticeBackend)? { _optLatticeRef(ref.lattice).map { CxxBackend($0) } }
    @inlinable var hasLattice: Bool { ref.is_managed() }

    @inlinable func hasValue(named name: String) -> Bool { ref.hasValue(named: std.string(name)) }
    func setNull(named name: String) {
        _annotatedSingleColumnWrite(column: name) { ref.setNil(named: std.string(name)) }
    }

    /// Item A Commit 8 (§2.3 v1.1): a managed single-column primitive write
    /// is, by construction, an UPDATE of exactly `column` on this object's
    /// table — but the core populates no `changedFieldsNames` for local
    /// writes, so the synchronous invalidation hook (which fires INLINE on
    /// this thread, inside the C++ set call, for an autocommit write) would
    /// otherwise classify the commit as "fields unknown ⇒ must invalidate".
    /// Bracketing the call with a thread-local annotation lets the
    /// coordinator's hook callback supply the missing field list precisely.
    /// Deterministically scoped: set before the write, cleared when it
    /// returns — a leaked annotation could misclassify a later INSERT as
    /// UPDATE-only (a missed invalidation), so the bracket is the whole
    /// contract. Unmanaged sets skip the bracket (no commit can fire);
    /// writes inside an explicit transaction settle later, outside the
    /// bracket, and stay conservatively classified. Multi-statement writes
    /// (`setObject`, link lists) are deliberately NOT annotated.
    private func _annotatedSingleColumnWrite(column: String, _ body: () -> Void) {
        guard ref.is_managed() else { return body() }
        LocalWriteFieldAnnotation.with(table: String(ref.getTableName()), column: column, body)
    }

    // Materialized reads — forwarded to the dynamic_object row cache.
    @inlinable func enableRowCache() { ref.enableRowCache() }
    @inlinable func disableRowCache() { ref.disableRowCache() }
    @inlinable func refreshRowCache() { ref.refreshRowCache() }
    @inlinable var isRowCacheEnabled: Bool { ref.isRowCacheEnabled() }
    func incrementInt(named name: String, by delta: Int64) {
        _annotatedSingleColumnWrite(column: name) {
            ref.incrementIntField(named: std.string(name), by: delta)
        }
    }

    @inlinable func getInt(named name: String) -> Int64 { Int64(ref.getInt(named: std.string(name))) }
    @inlinable func getDouble(named name: String) -> Double { ref.getDouble(named: std.string(name)) }
    @inlinable func getFloat(named name: String) -> Float { ref.getFloat(named: std.string(name)) }
    @inlinable func getBool(named name: String) -> Bool { ref.getBool(named: std.string(name)) }
    @inlinable func getString(named name: String) -> String { String(ref.getString(named: std.string(name))) }
    func getData(named name: String) -> Data {
        // Linux interop: feeding the returned std.vector temporary straight
        // into Data.init(Sequence) crashes — the Collection witnesses run
        // against an unmaterialized temporary (null self in count.getter,
        // observed on aarch64 Linux). Bind it, guard empty, copy explicitly.
        let vec = ref.getData(named: std.string(name))
        let count = Int(vec.size())
        guard count > 0 else { return Data() }
        var out = Data(capacity: count)
        for i in 0..<count { out.append(vec[i]) }
        return out
    }

    func setInt(named name: String, _ value: Int64) {
        _annotatedSingleColumnWrite(column: name) { ref.setInt(named: std.string(name), value) }
    }
    func setDouble(named name: String, _ value: Double) {
        _annotatedSingleColumnWrite(column: name) { ref.setDouble(named: std.string(name), value) }
    }
    func setFloat(named name: String, _ value: Float) {
        _annotatedSingleColumnWrite(column: name) { ref.setFloat(named: std.string(name), value) }
    }
    func setBool(named name: String, _ value: Bool) {
        _annotatedSingleColumnWrite(column: name) { ref.setBool(named: std.string(name), value) }
    }
    func setString(named name: String, _ value: String) {
        _annotatedSingleColumnWrite(column: name) { ref.setString(named: std.string(name), std.string(value)) }
    }
    func setData(named name: String, _ value: Data) {
        _annotatedSingleColumnWrite(column: name) {
            ref.setData(named: std.string(name), value.reduce(into: CxxByteVector()) { $0.push_back($1) })
        }
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

final class CxxObjectListBackend: ObjectListBackend, @unchecked Sendable {
    let ref: lattice.link_list_ref

    @inlinable init(_ ref: lattice.link_list_ref) { self.ref = ref }

    var size: Int { ref.size() }
    var linkTableName: String { String(ref.linkTableName) }
    var lattice: (any LatticeBackend)? { _optLatticeRef(ref.lattice).map { CxxBackend($0) } }

    func object(at position: Int) -> (any ObjectBackend)? {
        let proxy = ref[position]
        guard let objRef = _optRef(proxy.objectRef) else { return nil }
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
    func findIndices(matching predicate: String?, orderedBy column: String?, ascending: Bool) -> [Int] {
        let results = ref.findIndices(predicate: std.string(predicate ?? ""),
                                      orderBy: std.string(column ?? ""),
                                      ascending: ascending)
        return (0..<results.count).map { Int(results[$0]) }
    }
}

// MARK: - CxxBackend (wraps swift_lattice_ref)

final class CxxBackend: LatticeBackend, @unchecked Sendable {
    // The db ops are const forwarders on swift_lattice_ref, so they import
    // non-mutating on both paths and the handle can be a `let`.
    let ref: lattice.swift_lattice_ref

    // Push-style surface for sealed-query failures — the query analog of
    // setOnSyncError, but Swift-level: the C++ side has no query callback;
    // this backend checks the thread-local error slot after each query call
    // and fans out here. Guarded because queries run on many threads.
    private let onQueryErrorLock = NSLock()
    private var onQueryErrorHandler: (@Sendable (String) -> Void)?

    init(_ ref: lattice.swift_lattice_ref) { self.ref = ref }

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
        ref.add(cxx.ref, &err)
        if !err.msg.empty() { throw LatticeError.addFailed(String(err.msg)) }
    }
    // No cxx_error out-param on this bridge overload — a C++ failure here is
    // not detectable from Swift. `throws` satisfies the (throwing) protocol
    // requirement; this conformance never actually throws today.
    func addPreservingGlobalId(_ object: any ObjectBackend, globalId: UUID) throws {
        guard let cxx = object as? CxxObjectBackend else { preconditionFailure() }
        ref.add_preserving_global_id(cxx.ref, std.string(globalId.uuidString))
    }
    // Same as addPreservingGlobalId: the bulk bridge overload exposes no
    // failure signal, so this conformance never actually throws today.
    func addBulk(_ objects: [any ObjectBackend]) throws {
        var vec = lattice.DynamicObjectRefPtrVector()
        for o in objects {
            guard let cxx = o as? CxxObjectBackend else { preconditionFailure() }
            lattice.push_dynamic_object_ref(&vec, cxx.ref)
        }
        ref.add_bulk(&vec)
    }
    func remove(_ object: any ObjectBackend) -> Bool {
        guard let cxx = object as? CxxObjectBackend else { preconditionFailure() }
        return ref.remove(cxx.ref)
    }
    func object(primaryKey: Int64, table: String) -> (any ObjectBackend)? {
        let o = ref.object(primaryKey, std.string(table))
        return o.hasValue ? CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(o.pointee).make_shared())) : nil
    }
    func objectByGlobalId(_ globalId: String, table: String) -> (any ObjectBackend)? {
        guard let o = ref.object_by_global_id(std.string(globalId), std.string(table)).value else { return nil }
        return CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(o.pointee).make_shared()))
    }
    func objects(table: String, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?, distinctBy: String?) -> [any ObjectBackend] {
        let res = ref.objects(std.string(table), optStr(whereClause), optStr(orderBy), optInt(limit), optInt(offset), optStr(groupBy), optStr(distinctBy))
        reportQueryFailureIfAny()
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }
    func unionObjects(tables: [String], where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?) -> [any ObjectBackend] {
        let tableVec = tables.reduce(into: lattice.StringVector()) { $0.push_back(std.string($1)) }
        let res = ref.union_objects(tableVec, optStr(whereClause), optStr(orderBy), optInt(limit), optInt(offset))
        reportQueryFailureIfAny()
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }
    func count(table: String, where whereClause: String?, groupBy: String?, distinctBy: String?) -> Int64 {
        let n = Int64(ref.count(std.string(table), optStr(whereClause), optStr(groupBy), optStr(distinctBy)))
        reportQueryFailureIfAny()
        return n
    }
    func deleteWhere(table: String, where whereClause: String?) -> Bool {
        ref.delete_where(std.string(table), optStr(whereClause))
    }

    // Maintenance
    func trainUntrainedVec0Tables() { ref.trainUntrainedVec0Tables() }
    func waitForVec0Training() { ref.waitForVec0Training() }
    func vacuumVec0(table: String, column: String) -> Int64 { Int64(ref.vacuum_vec0(std.string(table), std.string(column))) }
    func vacuum() { ref.vacuum() }
    func safeCompactAuditLog(staleThresholdSeconds: Int64) -> Int64 { Int64(ref.safe_compact_audit_log(staleThresholdSeconds)) }
    func forceCompactAuditLog() -> Int64 { Int64(ref.force_compact_audit_log()) }
    func backdateReplicationSlots(seconds: Int64) { ref.backdate_replication_slots(seconds) }
    func checkpoint() { ref.checkpoint() }
    func optimize() { ref.optimize() }
    func beginTransaction() { ref.begin_transaction() }
    func commit() { ref.commit() }
    func rollback() { ref.rollback() }
    func close() { ref.close() }

    // Sync status
    func isSyncAgent() -> Bool { ref.is_sync_agent() }
    func isSyncConnected() -> Bool { ref.is_sync_connected() }
    func clearSyncFilter() { ref.clear_sync_filter() }

    // Spatial (R*Tree)
    func objectsWithinBBox(table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?) -> [any ObjectBackend] {
        let res = ref.objectsWithinBBox(table: std.string(table), geoColumn: std.string(geoColumn), minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, where: optStr(whereClause), orderBy: optStr(orderBy), limit: optInt(limit), offset: optInt(offset), groupBy: optStr(groupBy))
        reportQueryFailureIfAny()
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }
    func countWithinBBox(table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?) -> Int64 {
        let n = Int64(ref.countWithinBBox(table: std.string(table), geoColumn: std.string(geoColumn), minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, where: optStr(whereClause)))
        reportQueryFailureIfAny()
        return n
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
        let res = ref.combinedNearestQuery(table: std.string(table), bounds: cb, vectors: cv, geos: cg, texts: ct, where: optStr(whereClause), sort: cs, limit: limit, groupBy: optStr(groupBy), distinctBy: optStr(distinctBy))
        reportQueryFailureIfAny()
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
        let n = Int64(ref.combinedNearestQueryCount(table: std.string(table), bounds: cb, vectors: cv, geos: cg, texts: ct, where: optStr(whereClause), sort: cs, limit: limit, groupBy: optStr(groupBy), distinctBy: optStr(distinctBy)))
        reportQueryFailureIfAny()
        return n
    }

    // Attach another lattice's underlying handle (cloud-relay / multi-db).
    // Idempotent; failures (schema mismatch, alias collision, closed handle)
    // throw instead of crossing the interop boundary as C++ exceptions.
    func attach(_ other: any LatticeBackend) throws {
        guard let otherRef = other.asCxxLatticeRef else {
            fatalError("CxxBackend.attach requires a C++ backend on both sides")
        }
        guard ref.attach(otherRef) else {
            throw LatticeError.attachFailed(lastAttachError() ?? "unknown attach failure")
        }
    }

    func detach(_ other: any LatticeBackend) throws {
        guard let otherRef = other.asCxxLatticeRef else {
            fatalError("CxxBackend.detach requires a C++ backend on both sides")
        }
        guard ref.detach(otherRef) else {
            throw LatticeError.detachFailed(lastAttachError() ?? "unknown detach failure")
        }
    }

    private func lastAttachError() -> String? {
        let e = ref.last_attach_error()
        return e.__convertToBool() ? String(e.pointee) : nil
    }

    // Sync data ingestion — returns the affected globalId strings; the caller
    // parses them into UUIDs and checks `lastReceiveError()`.
    func receiveSyncData(_ data: Data) -> [String] {
        // Index loop, NOT .map: Sequence/Collection conformance operations on
        // imported C++ containers jump through a null protocol witness on
        // aarch64 Linux (Swift 6.3) — this exact line segfaulted the
        // production relay on the first received frame (Fly exit 139,
        // backtrace: null <- Collection witness for std.vector). Direct
        // method dispatch (size()/operator[]) is unaffected.
        let vec = ref.receive_sync_data(data.toCxxValue())
        var out: [String] = []
        out.reserveCapacity(vec.size())
        var i = 0
        while i < vec.size() {
            out.append(String(vec[i]))
            i += 1
        }
        return out
    }
    func lastReceiveError() -> String? {
        let e = ref.last_receive_error()
        return e.__convertToBool() ? String(e.pointee) : nil
    }

    // Sealed query surface (LatticeCore 1.2.4): the C++ side never throws
    // into Swift — a failed query returns empty/0 and stashes the reason in
    // a THREAD-LOCAL slot. Same-thread, immediately-after-the-call
    // semantics, like lastGenerationReadStale().
    func lastQueryError() -> String? {
        let e = ref.last_query_error()
        return e.__convertToBool() ? String(e.pointee) : nil
    }

    func setOnQueryError(_ handler: (@Sendable (String) -> Void)?) {
        onQueryErrorLock.lock(); defer { onQueryErrorLock.unlock() }
        onQueryErrorHandler = handler
    }

    /// Called by each query method right after its bridge call: fan a
    /// sealed-query failure out to the registered handler. Cheap on the
    /// success path (one thread-local read).
    @inline(__always) private func reportQueryFailureIfAny() {
        guard let msg = lastQueryError() else { return }
        onQueryErrorLock.lock()
        let handler = onQueryErrorHandler
        onQueryErrorLock.unlock()
        handler?(msg)
    }

    // Sync filter — translate the neutral [SyncFilterParam] to the C++ vector.
    func updateSyncFilter(_ filter: [SyncFilterParam]) {
        ref.update_sync_filter(_makeCxxSyncFilter(filter.map { ($0.tableName, $0.whereClause) }))
    }

    func updateSyncFilter(_ filter: [SyncFilterParam], forChannel channel: String) {
        ref.update_sync_filter_for_channel(
            std.string(channel),
            _makeCxxSyncFilter(filter.map { ($0.tableName, $0.whereClause) }))
    }

    func clearSyncFilter(forChannel channel: String) {
        ref.clear_sync_filter_for_channel(std.string(channel))
    }

    func removeSyncChannelState(syncId: String) {
        ref.remove_sync_channel_state(std.string(syncId))
    }

    func deleteRowsNoRelay(table: String, globalRowIds: [String]) -> Int64 {
        var ids = lattice.StringVector()
        for id in globalRowIds { ids.push_back(std.string(id)) }
        return ref.delete_rows_no_relay(std.string(table), ids)
    }

    func removeTableObserver(table: String, observerId: UInt64) {
        ref.remove_table_observer(std.string(table), observerId)
    }

    func pendingSyncEntryCount() -> Int64 { Int64(ref.pending_sync_entry_count()) }

    // MARK: Item A — synchronous invalidation + read generations (Commit 5)

    /// C trampoline over `swift_lattice_ref.add_invalidation_hook`. The thunk
    /// runs INLINE in the writer's hook frame (§2.3): it copies the C-string
    /// table names (valid only for the duration of the callback) into Swift
    /// strings and calls the boxed closure — whose body must obey the §2.3
    /// restrictions (leaf-lock state stores only; no SQL; nothing that can
    /// throw).
    func addInvalidationHook(
        _ callback: @escaping @Sendable (_ changedTables: [String], _ reason: InvalidationReason) -> Void
    ) -> UInt64 {
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        return ref.add_invalidation_hook(
            ptr,
            { ctx, tables, count, reason in
                guard let ctx else { return }
                let box = Unmanaged<_CxxClosureBox<@Sendable ([String], InvalidationReason) -> Void>>
                    .fromOpaque(ctx).takeUnretainedValue()
                var names: [String] = []
                if count > 0, let tables {
                    names.reserveCapacity(count)
                    for i in 0..<count {
                        if let t = tables[i] { names.append(String(cString: t)) }
                    }
                }
                box.fn(names, InvalidationReason(rawValue: Int32(reason)) ?? .commit)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable ([String], InvalidationReason) -> Void>>
                    .fromOpaque(ctx).release()
            }
        )
    }

    /// Detailed variant (item A Commit 8, §2.3 v1.1) over
    /// `swift_lattice_ref.add_invalidation_hook_with_fields`. Same inline
    /// hook-frame contract as `addInvalidationHook`; the thunk additionally
    /// copies the parallel `changed_fields` C-string array (valid only for
    /// the duration of the callback) — per table, the comma-joined deduped
    /// union of plain field names when (and only when) every event for that
    /// table in the batch was an UPDATE with a known field list; empty
    /// otherwise (= must invalidate).
    func addInvalidationHookWithFields(
        _ callback: @escaping @Sendable (_ changes: [InvalidationTableChange], _ reason: InvalidationReason) -> Void
    ) -> UInt64 {
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        return ref.add_invalidation_hook_with_fields(
            ptr,
            { ctx, tables, fields, count, reason in
                guard let ctx else { return }
                let box = Unmanaged<_CxxClosureBox<@Sendable ([InvalidationTableChange], InvalidationReason) -> Void>>
                    .fromOpaque(ctx).takeUnretainedValue()
                var changes: [InvalidationTableChange] = []
                if count > 0, let tables {
                    changes.reserveCapacity(count)
                    for i in 0..<count {
                        guard let t = tables[i] else { continue }
                        // `fields` is parallel to `tables` (bridge contract);
                        // a missing entry decodes as "must invalidate".
                        let f: String
                        if let fields, let fp = fields[i] {
                            f = String(cString: fp)
                        } else {
                            f = ""
                        }
                        changes.append(InvalidationTableChange(table: String(cString: t),
                                                               changedFields: f))
                    }
                }
                box.fn(changes, InvalidationReason(rawValue: Int32(reason)) ?? .commit)
            },
            { ctx in
                guard let ctx else { return }
                Unmanaged<_CxxClosureBox<@Sendable ([InvalidationTableChange], InvalidationReason) -> Void>>
                    .fromOpaque(ctx).release()
            }
        )
    }

    func removeInvalidationHook(token: UInt64) {
        ref.remove_invalidation_hook(token)
    }

    func acquireReadGeneration() -> UInt64 { ref.acquire_read_generation() }
    func retainReadGeneration(_ generationID: UInt64) -> Bool {
        ref.retain_read_generation(generationID)
    }
    func releaseReadGeneration(_ generationID: UInt64) {
        ref.release_read_generation(generationID)
    }
    func retireAllReadGenerations() { ref.retire_all_read_generations() }
    func readGenerationsOutstanding() -> Int { Int(ref.read_generations_outstanding()) }
    func localReadGenerationsOutstanding() -> Int { Int(ref.local_read_generations_outstanding()) }
    func runReadPoolMaintenance() { ref.run_read_pool_maintenance() }

    func setReadGenerationTTLMs(_ ms: Int64) { ref.set_read_generation_ttl_ms(ms) }
    func setReadGenerationMaxAgeMs(_ ms: Int64) { ref.set_read_generation_max_age_ms(ms) }
    func setWALKeeperEvictionThresholdBytes(_ bytes: Int64) {
        ref.set_wal_keeper_eviction_threshold_bytes(bytes)
    }
    func walEvictionPending() -> Bool { ref.wal_eviction_pending() }

    func objectsAt(generation: UInt64, table: String, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?, distinctBy: String?) -> [any ObjectBackend] {
        let res = ref.objects_at(generation, std.string(table), optStr(whereClause), optStr(orderBy), optInt(limit), optInt(offset), optStr(groupBy), optStr(distinctBy))
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }

    func countAt(generation: UInt64, table: String, where whereClause: String?, groupBy: String?, distinctBy: String?) -> Int64 {
        ref.count_at(generation, std.string(table), optStr(whereClause), optStr(groupBy), optStr(distinctBy))
    }

    func objectsWithinBBoxAt(generation: UInt64, table: String, geoColumn: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, where whereClause: String?, orderBy: String?, limit: Int64?, offset: Int64?, groupBy: String?) -> [any ObjectBackend] {
        let res = ref.objectsWithinBBoxAt(generation: generation, table: std.string(table), geoColumn: std.string(geoColumn), minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, where: optStr(whereClause), orderBy: optStr(orderBy), limit: optInt(limit), offset: optInt(offset), groupBy: optStr(groupBy))
        var out: [any ObjectBackend] = []
        out.reserveCapacity(res.size())
        for i in 0..<res.size() { out.append(CxxObjectBackend(CxxDynamicObjectRef.wrap(CxxDynamicObject(res[i]).make_shared()))) }
        return out
    }

    func queryIDs(table: String, where whereClause: String?, orderBy: String?) -> [Int64] {
        // Index loop, NOT map/Collection conformance — see receiveSyncData
        // (imported-vector Collection witnesses segfault on aarch64 Linux).
        let vec = ref.query_ids_at(std.string(table), optStr(whereClause), optStr(orderBy))
        var out: [Int64] = []
        out.reserveCapacity(vec.size())
        var i = 0
        while i < vec.size() {
            out.append(Int64(vec[i]))
            i += 1
        }
        return out
    }

    func dataVersion() -> Int64 { ref.data_version() }
    func lastGenerationReadStale() -> Bool { ref.lastGenerationReadStale() }

    // ---- C trampolines: observer / sync callbacks ----
    // Each registers a retained boxed Swift closure as the C++ `void* ctx`, a
    // @convention(c) thunk that unpacks it, and a destroy thunk that releases it.
    // Passing nil clears the handler (mirrors the C++ nullptr branch).

    func addTableObserver(table: String, _ callback: @escaping @Sendable ([TableChangeEvent]) -> Void) -> UInt64 {
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        return ref.add_table_observer(
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
        guard let callback else { ref.set_on_sync_progress(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        ref.set_on_sync_progress(
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
        guard let callback else { ref.set_on_sync_error(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        ref.set_on_sync_error(
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
        guard let callback else { ref.set_on_sync_state_change(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        ref.set_on_sync_state_change(
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
        guard let callback else { ref.set_on_xproc_idle(nil, nil, nil); return }
        let box = _CxxClosureBox(callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        ref.set_on_xproc_idle(
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
private final class _CxxClosureBox<F>: @unchecked Sendable {
    let fn: F
    init(_ fn: F) { self.fn = fn }
}

/// Single conversion point for sync-filter entries → the C++ vector. Used by
/// `Configuration.cxxConfiguration()` (db + per-IPC-target filters) and
/// `CxxBackend.updateSyncFilter`, so the marshalling can't drift.
func _makeCxxSyncFilter(_ entries: [(String, String?)]) -> lattice.SyncFilterVector {
    var vec = lattice.SyncFilterVector()
    for (tableName, whereClause) in entries {
        var entry = lattice.sync_filter_entry()
        entry.table_name = std.string(tableName)
        if let whereClause {
            entry.where_clause = lattice.string_to_optional(std.string(whereClause))
        }
        vec.push_back(entry)
    }
    return vec
}
