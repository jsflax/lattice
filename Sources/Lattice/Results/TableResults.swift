import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge

public final class TableResults<Element>: Results, ObservableObject, @unchecked Sendable where Element: Model {
    public typealias UnderlyingElement = Element

    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    // Stored as existential to avoid SortDescriptor type metadata link
    // failure on Linux release builds (swift-foundation bug: internal
    // AllowedComparison metadata not exported)
    internal let sortStatement: (any SortComparator)?
    internal var _sortDescriptor: SortDescriptor<Element>? {
        sortStatement as? SortDescriptor<Element>
    }
    /// The resolved ORDER BY column + direction, without touching
    /// `SortDescriptor.keyPath` (iOS 17+) except behind an availability guard.
    /// `sortedBy(_:order:)` stores a `KeyPathSort` so this resolves on any OS.
    internal var _sortColumn: (name: String, order: SortOrder)? {
        if let ks = sortStatement as? KeyPathSort<Element> {
            return (ks.column, ks.order)
        }
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
           let sd = sortStatement as? SortDescriptor<Element>, let kp = sd.keyPath {
            return (_name(for: kp), sd.order)
        }
        return nil
    }
    internal let boundsConstraint: BoundsConstraint?
    internal let groupByColumn: String?
    internal let distinctByColumn: String?

    // MARK: - Live generation-cached access (item A, Commit 5)
    //
    // `count`/`subscript` serve through the process-global query-shape
    // registry: one shared `QueryShapeState` per
    // (lattice identity, table, whereSQL, orderBySQL, groupBy, distinctBy),
    // so `@LatticeQuery` re-fetches, `@Relation` property accesses and TSR
    // resolves are thin facades over an already-warm cache (§1.5, §1.4).
    //
    // COMMIT-5 STATE: generations are real pinned snapshots. On FILE (WAL)
    // databases every count/page fill/snapshot for a generation executes on
    // its keeper connection (one MVCC snapshot — §1.1) through the
    // generation-scoped bridge surface; a stale sentinel (force-retired
    // keeper, §3.4) re-pins once and then falls back to a live head read —
    // the §1.2 rung-1 carve-out, served through the tolerant ladder. On the
    // MEMORY FAMILY generations are materialized-id vectors (§4.1): one
    // gated capture per shape per epoch (`queryIDs`), `count == ids.count`,
    // subscripts hydrate by primary key (rows deleted between capture and
    // hydration serve as invalidated placeholders — rung 2). Fills page by
    // KEYSET with persistent anchors (§2.4). Grouped/distinct/bbox shapes
    // keep OFFSET fills (§2.4/§4.5 carve-out) — generation-scoped on file
    // DBs (the OFFSET scan runs at the keeper snapshot), live-read on the
    // memory family (the Commit-4 id-capture surface carries no
    // group-by/bbox form — same never-trap ladder, minus within-access MVCC
    // exactness, mirroring §4.2's treatment of union/attach shapes).
    // Invalidation is the synchronous core hook (§2.3) — cross-handle
    // writes (second handles, sync-applied chunks) bump the epoch on the
    // writer's thread before the write call returns (T2b).

    /// Memoized shape identity — predicate SQL is built once per facade.
    /// `orderBySQL` is the EFFECTIVE order (§2.4): the user sort plus the
    /// deterministic `id ASC` tiebreaker (`id ASC` alone when unsorted).
    /// `keysetSpec` is non-nil exactly when the shape keyset-pages.
    private struct ShapeDescriptor {
        let key: QueryShapeKey
        let whereSQL: String?
        let orderBySQL: String?
        let keysetSpec: KeysetSortSpec?
    }
    private let _shapeMemo = UnfairLock<ShapeDescriptor?>(initialState: nil)
    /// Diagnostics (§1.7): the epoch this facade last served from.
    private let _lastServedEpoch = UnfairLock<UInt64>(initialState: 0)

    /// The effective ORDER BY (§2.4): a deterministic total order is
    /// mandatory for keyset resume, so the user sort always gains an
    /// `id ASC` tiebreaker and unsorted queries get `ORDER BY id ASC`
    /// (`id INTEGER PRIMARY KEY AUTOINCREMENT` exists on every model table —
    /// it aliases the rowid, so the unsorted case adds no sorter, and an
    /// indexed sort column already yields (key, rowid) order from its
    /// b-tree). `qualifyTiebreaker` disambiguates `id` on the bbox path,
    /// whose R*Tree join exposes a second `id` column.
    private func _effectiveOrderBySQL(qualifyTiebreaker: Bool) -> String {
        let idColumn = qualifyTiebreaker ? "\(Element.entityName).id" : "id"
        if let sc = _sortColumn {
            let dir = sc.order == .forward ? "ASC" : "DESC"
            if sc.name == "id" { return "\(idColumn) \(dir)" }
            return "\(sc.name) \(dir), \(idColumn) ASC"
        }
        return "\(idColumn) ASC"
    }

    private var _descriptor: ShapeDescriptor {
        if let memoized = _shapeMemo.withLockUnchecked({ $0 }) { return memoized }
        // Build OUTSIDE the memo lock (leaf-lock rule — predicate
        // construction is pure string building, but keep the lock tiny).
        let whereSQL = whereStatement?.predicate
        let orderBySQL: String? = _effectiveOrderBySQL(qualifyTiebreaker: boundsConstraint != nil)
        // Keyset paging needs a total order over stored `(col, id)` values:
        // grouped/distinct rows lack stable `(col, id)` identity and bbox
        // shapes route through the R*Tree join — those page by OFFSET
        // (§2.4/§4.5 carve-out), as do sorts on non-primitive columns.
        let keysetSpec: KeysetSortSpec? = (groupByColumn == nil && distinctByColumn == nil && boundsConstraint == nil)
            ? KeysetSortSpec.resolve(for: Element.self, sortColumn: _sortColumn)
            : nil
        // Spatial constraints are folded into the key's whereSQL component:
        // the spec's shape key has no bbox slot, and two shapes differing
        // only in bounding box must not collide (see QueryShapeKey).
        var keyWhere = whereSQL
        if let b = boundsConstraint {
            let bboxFragment = "\u{1F}bbox(\(b.propertyName),\(b.minLat),\(b.maxLat),\(b.minLon),\(b.maxLon))"
            keyWhere = (keyWhere ?? "") + bboxFragment
        }
        let built = ShapeDescriptor(
            key: QueryShapeKey(identityHash: _lattice.backend.identityHash,
                               table: Element.entityName,
                               whereSQL: keyWhere,
                               orderBySQL: orderBySQL,
                               groupBy: groupByColumn,
                               distinctBy: distinctByColumn),
            whereSQL: whereSQL,
            orderBySQL: orderBySQL,
            keysetSpec: keysetSpec)
        return _shapeMemo.withLockUnchecked { memo in
            if let existing = memo { return existing }
            memo = built
            return built
        }
    }

    private var _tuning: ResultsTuning { _lattice.configuration.resultsTuning }

    // MARK: Instance reuse (item A §1.6, Commit 7)

    /// Registry key component for instance reuse: the same normalized path
    /// string `ModelInstanceRegistry` keys on (both originate from the
    /// core's `path()`). Memoized — the C++ string conversion should be
    /// per-facade, not per-row.
    private let _dbPathMemo = UnfairLock<String?>(initialState: nil)
    private var _dbPath: String {
        if let cached = _dbPathMemo.withLockUnchecked({ $0 }) { return cached }
        let path = _lattice.backend.path
        return _dbPathMemo.withLockUnchecked { memo in
            if let existing = memo { return existing }
            memo = path
            return path
        }
    }

    /// §1.6 obligation 2 (Commit 7): page refills and iterator batches
    /// REUSE the live registered instance per (path, table, primaryKey)
    /// when one exists — a re-hydrated row is the SAME object identity as
    /// the instance a view already holds, so SwiftUI's `ForEach` diff stays
    /// stable at the instance level across epoch bumps, and
    /// observer-registration churn is bounded (A1 risk 3: a duplicate
    /// hydration would `add_object_observer` + register, then tear both
    /// down when the page rotates). Best-effort by contract: a dead weak
    /// ref hydrates fresh exactly as before. Reuse is scoped to instances
    /// hydrated from THIS facade's core handle (`identityHash`): an
    /// instance's writes route through its own handle's connection, so
    /// adopting another handle's instance would interleave our writes with
    /// that handle's transactions (see `ModelInstanceRegistry.lookup`).
    /// Row VALUES are unaffected either way — property reads are live
    /// through the object path
    /// (§1.3); membership, not values, is what the fill decided.
    /// `snapshot()` deliberately does NOT reuse: it is the explicit
    /// point-in-time copy, and `materializedSnapshot()` flips its elements
    /// into row-cache reads — reuse there would mutate the read semantics
    /// of instances the app already holds.
    private func _reuseOrHydrate(_ row: any ObjectBackend) -> Element {
        let primaryKey = _primedPrimaryKey(of: row)
        if primaryKey > 0,
           let reused = ModelInstanceRegistry.shared.lookup(databasePath: _dbPath,
                                                            tableName: Element.entityName,
                                                            primaryKey: primaryKey,
                                                            backendIdentity: _lattice.backend.identityHash) as? Element {
            return reused   // the fetched handle is discarded
        }
        // Hydrate with the row cache still ON: the primary-key reads inside
        // `Model.init(dynamicObject:)` + registration serve from the primed
        // handle (statement-free), halving the pre-Commit-7 per-row
        // hydration cost (2 pk SELECTs → the one priming re-fetch above).
        let element = Element(dynamicObject: row)
        // Restore live-read semantics (§1.3 object path): the element wraps
        // this very handle, and only `materialize()` may opt into snapshot
        // reads.
        row.disableRowCache()
        return element
    }

    /// Primary-key read of a freshly fetched row via row-cache priming: a
    /// bare `getInt(named: "id")` on a live handle is a per-row SELECT
    /// (§5's fill budget would grow by pageSize). Enabling the row cache
    /// re-fetches the FULL row in ONE statement (the fetched handle carries
    /// no hydrated values), after which `id` serves from the managed
    /// handle's own `id_` member — so the pk read itself is free, and so is
    /// every subsequent pk read while the handle stays primed. Idempotent:
    /// an already-primed handle pays nothing. The handle is exclusively
    /// ours at this point (pre-publication).
    private func _primedPrimaryKey(of row: any ObjectBackend) -> Int64 {
        if !row.isRowCacheEnabled {
            row.enableRowCache()
        }
        return row.getInt(named: "id")
    }

    private func _liveContext() -> (coordinator: GenerationCoordinator, shape: QueryShapeState, descriptor: ShapeDescriptor) {
        let descriptor = _descriptor
        let coordinator = GenerationCoordinatorRegistry.coordinator(for: _lattice.backend, tuning: _tuning)
        let shape = coordinator.shape(for: descriptor.key)
        return (coordinator, shape, descriptor)
    }

    private func _noteServed(_ epoch: UInt64) {
        _lastServedEpoch.withLockUnchecked { $0 = epoch }
    }

    /// Diagnostics/tests (§1.7): the epoch this facade last served from.
    public var generationID: UInt64 {
        _lastServedEpoch.withLockUnchecked { $0 }
    }

    /// Test hook: the shared shape state behind this facade (fill-mechanism
    /// counters, persistent anchor map). Internal — reached via @testable.
    internal var _shapeState: QueryShapeState {
        _liveContext().shape
    }

    /// Force the next access to advance the generation and drop caches (§1.7).
    public func refresh() {
        GenerationCoordinatorRegistry.coordinator(for: _lattice.backend, tuning: _tuning).forceAdvance()
    }

    /// §4.1 memory-family storage check (no keepers; gated reads).
    private var _isMemoryStore: Bool {
        if case .memory = _lattice.configuration.storage { return true }
        return false
    }

    /// §4.1 mechanism 2: on memory-family stores every live read batch runs
    /// under the per-store write gate — taken via the lattice-level
    /// transaction entry, whose core implementation holds the gate for the
    /// transaction's duration — so a cross-connection write transaction
    /// (sync chunk apply, second handle) never interleaves: no
    /// SQLITE_LOCKED in either direction on lattice-managed paths. Skipped
    /// when this thread already holds an explicit transaction (it already
    /// owns the gate; a nested same-connection BEGIN would wait on itself).
    /// File stores: passthrough — reads are keeper-routed or WAL-safe.
    private func _gatedLiveRead<T>(_ body: () -> T) -> T {
        guard _isMemoryStore, !Lattice._threadHoldsExplicitTransaction else {
            return body()
        }
        let backend = _lattice.backend
        backend.beginTransaction()
        defer { backend.commit() }
        return body()
    }

    private func _liveCount(_ descriptor: ShapeDescriptor) -> Int {
        _gatedLiveRead {
            if let bounds = boundsConstraint {
                return Int(_lattice.backend.countWithinBBox(table: Element.entityName, geoColumn: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon, where: descriptor.whereSQL))
            }
            return Int(_lattice.backend.count(table: Element.entityName, where: descriptor.whereSQL, groupBy: groupByColumn, distinctBy: distinctByColumn))
        }
    }

    /// COUNT(*) at a held generation's snapshot; nil = stale sentinel
    /// (retired keeper / thrown core read) — caller re-pins and retries,
    /// then falls back to `_liveCount`. Never called for bbox shapes (the
    /// Commit-4 bridge has no bbox count-at form — bbox counts stay live).
    private func _generationCount(_ descriptor: ShapeDescriptor, generation: UInt64) -> Int? {
        let counted = _lattice.backend.countAt(generation: generation,
                                               table: Element.entityName,
                                               where: descriptor.whereSQL,
                                               groupBy: groupByColumn,
                                               distinctBy: distinctByColumn)
        if counted < 0 || _lattice.backend.lastGenerationReadStale() { return nil }
        return Int(counted)
    }

    // MARK: Materialized-id generations (§4.1, memory family)

    /// Whether this shape serves through a materialized-id generation:
    /// memory-family storage (keepers are forbidden there — §4.1) and a
    /// keyset-able shape (the Commit-4 id-capture surface carries no
    /// group-by/distinct/bbox form — those shapes stay on live reads with
    /// logical-epoch caching, the §4.2-style carve-out).
    private func _usesMaterializedIDs(_ coordinator: GenerationCoordinator,
                                      _ descriptor: ShapeDescriptor) -> Bool {
        coordinator.isMemoryFamily && descriptor.keysetSpec != nil
    }

    /// The id vector for the batch-pinned epoch, capturing on a miss:
    /// `SELECT id … ORDER BY (sort, id)` inside a capture transaction under
    /// the per-store write gate with a bounded LOCKED retry (core-side,
    /// §4.1 mechanisms 1–3). nil = the capture exhausted its retry budget —
    /// tolerant ladder (last-known count / previous pages / live fill).
    private func _materializedIDs(shape: QueryShapeState, coordinator: GenerationCoordinator,
                                  descriptor: ShapeDescriptor,
                                  ctx: GenerationContext) -> ContiguousArray<Int64>? {
        if let ids = shape.ids(epoch: ctx.epoch, floor: ctx.floor) { return ids }
        let captured = _lattice.backend.queryIDs(table: Element.entityName,
                                                 where: descriptor.whereSQL,
                                                 orderBy: descriptor.orderBySQL)
        if _lattice.backend.lastGenerationReadStale() { return nil }
        let ids = ContiguousArray(captured)
        shape.publishIDs(ids, epoch: ctx.epoch, floor: ctx.floor,
                         currentFloor: coordinator.currentFloor(table: Element.entityName,
                                                                shapeKey: descriptor.key))
        return ids
    }

    /// Hydrate captured ids by primary key: one page-batched
    /// `WHERE id IN (…)`, input order preserved (§4.1). The batch runs
    /// under the per-store write gate — taken via the lattice-level
    /// transaction entry, whose core implementation holds the gate for the
    /// transaction's duration (§4.1 mechanism 2) — so a cross-connection
    /// write transaction (sync chunk apply, second handle) can never
    /// interleave: no SQLITE_LOCKED in either direction on lattice-managed
    /// paths. Skipped when this thread already holds an explicit
    /// transaction: the enclosing transaction already owns the gate, and a
    /// nested same-connection BEGIN would wait on itself.
    ///
    /// `placeholders`: a row deleted between capture and hydration serves as
    /// an invalidated (default-valued) placeholder — §1.2 rung 2 — for
    /// indexed access (blank row for ≤ 1 frame, corrected at the next
    /// epoch); iteration skips missing rows instead (§1.4: a shrinking
    /// table thins the walk — never a duplicate, never a trap).
    private func _hydrate(ids: ArraySlice<Int64>, placeholders: Bool) -> [Element] {
        guard !ids.isEmpty else { return [] }
        let backend = _lattice.backend
        let predicate = "id IN (\(ids.map(String.init).joined(separator: ",")))"
        // The WHOLE hydration batch — fetch, element construction, and the
        // id keying reads — runs inside the gate: hydrated instances have
        // LIVE property semantics (every read is SQL), so even the `id`
        // read after an ungated fetch could race a cross-connection write
        // transaction into SQLITE_LOCKED (§4.1 mechanism 2).
        return _gatedLiveRead {
            let fetched = backend.objects(table: Element.entityName, where: predicate,
                                          orderBy: nil, limit: nil, offset: nil,
                                          groupBy: nil, distinctBy: nil)
            var byID: [Int64: Element] = [:]
            byID.reserveCapacity(fetched.count)
            for row in fetched {
                // §1.6 (Commit 7): reuse the live registered instance when
                // one exists — only rows the fetch actually returned are
                // candidates (a captured id whose row died stays on the
                // placeholder path below). The priming read is idempotent,
                // so keying and reuse share one re-fetch.
                byID[_primedPrimaryKey(of: row)] = _reuseOrHydrate(row)
            }
            var rows: [Element] = []
            rows.reserveCapacity(ids.count)
            for id in ids {
                if let element = byID[id] {
                    rows.append(element)
                } else if placeholders {
                    rows.append(Element.defaultValue)
                }
            }
            return rows
        }
    }

    private struct PageFill {
        let rows: [Element]
        /// End-of-page anchor (§2.4), recorded only for FULL pages (a short
        /// page ends the result set, not a page boundary) on keyset shapes.
        let endAnchor: KeysetAnchor?
    }

    /// One page fill (§2.4), routed per the Commit-5 generation model.
    /// Returns nil when a generation-scoped read came back with the stale
    /// sentinel (force-retired keeper §3.4, exhausted §4.1 capture) — the
    /// caller re-pins once and finally falls back to a live fill.
    ///
    /// Keyset shapes resume from the nearest recorded anchor — filling page
    /// p from the anchor at p−1 is pure keyset, O(log n + pageSize); a
    /// farther anchor adds a small OFFSET remainder (O(gap), still one
    /// statement); no anchor at all is the cold random jump, one
    /// `LIMIT pageSize OFFSET k` — O(k) once per jump, then the
    /// neighborhood is anchored. Grouped/distinct/bbox shapes page by
    /// OFFSET (carve-out) at the keeper snapshot on file DBs.
    private func _fillPage(_ descriptor: ShapeDescriptor, shape: QueryShapeState,
                           coordinator: GenerationCoordinator, ctx: GenerationContext,
                           pageIndex: Int, pageSize: Int,
                           forceLive: Bool = false) -> PageFill? {
        // §4.1: memory-family keyset shapes serve from the materialized-id
        // generation — count and membership come from one captured vector.
        if !forceLive, _usesMaterializedIDs(coordinator, descriptor) {
            guard let ids = _materializedIDs(shape: shape, coordinator: coordinator,
                                             descriptor: descriptor, ctx: ctx) else {
                return nil
            }
            let start = pageIndex * pageSize
            guard start < ids.count else { return PageFill(rows: [], endAnchor: nil) }
            let slice = ids[start..<Swift.min(start + pageSize, ids.count)]
            let rows = _hydrate(ids: slice, placeholders: true)
            shape.noteFill(usedOffset: false, usedKeyset: true)
            return PageFill(rows: rows, endAnchor: nil)
        }

        let generation = forceLive ? 0 : ctx.generationID
        let offset = pageIndex * pageSize
        guard let spec = descriptor.keysetSpec else {
            guard let rows = _fillPageOffset(descriptor, generation: generation,
                                             offset: offset, limit: pageSize) else {
                return nil
            }
            shape.noteFill(usedOffset: offset > 0, usedKeyset: false)
            return PageFill(rows: rows, endAnchor: nil)
        }

        // Anchor lookup is its own (leaf) lock acquisition; the fill below
        // runs with NO locks held (§2.3 two-phase pattern).
        var resume: String? = nil
        var gapOffset = 0
        if pageIndex > 0 {
            if let (anchorPage, anchor) = shape.nearestAnchor(atOrBefore: pageIndex - 1) {
                resume = KeysetSQL.resumePredicate(spec: spec, anchor: anchor)
                gapOffset = (pageIndex - 1 - anchorPage) * pageSize
            } else {
                gapOffset = offset
            }
        }
        guard let rows = _queryRows(where: KeysetSQL.conjoin(where: descriptor.whereSQL, resume: resume),
                                    orderBy: descriptor.orderBySQL,
                                    generation: generation,
                                    limit: Int64(pageSize),
                                    offset: gapOffset == 0 ? nil : Int64(gapOffset),
                                    groupBy: nil, distinctBy: nil,
                                    reuseInstances: true) else {
            return nil
        }
        shape.noteFill(usedOffset: gapOffset != 0, usedKeyset: resume != nil || pageIndex == 0)
        let endAnchor: KeysetAnchor? = rows.count == pageSize
            ? rows.last.flatMap { KeysetSQL.extractAnchor(from: $0, spec: spec) }
            : nil
        return PageFill(rows: rows, endAnchor: endAnchor)
    }

    /// The full fill ladder for one cold page: fill at the resolved
    /// generation → stale? re-pin once and retry at the fresh snapshot
    /// (§3.4 force-retire protocol: liveness is re-validated per statement;
    /// a read that still loses serves below) → still stale? live head-state
    /// fill (§1.2 rung-1 carve-out). `ctx` is updated so the caller
    /// publishes at the epoch actually served.
    private func _fillPageResolving(_ descriptor: ShapeDescriptor, shape: QueryShapeState,
                                    coordinator: GenerationCoordinator, ctx: inout GenerationContext,
                                    pageIndex: Int, pageSize: Int) -> PageFill {
        if let fill = _fillPage(descriptor, shape: shape, coordinator: coordinator, ctx: ctx,
                                pageIndex: pageIndex, pageSize: pageSize) {
            return fill
        }
        if ctx.generationID != 0 {
            ctx = coordinator.resolveAfterStaleRead(failedGeneration: ctx.generationID,
                                                    table: Element.entityName,
                                                    shapeKey: descriptor.key)
            if let fill = _fillPage(descriptor, shape: shape, coordinator: coordinator, ctx: ctx,
                                    pageIndex: pageIndex, pageSize: pageSize) {
                return fill
            }
        }
        // Live fallback cannot return nil (no generation-scoped read).
        return _fillPage(descriptor, shape: shape, coordinator: coordinator, ctx: ctx,
                         pageIndex: pageIndex, pageSize: pageSize, forceLive: true)!
    }

    /// Row query routed through a held generation's keeper connection when
    /// `generation != 0` (one MVCC snapshot — §1.1); live read otherwise.
    /// nil = stale sentinel from the generation-scoped read.
    /// `reuseInstances` (§1.6, Commit 7): page fills and iterator batches
    /// reuse live registered instances; `snapshot()` hydrates fresh copies.
    private func _queryRows(where whereClause: String?, orderBy: String?,
                            generation: UInt64,
                            limit: Int64?, offset: Int64?,
                            groupBy: String?, distinctBy: String?,
                            reuseInstances: Bool = false) -> [Element]? {
        if generation != 0 {
            let rows = _lattice.backend.objectsAt(generation: generation,
                                                  table: Element.entityName,
                                                  where: whereClause, orderBy: orderBy,
                                                  limit: limit, offset: offset,
                                                  groupBy: groupBy, distinctBy: distinctBy)
            if _lattice.backend.lastGenerationReadStale() { return nil }
            return reuseInstances
                ? rows.map { _reuseOrHydrate($0) }
                : rows.map { Element(dynamicObject: $0) }
        }
        return _gatedLiveRead {
            let rows = _lattice.backend.objects(table: Element.entityName,
                                                where: whereClause, orderBy: orderBy,
                                                limit: limit, offset: offset,
                                                groupBy: groupBy, distinctBy: distinctBy)
            return reuseInstances
                ? rows.map { _reuseOrHydrate($0) }
                : rows.map { Element(dynamicObject: $0) }
        }
    }

    /// OFFSET page fill — the §2.4/§4.5 carve-out (grouped/distinct/bbox and
    /// non-primitive sort columns). Cold pages are O(offset); never traps.
    /// Generation-scoped on file DBs (the scan runs at the keeper snapshot);
    /// nil = stale sentinel.
    private func _fillPageOffset(_ descriptor: ShapeDescriptor, generation: UInt64,
                                 offset: Int, limit: Int) -> [Element]? {
        if let bounds = boundsConstraint {
            if generation != 0 {
                let rows = _lattice.backend.objectsWithinBBoxAt(
                    generation: generation,
                    table: Element.entityName, geoColumn: bounds.propertyName,
                    minLat: bounds.minLat, maxLat: bounds.maxLat,
                    minLon: bounds.minLon, maxLon: bounds.maxLon,
                    where: descriptor.whereSQL, orderBy: descriptor.orderBySQL,
                    limit: Int64(limit), offset: Int64(offset), groupBy: groupByColumn)
                if _lattice.backend.lastGenerationReadStale() { return nil }
                return rows.map { _reuseOrHydrate($0) }
            }
            return _gatedLiveRead {
                _lattice.backend.objectsWithinBBox(table: Element.entityName, geoColumn: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon, where: descriptor.whereSQL, orderBy: descriptor.orderBySQL, limit: Int64(limit), offset: Int64(offset), groupBy: groupByColumn).map { _reuseOrHydrate($0) }
            }
        }
        return _queryRows(where: descriptor.whereSQL, orderBy: descriptor.orderBySQL,
                          generation: generation,
                          limit: Int64(limit), offset: Int64(offset),
                          groupBy: groupByColumn, distinctBy: distinctByColumn,
                          reuseInstances: true)
    }

    /// Non-trapping indexed access (§1.7): tolerant-ladder rungs (a) — the
    /// current generation's fill result — and (b) — the retained previous
    /// generation's page. Returns nil instead of rungs (c)/(d) (the lifeboat
    /// and the invalidated placeholder exist to satisfy the non-optional
    /// `subscript`; an optional return expresses "no such element" directly).
    public func element(at index: Int) -> Element? {
        guard index >= 0 else { return nil }
        let (coordinator, shape, descriptor) = _liveContext()
        var ctx = coordinator.resolve(table: Element.entityName, shapeKey: descriptor.key)
        let pageSize = Swift.max(1, _tuning.pageSize)
        let pageIndex = index / pageSize
        let slot = index % pageSize

        // Rung (a): the current generation's fill result.
        if let cached = shape.page(pageIndex, epoch: ctx.epoch, floor: ctx.floor) {
            _noteServed(ctx.epoch)
            if slot < cached.count, let element = cached[slot] as? Element {
                return element
            }
            // Cached page is short at this epoch — index not present; fall
            // through to the stale rungs.
        } else {
            // Cold page: fill with NO locks held (§2.3 two-phase), publish
            // with epoch re-validation. The end-of-page anchor is recorded
            // unconditionally (anchors are content-positional and
            // epoch-agnostic, §2.4). Stale generation reads re-pin once and
            // then fall back to a live fill inside `_fillPageResolving`.
            let fill = _fillPageResolving(descriptor, shape: shape, coordinator: coordinator,
                                          ctx: &ctx, pageIndex: pageIndex, pageSize: pageSize)
            shape.publishPage(pageIndex, rows: fill.rows, endAnchor: fill.endAnchor,
                              epoch: ctx.epoch, floor: ctx.floor,
                              currentFloor: coordinator.currentFloor(table: Element.entityName,
                                                                     shapeKey: descriptor.key),
                              maxCachedPages: _tuning.maxCachedPages)
            _noteServed(ctx.epoch)
            if slot < fill.rows.count {
                return fill.rows[slot]
            }
        }

        // Rung (b): the retained previous generation's page (§1.2 rung 3 —
        // stale indices are the EXPECTED path under write bursts).
        if let previous = shape.previousPage(pageIndex), slot < previous.count,
           let stale = previous[slot] as? Element {
            return stale
        }
        return nil
    }

    /// Never-trapping subscript (§1.2): the tolerant ladder replaces the old
    /// `fatalError("Index out of bounds")`. Rungs (a)/(b) via `element(at:)`,
    /// rung (c) — the lifeboat (last element any fill returned) — and rung
    /// (d) — a freshly hydrated invalidated placeholder instance (an
    /// unmanaged default-valued Element; live property reads of a missing
    /// row return column defaults, never a crash). Rung (d) renders a blank
    /// row for one frame instead of aborting the process.
    public subscript(index: Int) -> Element {
        if let element = element(at: index) {
            return element
        }
        let (_, shape, _) = _liveContext()
        if let lifeboat = shape.lifeboatElement() as? Element {
            return lifeboat
        }
        return Element.defaultValue
    }

    /// Tolerant-ladder rung (d) witness: an unmanaged, default-valued
    /// (invalidated) placeholder instance.
    public func _ladderPlaceholder() -> Element? {
        Element.defaultValue
    }

    /// Single-row read at the current generation. Shadows `Collection.first`
    /// for concrete callers: one `LIMIT 1` statement instead of a count +
    /// page fill — the observer-membership path (`rowMatchesNow`) and
    /// one-shot `.first` lookups do not populate the shape registry. The
    /// current generation post-dates any same-process write (the epoch bump
    /// is synchronous on the writer's thread — §1.3), so observer-callback
    /// membership checks see the commit that fired them.
    public var first: Element? {
        snapshot(limit: 1, offset: nil).first
    }

    // MARK: - Observation infrastructure

    // Explicit point-in-time copy. Item A Commit 5: on a live facade over a
    // file DB the copy executes AT THE CURRENT (batch-pinned) GENERATION —
    // the same MVCC snapshot count/subscript serve — re-pinning once on a
    // stale sentinel and falling back to a live head read (§1.2 rung-1
    // carve-out). Memory-family and keeperless epochs read the live
    // committed head (same-process settled writes are already reflected,
    // §1.3). Uses the EFFECTIVE order (§2.4 / MIGRATION line): unsorted
    // snapshots gain a deterministic implicit `ORDER BY id ASC`, sorted ones
    // the `id ASC` tiebreaker — so `snapshot()` order ≡ the keyset walk's
    // total order (pinned by the Commit-2 property matrix).
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        LatticePerf.bump(.snapshots)

        // Coordinator + descriptor WITHOUT registering a query shape: one-shot
        // snapshots (`first`, `rowMatchesNow`) must not churn the registry.
        let descriptor = _descriptor
        let coordinator = GenerationCoordinatorRegistry.coordinator(for: _lattice.backend, tuning: _tuning)
        var ctx = coordinator.resolve(table: Element.entityName)

        // If we have a bounds constraint, use the spatial query path
        if let bounds = boundsConstraint {
            if ctx.generationID != 0 {
                if let rows = _bboxRowsAt(generation: ctx.generationID, bounds: bounds,
                                          whereSQL: descriptor.whereSQL, limit: limit, offset: offset) {
                    return rows
                }
                ctx = coordinator.resolveAfterStaleRead(failedGeneration: ctx.generationID,
                                                        table: Element.entityName)
                if ctx.generationID != 0,
                   let rows = _bboxRowsAt(generation: ctx.generationID, bounds: bounds,
                                          whereSQL: descriptor.whereSQL, limit: limit, offset: offset) {
                    return rows
                }
            }
            return snapshotWithBounds(bounds, limit: limit, offset: offset)
        }

        if ctx.generationID != 0 {
            if let rows = _queryRows(where: descriptor.whereSQL,
                                     orderBy: _effectiveOrderBySQL(qualifyTiebreaker: false),
                                     generation: ctx.generationID,
                                     limit: limit, offset: offset,
                                     groupBy: groupByColumn, distinctBy: distinctByColumn) {
                return rows
            }
            ctx = coordinator.resolveAfterStaleRead(failedGeneration: ctx.generationID,
                                                    table: Element.entityName)
            if ctx.generationID != 0,
               let rows = _queryRows(where: descriptor.whereSQL,
                                     orderBy: _effectiveOrderBySQL(qualifyTiebreaker: false),
                                     generation: ctx.generationID,
                                     limit: limit, offset: offset,
                                     groupBy: groupByColumn, distinctBy: distinctByColumn) {
                return rows
            }
        }
        return _gatedLiveRead {
            _lattice.backend.objects(table: Element.entityName, where: whereStatement?.predicate, orderBy: _effectiveOrderBySQL(qualifyTiebreaker: false), limit: limit, offset: offset, groupBy: groupByColumn, distinctBy: distinctByColumn).map { Element(dynamicObject: $0) }
        }
    }

    /// bbox rows at a held generation; nil = stale sentinel.
    private func _bboxRowsAt(generation: UInt64, bounds: BoundsConstraint,
                             whereSQL: String?, limit: Int64?, offset: Int64?) -> [Element]? {
        let rows = _lattice.backend.objectsWithinBBoxAt(
            generation: generation,
            table: Element.entityName, geoColumn: bounds.propertyName,
            minLat: bounds.minLat, maxLat: bounds.maxLat,
            minLon: bounds.minLon, maxLon: bounds.maxLon,
            where: whereSQL, orderBy: _effectiveOrderBySQL(qualifyTiebreaker: true),
            limit: limit, offset: offset, groupBy: groupByColumn)
        if _lattice.backend.lastGenerationReadStale() { return nil }
        return rows.map { Element(dynamicObject: $0) }
    }

    private func snapshotWithBounds(_ bounds: BoundsConstraint, limit: Int64?, offset: Int64?) -> [Element] {
        return _gatedLiveRead {
            _lattice.backend.objectsWithinBBox(table: Element.entityName, geoColumn: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon, where: whereStatement?.predicate, orderBy: _effectiveOrderBySQL(qualifyTiebreaker: true), limit: limit, offset: offset, groupBy: groupByColumn).map { Element(dynamicObject: $0) }
        }
    }

    // MARK: - Iteration (item A §1.4, Commits 2 + 5)

    /// Keyset walk: batches of `pageSize` resumed by NULL-aware anchor
    /// predicate on the effective total order `(sortColumn userDir, id ASC)`
    /// — O(n) for a full walk, each key visited at most once, never a trap
    /// (a shrinking table ends the walk early; the resume predicate is
    /// value-based, so a deleted anchor row cannot derail it). Batch
    /// boundaries align with page boundaries (`batchSize == pageSize`), so
    /// the walk warms the shape's persistent anchor map as it streams (§2.4).
    /// Carve-out shapes (grouped/distinct/bbox/non-primitive sort) batch by
    /// OFFSET through `snapshot()` (generation-routed per batch on file DBs).
    ///
    /// COMMIT 5: the cursor captures the current generation REFCOUNTED
    /// (§1.4) — file-DB batches execute at its keeper snapshot. If the
    /// generation is force-retired mid-iteration (TTL, threshold eviction,
    /// lifecycle — §3), the iterator transparently re-pins at the current
    /// head and RESUMES BY KEYSET ANCHOR — the resume predicate is
    /// position-free, so generation-hopping is safe (rows inserted behind
    /// the cursor at the hop are missed, ahead are seen; no duplicates).
    /// Memory family: the walk iterates the materialized-id generation
    /// (§4.1) — the id vector captured at the current epoch — hydrating per
    /// batch; rows deleted after capture are skipped.
    public func makeIterator() -> KeysetCursor<Element> {
        let descriptor = _descriptor
        guard let spec = descriptor.keysetSpec else {
            return KeysetCursor(self)
        }
        let (coordinator, shape, _) = _liveContext()
        let backend = _lattice.backend
        let table = Element.entityName
        let batchSize = Swift.max(1, _tuning.pageSize)

        if _usesMaterializedIDs(coordinator, descriptor) {
            let ctx = coordinator.resolve(table: table, shapeKey: descriptor.key)
            if let ids = _materializedIDs(shape: shape, coordinator: coordinator,
                                          descriptor: descriptor, ctx: ctx) {
                var cursor = 0
                // Captures self STRONGLY: `for x in lattice.objects(…)`
                // iterates a temporary facade — only the cursor's closure
                // keeps it alive for the walk (no cycle: the facade does not
                // own the cursor).
                return KeysetCursor(nextBatch: {
                    // A fully-deleted batch thins to empty — keep walking
                    // (§1.4); the vector is finite, so the walk terminates.
                    while cursor < ids.count {
                        let end = Swift.min(cursor + batchSize, ids.count)
                        let batch = self._hydrate(ids: ids[cursor..<end], placeholders: false)
                        cursor = end
                        if !batch.isEmpty { return batch }
                    }
                    return nil
                })
            }
            // Capture exhausted its retry budget: fall through to the live
            // keyset walk below (Commit-2 behavior — still never a trap).
        }

        // Capture the current generation with a logical hold (§1.4): the
        // walk survives coordinator supersession; only a force-retire (§3)
        // can invalidate it, and then the walk re-pins + resumes by anchor.
        let initial = coordinator.resolve(table: table, shapeKey: descriptor.key)
        let hold = _IteratorGenerationHold(backend: backend)
        hold.retain(initial.generationID)

        var anchor: KeysetAnchor? = nil
        var pageIndex = 0
        /// Batch boundaries coincide with page boundaries only until a trim
        /// or a generation hop (below); after that, stop feeding the shared
        /// anchor map — the walk's own resume anchor stays exact either way.
        var alignedWithPages = true
        var finished = false
        // Captures self STRONGLY — see the materialized-id walk above: the
        // cursor must keep the (possibly temporary) facade alive.
        return KeysetCursor(nextBatch: {
            if finished { return nil }
            let resume = anchor.map { KeysetSQL.resumePredicate(spec: spec, anchor: $0) }
            let whereSQL = KeysetSQL.conjoin(where: descriptor.whereSQL, resume: resume)
            var fetched = self._queryRows(where: whereSQL, orderBy: descriptor.orderBySQL,
                                          generation: hold.id,
                                          limit: Int64(batchSize), offset: nil,
                                          groupBy: nil, distinctBy: nil,
                                          reuseInstances: true)
            if fetched == nil {
                // Generation force-retired mid-walk (TTL, threshold
                // eviction, lifecycle — §3): transparently re-pin at the
                // current head and resume by anchor (§1.4).
                let fresh = coordinator.resolveAfterStaleRead(failedGeneration: hold.id, table: table,
                                                              shapeKey: descriptor.key)
                hold.retain(fresh.generationID)
                alignedWithPages = false   // ranks may have shifted at the hop
                fetched = self._queryRows(where: whereSQL, orderBy: descriptor.orderBySQL,
                                          generation: hold.id,
                                          limit: Int64(batchSize), offset: nil,
                                          groupBy: nil, distinctBy: nil,
                                          reuseInstances: true)
                    ?? self._queryRows(where: whereSQL, orderBy: descriptor.orderBySQL,
                                       generation: 0,
                                       limit: Int64(batchSize), offset: nil,
                                       groupBy: nil, distinctBy: nil,
                                       reuseInstances: true)
            }
            var rows = fetched ?? []
            if rows.count < batchSize {
                // Short batch = end of the result set at fill time.
                finished = true
                hold.release()
                return rows.isEmpty ? nil : rows
            }
            // Full batch: resume from the LAST delivered row. A boundary row
            // deleted between the fill and the anchor read cannot anchor
            // (extractAnchor refuses dead rows rather than fabricating a
            // NULL anchor) — TRIM it and resume from the nearest anchorable
            // predecessor instead: trimmed rows are re-fetched by the next
            // batch if still live, so nothing is skipped and nothing is
            // delivered twice.
            var end: KeysetAnchor? = nil
            while let last = rows.last {
                if let extracted = KeysetSQL.extractAnchor(from: last, spec: spec) {
                    end = extracted
                    break
                }
                rows.removeLast()
            }
            guard let end else {
                // The entire batch died mid-flight (heavy churn): ending the
                // walk early is within contract (§1.4 — a shrinking table
                // ends the walk early; never a trap, never a duplicate).
                finished = true
                hold.release()
                return nil
            }
            anchor = end
            if rows.count == batchSize, alignedWithPages {
                // Untrimmed batches end exactly at page boundaries: warm the
                // shape's persistent anchor map as the walk streams (§2.4).
                shape.recordAnchor(end, endOfPage: pageIndex)
            } else if rows.count < batchSize {
                alignedWithPages = false
            }
            pageIndex += 1
            return rows
        })
    }

    init(_ lattice: Lattice, whereStatement: Query<Bool>? = nil, sortStatement: (any SortComparator)? = nil, boundsConstraint: BoundsConstraint? = nil, groupByColumn: String? = nil, distinctByColumn: String? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.groupByColumn = groupByColumn
        self.distinctByColumn = distinctByColumn
    }

    init(_ lattice: Lattice, whereStatement: Predicate<Element>, sortStatement: (any SortComparator)? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement(Query())
        self.sortStatement = sortStatement
        self.boundsConstraint = nil
        self.groupByColumn = nil
        self.distinctByColumn = nil
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    /// Key-path based sort, available on all deployment targets (unlike the
    /// `SortDescriptor` overload, whose `keyPath` is iOS 17+). Resolves the
    /// column at call time and stores it as a `KeyPathSort`.
    public func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder = .forward) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: KeyPathSort<Element>(column: _name(for: keyPath), order: order), boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    /// Applies a pre-resolved `KeyPathSort` (used by `@LatticeQuery`, which
    /// resolves the column from a key path up front so it works on iOS 15).
    internal func _sorted(by comparator: KeyPathSort<Element>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: comparator, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func `where`(_ query: ((Query<Element>) -> Query<Bool>)) -> TableResults<Element> {
        let q = Query<Element>()
        let firstResult = query(q)

        // No union fields accessed — normal path
        guard !q._unionAccessTracker.fields.isEmpty else {
            let combined: Query<Bool>? = if let existing = whereStatement {
                existing && firstResult
            } else {
                firstResult
            }
            return TableResults(_lattice, whereStatement: combined, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        }

        // Union path: build a SQL CASE WHEN from variant runs.
        // First run result is the ELSE (default/fallthrough).
        // Each variant run is a WHEN condition THEN predicate.
        var result: Query<Bool> = firstResult
        for (fieldName, unionType) in q._unionAccessTracker.fields {
            let variants = unionType._makeQueryVariants(parentKeyPath: [fieldName])
            var whens: [(condition: Query<Bool>, result: Query<Bool>)] = []

            for (caseName, variant) in variants {
                var q2 = Query<Element>()
                q2._unionOverrides[fieldName] = variant
                let variantResult = query(q2)

                let condition = Query<Bool>._unionSubquery(
                    parentKeyPath: [fieldName],
                    unionTable: unionType.unionTableName,
                    whereClause: "\"case\" = '\(caseName)'")
                // Wrap the variant's predicate in a subquery so union columns resolve
                // against the union table (parent columns resolve via correlated subquery)
                let thenSQL = variantResult._constructPredicate().0
                let wrappedResult = Query<Bool>._unionSubquery(
                    parentKeyPath: [fieldName],
                    unionTable: unionType.unionTableName,
                    whereClause: "\"case\" = '\(caseName)' AND (\(thenSQL))")
                whens.append((condition: condition, result: wrappedResult))
            }

            result = Query<Bool>._caseWhen(whens: whens, elseResult: firstResult)
        }

        let combined: Query<Bool>? = if let existing = whereStatement {
            existing && result
        } else {
            result
        }
        return TableResults(_lattice, whereStatement: combined, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: _name(for: keyPath), distinctByColumn: distinctByColumn)
    }

    public func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: _name(for: keyPath))
    }

    public var startIndex: Int { 0 }
    public var count: Int { endIndex }

    #if canImport(Combine)
    public var objectWillChange: ResultsChangePublisher {
        ResultsChangePublisher { [weak self] callback in
            guard let self else { return AnyCancellable {} }
            return self.observe { change in callback(change) }
        }
    }
    #endif


    public var endIndex: Int {
        // Epoch-cached count (item A §5: idle render tick issues ZERO
        // collection queries). Batch-pinned generation resolution keeps one
        // render batch on one snapshot (§1.3); the count statement itself
        // runs with no locks held — on the generation's keeper connection
        // for file DBs (§1.1), from the materialized-id vector for the
        // memory family (§4.1) — and publishes under epoch re-validation
        // (§2.3).
        let (coordinator, shape, descriptor) = _liveContext()
        var ctx = coordinator.resolve(table: Element.entityName, shapeKey: descriptor.key)
        if let cached = shape.count(epoch: ctx.epoch, floor: ctx.floor) {
            _noteServed(ctx.epoch)
            return cached
        }
        // Memory family (§4.1): count == ids.count from one captured vector
        // (structural consistency with subscript membership — rung 1).
        if _usesMaterializedIDs(coordinator, descriptor) {
            if let ids = _materializedIDs(shape: shape, coordinator: coordinator,
                                          descriptor: descriptor, ctx: ctx) {
                _noteServed(ctx.epoch)
                return ids.count
            }
            // Capture exhausted its LOCKED-retry budget (§4.1 mechanism 3):
            // serve the last-known count, else fall through to a live count.
            if let lastKnown = shape.lastKnownCountValue() {
                _noteServed(ctx.epoch)
                return lastKnown
            }
        }
        // File-DB keeper path: COUNT(*) at the generation's snapshot; a
        // stale sentinel re-pins once (§3.4); still stale → live head count
        // (§1.2 rung-1 carve-out). Bbox shapes count live (the Commit-4
        // bridge carries no bbox count-at form).
        var counted: Int? = nil
        if ctx.generationID != 0, boundsConstraint == nil {
            counted = _generationCount(descriptor, generation: ctx.generationID)
            if counted == nil {
                ctx = coordinator.resolveAfterStaleRead(failedGeneration: ctx.generationID,
                                                        table: Element.entityName,
                                                        shapeKey: descriptor.key)
                if ctx.generationID != 0 {
                    counted = _generationCount(descriptor, generation: ctx.generationID)
                }
            }
        }
        let result = counted ?? _liveCount(descriptor)
        shape.publishCount(result, epoch: ctx.epoch, floor: ctx.floor,
                           currentFloor: coordinator.currentFloor(table: Element.entityName,
                                                                  shapeKey: descriptor.key))
        _noteServed(ctx.epoch)
        return result
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

//    public enum CollectionChange: Sendable {
//        case insert(Int64)
//        case delete(Int64)
//    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        _lattice.observe(Element.self, where: self.whereStatement) { change in
            observer(change)
        }
    }

    // MARK: - Vector Search

    /// Find the k nearest neighbors to a query vector.
    /// Returns objects sorted by distance (closest first).
    ///
    /// When called on filtered results (via `.where()`), only objects matching
    /// the filter are considered for the search.
    ///
    /// Example:
    /// ```swift
    /// // Search all documents
    /// let similar = lattice.objects(Document.self)
    ///     .nearest(to: queryEmbedding, on: \.embedding, limit: 10)
    ///
    /// // Search only in a specific category
    /// let filtered = lattice.objects(Document.self)
    ///     .where { $0.category == "science" }
    ///     .nearest(to: queryEmbedding, on: \.embedding, limit: 10)
    /// ```
    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<Element, Vector<V>>,
        limit k: Int,
        distance metric: DistanceMetric
    ) -> any NearestResults<Element> {
        let constraint = VectorConstraint(keyPath: keyPath, queryVector: queryVector, k: k, metric: metric)
        return TableNearestResults(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name), order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .vector(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }

    // MARK: - Spatial Query (geo_bounds)

    /// Filter results to objects within a geographic bounding box.
    /// Uses R*Tree spatial index for efficient queries.
    ///
    /// Example:
    /// ```swift
    /// // Find places near San Francisco
    /// let sfPlaces = lattice.objects(Place.self)
    ///     .withinBounds(\.location, minLat: 37.7, maxLat: 37.8, minLon: -122.5, maxLon: -122.4)
    ///
    /// // Combined with other filters
    /// let sfCafes = lattice.objects(Place.self)
    ///     .where { $0.category == "cafe" }
    ///     .withinBounds(\.location, minLat: 37.7, maxLat: 37.8, minLon: -122.5, maxLon: -122.4)
    /// ```
    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<Element, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> TableResults<Element> {
        let constraint = BoundsConstraint(keyPath: keyPath, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    // MARK: - Geo Nearest (proximity search)

    /// Find objects nearest to a geographic point within a radius.
    /// Uses R*Tree for efficient spatial filtering.
    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<Element, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<Element> {
        let constraint = GeoNearestConstraint(
            keyPath: keyPath,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )
        return TableNearestResults(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name), order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .geo(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }

    // MARK: - Full-Text Search (FTS5)

    /// Search for objects matching a full-text query string.
    /// Terms are implicitly ANDed (FTS5 default).
    ///
    /// For explicit control over query semantics, use the `TextQuery` overload:
    /// ```swift
    /// .matching(.anyOf("machine", "learning"), on: \.content)   // OR
    /// .matching(.phrase("machine learning"), on: \.content)      // exact phrase
    /// ```
    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<Element, String>,
        limit: Int = 100
    ) -> any NearestResults<Element> {
        let constraint = TextConstraint(keyPath: keyPath, searchText: searchText, limit: limit)
        return TableNearestResults(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name), order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .text(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }

    /// Search for objects matching a type-safe full-text query.
    ///
    /// ```swift
    /// .matching(.allOf("machine", "learning"), on: \.content)   // AND
    /// .matching(.anyOf("machine", "learning"), on: \.content)   // OR
    /// .matching(.phrase("machine learning"), on: \.content)      // exact phrase
    /// .matching(.prefix("mach"), on: \.content)                  // prefix
    /// ```
    public func matching(
        _ query: TextQuery,
        on keyPath: KeyPath<Element, String>,
        limit: Int = 100
    ) -> any NearestResults<Element> {
        let constraint = TextConstraint(keyPath: keyPath, query: query, limit: limit)
        return TableNearestResults(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name), order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .text(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }
}

// MARK: - Iterator generation hold (item A §1.4, Commit 5)

/// Refcounted keeper hold for an in-flight iterator: retains the generation
/// so coordinator supersession cannot COMMIT the keeper under the walk. A
/// force-retire (§3: TTL, threshold eviction, lifecycle) still can — the
/// walk then re-pins and resumes by anchor. The hold releases on walk
/// completion and (belt) on cursor deallocation.
private final class _IteratorGenerationHold {
    private let backend: any LatticeBackend
    private(set) var id: UInt64 = 0

    init(backend: any LatticeBackend) { self.backend = backend }

    /// Swap the hold to `generationID` (0 = none): retains the new id when
    /// the generation is still live (a retiring/retired generation refuses —
    /// the walk falls back to a live batch), then releases the old hold.
    func retain(_ generationID: UInt64) {
        let previous = id
        if generationID != 0, generationID != previous, backend.retainReadGeneration(generationID) {
            id = generationID
        } else if generationID != previous {
            id = 0
        }
        if previous != 0, id != previous {
            backend.releaseReadGeneration(previous)
        }
    }

    func release() {
        if id != 0 { backend.releaseReadGeneration(id) }
        id = 0
    }

    deinit {
        if id != 0 { backend.releaseReadGeneration(id) }
    }
}
