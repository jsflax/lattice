// LatticeCore Phase 2 — runtime-dispatched backend protocols.
//
// Three backend-neutral protocol existentials that box the C++ foreign-reference
// types (iOS 16.4) on modern OSes and the future pure-C LatticeCAPI on iOS 15.
//
// Constraints honored:
//   * Each protocol is usable as `any` (no associated types in callable position).
//   * Each protocol is `Sendable` (and class-bound so the Cxx conformer is a
//     `final class` + `@inlinable` forwarding with zero extra indirection).
//   * Signatures are backend-neutral: only Swift-native types appear
//     (String, Int64, Int32, Double, Float, Bool, Data, UUID, UInt64) — no
//     std.* or lattice.* types leak into the protocol surface.
//   * Cross-references are consistent:
//       - object getter            -> any ObjectBackend
//       - getLinkList              -> any ObjectListBackend
//       - object's owning lattice  -> any LatticeBackend?
//       - lattice query results    -> [any ObjectBackend]
//       - NearestRow.object        -> any ObjectBackend
//
// Verified: xcrun swiftc -typecheck under -swift-version 5 AND -swift-version 6
// (strict concurrency, even with -warnings-as-errors) -> EXIT 0.

import Foundation

// MARK: - Neutral helper value types

/// A SQLite WHERE-fragment predicate carried as text. Backend-portable; the Cxx
/// conformer feeds it straight to find_where. A `String` alias for documentation.
public typealias SQLPredicate = String

/// One change event delivered to a table observer. Mirrors the parallel-array
/// payload the C trampoline decodes today (operation / row_id / global_row_id).
public struct TableChangeEvent: Sendable, Equatable {
    public var operation: String
    public var rowId: Int64
    public var globalRowId: String

    public init(operation: String, rowId: Int64, globalRowId: String) {
        self.operation = operation
        self.rowId = rowId
        self.globalRowId = globalRowId
    }
}

/// One sync-filter rule: a table plus an optional WHERE-fragment limiting which
/// rows upload. Replaces lattice.sync_filter_entry on the neutral surface.
public struct SyncFilterParam: Sendable, Equatable {
    public var tableName: String
    public var whereClause: String?

    public init(tableName: String, whereClause: String?) {
        self.tableName = tableName
        self.whereClause = whereClause
    }
}

/// Neutral geo-bounds value: the 4 doubles of lattice::geo_bounds.
/// center_lat/lon and lat/lon_span are intentionally omitted (derivable).
public struct GeoBoundsValue: Sendable, Equatable {
    public var minLat: Double
    public var maxLat: Double
    public var minLon: Double
    public var maxLon: Double

    public init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }
}

// MARK: - Composite-nearest neutral param structs (replace lattice.*_constraint)

public struct BoundsConstraintParam: Sendable, Equatable {
    public var column: String
    public var minLat: Double
    public var maxLat: Double
    public var minLon: Double
    public var maxLon: Double

    public init(column: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.column = column
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }
}

public struct VectorConstraintParam: Sendable, Equatable {
    public var column: String
    public var queryVector: [UInt8]   // was lattice.ByteVector
    public var k: Int32               // C++ int width
    public var metric: Int32

    public init(column: String, queryVector: [UInt8], k: Int32, metric: Int32) {
        self.column = column
        self.queryVector = queryVector
        self.k = k
        self.metric = metric
    }
}

public struct GeoConstraintParam: Sendable, Equatable {
    public var column: String
    public var centerLat: Double
    public var centerLon: Double
    public var radiusMeters: Double

    public init(column: String, centerLat: Double, centerLon: Double, radiusMeters: Double) {
        self.column = column
        self.centerLat = centerLat
        self.centerLon = centerLon
        self.radiusMeters = radiusMeters
    }
}

public struct TextConstraintParam: Sendable, Equatable {
    public var column: String
    public var searchText: String
    public var limit: Int32

    public init(column: String, searchText: String, limit: Int32) {
        self.column = column
        self.searchText = searchText
        self.limit = limit
    }
}

public enum SortKind: Int32, Sendable {
    case none = 0
    case geoDistance = 1
    case vectorDistance = 2
    case property = 3
    case textRank = 4
}

public struct SortDescriptorParam: Sendable, Equatable {
    public var kind: SortKind
    public var column: String
    public var ascending: Bool

    public init(kind: SortKind, column: String, ascending: Bool) {
        self.kind = kind
        self.column = column
        self.ascending = ascending
    }
}

/// One row of a combined-nearest result: the boxed object plus per-column
/// distances. Replaces lattice.combined_query_result + distance_entry.
public struct NearestRow: Sendable {
    public var object: any ObjectBackend
    public var distances: [DistanceEntry]

    public init(object: any ObjectBackend, distances: [DistanceEntry]) {
        self.object = object
        self.distances = distances
    }
}

/// A single (column, distance) pair. A named struct rather than a tuple so the
/// row stays trivially `Sendable` and printable.
public struct DistanceEntry: Sendable, Equatable {
    public var column: String
    public var distance: Double

    public init(column: String, distance: Double) {
        self.column = column
        self.distance = distance
    }
}

// MARK: - ObjectBackend (per-object field access — the hot path)

/// Neutral per-object field accessor replacing lattice.dynamic_object_ref that
/// ModelStorage._ref holds today. The HOT PATH is getX/setX(named:); per-type
/// non-generic getters/setters (mirroring the existing CxxObject protocol) keep
/// the protocol existential and let the Cxx conformer be a `final class` with
/// `@inlinable` thunks. Class-bound, so setters are non-mutating.
public protocol ObjectBackend: AnyObject, Sendable {

    // Identity / metadata
    var tableName: String { get }
    var lattice: (any LatticeBackend)? { get }   // CROSS-REF; nil when unmanaged

    // Presence / nullability
    func hasValue(named name: String) -> Bool
    func setNull(named name: String)

    // Primitive getters (HOT)
    func getInt(named name: String) -> Int64
    func getDouble(named name: String) -> Double
    func getFloat(named name: String) -> Float
    func getBool(named name: String) -> Bool
    func getString(named name: String) -> String
    func getData(named name: String) -> Data

    // Primitive setters (HOT) — non-mutating (class-bound; ref is a reference)
    func setInt(named name: String, _ value: Int64)
    func setDouble(named name: String, _ value: Double)
    func setFloat(named name: String, _ value: Float)
    func setBool(named name: String, _ value: Bool)
    func setString(named name: String, _ value: String)
    func setData(named name: String, _ value: Data)

    // Linked object (CROSS-REF: self type)
    func getObject(named name: String) -> any ObjectBackend
    func setObject(named name: String, _ value: any ObjectBackend)

    // Link list (CROSS-REF: ObjectListBackend)
    func getLinkList(named name: String) -> any ObjectListBackend

    // Diagnostics
    func debugDescription() -> String
}

// MARK: - ObjectListBackend (link_list — List<Model> / VirtualList)

/// Neutral link-list surface. Split from the geo-bounds list because element
/// types differ (`any ObjectBackend` vs `GeoBoundsValue`); a single protocol
/// would need an associated Element in callable position, which makes the write
/// half (pushBack/setObject/findIndex) uncallable on the bare existential.
public protocol ObjectListBackend: AnyObject, Sendable {
    var size: Int { get }
    var linkTableName: String { get }            // "" for unmanaged lists
    var lattice: (any LatticeBackend)? { get }   // CROSS-REF; nil for unmanaged

    func object(at position: Int) -> (any ObjectBackend)?   // proxy.objectRef can be null
    func setObject(at position: Int, _ element: any ObjectBackend)
    func pushBack(_ element: any ObjectBackend)
    func erase(at position: Int)
    func clear()
    func findIndex(of element: any ObjectBackend) -> Int?
    func findWhere(_ predicate: SQLPredicate) -> [Int]
}

// MARK: - GeoBoundsListBackend (geo_bounds_list — List<MKCoordinateRegion> etc.)

/// Neutral geo-bounds-list surface. Distinct element type (`GeoBoundsValue`)
/// from ObjectListBackend, which is the concrete reason the two cannot share
/// one existential. NOTE: spatial features are modern-only today; this protocol
/// is defined for shape-completeness but ObjectBackend does NOT require
/// getGeoBoundsList in Phase 2 (geo accessors stay Cxx-gated).
public protocol GeoBoundsListBackend: AnyObject, Sendable {
    var size: Int { get }
    var linkTableName: String { get }
    var lattice: (any LatticeBackend)? { get }

    func bounds(at position: Int) -> GeoBoundsValue
    func setBounds(at position: Int, _ element: GeoBoundsValue)
    func pushBack(_ element: GeoBoundsValue)
    func erase(at position: Int)
    func clear()
    func findIndex(of element: GeoBoundsValue) -> Int?
    func findWhere(_ predicate: SQLPredicate) -> [Int]
}

// MARK: - LatticeBackend (db-level operations)

/// Neutral database-level surface. All members are per-query / per-snapshot, so
/// array-of-existential returns (allocating once per snapshot) match today's
/// vector-hydration cost. Class-bound for `final class` + `@inlinable`
/// forwarding on the Cxx conformer. The conformer holds BOTH the
/// swift_lattice_ref (for identity/cache key) and the swift_lattice& (ops).
public protocol LatticeBackend: AnyObject, Sendable {

    // Identity / diagnostics
    var identityHash: Int64 { get }   // stable cache key (per-config Lattice instance)
    var path: String { get }

    // CRUD
    func add(_ object: any ObjectBackend) throws
    func addPreservingGlobalId(_ object: any ObjectBackend, globalId: UUID)
    func addBulk(_ objects: [any ObjectBackend])
    @discardableResult func remove(_ object: any ObjectBackend) -> Bool

    // Fetch single
    func object(primaryKey: Int64, table: String) -> (any ObjectBackend)?
    func objectByGlobalId(_ globalId: String, table: String) -> (any ObjectBackend)?

    // Fetch many
    func objects(
        table: String,
        where whereClause: String?,
        orderBy: String?,
        limit: Int64?,
        offset: Int64?,
        groupBy: String?,
        distinctBy: String?
    ) -> [any ObjectBackend]

    func unionObjects(
        tables: [String],
        where whereClause: String?,
        orderBy: String?,
        limit: Int64?,
        offset: Int64?
    ) -> [any ObjectBackend]

    // Counts / deletes (collapsed arity overloads -> one requirement each)
    func count(table: String, where whereClause: String?, groupBy: String?, distinctBy: String?) -> Int64
    @discardableResult func deleteWhere(table: String, where whereClause: String?) -> Bool

    // Spatial (R*Tree)
    func objectsWithinBBox(
        table: String, geoColumn: String,
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        where whereClause: String?, orderBy: String?,
        limit: Int64?, offset: Int64?, groupBy: String?
    ) -> [any ObjectBackend]

    func countWithinBBox(
        table: String, geoColumn: String,
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        where whereClause: String?
    ) -> Int64

    // Composite proximity (vector + geo + bounds + text)
    func combinedNearestQuery(
        table: String,
        bounds: [BoundsConstraintParam],
        vectors: [VectorConstraintParam],
        geos: [GeoConstraintParam],
        texts: [TextConstraintParam],
        where whereClause: String?,
        sort: SortDescriptorParam,
        limit: Int64,
        groupBy: String?,
        distinctBy: String?
    ) -> [NearestRow]

    func combinedNearestQueryCount(
        table: String,
        bounds: [BoundsConstraintParam],
        vectors: [VectorConstraintParam],
        geos: [GeoConstraintParam],
        texts: [TextConstraintParam],
        where whereClause: String?,
        sort: SortDescriptorParam,
        limit: Int64,
        groupBy: String?,
        distinctBy: String?
    ) -> Int64

    // Vector-index maintenance
    func trainUntrainedVec0Tables()
    func waitForVec0Training()
    @discardableResult func vacuumVec0(table: String, column: String) -> Int64

    // Maintenance
    func vacuum()
    @discardableResult func safeCompactAuditLog(staleThresholdSeconds: Int64) -> Int64
    @discardableResult func forceCompactAuditLog() -> Int64
    func backdateReplicationSlots(seconds: Int64)
    func checkpoint()

    // Transactions
    func beginTransaction()
    func commit()

    // Lifecycle
    func close()
    func attach(_ other: any LatticeBackend)   // C++-to-C++; conformer downcasts peer

    // Sync status
    func isSyncAgent() -> Bool
    func isSyncConnected() -> Bool

    // Sync data flow
    func receiveSyncData(_ data: Data) -> [String]   // acked global ids
    func lastReceiveError() -> String?

    // Sync filter
    func updateSyncFilter(_ filter: [SyncFilterParam])
    func clearSyncFilter()

    // Observation — single @escaping @Sendable closure replaces C fn-ptr+ctx+destroy
    func addTableObserver(
        table: String,
        _ callback: @escaping @Sendable ([TableChangeEvent]) -> Void
    ) -> UInt64
    func removeTableObserver(table: String, observerId: UInt64)

    // Sync callbacks — optional closures; nil clears (matches nullptr branch)
    func setOnSyncProgress(
        _ callback: (@Sendable (_ pendingUpload: Int64, _ totalUpload: Int64, _ acked: Int64, _ received: Int64) -> Void)?
    )
    func setOnSyncError(_ callback: (@Sendable (String) -> Void)?)
    func setOnSyncStateChange(_ callback: (@Sendable (Bool) -> Void)?)
    /// NOTE: fires on the xproc background thread, NOT the scheduler — @Sendable is load-bearing.
    func setOnXprocIdle(_ callback: (@Sendable () -> Void)?)
}

// MARK: - Convenience default-arg wrappers (so callers needn't pass every label)
// Protocol requirements can't supply default args that participate in witness
// matching, so the ergonomic optionals live in an extension that forwards.

extension LatticeBackend {
    @inlinable
    public func objects(table: String) -> [any ObjectBackend] {
        objects(table: table, where: nil, orderBy: nil, limit: nil, offset: nil, groupBy: nil, distinctBy: nil)
    }
    @inlinable
    public func count(table: String, where whereClause: String? = nil) -> Int64 {
        count(table: table, where: whereClause, groupBy: nil, distinctBy: nil)
    }
    @inlinable
    public func deleteWhere(table: String) -> Bool {
        deleteWhere(table: table, where: nil)
    }
}
