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
    internal let boundsConstraint: BoundsConstraint?
    internal let groupByColumn: String?
    internal let distinctByColumn: String?

    // MARK: - Observation infrastructure

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
        let orderBy: lattice.OptionalString = if let sd = _sortDescriptor, let keyPath = sd.keyPath {
            lattice.string_to_optional(std.string("\(_name(for: keyPath)) \(sd.order == .forward ? "ASC" : "DESC")"))
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
        let distinctByOpt: lattice.OptionalString = if let distinctByColumn {
            lattice.string_to_optional(std.string(distinctByColumn))
        } else {
            .init()
        }

        let cxxResults = _lattice.cxxLattice.objects(tableName, whereClause, orderBy, limitOpt, offsetOpt, groupByOpt, distinctByOpt)

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

        let orderBy: lattice.OptionalString = if let sd = _sortDescriptor, let kp = sd.keyPath {
            lattice.string_to_optional(std.string("\(_name(for: kp)) \(sd.order == .forward ? "ASC" : "DESC")"))
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

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
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
        let distinctByOpt: lattice.OptionalString = if let distinctByColumn {
            lattice.string_to_optional(std.string(distinctByColumn))
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
        return Int(_lattice.cxxLattice.count(tableName, whereClause, groupByOpt, distinctByOpt))
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
            sortStatement: _sortDescriptor.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
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
            sortStatement: _sortDescriptor.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
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
            sortStatement: _sortDescriptor.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
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
            sortStatement: _sortDescriptor.map {
                RawNearestSortDescriptor($0.keyPath!, order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .text(constraint),
            groupByColumn: groupByColumn,
            distinctByColumn: distinctByColumn
        )
    }
}
