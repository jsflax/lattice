import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge

// iOS 15 (pre-variadic-generics) equivalent of `_VirtualNearestResults<each M, T>`.
// The model types are carried as a runtime array; the two `for type in
// repeat (each M).self` loops (count + execution) become `for type in modelTypes`.
// Everything else — the C++ constraint-vector building — is byte-for-byte the
// gated pack type's logic. Bodies still call `cxxLattice` (iOS 16.4); Phase 2
// boxes that behind the backend protocol, at which point this compiles at iOS 15.
package struct _VirtualNearestResultsCompat<T>: NearestResults {
    public typealias Element = _NearestMatch<T>
    public typealias QueryType = Query<_NearestMatch<T>>
    public typealias NearestMatchType = _NearestMatch<T>
    public typealias UnderlyingElement = T

    private let _lattice: Lattice
    let modelTypes: [any Model.Type]
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: RawNearestSortDescriptor?
    internal let boundsConstraint: BoundsConstraint?
    internal let proximity: ProximityType
    internal let groupByColumn: String?
    internal let distinctByColumn: String?

    init(lattice: Lattice,
         modelTypes: [any Model.Type],
         whereStatement: Query<Bool>? = nil,
         sortStatement: RawNearestSortDescriptor? = nil,
         boundsConstraint: BoundsConstraint? = nil,
         proximity: ProximityType,
         groupByColumn: String? = nil,
         distinctByColumn: String? = nil) {
        self._lattice = lattice
        self.modelTypes = modelTypes
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.proximity = proximity
        self.groupByColumn = groupByColumn
        self.distinctByColumn = distinctByColumn
    }

    private var firstType: any Model.Type {
        guard let t = modelTypes.first else { preconditionFailure("virtual nearest with no model types") }
        return t
    }

    // MARK: - Chainable Methods

    public func `where`(_ predicate: (Query<Element>) -> Query<Bool>) -> Self {
        let newWhere = predicate(Query())
        let combined: Query<Bool>? = if let existing = whereStatement {
            existing && newWhere
        } else {
            newWhere
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: combined, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let columnName = object._lastKeyPathUsed else {
            preconditionFailure("Could not resolve keyPath to column name")
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: columnName, distinctByColumn: distinctByColumn)
    }

    public func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let columnName = object._lastKeyPathUsed else {
            preconditionFailure("Could not resolve keyPath to column name")
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: columnName)
    }

    // MARK: - Results Protocol Conformance

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self {
        _sorted(by: sortDescriptor.keyPath!, order: sortDescriptor.order)
    }

    public func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder = .forward) -> Self {
        _sorted(by: keyPath, order: order)
    }

    private func _sorted(by keyPath: PartialKeyPath<Element>, order: SortOrder) -> Self {
        let object = firstType.init(isolation: #isolation) as! T
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let column = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .keyPath(column), order: order), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func sortedBy(_ sortDescriptor: NearestSortDescriptor<Element>) -> Self {
        switch sortDescriptor {
        case .geoDistance(let sortOrder):
            return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .geoDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        case .vectorDistance(let sortOrder):
            return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .vectorDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        case .textRank(let sortOrder):
            return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .textRank, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        }
    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        var cancellables: [AnyCancellable] = []
        for type in modelTypes {
            cancellables.append(_lattice.observe(type, where: self.whereStatement) { change in
                observer(change)
            })
        }
        return AnyCancellable {
            cancellables.forEach { $0.cancel() }
        }
    }

    public var startIndex: Int { 0 }
    public var count: Int { endIndex }

    private func flattenProximity(_ p: ProximityType) -> (vectors: [VectorConstraint], geos: [GeoNearestConstraint], texts: [TextConstraint]) {
        switch p {
        case .vector(let v): return ([v], [], [])
        case .geo(let g): return ([], [g], [])
        case .text(let t): return ([], [], [t])
        case .conjunction(let left, let right):
            let (lv, lg, lt) = flattenProximity(left)
            let (rv, rg, rt) = flattenProximity(right)
            return (lv + rv, lg + rg, lt + rt)
        }
    }

    /// Builds the neutral constraint params shared by `endIndex` and `snapshot`.
    private func buildConstraints() -> (bounds: [BoundsConstraintParam], vectors: [VectorConstraintParam], geos: [GeoConstraintParam], texts: [TextConstraintParam], sort: SortDescriptorParam, flatVectors: [VectorConstraint], flatGeos: [GeoNearestConstraint], flatTexts: [TextConstraint]) {
        let (vectors, geos, texts) = flattenProximity(proximity)

        var cb: [BoundsConstraintParam] = []
        if let bounds = boundsConstraint {
            cb.append(BoundsConstraintParam(column: bounds.propertyName, minLat: bounds.minLat, maxLat: bounds.maxLat, minLon: bounds.minLon, maxLon: bounds.maxLon))
        }
        let cv = vectors.map { VectorConstraintParam(column: $0.propertyName, queryVector: Array($0.queryVector), k: Int32($0.k), metric: Int32($0.metric.rawValue)) }
        let cg = geos.map { GeoConstraintParam(column: $0.propertyName, centerLat: $0.centerLat, centerLon: $0.centerLon, radiusMeters: $0.radiusMeters) }
        let ct = texts.map { TextConstraintParam(column: $0.propertyName, searchText: $0.searchText, limit: Int32($0.limit)) }

        var cs = SortDescriptorParam(kind: .none, column: "", ascending: true)
        if let sort = sortStatement {
            let kind: SortKind
            let column: String
            switch sort.descriptor {
            case .keyPath(let propName): kind = .property; column = propName
            case .geoDistance: kind = .geoDistance; column = geos.first?.propertyName ?? ""
            case .vectorDistance: kind = .vectorDistance; column = vectors.first?.propertyName ?? ""
            case .textRank: kind = .textRank; column = texts.first?.propertyName ?? ""
            }
            cs = SortDescriptorParam(kind: kind, column: column, ascending: sort.order == .forward)
        }
        return (cb, cv, cg, ct, cs, vectors, geos, texts)
    }

    public var endIndex: Int {
        let c = buildConstraints()
        let vectorLimit = c.flatVectors.map(\.k).min() ?? Int.max
        let geoLimit = c.flatGeos.map(\.limit).min() ?? Int.max
        let textLimit = c.flatTexts.map(\.limit).min() ?? Int.max
        let maxLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        var total = 0
        for type in modelTypes {
            total += Int(_lattice.backend.combinedNearestQueryCount(table: type.entityName, bounds: c.bounds, vectors: c.vectors, geos: c.geos, texts: c.texts, where: whereStatement?.predicate, sort: c.sort, limit: Int64(maxLimit), groupBy: groupByColumn, distinctBy: distinctByColumn))
        }
        return Swift.min(total, maxLimit)
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [_NearestMatch<T>] {
        let c = buildConstraints()

        let vectorLimit = c.flatVectors.map(\.k).min() ?? Int.max
        let geoLimit = c.flatGeos.map(\.limit).min() ?? Int.max
        let textLimit = c.flatTexts.map(\.limit).min() ?? Int.max
        let constraintLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        let effectiveOffset = offset.map { Int($0) } ?? 0
        let effectiveLimit = limit.map { Int($0) } ?? constraintLimit
        let fetchLimit = Int64(Swift.min(effectiveOffset + effectiveLimit, constraintLimit))

        let geoUnits: [String: DistanceUnit] = Dictionary(
            c.flatGeos.map { ($0.propertyName, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )

        var allResults: [_NearestMatch<T>] = []

        for type in modelTypes {
            let rows = _lattice.backend.combinedNearestQuery(table: type.entityName, bounds: c.bounds, vectors: c.vectors, geos: c.geos, texts: c.texts, where: whereStatement?.predicate, sort: c.sort, limit: fetchLimit, groupBy: groupByColumn, distinctBy: distinctByColumn)
            for row in rows {
                var distances: [String: Double] = [:]
                for entry in row.distances {
                    if let unit = geoUnits[entry.column] {
                        distances[entry.column] = unit.fromMeters(entry.distance)
                    } else {
                        distances[entry.column] = entry.distance
                    }
                }
                allResults.append(_NearestMatch(object: type.init(dynamicObject: row.object) as! T, distances: distances))
            }
        }

        allResults.sort { $0.distance < $1.distance }

        let startIdx = effectiveOffset
        let endIdx = Swift.min(allResults.count, effectiveOffset + effectiveLimit)
        guard startIdx < allResults.count else { return [] }
        return Array(allResults[startIdx..<endIdx])
    }

    // MARK: - Results Protocol: nearest/withinBounds chaining (hybrid search)

    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<_NearestMatch<T>, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let keyPath = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = BoundsConstraint(keyPath: keyPath, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, proximity: self.proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        limit k: Int,
        distance metric: DistanceMetric
    ) -> any NearestResults<UnderlyingElement> {
        let object = firstType.init(isolation: #isolation) as! T
        _ = object[keyPath: keyPath]
        guard let keyPath = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = VectorConstraint(keyPath: keyPath, queryVector: queryVector, k: k, metric: metric)
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: self.boundsConstraint,
                    proximity: .conjunction(self.proximity, .vector(constraint)), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
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
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint,
                    proximity: .conjunction(proximity, .geo(constraint)), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        matching(.raw(searchText), on: keyPath, limit: limit)
    }

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
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint,
                    proximity: .conjunction(self.proximity, .text(constraint)), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }
}
