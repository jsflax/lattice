import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge

extension Lattice {
    public func objects<V>(_ virtualModel: V.Type) -> any VirtualResults<V> {
        self.schema!._generateVirtualResults(virtualModel, on: self)
    }
}

public protocol VirtualResults<Element> : Results where UnderlyingElement == Element {
    associatedtype Models
    func _addType<M: Model>(_ type: M.Type) -> any VirtualResults<Element>
}

// Parameter-pack polymorphic results. Gated to iOS 17 (variadic generics).
// iOS 15 uses `_VirtualResultsCompat` (VirtualResultsCompat.swift), which stores
// the model types in an array instead of a pack.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public final class _VirtualResults<each M: Model, Element>: VirtualResults, ObservableObject, @unchecked Sendable {
    public typealias UnderlyingElement = Element
    public typealias Models = (repeat each M)

    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: (any SortComparator)?
    internal var _sortDescriptor: SortDescriptor<Element>? {
        sortStatement as? SortDescriptor<Element>
    }
    /// Resolved ORDER BY column + direction without touching the iOS-17-only
    /// `SortDescriptor.keyPath` except behind an availability guard.
    /// `sortedBy(_:order:)` stores a `KeyPathSort` so this resolves on any OS.
    internal var _sortColumn: (name: String, order: SortOrder)? {
        if let ks = sortStatement as? KeyPathSort<Element> {
            return (ks.column, ks.order)
        }
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
           let sd = sortStatement as? SortDescriptor<Element>, let kp = sd.keyPath {
            return (nameForKeyPath(kp), sd.order)
        }
        return nil
    }
    internal let boundsConstraint: BoundsConstraint?
    internal let groupByColumn: String?
    internal let distinctByColumn: String?

    // MARK: - Observation infrastructure
    #if canImport(Combine)
    public var objectWillChange: ResultsChangePublisher {
        ResultsChangePublisher { [weak self] callback in
            guard let self else { return AnyCancellable {} }
            return self.observe { change in callback(change) }
        }
    }
    #endif

    public func _addType<Q: Model>(_ type: Q.Type) -> any VirtualResults<Element> {
        _VirtualResults<repeat each M, Q, Element>.init(self._lattice)
    }

    package func merge<each V: Model>(other virtualResults: _VirtualResults<repeat each V, Element>) -> _VirtualResults<repeat each M, repeat each V, Element> {
        return .init(self._lattice)
    }

    package init(types: repeat (each M).Type, proto: Element.Type, lattice: Lattice) {
        self._lattice = lattice
        whereStatement = nil
        sortStatement = nil
        boundsConstraint = nil
        groupByColumn = nil
        distinctByColumn = nil
    }
    private var firstType: any Model.Type {
        for t in repeat (each M).self {
            return t
        }
        // Structurally unreachable: `_buildVirtualResults` always seeds the
        // pack with at least one conforming type.
        preconditionFailure("virtual results with an empty model-type pack")
    }

    /// Tolerant-ladder rung (d) witness (item A §1.2): an unmanaged,
    /// default-valued instance of the first conforming concrete type.
    public func _ladderPlaceholder() -> Element? {
        firstType.init(isolation: nil) as? Element
    }

    private var tableNames: [String] {
        var tableNames: [String] = []
        for type in repeat (each M).self {
            tableNames.append(type.entityName)
        }
        return tableNames
    }

    // Helper to build query parameters - always fetches fresh from DB (live results)
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        var objects: [Element] = []
        
        let orderBy: String? = _sortColumn.map { "\($0.name) \($0.order == .forward ? "ASC" : "DESC")" }
        let cxxResults = _lattice.backend.unionObjects(tables: self.tableNames, where: whereStatement?.predicate, orderBy: orderBy, limit: limit, offset: offset)
        
        for row in cxxResults {
            for type in repeat (each M).self {
                if type.entityName == row.tableName {
                    objects.append(type.init(dynamicObject: row) as! Element)
                    break
                }
            }
        }

        return objects
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
    
    private func constructVirtualQuery<T>(_ t: T.Type) -> some _Query<Element> where T: Model {
        _VirtualQuery<T, Element>()
    }
    
    public func `where`(_ query: (_VirtualQuery<repeat each M, Element>) -> Query<Bool>) -> _VirtualResults<repeat each M, Element> {
        let types = (repeat (each M).self)
        for t in repeat each types {
            return _VirtualResults(_lattice,
                        whereStatement: query(_VirtualQuery<repeat each M, Element>()),
                        sortStatement: sortStatement,
                        boundsConstraint: boundsConstraint,
                        groupByColumn: groupByColumn,
                        distinctByColumn: distinctByColumn)
        }
        // Structurally unreachable: the pack is never empty (see firstType).
        preconditionFailure("virtual results with an empty model-type pack")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> _VirtualResults<repeat each M, Element> {
        return _VirtualResults(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    /// Key-path based sort, available on all deployment targets (the
    /// `SortDescriptor` overload's `keyPath` is iOS 17+).
    public func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder = .forward) -> _VirtualResults<repeat each M, Element> {
        return _VirtualResults(_lattice, whereStatement: whereStatement, sortStatement: KeyPathSort<Element>(column: nameForKeyPath(keyPath), order: order), boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> _VirtualResults<repeat each M, Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let columnName = inst._lastKeyPathUsed ?? "id"
        return _VirtualResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: columnName, distinctByColumn: distinctByColumn)
    }

    public func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> _VirtualResults<repeat each M, Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let columnName = inst._lastKeyPathUsed ?? "id"
        return _VirtualResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: columnName)
    }
    
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        var cancellables: [AnyCancellable] = []
        for t in repeat (each M).self {
            cancellables.append(_lattice.observe(t.self, where: self.whereStatement) { change in
                observer(change)
            })
        }
        return AnyCancellable {
            cancellables.forEach { $0.cancel() }
        }
    }
    
    public var startIndex: Int { 0 }
    public var count: Int { endIndex }

    public var endIndex: Int {
        // Live count from C++
        var count = 0
        for type in repeat (each M).self {
            count += Int(_lattice.backend.count(table: type.entityName, where: whereStatement?.predicate))
        }
        return count
    }

    public func index(after i: Int) -> Int {
        i + 1
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
        limit k: Int = 10,
        distance metric: DistanceMetric = .l2
    ) -> any NearestResults<Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = VectorConstraint(keyPath: propertyName, queryVector: queryVector, k: k, metric: metric)

        return _VirtualNearestResults<repeat each M, Element>(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name),
                                         order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .vector(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }

    func nameForKeyPath(_ keyPath: PartialKeyPath<Element>) -> String {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        return inst._lastKeyPathUsed ?? "id"
    }

    // MARK: - Spatial Query (geo_bounds)

    /// Filter results to objects within a geographic bounding box.
    /// Queries each type's R*Tree and merges results.
    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<Element, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> _VirtualResults<repeat each M, Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = BoundsConstraint(
            propertyName: propertyName,
            minLat: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: maxLon
        )
        return _VirtualResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    /// Find objects nearest to a geographic point.
    /// Queries each type's R*Tree and merges results.
    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<Element, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = GeoNearestConstraint(
            keyPath: propertyName,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )

        return _VirtualNearestResults<repeat each M, Element>(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name),
                                         order: $0.order)
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
    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<Element, String>,
        limit: Int = 100
    ) -> any NearestResults<Element> {
        matching(.raw(searchText), on: keyPath, limit: limit)
    }

    /// Search for objects matching a type-safe full-text query.
    ///
    /// ```swift
    /// .matching(.allOf("machine", "learning"), on: \.content)   // AND
    /// .matching(.anyOf("machine", "learning"), on: \.content)   // OR
    /// .matching(.phrase("machine learning"), on: \.content)      // exact phrase
    /// ```
    public func matching(
        _ query: TextQuery,
        on keyPath: KeyPath<Element, String>,
        limit: Int = 100
    ) -> any NearestResults<Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = TextConstraint(propertyName: propertyName, query: query, limit: limit)

        return _VirtualNearestResults<repeat each M, Element>(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: _sortColumn.map {
                RawNearestSortDescriptor(descriptor: .keyPath($0.name),
                                         order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .text(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }
}
