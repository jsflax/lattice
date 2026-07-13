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

    // MARK: - Live generation-cached access (item A, Commit 1)
    //
    // `count`/`subscript` serve through the process-global query-shape
    // registry: one shared `QueryShapeState` per
    // (lattice identity, table, whereSQL, orderBySQL, groupBy, distinctBy),
    // so `@LatticeQuery` re-fetches, `@Relation` property accesses and TSR
    // resolves are thin facades over an already-warm cache (§1.5, §1.4).
    //
    // COMMIT-2 STAGING: epochs are logical (no pinned read snapshot yet);
    // cold fills and counts are live reads on the existing neutral backend
    // surface until the keeper pool / generation-scoped bridge reads land
    // (Commits 3–5). Fills page by KEYSET with persistent anchors (§2.4):
    // deterministic total order `(sortColumn userDir, id ASC)`, NULL-aware
    // resume predicates, one `LIMIT pageSize OFFSET k` per cold random jump
    // only. Grouped/distinct/bbox shapes keep OFFSET fills (§2.4/§4.5
    // carve-out — no sound keyset anchor exists for them). Same-handle
    // writes invalidate synchronously (read-your-writes, §1.3 Layer 1);
    // cross-handle writes ride the interim scheduler-dispatched observer
    // signal (see GenerationCoordinator).

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

    private func _liveCount(_ descriptor: ShapeDescriptor) -> Int {
        if let bounds = boundsConstraint {
            return Int(_lattice.backend.countWithinBBox(table: Element.entityName, geoColumn: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon, where: descriptor.whereSQL))
        }
        return Int(_lattice.backend.count(table: Element.entityName, where: descriptor.whereSQL, groupBy: groupByColumn, distinctBy: distinctByColumn))
    }

    private struct PageFill {
        let rows: [Element]
        /// End-of-page anchor (§2.4), recorded only for FULL pages (a short
        /// page ends the result set, not a page boundary) on keyset shapes.
        let endAnchor: KeysetAnchor?
    }

    /// One page fill (Commit 2, §2.4). Keyset shapes resume from the nearest
    /// recorded anchor — filling page p from the anchor at p−1 is pure
    /// keyset, O(log n + pageSize); a farther anchor adds a small OFFSET
    /// remainder (O(gap), still one statement); no anchor at all is the cold
    /// random jump, one `LIMIT pageSize OFFSET k` — O(k) once per jump, then
    /// the neighborhood is anchored. Grouped/distinct/bbox shapes page by
    /// OFFSET (carve-out). Generation-scoped connection routing lands in
    /// Commit 5; fills are live reads until then.
    private func _fillPage(_ descriptor: ShapeDescriptor, shape: QueryShapeState,
                           pageIndex: Int, pageSize: Int) -> PageFill {
        let offset = pageIndex * pageSize
        guard let spec = descriptor.keysetSpec else {
            let rows = _fillPageOffset(descriptor, offset: offset, limit: pageSize)
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
        let rows = _lattice.backend.objects(
            table: Element.entityName,
            where: KeysetSQL.conjoin(where: descriptor.whereSQL, resume: resume),
            orderBy: descriptor.orderBySQL,
            limit: Int64(pageSize),
            offset: gapOffset == 0 ? nil : Int64(gapOffset),
            groupBy: nil, distinctBy: nil
        ).map { Element(dynamicObject: $0) }
        shape.noteFill(usedOffset: gapOffset != 0, usedKeyset: resume != nil || pageIndex == 0)
        let endAnchor: KeysetAnchor? = rows.count == pageSize
            ? rows.last.flatMap { KeysetSQL.extractAnchor(from: $0, spec: spec) }
            : nil
        return PageFill(rows: rows, endAnchor: endAnchor)
    }

    /// OFFSET page fill — the §2.4/§4.5 carve-out (grouped/distinct/bbox and
    /// non-primitive sort columns). Cold pages are O(offset); never traps.
    private func _fillPageOffset(_ descriptor: ShapeDescriptor, offset: Int, limit: Int) -> [Element] {
        if let bounds = boundsConstraint {
            return _lattice.backend.objectsWithinBBox(table: Element.entityName, geoColumn: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon, where: descriptor.whereSQL, orderBy: descriptor.orderBySQL, limit: Int64(limit), offset: Int64(offset), groupBy: groupByColumn).map { Element(dynamicObject: $0) }
        }
        return _lattice.backend.objects(table: Element.entityName, where: descriptor.whereSQL, orderBy: descriptor.orderBySQL, limit: Int64(limit), offset: Int64(offset), groupBy: groupByColumn, distinctBy: distinctByColumn).map { Element(dynamicObject: $0) }
    }

    /// Non-trapping indexed access (§1.7): tolerant-ladder rungs (a) — the
    /// current generation's fill result — and (b) — the retained previous
    /// generation's page. Returns nil instead of rungs (c)/(d) (the lifeboat
    /// and the invalidated placeholder exist to satisfy the non-optional
    /// `subscript`; an optional return expresses "no such element" directly).
    public func element(at index: Int) -> Element? {
        guard index >= 0 else { return nil }
        let (coordinator, shape, descriptor) = _liveContext()
        let (epoch, floor) = coordinator.resolve(table: Element.entityName)
        let pageSize = Swift.max(1, _tuning.pageSize)
        let pageIndex = index / pageSize
        let slot = index % pageSize

        // Rung (a): the current generation's fill result.
        if let cached = shape.page(pageIndex, epoch: epoch, floor: floor) {
            _noteServed(epoch)
            if slot < cached.count, let element = cached[slot] as? Element {
                return element
            }
            // Cached page is short at this epoch — index not present; fall
            // through to the stale rungs.
        } else {
            // Cold page: fill with NO locks held (§2.3 two-phase), publish
            // with epoch re-validation. The end-of-page anchor is recorded
            // unconditionally (anchors are content-positional and
            // epoch-agnostic, §2.4).
            let fill = _fillPage(descriptor, shape: shape, pageIndex: pageIndex, pageSize: pageSize)
            shape.publishPage(pageIndex, rows: fill.rows, endAnchor: fill.endAnchor,
                              epoch: epoch, floor: floor,
                              currentFloor: coordinator.currentFloor(table: Element.entityName),
                              maxCachedPages: _tuning.maxCachedPages)
            _noteServed(epoch)
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

    /// Statement-fresh single-row read. Shadows `Collection.first` for
    /// concrete callers: one `LIMIT 1` statement instead of a count + page
    /// fill — the observer-membership path (`rowMatchesNow`) and one-shot
    /// `.first` lookups stay fresh and do not populate the shape registry.
    public var first: Element? {
        snapshot(limit: 1, offset: nil).first
    }

    // MARK: - Observation infrastructure

    // Helper to build query parameters - always fetches fresh from DB (live
    // results). Uses the EFFECTIVE order (§2.4 / MIGRATION line): unsorted
    // snapshots gain a deterministic implicit `ORDER BY id ASC`, sorted ones
    // the `id ASC` tiebreaker — so `snapshot()` order ≡ the keyset walk's
    // total order (pinned by the Commit-2 property matrix).
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        LatticePerf.bump(.snapshots)

        // If we have a bounds constraint, use the spatial query path
        if let bounds = boundsConstraint {
            return snapshotWithBounds(bounds, limit: limit, offset: offset)
        }

        return _lattice.backend.objects(table: Element.entityName, where: whereStatement?.predicate, orderBy: _effectiveOrderBySQL(qualifyTiebreaker: false), limit: limit, offset: offset, groupBy: groupByColumn, distinctBy: distinctByColumn).map { Element(dynamicObject: $0) }
    }

    private func snapshotWithBounds(_ bounds: BoundsConstraint, limit: Int64?, offset: Int64?) -> [Element] {
        return _lattice.backend.objectsWithinBBox(table: Element.entityName, geoColumn: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon, where: whereStatement?.predicate, orderBy: _effectiveOrderBySQL(qualifyTiebreaker: true), limit: limit, offset: offset, groupBy: groupByColumn).map { Element(dynamicObject: $0) }
    }

    // MARK: - Iteration (item A §1.4, Commit 2)

    /// Keyset walk: batches of `pageSize` resumed by NULL-aware anchor
    /// predicate on the effective total order `(sortColumn userDir, id ASC)`
    /// — O(n) for a full walk, each key visited at most once, never a trap
    /// (a shrinking table ends the walk early; the resume predicate is
    /// value-based, so a deleted anchor row cannot derail it). Batch
    /// boundaries align with page boundaries (`batchSize == pageSize`), so
    /// the walk warms the shape's persistent anchor map as it streams (§2.4).
    /// Carve-out shapes (grouped/distinct/bbox/non-primitive sort) batch by
    /// OFFSET exactly as the old `Cursor` did.
    public func makeIterator() -> KeysetCursor<Element> {
        let descriptor = _descriptor
        guard let spec = descriptor.keysetSpec else {
            return KeysetCursor(self)
        }
        let (_, shape, _) = _liveContext()
        let backend = _lattice.backend
        let table = Element.entityName
        let batchSize = Swift.max(1, _tuning.pageSize)
        var anchor: KeysetAnchor? = nil
        var pageIndex = 0
        /// Batch boundaries coincide with page boundaries only until a trim
        /// (below); after that, stop feeding the shared anchor map — the
        /// walk's own resume anchor stays exact either way.
        var alignedWithPages = true
        var finished = false
        return KeysetCursor(nextBatch: {
            if finished { return nil }
            let resume = anchor.map { KeysetSQL.resumePredicate(spec: spec, anchor: $0) }
            var rows = backend.objects(
                table: table,
                where: KeysetSQL.conjoin(where: descriptor.whereSQL, resume: resume),
                orderBy: descriptor.orderBySQL,
                limit: Int64(batchSize), offset: nil,
                groupBy: nil, distinctBy: nil
            ).map { Element(dynamicObject: $0) }
            if rows.count < batchSize {
                // Short batch = end of the result set at fill time.
                finished = true
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
        // collection queries). Batch-pinned epoch resolution keeps one
        // render batch on one epoch (§1.3); the count statement itself runs
        // with no locks held and publishes under epoch re-validation (§2.3).
        let (coordinator, shape, descriptor) = _liveContext()
        let (epoch, floor) = coordinator.resolve(table: Element.entityName)
        if let cached = shape.count(epoch: epoch, floor: floor) {
            _noteServed(epoch)
            return cached
        }
        let counted = _liveCount(descriptor)
        shape.publishCount(counted, epoch: epoch, floor: floor,
                           currentFloor: coordinator.currentFloor(table: Element.entityName))
        _noteServed(epoch)
        return counted
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
