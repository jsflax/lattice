// The backend protocols — the neutral seam between the ORM and the C++ core.
//
// The conformers (CxxBackend.swift) wrap the lattice handle types, which work
// on every OS: foreign-reference classes on iOS 16.4+/macOS 13.3+, copyable
// value types over the same shared_ptr-owned state below that floor
// (LATTICE_HAS_FRT in LatticeCore). There is no other backend.
//
// Constraints honored:
//   * Each protocol is usable as `any` (no associated types in callable position).
//   * Each protocol is `Sendable` (and class-bound so the Cxx conformer is a
//     `final class` + `@inlinable` forwarding with zero extra indirection).
//     See the Sendable CONTRACT note on ObjectBackend/ObjectListBackend.
//   * Signatures are backend-neutral: only Swift-native types appear
//     (String, Int64, Int32, Double, Float, Bool, Data, UUID, UInt64) — no
//     std.* or lattice.* types leak into the protocol surface.
//   * Cross-references are consistent:
//       - object getter            -> any ObjectBackend
//       - getLinkList              -> any ObjectListBackend
//       - object's owning lattice  -> any LatticeBackend?
//       - lattice query results    -> [any ObjectBackend]
//       - NearestRow.object        -> any ObjectBackend

import Foundation

// MARK: - Neutral helper value types

/// A SQLite WHERE-fragment predicate carried as text. Backend-portable; the Cxx
/// conformer feeds it straight to find_where. A `String` alias for documentation.
public typealias SQLPredicate = String

/// One value bound to a `?` placeholder in a parameterized predicate.
///
/// The neutral mirror of the core's `column_value_t` variant. Ordered
/// positionally: `params[i]` binds the i-th `?` in the statement text, which is
/// why every renderer appends to the SQL string and to the parameter array in
/// the SAME traversal step (see `Query`'s parameterized channel).
///
/// A predicate rendered on the LITERAL channel always carries an EMPTY
/// parameter array — that channel is byte-identical to the pre-parameter
/// renderer and is the only form safe to splice into composed SQL text
/// (sync filters, union CASE-WHEN wrapping, `_unionSubquery`).
public enum QueryParameter: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

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

/// Why a synchronous invalidation fired (item A §2.3). Raw values mirror the
/// bridge's `invalidation_reason` codes.
public enum InvalidationReason: Int32, Sendable, Equatable {
    /// A settled commit. The payload names the batch's changed tables (empty
    /// for bookkeeping-only commits — the epoch bump is table-agnostic §2.3).
    case commit = 0
    /// A rolled-back transaction. No change batch is delivered by design, so
    /// any state captured while the transaction was open may be poisoned —
    /// re-capture at the next access (§4.1).
    case rollback = 1
    /// A generation-advance request (§3.3/§3.4): content did not change;
    /// facades re-pin at the next access so the WAL can rewind/truncate.
    case advance = 2
}

/// One table's slice of a synchronous-invalidation payload, in the detailed
/// (Commit 4 / v1.1) form (item A §2.3). Mirrors the bridge's
/// `invalidation_table_change`.
public struct InvalidationTableChange: Sendable, Equatable {
    public var table: String
    /// Comma-joined, deduped union of plain field names (e.g. "age,name").
    /// NON-EMPTY only when every event for `table` in the batch was an
    /// UPDATE with a known changed-field list — the only case where the
    /// Commit-8 disjointness skip may fire. EMPTY means the consumer MUST
    /// invalidate: INSERT/DELETE present (pre-change membership is
    /// unknowable post-hoc), fields unknown (local setter writes carry no
    /// changedFieldsNames in the core payload), or a rollback/advance
    /// signal.
    public var changedFields: String

    public init(table: String, changedFields: String) {
        self.table = table
        self.changedFields = changedFields
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
///
/// Sendable CONTRACT: `Sendable` here means "safe to TRANSPORT across
/// isolation, not to mutate concurrently". The underlying C++ object state
/// (dynamic_object) has no internal locking — per-object handles are
/// thread-confined by convention, and cross-thread handoff goes through
/// ThreadSafeReference. (The db-level LatticeBackend ops ARE internally
/// synchronized by lattice_db.)
public protocol ObjectBackend: AnyObject, Sendable {

    // Identity / metadata
    var tableName: String { get }
    var lattice: (any LatticeBackend)? { get }   // CROSS-REF; nil when unmanaged
    /// Cheap managed-check (no backend boxing) — `lattice != nil` without
    /// allocating the boxed handle. Used by the per-add guards.
    var hasLattice: Bool { get }

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

    // Materialized reads (row cache). Defaults are no-ops so non-Cxx
    // conformers are unaffected; the Cxx backend forwards to the
    // dynamic_object row cache (see its contract in the bridge header).
    func enableRowCache()
    func disableRowCache()
    func refreshRowCache()
    var isRowCacheEnabled: Bool { get }

    /// SQL-side atomic increment (`SET col = col + delta`). The default
    /// falls back to a non-atomic get+set for backends without native
    /// support.
    func incrementInt(named name: String, by delta: Int64)
}

public extension ObjectBackend {
    func enableRowCache() {}
    func disableRowCache() {}
    func refreshRowCache() {}
    var isRowCacheEnabled: Bool { false }
    func incrementInt(named name: String, by delta: Int64) {
        setInt(named: name, getInt(named: name) + delta)
    }
}

// MARK: - ObjectListBackend (link_list — List<Model> / VirtualList)

/// Neutral link-list surface. (Geo-bounds lists stay on the C++ handle surface
/// directly — see Geobounds.swift — so there is no geo list protocol here.)
///
/// Sendable CONTRACT: same as ObjectBackend — transport-only; link_list has no
/// internal locking, so list handles are thread-confined by convention.
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
    /// Positions of elements matching `predicate`, ordered by `column`
    /// (nil = list order). Positions only — no rows are hydrated.
    func findIndices(matching predicate: String?, orderedBy column: String?, ascending: Bool) -> [Int]
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
    // All three insert paths `throw` for contract stability. Today only
    // `add` has a detectable failure signal from the Cxx bridge (a cxx_error
    // out-param); the preserving-globalId and bulk paths surface no error
    // and their conformances simply never throw — the requirement is throwing
    // so backends CAN report failures without another surface break.
    func add(_ object: any ObjectBackend) throws
    func addPreservingGlobalId(_ object: any ObjectBackend, globalId: UUID) throws
    func addBulk(_ objects: [any ObjectBackend]) throws
    @discardableResult func remove(_ object: any ObjectBackend) -> Bool

    // Fetch single
    func object(primaryKey: Int64, table: String) -> (any ObjectBackend)?
    func objectByGlobalId(_ globalId: String, table: String) -> (any ObjectBackend)?

    // Fetch many
    //
    // PARAMETERIZED SURFACE: the trailing `params` binds the `?` placeholders
    // in `whereClause`, positionally. Callers that render a predicate on the
    // literal channel (`Query.predicate`) pass `[]` — and the no-`params`
    // overloads in the extension below do exactly that, so a caller who has no
    // parameter channel cannot accidentally emit an unbound statement.
    func objects(
        table: String,
        where whereClause: String?,
        orderBy: String?,
        limit: Int64?,
        offset: Int64?,
        groupBy: String?,
        distinctBy: String?,
        params: [QueryParameter]
    ) -> [any ObjectBackend]

    func unionObjects(
        tables: [String],
        where whereClause: String?,
        orderBy: String?,
        limit: Int64?,
        offset: Int64?,
        params: [QueryParameter]
    ) -> [any ObjectBackend]

    // Counts / deletes (collapsed arity overloads -> one requirement each)
    func count(table: String, where whereClause: String?, groupBy: String?, distinctBy: String?,
               params: [QueryParameter]) -> Int64
    @discardableResult func deleteWhere(table: String, where whereClause: String?,
                                        params: [QueryParameter]) -> Bool

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
    /// Repair audit rows whose timestamp was stored as TEXT in the REAL
    /// column (pre-fix remote-apply path). Idempotent; returns rows fixed.
    @discardableResult func normalizeAuditTimestamps() -> Int64
    func backdateReplicationSlots(seconds: Int64)
    func checkpoint()
    /// Bounded WAL checkpoint (TRUNCATE with a small busy budget, PASSIVE
    /// fallback + generation-advance on busy). Safe to call between write
    /// batches; returns frames checkpointed (-1 when nothing ran).
    func checkpointBounded(busyBudgetMs: Int64) -> Int64
    /// Incremental query-planner statistics refresh (`PRAGMA optimize`).
    func optimize()

    // Transactions
    func beginTransaction()
    func rollback()
    func commit()

    // Lifecycle
    func close()
    func attach(_ other: any LatticeBackend) throws   // C++-to-C++; conformer downcasts peer
    func detach(_ other: any LatticeBackend) throws

    // Sync status
    func isSyncAgent() -> Bool
    func isSyncConnected() -> Bool
    /// Count of AuditLog entries not yet synchronized — used by the cross-process
    /// progress derivations (xproc-idle / AuditLog-observer fallbacks).
    func pendingSyncEntryCount() -> Int64

    // Sync data flow
    func receiveSyncData(_ data: Data) -> [String]   // acked global ids
    func lastReceiveError() -> String?

    // Sync filter
    func updateSyncFilter(_ filter: [SyncFilterParam])
    func clearSyncFilter()
    // Per-channel variants (Stage A2/A6): scope a filter update to ONE
    // synchronizer instead of fanning it to WSS + every IPC target, and
    // drop a removed channel's sync bookkeeping so its stale state can't
    // collapse entries the live channels still need.
    func updateSyncFilter(_ filter: [SyncFilterParam], forChannel channel: String)
    func clearSyncFilter(forChannel channel: String)
    func removeSyncChannelState(syncId: String)

    // No-relay hard delete (admin tombstone purge): rows vanish locally and
    // the DELETE entries carry the filter-removal marker, so no peer ever
    // applies them. Returns rows deleted.
    func deleteRowsNoRelay(table: String, globalRowIds: [String]) -> Int64

    // Observation — single @escaping @Sendable closure replaces C fn-ptr+ctx+destroy
    func addTableObserver(
        table: String,
        _ callback: @escaping @Sendable ([TableChangeEvent]) -> Void
    ) -> UInt64
    func removeTableObserver(table: String, observerId: UInt64)

    // MARK: Item A — synchronous invalidation + read generations (Commit 5)

    /// Register a SYNCHRONOUS invalidation hook (§2.3). The callback runs
    /// INLINE on the writer's thread — for file DBs inside SQLite's
    /// post-commit C hook frame — once per settled top-level transaction,
    /// BEFORE the scheduler-dispatched observer fan-out, fanned to every
    /// alive same-path core instance. The §2.3 restrictions apply to the
    /// callback body verbatim: atomic epoch increments / dirty-flag stores
    /// under LEAF locks only. No SQL, no allocation-heavy work, nothing that
    /// can throw, no lock any thread ever holds across a SQL statement.
    func addInvalidationHook(
        _ callback: @escaping @Sendable (_ changedTables: [String], _ reason: InvalidationReason) -> Void
    ) -> UInt64
    /// Detailed variant (item A Commit 8, §2.3 v1.1): identical contract to
    /// `addInvalidationHook`, but the payload additionally carries each
    /// table's `changedFields` union (see `InvalidationTableChange` — empty
    /// string = must invalidate). Same callback restrictions verbatim.
    func addInvalidationHookWithFields(
        _ callback: @escaping @Sendable (_ changes: [InvalidationTableChange], _ reason: InvalidationReason) -> Void
    ) -> UInt64
    func removeInvalidationHook(token: UInt64)

    /// Acquire a read generation (a pooled read-only connection holding an
    /// open read transaction — one MVCC snapshot, §1.1). Returns 0 when this
    /// storage refuses keepers (memory family, Emscripten, closed instance)
    /// or the store cannot be pinned — treat 0 as "no keeper" and use the
    /// non-generation path.
    func acquireReadGeneration() -> UInt64
    /// Add a logical hold on a live generation (iterators). false = already
    /// retired or retiring — re-resolve.
    func retainReadGeneration(_ generationID: UInt64) -> Bool
    /// Drop a hold; at refcount 0 the keeper COMMITs and its connection
    /// returns to the pool. Releasing an already-retired id is a no-op.
    func releaseReadGeneration(_ generationID: UInt64)
    /// Force-retire every live generation on this instance (§3.4 protocol;
    /// §3.6 lifecycle contract).
    func retireAllReadGenerations()
    /// Live generations across every alive same-path core instance (§3.3).
    func readGenerationsOutstanding() -> Int
    /// Live generations held by THIS instance only.
    func localReadGenerationsOutstanding() -> Int
    /// §3.2 maintenance tick: TTL retire, absolute age cap, pending
    /// WAL-threshold evictions. The Swift coordinator's maintenance timer is
    /// the actor of record for EVERY storage/config.
    func runReadPoolMaintenance()

    // Pool tunables (§1.7 ResultsTuning — forwarded per-Lattice at open).
    func setReadGenerationTTLMs(_ ms: Int64)
    func setReadGenerationMaxAgeMs(_ ms: Int64)
    func setWALKeeperEvictionThresholdBytes(_ bytes: Int64)
    /// Diagnostics/tests: an armed-but-unserviced WAL threshold eviction.
    func walEvictionPending() -> Bool

    // Generation-scoped reads (§2.2; tolerant-ladder sentinels on failure).
    /// `objects` executed at a held read generation. EMPTY +
    /// `lastGenerationReadStale()` when the generation is no longer live or
    /// the read failed; an empty result with the flag clear is genuine.
    func objectsAt(
        generation: UInt64,
        table: String,
        where whereClause: String?,
        orderBy: String?,
        limit: Int64?,
        offset: Int64?,
        groupBy: String?,
        distinctBy: String?,
        params: [QueryParameter]
    ) -> [any ObjectBackend]
    /// `count` executed at a held read generation. -1 + stale flag on
    /// failure; 0 is a genuine zero.
    func countAt(
        generation: UInt64,
        table: String,
        where whereClause: String?,
        groupBy: String?,
        distinctBy: String?,
        params: [QueryParameter]
    ) -> Int64
    /// `objectsWithinBBox` executed at a held read generation. EMPTY + stale
    /// flag on failure.
    func objectsWithinBBoxAt(
        generation: UInt64,
        table: String, geoColumn: String,
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        where whereClause: String?, orderBy: String?,
        limit: Int64?, offset: Int64?, groupBy: String?
    ) -> [any ObjectBackend]
    /// §4.1 materialized-id capture (memory family): `SELECT id FROM T
    /// [WHERE …] [ORDER BY …]` inside a capture transaction under the
    /// per-store write gate, with a bounded LOCKED retry. NOT
    /// generation-scoped. EMPTY + stale flag after the retry budget.
    func queryIDs(table: String, where whereClause: String?, orderBy: String?,
                  params: [QueryParameter]) -> [Int64]
    /// `PRAGMA data_version` on the dedicated non-transaction cross-process
    /// read connection (Commit-6 belt). -1 on failure.
    func dataVersion() -> Int64
    /// Whether the LAST generation-scoped read on THIS thread returned a
    /// sentinel because it could not be served. Check on the same thread,
    /// immediately after the read, before trusting an empty/-1 result.
    func lastGenerationReadStale() -> Bool

    // Sync callbacks — optional closures; nil clears (matches nullptr branch)
    func setOnSyncProgress(
        _ callback: (@Sendable (_ pendingUpload: Int64, _ totalUpload: Int64, _ acked: Int64, _ received: Int64, _ syncId: String) -> Void)?
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
        objects(table: table, where: nil, orderBy: nil, limit: nil, offset: nil, groupBy: nil, distinctBy: nil,
                params: [])
    }
    @inlinable
    public func count(table: String, where whereClause: String? = nil) -> Int64 {
        count(table: table, where: whereClause, groupBy: nil, distinctBy: nil, params: [])
    }
    @inlinable
    public func deleteWhere(table: String) -> Bool {
        deleteWhere(table: table, where: nil, params: [])
    }

    // LITERAL-CHANNEL overloads. Dropping `params` means "this predicate has
    // no placeholders" — the only correct call for a fragment rendered by
    // `Query.predicate`. Kept so the many literal-channel call sites read
    // exactly as they did before parameterization.
    @inlinable
    public func objects(table: String, where whereClause: String?, orderBy: String?,
                        limit: Int64?, offset: Int64?, groupBy: String?, distinctBy: String?) -> [any ObjectBackend] {
        objects(table: table, where: whereClause, orderBy: orderBy, limit: limit, offset: offset,
                groupBy: groupBy, distinctBy: distinctBy, params: [])
    }
    @inlinable
    public func unionObjects(tables: [String], where whereClause: String?, orderBy: String?,
                             limit: Int64?, offset: Int64?) -> [any ObjectBackend] {
        unionObjects(tables: tables, where: whereClause, orderBy: orderBy, limit: limit, offset: offset,
                     params: [])
    }
    @inlinable
    public func count(table: String, where whereClause: String?, groupBy: String?, distinctBy: String?) -> Int64 {
        count(table: table, where: whereClause, groupBy: groupBy, distinctBy: distinctBy, params: [])
    }
    @inlinable
    @discardableResult
    public func deleteWhere(table: String, where whereClause: String?) -> Bool {
        deleteWhere(table: table, where: whereClause, params: [])
    }
    @inlinable
    public func objectsAt(generation: UInt64, table: String, where whereClause: String?, orderBy: String?,
                          limit: Int64?, offset: Int64?, groupBy: String?, distinctBy: String?) -> [any ObjectBackend] {
        objectsAt(generation: generation, table: table, where: whereClause, orderBy: orderBy,
                  limit: limit, offset: offset, groupBy: groupBy, distinctBy: distinctBy, params: [])
    }
    @inlinable
    public func countAt(generation: UInt64, table: String, where whereClause: String?,
                        groupBy: String?, distinctBy: String?) -> Int64 {
        countAt(generation: generation, table: table, where: whereClause,
                groupBy: groupBy, distinctBy: distinctBy, params: [])
    }
    @inlinable
    public func queryIDs(table: String, where whereClause: String?, orderBy: String?) -> [Int64] {
        queryIDs(table: table, where: whereClause, orderBy: orderBy, params: [])
    }
}
