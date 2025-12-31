import Foundation
import LatticeSwiftCppBridge

public final class TableResults<Element>: Results where Element: Model {
    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<Element>?

    // Helper to build query parameters - always fetches fresh from DB (live results)
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
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

        let cxxResults = _lattice.cxxLattice.objects(tableName, whereClause, orderBy, limitOpt, offsetOpt)

        var objects: [Element] = []
        objects.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let cxxObject = cxxResults[i]
            let object = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(cxxObject).make_shared()))
            objects.append(object)
        }

        return objects
    }

    private var token: AnyCancellable?

    init(_ lattice: Lattice, whereStatement: Query<Bool>? = nil, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
    }

    init(_ lattice: Lattice, whereStatement: Predicate<Element>, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement(Query())
        self.sortStatement = sortStatement
    }

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor)
    }

    public func `where`(_ query: ((Query<Element>) -> Query<Bool>)) -> TableResults<Element> {
        return TableResults(_lattice, whereStatement: query(Query()))
    }

    public var startIndex: Int { 0 }

    deinit {
        token?.cancel()
    }

    public var endIndex: Int {
        // Live count from C++
        let tableName = std.string(Element.entityName)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }
        return Int(_lattice.cxxLattice.count(tableName, whereClause))
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
        limit k: Int = 10,
        distance metric: DistanceMetric = .l2
    ) -> [NearestMatch<Element>] {
        let propertyName = _name(for: keyPath)
        let queryData = queryVector.toData()

        var byteVec = lattice.ByteVector()
        for byte in queryData {
            byteVec.push_back(byte)
        }

        // Build the where clause if we have a filter
        // The predicate uses column names from the model table (aliased as 'm' in the JOIN)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        let cxxResults = _lattice.cxxLattice.nearest_neighbors(
            std.string(Element.entityName),
            std.string(propertyName),
            byteVec,
            Int32(k),
            metric.rawValue,
            whereClause
        )

        var results: [NearestMatch<Element>] = []
        results.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let pair = cxxResults[i]
            var managedObj = pair.first
            let distance = pair.second

            var swiftObj = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
            results.append(NearestMatch(object: swiftObj, distance: distance))
        }

        return results
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
    ) -> [Element] {
        let propertyName = _name(for: keyPath)

        // Build the where clause if we have a filter
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

        let cxxResults = _lattice.cxxLattice.objectsWithinBBox(
            table: std.string(Element.entityName),
            geoColumn: std.string(propertyName),
            minLat: minLat,
            maxLat: maxLat,
            minLon: minLon,
            maxLon: maxLon,
            where: whereClause,
            orderBy: orderBy,
            limit: .init(),
            offset: .init()
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
    ) -> [NearestMatch<Element>] {
        let propertyName = _name(for: keyPath)
        let radiusMeters = maxDistance * unit.toMeters

        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        let cxxResults = _lattice.cxxLattice.geoNearest(
            table: std.string(Element.entityName),
            geoColumn: std.string(propertyName),
            lat: location.latitude,
            lon: location.longitude,
            radius: radiusMeters,
            limit: Int32(limit),
            sortByDistance: sortedByDistance,
            where: whereClause
        )

        var results: [NearestMatch<Element>] = []
        results.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let pair = cxxResults[i]
            var managedObj = pair.first
            let distanceMeters = pair.second

            let swiftObj = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
            let distanceInUnit = unit.fromMeters(distanceMeters)
            results.append(NearestMatch(object: swiftObj, distance: distanceInUnit))
        }

        return results
    }
}
