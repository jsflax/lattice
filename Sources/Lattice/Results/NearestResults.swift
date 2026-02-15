import Foundation
import LatticeSwiftCppBridge
import Combine

// MARK: - Constraint Types

/// Bounding box constraint for spatial filtering (R*Tree)
package struct BoundsConstraint: Sendable {
    let propertyName: String
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    init<T: Model, G: GeoboundsProperty>(keyPath: KeyPath<T, G>, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.propertyName = _name(for: keyPath)
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }

    init(keyPath: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.propertyName = keyPath
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }

    init(propertyName: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.propertyName = propertyName
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }
}

/// Vector similarity constraint (vec0)
package struct VectorConstraint: Sendable {
    let propertyName: String
    let queryVector: Data
    let k: Int
    let metric: DistanceMetric

    init<T: Model, V: VectorElement>(keyPath: KeyPath<T, Vector<V>>,
                                     queryVector: Vector<V>, k: Int, metric: DistanceMetric) {
        self.propertyName = _name(for: keyPath)
        self.queryVector = queryVector.toData()
        self.k = k
        self.metric = metric
    }
    init<V: VectorElement>(keyPath: String,
                           queryVector: Vector<V>, k: Int, metric: DistanceMetric) {
        self.propertyName = keyPath
        self.queryVector = queryVector.toData()
        self.k = k
        self.metric = metric
    }
}

/// Geographic proximity constraint (R*Tree + Haversine)
package struct GeoNearestConstraint: Sendable {
    let propertyName: String
    let centerLat: Double
    let centerLon: Double
    let radiusMeters: Double
    let limit: Int
    let sortByDistance: Bool
    let unit: DistanceUnit

    init<T: Model, G: GeoboundsProperty>(keyPath: KeyPath<T, G>,
                                         center: (lat: Double, lon: Double),
                                         maxDistance: Double, unit: DistanceUnit, limit: Int, sortByDistance: Bool) {
        self.propertyName = _name(for: keyPath)
        self.centerLat = center.lat
        self.centerLon = center.lon
        self.radiusMeters = maxDistance * unit.toMeters
        self.limit = limit
        self.sortByDistance = sortByDistance
        self.unit = unit
    }
    
    init(keyPath: String,
         center: (lat: Double, lon: Double),
         maxDistance: Double, unit: DistanceUnit, limit: Int, sortByDistance: Bool) {
        self.propertyName = keyPath
        self.centerLat = center.lat
        self.centerLon = center.lon
        self.radiusMeters = maxDistance * unit.toMeters
        self.limit = limit
        self.sortByDistance = sortByDistance
        self.unit = unit
    }
}

/// Type-safe builder for FTS5 full-text search queries.
///
/// Use this instead of raw strings to make query semantics explicit:
/// ```swift
/// // All terms must match (AND)
/// .matching(.allOf("machine", "learning"), on: \.content)
///
/// // Any term can match (OR)
/// .matching(.anyOf("machine", "learning"), on: \.content)
///
/// // Exact phrase
/// .matching(.phrase("machine learning"), on: \.content)
///
/// // Prefix search
/// .matching(.prefix("mach"), on: \.content)
///
/// // Proximity: terms within N tokens of each other
/// .matching(.near("machine", "learning", distance: 2), on: \.content)
///
/// // Raw FTS5 syntax for advanced queries
/// .matching(.raw("(machine OR deep) AND learning"), on: \.content)
/// ```
public enum TextQuery: Sendable {
    /// All terms must match (implicit AND). This is FTS5's default behavior.
    case _allOf([String])
    /// Any term can match (OR).
    case _anyOf([String])
    /// Exact contiguous phrase match.
    case phrase(String)
    /// Prefix match — matches words starting with the given text.
    case prefix(String)
    /// Terms must appear within `distance` tokens of each other (default 10).
    case near(String, String, distance: Int = 10)
    /// Raw FTS5 query string for advanced usage (NEAR, column filters, grouping, etc.).
    case raw(String)

    /// All terms must match (AND).
    public static func allOf(_ terms: String...) -> TextQuery { ._allOf(terms) }
    /// Any term can match (OR).
    public static func anyOf(_ terms: String...) -> TextQuery { ._anyOf(terms) }

    /// Renders to FTS5 MATCH syntax.
    package var fts5Query: String {
        switch self {
        case ._allOf(let terms):
            return terms.map { "\"\($0)\"" }.joined(separator: " ")
        case ._anyOf(let terms):
            return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        case .phrase(let text):
            return "\"\(text)\""
        case .prefix(let text):
            return "\(text)*"
        case .near(let a, let b, let distance):
            return "NEAR(\"\(a)\" \"\(b)\", \(distance))"
        case .raw(let query):
            return query
        }
    }
}

/// Full-text search constraint (FTS5)
package struct TextConstraint: Sendable {
    let propertyName: String
    let searchText: String
    let limit: Int

    init<T: Model>(keyPath: KeyPath<T, String>, searchText: String, limit: Int) {
        self.propertyName = _name(for: keyPath)
        self.searchText = searchText
        self.limit = limit
    }

    init<T: Model>(keyPath: KeyPath<T, String>, query: TextQuery, limit: Int) {
        self.propertyName = _name(for: keyPath)
        self.searchText = query.fts5Query
        self.limit = limit
    }

    init(propertyName: String, searchText: String, limit: Int) {
        self.propertyName = propertyName
        self.searchText = searchText
        self.limit = limit
    }

    init(propertyName: String, query: TextQuery, limit: Int) {
        self.propertyName = propertyName
        self.searchText = query.fts5Query
        self.limit = limit
    }
}

/// Represents the type of proximity search being performed
package indirect enum ProximityType: Sendable {
    case vector(VectorConstraint)
    case geo(GeoNearestConstraint)
    case text(TextConstraint)
    case conjunction(ProximityType, ProximityType)
}

public enum NearestSortDescriptor<T> {
    case geoDistance(SortOrder)
    case vectorDistance(SortOrder)
    case textRank(SortOrder)
}

struct RawNearestSortDescriptor {
    enum Descriptor {
        case keyPath(String)
        case geoDistance
        case vectorDistance
        case textRank
    }
    let descriptor: Descriptor
    let order: SortOrder
    
    init(descriptor: Descriptor, order: SortOrder) {
        self.descriptor = descriptor
        self.order = order
    }
    
    init<T: Model>(_ keyPath: PartialKeyPath<T>, order: SortOrder) {
        self.descriptor = .keyPath(_name(for: keyPath))
        self.order = order
    }
}

// MARK: - NearestResults
public protocol NearestResults<T>: Results where UnderlyingElement == T, Element == _NearestMatch<T> {
    associatedtype T

    func sortedBy(_ sortDescriptor: NearestSortDescriptor<Element>) -> Self
}


/// Results type for proximity queries (vector or geographic).
/// Element type is `NearestMatch<T>` which includes both the object and its distance.
///
/// Supports full chaining:
/// ```swift
/// lattice.objects(Place.self)
///     .nearest(to: (37.7, -122.4), on: \.location, maxDistance: 1, unit: .miles)
///     .where { $0.distance < 0.5 }
///     .nearest(to: embedding, on: \.embedding, limit: 10)
/// ```
public struct TableNearestResults<T: Model>: NearestResults {
    public typealias Element = _NearestMatch<T>
    public typealias QueryType = Query<_NearestMatch<T>>
    public typealias NearestMatchType = _NearestMatch<Element>
    public typealias UnderlyingElement = T

    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: RawNearestSortDescriptor?
    internal let boundsConstraint: BoundsConstraint?
    internal let proximity: ProximityType
    internal let groupByColumn: String?

    init(lattice: Lattice,
         whereStatement: Query<Bool>? = nil,
         sortStatement: RawNearestSortDescriptor? = nil,
         boundsConstraint: BoundsConstraint? = nil,
         proximity: ProximityType,
         groupByColumn: String? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.proximity = proximity
        self.groupByColumn = groupByColumn
    }

    // MARK: - Chainable Methods

    /// Filter results by properties on the object or by distance.
    ///
    /// Example:
    /// ```swift
    /// .where { $0.distance < 0.5 }  // filter by distance
    /// .where { $0.rating > 4.0 }    // filter by object property (via dynamic member)
    /// ```
    public func `where`(_ predicate: (Query<Element>) -> Query<Bool>) -> Self {
        let newWhere = predicate(Query())
        let combined: Query<Bool>? = if let existing = whereStatement {
            existing && newWhere
        } else {
            newWhere
        }
        return Self(
            lattice: _lattice,
            whereStatement: combined,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: proximity,
            groupByColumn: groupByColumn
        )
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let object = T.init(isolation: #isolation)
        let match = _NearestMatch(object: object, distance: 0)
        _ = match[keyPath: keyPath]
        guard let columnName = object._lastKeyPathUsed else {
            preconditionFailure("Could not resolve keyPath to column name")
        }
        return Self(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: proximity,
            groupByColumn: columnName
        )
    }

    // MARK: - Results Protocol Conformance

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self {
        // NearestResults are sorted by distance from the proximity query
        // Additional sorting would require storing and applying a sort descriptor
        // For now, return self (proximity results are pre-sorted by distance)
        let t = T.init(isolation: #isolation)
        _ = _NearestMatch.init(object: t, distance: 0)[keyPath: sortDescriptor.keyPath!]
        return .init(lattice: self._lattice,
                     whereStatement: whereStatement,
                     sortStatement: .init(descriptor: .keyPath(t._lastKeyPathUsed!),
                                          order: sortDescriptor.order),
                     boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
    }

    public func sortedBy(_ sortDescriptor: NearestSortDescriptor<Element>) -> Self {
        switch sortDescriptor {
        case .geoDistance(let sortOrder):
            return .init(lattice: self._lattice,
                         whereStatement: whereStatement,
                         sortStatement: .init(descriptor: .geoDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
        case .vectorDistance(let sortOrder):
            return .init(lattice: self._lattice,
                         whereStatement: whereStatement,
                         sortStatement: .init(descriptor: .vectorDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
        case .textRank(let sortOrder):
            return .init(lattice: self._lattice,
                         whereStatement: whereStatement,
                         sortStatement: .init(descriptor: .textRank, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
        }
    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        _lattice.observe(T.self, where: self.whereStatement) { change in
            observer(change)
        }
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        // For proximity queries, we need to execute the query to get actual count
        // This is necessary because WHERE clauses can filter results below the limit
        let (vectors, geos, texts) = flattenProximity(proximity)
        let vectorLimit = vectors.map(\.k).min() ?? Int.max
        let geoLimit = geos.map(\.limit).min() ?? Int.max
        let textLimit = texts.map(\.limit).min() ?? Int.max
        let maxLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        // Execute snapshot to get actual count (capped at maxLimit)
        return Swift.min(snapshot(limit: Int64(maxLimit), offset: nil).count, maxLimit)
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    // MARK: - Execution

    /// Flatten the proximity tree into arrays for C++ API
    private func flattenProximity(_ p: ProximityType) -> (vectors: [VectorConstraint], geos: [GeoNearestConstraint], texts: [TextConstraint]) {
        switch p {
        case .vector(let v):
            return ([v], [], [])
        case .geo(let g):
            return ([], [g], [])
        case .text(let t):
            return ([], [], [t])
        case .conjunction(let left, let right):
            let (lv, lg, lt) = flattenProximity(left)
            let (rv, rg, rt) = flattenProximity(right)
            return (lv + rv, lg + rg, lt + rt)
        }
    }

    /// Execute the query and return results with distances.
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [_NearestMatch<T>] {
        let tableName = std.string(T.entityName)
        let (vectors, geos, texts) = flattenProximity(proximity)

        // Build C++ constraint vectors
        var cxxBounds = lattice.BoundsConstraintVector()
        if let bounds = boundsConstraint {
            var bc = lattice.bounds_constraint()
            bc.column = std.string(bounds.propertyName)
            bc.min_lat = bounds.minLat
            bc.max_lat = bounds.maxLat
            bc.min_lon = bounds.minLon
            bc.max_lon = bounds.maxLon
            cxxBounds.push_back(bc)
        }

        var cxxVectors = lattice.VectorConstraintVector()
        for vc in vectors {
            var cxxVc = lattice.vector_constraint()
            cxxVc.column = std.string(vc.propertyName)
            var byteVec = lattice.ByteVector()
            for byte in vc.queryVector {
                byteVec.push_back(byte)
            }
            cxxVc.query_vector = byteVec
            cxxVc.k = Int32(vc.k)
            cxxVc.metric = vc.metric.rawValue
            cxxVectors.push_back(cxxVc)
        }

        var cxxGeos = lattice.GeoConstraintVector()
        for gc in geos {
            var cxxGc = lattice.geo_constraint()
            cxxGc.column = std.string(gc.propertyName)
            cxxGc.center_lat = gc.centerLat
            cxxGc.center_lon = gc.centerLon
            cxxGc.radius_meters = gc.radiusMeters
            cxxGeos.push_back(cxxGc)
        }

        var cxxTexts = lattice.TextConstraintVector()
        for tc in texts {
            var cxxTc = lattice.text_constraint()
            cxxTc.column = std.string(tc.propertyName)
            cxxTc.search_text = std.string(tc.searchText)
            cxxTc.limit = Int32(tc.limit)
            cxxTexts.push_back(cxxTc)
        }

        // Build where clause
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        // Build sort descriptor
        var cxxSort = lattice.sort_descriptor()
        if let sort = sortStatement {
            switch sort.descriptor {
            case .keyPath(let propName):
                cxxSort.type = .property
                cxxSort.column = std.string(propName)
            case .geoDistance:
                cxxSort.type = .geo_distance
                cxxSort.column = std.string(geos.first?.propertyName ?? "")
            case .vectorDistance:
                cxxSort.type = .vector_distance
                cxxSort.column = std.string(vectors.first?.propertyName ?? "")
            case .textRank:
                cxxSort.type = .text_rank
                cxxSort.column = std.string(texts.first?.propertyName ?? "")
            }
            cxxSort.ascending = (sort.order == .forward)
        }

        // Calculate effective limit from constraints (not endIndex to avoid recursion)
        let vectorLimit = vectors.map(\.k).min() ?? Int.max
        let geoLimit = geos.map(\.limit).min() ?? Int.max
        let textLimit = texts.map(\.limit).min() ?? Int.max
        let constraintLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        let effectiveOffset = offset.map { Int($0) } ?? 0
        let effectiveLimit = limit.map { Int($0) } ?? constraintLimit
        let fetchLimit = Int64(Swift.min(effectiveOffset + effectiveLimit, constraintLimit))

        // Build group by
        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else {
            .init()
        }

        // Call combined C++ query
        let cxxResults = _lattice.cxxLattice.combinedNearestQuery(
            table: tableName,
            bounds: cxxBounds,
            vectors: cxxVectors,
            geos: cxxGeos,
            texts: cxxTexts,
            where: whereClause,
            sort: cxxSort,
            limit: fetchLimit,
            groupBy: groupByOpt
        )

        // Convert results
        var results: [_NearestMatch<T>] = []
        let startIdx = effectiveOffset
        let endIdx = Swift.min(Int(cxxResults.size()), effectiveOffset + effectiveLimit)
        results.reserveCapacity(Swift.max(0, endIdx - startIdx))

        // Build lookup for geo units (handle multiple constraints on same column)
        let geoUnits: [String: DistanceUnit] = Dictionary(
            geos.map { ($0.propertyName, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )

        for i in startIdx..<endIdx {
            let result = cxxResults[i]
            let managedObj = result.object

            // Extract distances from the vector
            var distances: [String: Double] = [:]
            for j in 0..<result.distances.size() {
                let entry = result.distances[j]
                let columnName = String(entry.column)
                let distanceValue = entry.distance

                // Convert geo distances from meters to requested unit
                if let unit = geoUnits[columnName] {
                    distances[columnName] = unit.fromMeters(distanceValue)
                } else {
                    distances[columnName] = distanceValue
                }
            }

            let swiftObj = T(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
            results.append(_NearestMatch(object: swiftObj, distances: distances))
        }

        return results
    }

    // MARK: - Results Protocol: nearest/withinBounds (Element = NearestMatch<T>)
    // These are required by protocol but not practically useful since NearestMatch doesn't have geo/vector properties.
    // The useful versions that take KeyPath<T, ...> are defined above.

    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<_NearestMatch<T>, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self {
        // NearestMatch doesn't have GeoboundsProperty, so this is never called
        let object = T.init(isolation: #isolation)
        let match = _NearestMatch(object: object, distance: 0)
        _ = match[keyPath: keyPath]
        guard let keyPath = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = BoundsConstraint(keyPath: keyPath, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        return Self(lattice: _lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, proximity: self.proximity, groupByColumn: groupByColumn)
    }

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        limit k: Int,
        distance metric: DistanceMetric
    ) -> any NearestResults<T> {
        let object = T.init(isolation: #isolation)
        let match = _NearestMatch(object: object, distance: 0)
        _ = object[keyPath: keyPath]
        guard let keyPath = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = VectorConstraint(keyPath: keyPath, queryVector: queryVector, k: k, metric: metric)
        return Self(lattice: _lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: self.boundsConstraint,
                    proximity: .conjunction(self.proximity, .vector(constraint)), groupByColumn: groupByColumn)
    }

    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<T> {
        let object = T.init(isolation: #isolation)
        let match = _NearestMatch(object: object, distance: 0)
        _ = object[keyPath: keyPath]
        guard let keyPath = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = GeoNearestConstraint(
            keyPath: keyPath,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )
        let combined = ProximityType.conjunction(proximity, .geo(constraint))
        return Self(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: combined,
            groupByColumn: groupByColumn
        )
    }

    /// Chain a full-text search onto existing proximity constraints (hybrid search).
    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        matching(.raw(searchText), on: keyPath, limit: limit)
    }

    /// Chain a type-safe full-text search onto existing proximity constraints (hybrid search).
    public func matching(
        _ query: TextQuery,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        let constraint = TextConstraint(keyPath: keyPath, query: query, limit: limit)
        return Self(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: .conjunction(self.proximity, .text(constraint)),
            groupByColumn: groupByColumn
        )
    }
}

package struct _VirtualNearestResults<each M: Model, T>: NearestResults {
    public typealias Element = _NearestMatch<T>
    public typealias QueryType = Query<_NearestMatch<T>>
    public typealias NearestMatchType = _NearestMatch<T>
    public typealias UnderlyingElement = T

    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: RawNearestSortDescriptor?
    internal let boundsConstraint: BoundsConstraint?
    internal let proximity: ProximityType
    internal let groupByColumn: String?

    init(lattice: Lattice,
         whereStatement: Query<Bool>? = nil,
         sortStatement: RawNearestSortDescriptor? = nil,
         boundsConstraint: BoundsConstraint? = nil,
         proximity: ProximityType,
         groupByColumn: String? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.proximity = proximity
        self.groupByColumn = groupByColumn
    }
    
    private var firstType: any Model.Type {
        for t in repeat (each M).self {
            return t
        }
        fatalError()
    }

    // MARK: - Chainable Methods

    /// Filter results by properties on the object or by distance.
    ///
    /// Example:
    /// ```swift
    /// .where { $0.distance < 0.5 }  // filter by distance
    /// .where { $0.rating > 4.0 }    // filter by object property (via dynamic member)
    /// ```
    public func `where`(_ predicate: (Query<Element>) -> Query<Bool>) -> Self {
        let newWhere = predicate(Query())
        let combined: Query<Bool>? = if let existing = whereStatement {
            existing && newWhere
        } else {
            newWhere
        }
        return Self(
            lattice: _lattice,
            whereStatement: combined,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: proximity,
            groupByColumn: groupByColumn
        )
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let columnName = object._lastKeyPathUsed else {
            preconditionFailure("Could not resolve keyPath to column name")
        }
        return Self(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: proximity,
            groupByColumn: columnName
        )
    }

    // MARK: - Results Protocol Conformance

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self {
        // NearestResults are sorted by distance from the proximity query
        // Additional sorting would require storing and applying a sort descriptor
        // For now, return self (proximity results are pre-sorted by distance)
        let object = firstType.init(isolation: #isolation) as! T
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: sortDescriptor.keyPath!]
        guard let keyPath = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        return .init(lattice: self._lattice,
                     whereStatement: whereStatement,
                     sortStatement: .init(descriptor: .keyPath(keyPath),
                                          order: sortDescriptor.order),
                     boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
    }

    public func sortedBy(_ sortDescriptor: NearestSortDescriptor<Element>) -> Self {
        switch sortDescriptor {
        case .geoDistance(let sortOrder):
            return .init(lattice: self._lattice,
                         whereStatement: whereStatement,
                         sortStatement: .init(descriptor: .geoDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
        case .vectorDistance(let sortOrder):
            return .init(lattice: self._lattice,
                         whereStatement: whereStatement,
                         sortStatement: .init(descriptor: .vectorDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
        case .textRank(let sortOrder):
            return .init(lattice: self._lattice,
                         whereStatement: whereStatement,
                         sortStatement: .init(descriptor: .textRank, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn)
        }
    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        var cancellables: [AnyCancellable] = []
        for type in repeat (each M).self {
            cancellables.append(_lattice.observe(type.self, where: self.whereStatement) { change in
                observer(change)
            })
        }
        return AnyCancellable {
            cancellables.forEach { $0.cancel() }
        }
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        // For proximity queries, we need to execute the query to get actual count
        // This is necessary because WHERE clauses can filter results below the limit
        let (vectors, geos, texts) = flattenProximity(proximity)
        let vectorLimit = vectors.map(\.k).min() ?? Int.max
        let geoLimit = geos.map(\.limit).min() ?? Int.max
        let textLimit = texts.map(\.limit).min() ?? Int.max
        let maxLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        // Execute snapshot to get actual count (capped at maxLimit)
        return Swift.min(snapshot(limit: Int64(maxLimit), offset: nil).count, maxLimit)
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    // MARK: - Execution

    /// Flatten the proximity tree into arrays for C++ API
    private func flattenProximity(_ p: ProximityType) -> (vectors: [VectorConstraint], geos: [GeoNearestConstraint], texts: [TextConstraint]) {
        switch p {
        case .vector(let v):
            return ([v], [], [])
        case .geo(let g):
            return ([], [g], [])
        case .text(let t):
            return ([], [], [t])
        case .conjunction(let left, let right):
            let (lv, lg, lt) = flattenProximity(left)
            let (rv, rg, rt) = flattenProximity(right)
            return (lv + rv, lg + rg, lt + rt)
        }
    }

    /// Execute the query and return results with distances.
    /// Queries each model type and merges results.
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [_NearestMatch<T>] {
        let (vectors, geos, texts) = flattenProximity(proximity)

        // Build C++ constraint vectors (shared across all types)
        var cxxBounds = lattice.BoundsConstraintVector()
        if let bounds = boundsConstraint {
            var bc = lattice.bounds_constraint()
            bc.column = std.string(bounds.propertyName)
            bc.min_lat = bounds.minLat
            bc.max_lat = bounds.maxLat
            bc.min_lon = bounds.minLon
            bc.max_lon = bounds.maxLon
            cxxBounds.push_back(bc)
        }

        var cxxVectors = lattice.VectorConstraintVector()
        for vc in vectors {
            var cxxVc = lattice.vector_constraint()
            cxxVc.column = std.string(vc.propertyName)
            var byteVec = lattice.ByteVector()
            for byte in vc.queryVector {
                byteVec.push_back(byte)
            }
            cxxVc.query_vector = byteVec
            cxxVc.k = Int32(vc.k)
            cxxVc.metric = vc.metric.rawValue
            cxxVectors.push_back(cxxVc)
        }

        var cxxGeos = lattice.GeoConstraintVector()
        for gc in geos {
            var cxxGc = lattice.geo_constraint()
            cxxGc.column = std.string(gc.propertyName)
            cxxGc.center_lat = gc.centerLat
            cxxGc.center_lon = gc.centerLon
            cxxGc.radius_meters = gc.radiusMeters
            cxxGeos.push_back(cxxGc)
        }

        var cxxTexts = lattice.TextConstraintVector()
        for tc in texts {
            var cxxTc = lattice.text_constraint()
            cxxTc.column = std.string(tc.propertyName)
            cxxTc.search_text = std.string(tc.searchText)
            cxxTc.limit = Int32(tc.limit)
            cxxTexts.push_back(cxxTc)
        }

        // Build where clause
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        // Build sort descriptor
        var cxxSort = lattice.sort_descriptor()
        if let sort = sortStatement {
            switch sort.descriptor {
            case .keyPath(let propName):
                cxxSort.type = .property
                cxxSort.column = std.string(propName)
            case .geoDistance:
                cxxSort.type = .geo_distance
                cxxSort.column = std.string(geos.first?.propertyName ?? "")
            case .vectorDistance:
                cxxSort.type = .vector_distance
                cxxSort.column = std.string(vectors.first?.propertyName ?? "")
            case .textRank:
                cxxSort.type = .text_rank
                cxxSort.column = std.string(texts.first?.propertyName ?? "")
            }
            cxxSort.ascending = (sort.order == .forward)
        }

        // Calculate effective limit from constraints (not endIndex to avoid recursion)
        let vectorLimit = vectors.map(\.k).min() ?? Int.max
        let geoLimit = geos.map(\.limit).min() ?? Int.max
        let textLimit = texts.map(\.limit).min() ?? Int.max
        let constraintLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        let effectiveOffset = offset.map { Int($0) } ?? 0
        let effectiveLimit = limit.map { Int($0) } ?? constraintLimit
        let fetchLimit = Int64(Swift.min(effectiveOffset + effectiveLimit, constraintLimit))

        // Build lookup for geo units (handle multiple constraints on same column)
        let geoUnits: [String: DistanceUnit] = Dictionary(
            geos.map { ($0.propertyName, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )

        // Build group by
        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else {
            .init()
        }

        // Query each model type and collect results
        var allResults: [_NearestMatch<T>] = []

        for type in repeat (each M).self {
            let tableName = std.string(type.entityName)

            let cxxResults = _lattice.cxxLattice.combinedNearestQuery(
                table: tableName,
                bounds: cxxBounds,
                vectors: cxxVectors,
                geos: cxxGeos,
                texts: cxxTexts,
                where: whereClause,
                sort: cxxSort,
                limit: fetchLimit,
                groupBy: groupByOpt
            )

            for i in 0..<Int(cxxResults.size()) {
                let result = cxxResults[i]
                let managedObj = result.object

                // Extract distances from the vector
                var distances: [String: Double] = [:]
                for j in 0..<result.distances.size() {
                    let entry = result.distances[j]
                    let columnName = String(entry.column)
                    let distanceValue = entry.distance

                    // Convert geo distances from meters to requested unit
                    if let unit = geoUnits[columnName] {
                        distances[columnName] = unit.fromMeters(distanceValue)
                    } else {
                        distances[columnName] = distanceValue
                    }
                }

                let swiftObj = type.init(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
                allResults.append(_NearestMatch(object: swiftObj as! T, distances: distances))
            }
        }

        // Sort merged results by primary distance
        allResults.sort { $0.distance < $1.distance }

        // Apply offset and limit after merging
        let startIdx = effectiveOffset
        let endIdx = Swift.min(allResults.count, effectiveOffset + effectiveLimit)
        guard startIdx < allResults.count else { return [] }

        return Array(allResults[startIdx..<endIdx])
    }

    // MARK: - Results Protocol: nearest/withinBounds (Element = NearestMatch<T>)
    // These are required by protocol but not practically useful since NearestMatch doesn't have geo/vector properties.
    // The useful versions that take KeyPath<T, ...> are defined above.

    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<_NearestMatch<T>, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self {
        // NearestMatch doesn't have GeoboundsProperty, so this is never called
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let keyPath = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = BoundsConstraint(keyPath: keyPath, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        return Self(lattice: _lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, proximity: self.proximity, groupByColumn: groupByColumn)
    }

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        limit k: Int,
        distance metric: DistanceMetric
    ) -> any NearestResults<UnderlyingElement> {
        let object = firstType.init(isolation: #isolation) as! T
        let match = _NearestMatch<T>(object: object as! T, distance: 0)
        _ = object[keyPath: keyPath]
        guard let keyPath = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = VectorConstraint(keyPath: keyPath, queryVector: queryVector, k: k, metric: metric)
        return Self(lattice: _lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: self.boundsConstraint,
                    proximity: .conjunction(self.proximity, .vector(constraint)), groupByColumn: groupByColumn)
    }

    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<T> {
        let object = firstType.init(isolation: #isolation) as! T
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = object[keyPath: keyPath]
        guard let keyPath = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = GeoNearestConstraint(
            keyPath: keyPath,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )
        let combined = ProximityType.conjunction(proximity, .geo(constraint))
        return Self(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: combined,
            groupByColumn: groupByColumn
        )
    }

    /// Chain a full-text search onto existing proximity constraints (hybrid search).
    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        matching(.raw(searchText), on: keyPath, limit: limit)
    }

    /// Chain a type-safe full-text search onto existing proximity constraints (hybrid search).
    public func matching(
        _ query: TextQuery,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        let object = firstType.init(isolation: #isolation)
        guard let virtualObj = object as? T else {
            preconditionFailure()
        }
        _ = virtualObj[keyPath: keyPath]
        guard let propertyName = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = TextConstraint(propertyName: propertyName, query: query, limit: limit)
        return Self(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: .conjunction(self.proximity, .text(constraint)),
            groupByColumn: groupByColumn
        )
    }
}
// MARK: - Query Extension for NearestMatch
//
//extension Query where T: Sendable {
//    /// Access the distance property on NearestMatch queries
//    public var distance: Query<Double> {
//        Query<Double>(.keyPath(["distance"], options: []), isAuditing: isAuditing)
//    }
//}
