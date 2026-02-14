import Foundation
import LatticeSwiftCppBridge

public final class TableResults<Element>: Results where Element: Model {
    public typealias UnderlyingElement = Element

    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<Element>?
    internal let boundsConstraint: BoundsConstraint?
    internal let groupByColumn: String?

    // Helper to build query parameters - always fetches fresh from DB (live results)
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        // If we have a bounds constraint, use the spatial query path
        if let bounds = boundsConstraint {
            return snapshotWithBounds(bounds, limit: limit, offset: offset)
        }

        let tableName = std.string(Element.entityName)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }
        let orderBy: lattice.OptionalString = if let sortStatement, let keyPath = sortStatement.keyPath {
            lattice.string_to_optional(std.string("\(_name(for: keyPath)) \(sortStatement.order == .forward ? "ASC" : "DESC")"))
        } else {
            .init()
        }
        let limitOpt: lattice.OptionalInt64 = if let limit { lattice.int64_to_optional(limit) } else { .init() }
        let offsetOpt: lattice.OptionalInt64 = if let offset { lattice.int64_to_optional(offset) } else { .init() }
        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else {
            .init()
        }

        let cxxResults = _lattice.cxxLattice.objects(tableName, whereClause, orderBy, limitOpt, offsetOpt, groupByOpt)

        var objects: [Element] = []
        objects.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let cxxObject = cxxResults[i]
            let object = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(cxxObject).make_shared()))
            objects.append(object)
        }

        return objects
    }

    private func snapshotWithBounds(_ bounds: BoundsConstraint, limit: Int64?, offset: Int64?) -> [Element] {
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        let orderBy: lattice.OptionalString = if let sortStatement, let kp = sortStatement.keyPath {
            lattice.string_to_optional(std.string("\(_name(for: kp)) \(sortStatement.order == .forward ? "ASC" : "DESC")"))
        } else {
            .init()
        }

        let limitOpt: lattice.OptionalInt64 = if let limit { lattice.int64_to_optional(limit) } else { .init() }
        let offsetOpt: lattice.OptionalInt64 = if let offset { lattice.int64_to_optional(offset) } else { .init() }
        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else {
            .init()
        }

        let cxxResults = _lattice.cxxLattice.objectsWithinBBox(
            table: std.string(Element.entityName),
            geoColumn: std.string(bounds.propertyName),
            minLat: bounds.minLat,
            maxLat: bounds.maxLat,
            minLon: bounds.minLon,
            maxLon: bounds.maxLon,
            where: whereClause,
            orderBy: orderBy,
            limit: limitOpt,
            offset: offsetOpt,
            groupBy: groupByOpt
        )

        var results: [Element] = []
        results.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let cxxObject = cxxResults[i]
            let object = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(cxxObject).make_shared()))
            results.append(object)
        }

        return results
    }

    private var token: AnyCancellable?

    init(_ lattice: Lattice, whereStatement: Query<Bool>? = nil, sortStatement: SortDescriptor<Element>? = nil, boundsConstraint: BoundsConstraint? = nil, groupByColumn: String? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.groupByColumn = groupByColumn
    }

    init(_ lattice: Lattice, whereStatement: Predicate<Element>, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement(Query())
        self.sortStatement = sortStatement
        self.boundsConstraint = nil
        self.groupByColumn = nil
    }

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn)
    }

    public func `where`(_ query: ((Query<Element>) -> Query<Bool>)) -> TableResults<Element> {
        let newWhere = query(Query())
        let combined: Query<Bool>? = if let existing = whereStatement {
            existing && newWhere
        } else {
            newWhere
        }
        return TableResults(_lattice, whereStatement: combined, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: _name(for: keyPath))
    }

    public var startIndex: Int { 0 }

    deinit {
        token?.cancel()
    }

    public var endIndex: Int {
        let tableName = std.string(Element.entityName)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }
        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else {
            .init()
        }

        // If we have a bounds constraint, use the spatial count method
        if let bounds = boundsConstraint {
            return Int(_lattice.cxxLattice.countWithinBBox(
                table: tableName,
                geoColumn: std.string(bounds.propertyName),
                minLat: bounds.minLat,
                maxLat: bounds.maxLat,
                minLon: bounds.minLon,
                maxLon: bounds.maxLon,
                where: whereClause
            ))
        }

        // Live count from C++
        return Int(_lattice.cxxLattice.count(tableName, whereClause, groupByOpt))
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
            sortStatement: sortStatement.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .vector(constraint),
            groupByColumn: groupByColumn
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
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, groupByColumn: groupByColumn)
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
            sortStatement: sortStatement.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .geo(constraint),
            groupByColumn: groupByColumn
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
            sortStatement: sortStatement.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .text(constraint),
            groupByColumn: groupByColumn
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
            sortStatement: sortStatement.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .text(constraint),
            groupByColumn: groupByColumn
        )
    }
}
