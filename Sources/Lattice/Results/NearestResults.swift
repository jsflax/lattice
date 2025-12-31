import Foundation
import LatticeSwiftCppBridge
import Combine

// MARK: - Constraint Types

/// Bounding box constraint for spatial filtering (R*Tree)
public struct BoundsConstraint: Sendable {
    let propertyName: String
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    init<G: GeoboundsProperty>(keyPath: AnyKeyPath, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.propertyName = _name(for: keyPath)
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }
}

/// Vector similarity constraint (vec0)
public struct VectorConstraint: Sendable {
    let propertyName: String
    let queryVector: Data
    let k: Int
    let metric: DistanceMetric

    init<V: VectorElement>(keyPath: AnyKeyPath, queryVector: Vector<V>, k: Int, metric: DistanceMetric) {
        self.propertyName = _name(for: keyPath)
        self.queryVector = queryVector.toData()
        self.k = k
        self.metric = metric
    }
}

/// Geographic proximity constraint (R*Tree + Haversine)
public struct GeoNearestConstraint: Sendable {
    let propertyName: String
    let centerLat: Double
    let centerLon: Double
    let radiusMeters: Double
    let limit: Int
    let sortByDistance: Bool
    let unit: DistanceUnit

    init<G: GeoboundsProperty>(keyPath: AnyKeyPath, center: (lat: Double, lon: Double),
                                maxDistance: Double, unit: DistanceUnit, limit: Int, sortByDistance: Bool) {
        self.propertyName = _name(for: keyPath)
        self.centerLat = center.lat
        self.centerLon = center.lon
        self.radiusMeters = maxDistance * unit.toMeters
        self.limit = limit
        self.sortByDistance = sortByDistance
        self.unit = unit
    }
}

/// Represents the type of proximity search being performed
public enum ProximityType: Sendable {
    case vector(VectorConstraint)
    case geo(GeoNearestConstraint)
}

// MARK: - NearestMatch with Dynamic Member Lookup

/// Result from a nearest neighbor query, containing the object and its distance
@dynamicMemberLookup
public struct NearestMatch<Element>: Sendable where Element: Sendable {
    public let object: Element
    public let distance: Double

    public init(object: Element, distance: Double) {
        self.object = object
        self.distance = distance
    }

    /// Access properties on the underlying object directly
    public subscript<V>(dynamicMember keyPath: KeyPath<Element, V>) -> V {
        object[keyPath: keyPath]
    }
}

// MARK: - NearestResults

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
public final class NearestResults<T: Model>: Sequence {

    // Base constraints inherited from TableResults
    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<T>?
    internal let boundsConstraint: BoundsConstraint?

    // The proximity constraint that produces distances
    internal let proximity: ProximityType

    // Previous stage results (for chained nearest calls)
    // When set, we filter from these IDs rather than the full table
    internal let previousStageGlobalIds: [String]?

    // Post-proximity where clause (filters on NearestMatch, including distance)
    internal let postProximityWhere: ((Query<NearestMatch<T>>) -> Query<Bool>)?

    init(lattice: Lattice,
         whereStatement: Query<Bool>? = nil,
         sortStatement: SortDescriptor<T>? = nil,
         boundsConstraint: BoundsConstraint? = nil,
         proximity: ProximityType,
         previousStageGlobalIds: [String]? = nil,
         postProximityWhere: ((Query<NearestMatch<T>>) -> Query<Bool>)? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.proximity = proximity
        self.previousStageGlobalIds = previousStageGlobalIds
        self.postProximityWhere = postProximityWhere
    }

    // MARK: - Chainable Methods

    /// Filter results by properties on the object or by distance.
    ///
    /// Example:
    /// ```swift
    /// .where { $0.distance < 0.5 }  // filter by distance
    /// .where { $0.rating > 4.0 }    // filter by object property (via dynamic member)
    /// ```
    public func `where`(_ predicate: @escaping (Query<NearestMatch<T>>) -> Query<Bool>) -> NearestResults<T> {
        // Combine with existing post-proximity where if present
        let combined: ((Query<NearestMatch<T>>) -> Query<Bool>)? = if let existing = postProximityWhere {
            { query in existing(query) && predicate(query) }
        } else {
            predicate
        }

        return NearestResults(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: boundsConstraint,
            proximity: proximity,
            previousStageGlobalIds: previousStageGlobalIds,
            postProximityWhere: combined
        )
    }

    /// Add a bounding box spatial filter.
    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<T, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> NearestResults<T> {
        let constraint = BoundsConstraint(
            keyPath: keyPath,
            minLat: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: maxLon
        )
        return NearestResults(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement,
            boundsConstraint: constraint,
            proximity: proximity,
            previousStageGlobalIds: previousStageGlobalIds,
            postProximityWhere: postProximityWhere
        )
    }

    /// Chain another vector similarity search.
    /// The current results are filtered/materialized, then vector search is performed on that subset.
    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<T, Vector<V>>,
        limit k: Int = 10,
        distance metric: DistanceMetric = .l2
    ) -> NearestResults<T> {
        // Materialize current results to get the globalIds we'll search within
        let currentResults = snapshot()
        let globalIds = currentResults.compactMap { $0.object.globalId }

        let constraint = VectorConstraint(keyPath: keyPath, queryVector: queryVector, k: k, metric: metric)

        return NearestResults(
            lattice: _lattice,
            whereStatement: nil,  // Previous filters already applied
            sortStatement: nil,
            boundsConstraint: nil,
            proximity: .vector(constraint),
            previousStageGlobalIds: globalIds,
            postProximityWhere: nil
        )
    }

    /// Chain another geographic proximity search.
    /// The current results are filtered/materialized, then geo search is performed on that subset.
    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<T, G>,
        maxDistance: Double,
        unit: DistanceUnit = .meters,
        limit: Int = 100,
        sortedByDistance: Bool = true
    ) -> NearestResults<T> {
        // Materialize current results to get the globalIds we'll search within
        let currentResults = snapshot()
        let globalIds = currentResults.compactMap { $0.object.globalId }

        let constraint = GeoNearestConstraint(
            keyPath: keyPath,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )

        return NearestResults(
            lattice: _lattice,
            whereStatement: nil,
            sortStatement: nil,
            boundsConstraint: nil,
            proximity: .geo(constraint),
            previousStageGlobalIds: globalIds,
            postProximityWhere: nil
        )
    }

    // MARK: - Execution

    /// Execute the query and return results with distances.
    public func snapshot() -> [NearestMatch<T>] {
        var results: [NearestMatch<T>]

        switch proximity {
        case .vector(let constraint):
            results = executeVectorQuery(constraint)
        case .geo(let constraint):
            results = executeGeoQuery(constraint)
        }

        // Apply post-proximity where filter if present
        if let filter = postProximityWhere {
            results = results.filter { match in
                // Build a query and evaluate it
                // For now, we'll need to evaluate the predicate
                // This requires extending Query to support NearestMatch evaluation
                evaluateNearestMatchPredicate(filter, on: match)
            }
        }

        return results
    }

    private func executeVectorQuery(_ constraint: VectorConstraint) -> [NearestMatch<T>] {
        let tableName = std.string(T.entityName)

        var byteVec = lattice.ByteVector()
        for byte in constraint.queryVector {
            byteVec.push_back(byte)
        }

        // Build where clause combining base where + bounds + previousStageGlobalIds
        let whereClause = buildCombinedWhereClause()

        let cxxResults = _lattice.cxxLattice.nearest_neighbors(
            tableName,
            std.string(constraint.propertyName),
            byteVec,
            Int32(constraint.k),
            constraint.metric.rawValue,
            whereClause
        )

        var results: [NearestMatch<T>] = []
        results.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let pair = cxxResults[i]
            var managedObj = pair.first
            let distance = pair.second

            let swiftObj = T(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
            results.append(NearestMatch(object: swiftObj, distance: distance))
        }

        return results
    }

    private func executeGeoQuery(_ constraint: GeoNearestConstraint) -> [NearestMatch<T>] {
        let tableName = std.string(T.entityName)

        let whereClause = buildCombinedWhereClause()

        let cxxResults = _lattice.cxxLattice.geoNearest(
            table: tableName,
            geoColumn: std.string(constraint.propertyName),
            lat: constraint.centerLat,
            lon: constraint.centerLon,
            radius: constraint.radiusMeters,
            limit: Int32(constraint.limit),
            sortByDistance: constraint.sortByDistance,
            where: whereClause
        )

        var results: [NearestMatch<T>] = []
        results.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let pair = cxxResults[i]
            var managedObj = pair.first
            let distanceMeters = pair.second

            let swiftObj = T(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
            let distanceInUnit = constraint.unit.fromMeters(distanceMeters)
            results.append(NearestMatch(object: swiftObj, distance: distanceInUnit))
        }

        return results
    }

    private func buildCombinedWhereClause() -> lattice.OptionalString {
        var clauses: [String] = []

        // Base where clause
        if let whereStatement {
            clauses.append("(\(whereStatement.predicate))")
        }

        // Previous stage globalIds filter
        if let globalIds = previousStageGlobalIds, !globalIds.isEmpty {
            let quoted = globalIds.map { "'\($0)'" }.joined(separator: ", ")
            clauses.append("globalId IN (\(quoted))")
        }

        // Note: boundsConstraint is handled differently - it's passed to the C++ layer
        // which does the R*Tree join. For now we'll handle it in a future C++ update.
        // TODO: Pass boundsConstraint to C++ combined query

        if clauses.isEmpty {
            return .init()
        } else {
            return lattice.string_to_optional(std.string(clauses.joined(separator: " AND ")))
        }
    }

    private func evaluateNearestMatchPredicate(_ predicate: (Query<NearestMatch<T>>) -> Query<Bool>,
                                                on match: NearestMatch<T>) -> Bool {
        // Build the query to get the predicate string
        let query = predicate(Query<NearestMatch<T>>())
        let predicateString = query.predicate

        // For distance comparisons, we need to evaluate them directly
        // This is a simplified evaluation - a full implementation would parse the predicate
        // For now, we'll check for common patterns

        // Check if it's a simple distance comparison
        if predicateString.contains("distance") {
            // Parse simple comparisons like "distance < 0.5"
            if let range = predicateString.range(of: #"distance\s*([<>=!]+)\s*([\d.]+)"#, options: .regularExpression) {
                let matchStr = String(predicateString[range])
                // Extract operator and value
                let components = matchStr.components(separatedBy: CharacterSet(charactersIn: "<>=!"))
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

                if let valueStr = components.last?.trimmingCharacters(in: .whitespaces),
                   let value = Double(valueStr) {
                    if matchStr.contains("<=") {
                        return match.distance <= value
                    } else if matchStr.contains(">=") {
                        return match.distance >= value
                    } else if matchStr.contains("<") {
                        return match.distance < value
                    } else if matchStr.contains(">") {
                        return match.distance > value
                    } else if matchStr.contains("==") {
                        return match.distance == value
                    } else if matchStr.contains("!=") {
                        return match.distance != value
                    }
                }
            }
        }

        // For non-distance predicates, we'd need to evaluate against the object
        // This requires more sophisticated predicate parsing
        // For now, return true (no filtering)
        return true
    }

    // MARK: - Sequence Conformance

    public struct Iterator: IteratorProtocol {
        private var results: [NearestMatch<T>]
        private var index: Int = 0

        init(_ results: NearestResults<T>) {
            self.results = results.snapshot()
        }

        public mutating func next() -> NearestMatch<T>? {
            guard index < results.count else { return nil }
            defer { index += 1 }
            return results[index]
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(self)
    }
}

// MARK: - Query Extension for NearestMatch

extension Query where T: Sendable {
    /// Access the distance property on NearestMatch queries
    public var distance: Query<Double> {
        Query<Double>(.keyPath(["distance"], options: []), isAuditing: isAuditing)
    }
}
